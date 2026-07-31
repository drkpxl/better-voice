import AVFoundation
import Foundation
import FluidAudio
import BetterVoiceCore

/// Parakeet TDT v3: the app's speech engine.
///
/// Owns one `AsrManager` for the process lifetime, mirroring the intent of the Apple path's
/// `modelRetention: .processLifetime`, and single-flights preparation the way
/// `OfflineDiarizerHost.preparedBox` does (`OfflineDiarizerHost.swift:60-72`).
///
/// It does **not** copy that file's `@unchecked Sendable` box, `nonisolated static` helpers, or
/// confinement apparatus, which the migration plan suggested. All of that exists because
/// `OfflineDiarizerManager` is not `Sendable`. `AsrManager` is a `public actor`, so it confines
/// itself and can simply be stored — the boxing would have been ceremony with no purpose.
///
/// This type is still an `actor`, for two reasons that survive that simplification: the single-flight
/// `preparing` state needs serialized access, and `transcriptionProgressStream` is documented
/// single-session, so two concurrent `transcribe` calls would interleave ticks from different files
/// onto one stream.
///
/// **v3 with default settings**, decided by measurement rather than preference. See
/// `bench/results/2026-07-30-phase0-findings.md`: v3 leads v2 by 2.5 WER points on the dictation
/// fixture (25.3% vs 27.8%), and the documented `melChunkContext: false` workaround for its
/// chunk-boundary dropout costs 2.0 points while being dominated by v2 outright. The dropout is real —
/// it silently loses roughly 0.5% of content at chunk seams — and was accepted for the accuracy.
/// `dualDecodeArbitration` was measured and produces byte-identical output, so it is not a fallback.
///
/// There was a `Transcriber` protocol and a `TranscriberFactory` in front of this, built so the
/// bake-off could A/B Apple's `SpeechTranscriber` against Parakeet through the same call sites. The
/// A/B concluded and Apple was deleted, leaving a protocol with one conformer, a factory with one
/// product, a `unload()` default written for "an engine whose models the system manages" that no
/// longer existed, and an `init(transcriber:)` on `ImportPipeline` documented as "injectable so the
/// bench can pin an engine" that the bench never used. All of it is gone; this is the engine.
actor ParakeetTranscriber {

    /// The process-wide instance. One, because it holds 470 MB of loaded models for the process
    /// lifetime -- constructing another would reload them.
    static let shared = ParakeetTranscriber()

    nonisolated let engineID = "parakeet-tdt-v3"

    /// The variant the app is built around. Not a config key: Phase 0 eliminated every alternative on
    /// measured grounds, and exposing it would invite shipping an unmeasured one.
    private static let version: AsrModelVersion = .v3

    private var manager: AsrManager?
    private var decoderLayers = 2

    /// In-flight preparation shared by concurrent callers. Actor methods interleave at suspension
    /// points, so a bare `manager == nil` check is not a mutex — a launch warm-up racing a fast first
    /// import would otherwise download and load the models twice.
    private var preparing: Task<(AsrManager, Int), Error>?

    /// Owns "are the models on disk, and if not what is happening about it". Split from `preparing`
    /// above, which single-flights *this* type's `AsrManager` construction: the store single-flights
    /// the 470 MB fetch and is the only thing that can report its progress. Before it was wired up,
    /// `prepared()` awaited that download with `progress: nil` and no phase to read, so a dictation
    /// taken during a first-run download parked in `.transcribing` with a live-looking HUD until the
    /// user force-quit — the 1.1.0 hang.
    private let downloader: ParakeetModelDownloader
    private let store: AsrModelStore

    init() {
        let downloader = ParakeetModelDownloader(version: Self.version)
        self.downloader = downloader
        self.store = AsrModelStore(downloader: downloader)
    }

    var isReady: Bool { manager != nil }

    /// What the model cache is doing. The app's single source for "may I dictate right now?" and for
    /// the progress shown while the answer is no.
    var phase: AsrModelPhase {
        get async { await store.phase }
    }

    /// Human-readable description of the current fetch stage ("Downloading speech model — file 2 of
    /// 4"), or nil when nothing is downloading. Shown INSTEAD of a percentage; see the note on
    /// `ParakeetModelDownloader.activity` for why the library's fraction is not presentable.
    nonisolated var activity: String? { downloader.activity }

    /// Download (470 MB on first run) and load the models. Idempotent; a no-op once prepared.
    ///
    /// On failure the in-flight task is cleared so the next call retries rather than caching the
    /// failure forever — a warm-up that failed on a flaky network must not poison the first real use.
    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        // Progress now lives in `store.phase` rather than travelling down as a callback, because the
        // hotkey path needs to *read* it at an arbitrary moment ("is it safe to record?") and a
        // callback only tells whoever happens to be awaiting. Callers that still want a callback —
        // the import wizard's progress bar — get one by polling that phase for the duration.
        guard let progress else {
            _ = try await prepared()
            return
        }

        let poller = Task { [store] in
            while !Task.isCancelled {
                if case .downloading(let fraction) = await store.phase { progress(fraction) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }
        _ = try await prepared()
    }

    func transcribe(
        fileURL: URL,
        locale: Locale? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        // `locale` is deliberately ignored rather than rejected: the app is English-only (decision 3)
        // and throwing would break the bench's `--locale` flag for no benefit.
        let (manager, layers) = try await prepared()

        let audioDuration = try Self.duration(of: fileURL)

        // Forward the manager's own progress stream for the duration of this call only. FluidAudio
        // emits on it for audio over ~15s; short files legitimately produce no ticks, so callers must
        // not require a terminal 1.0.
        // Written out rather than via `Optional.map`, because reading the stream is itself `async` and
        // `map` takes a synchronous closure.
        var progressTask: Task<Void, Never>?
        if let progress {
            let stream = await manager.transcriptionProgressStream
            progressTask = Task {
                // A stream fault is not this call's error to surface -- the `transcribe` below reports
                // the real failure. Swallowing here keeps a progress fault from masking it.
                do {
                    for try await fraction in stream { progress(min(max(fraction, 0), 1)) }
                } catch {}
            }
        }
        defer { progressTask?.cancel() }

        // A FRESH decoder state per call. `TdtDecoderState` carries the TDT decoder's recurrent hidden
        // state, so reusing one across unrelated files would let the previous file's tail condition the
        // next file's opening tokens.
        var decoderState = TdtDecoderState.make(decoderLayers: layers)
        let result: ASRResult
        do {
            result = try await manager.transcribe(fileURL, decoderState: &decoderState)
        } catch {
            throw TranscriptionError.engineFailure("\(error)")
        }

        let words = Self.words(from: result)

        // `result.text` is the engine's own joined text and stays authoritative for the full transcript.
        // `phrases` is what consumers actually use, synthesized because Parakeet emits only words.
        return Transcript(
            text: result.text,
            phrases: PhraseSegmentation.phrases(from: words),
            words: words,
            audioDuration: audioDuration > 0 ? audioDuration : result.duration,
            engineID: engineID
        )
    }

    /// True in-memory transcription -- no file, no round trip. Dictation's path.
    ///
    /// **Not for meetings.** The `fileURL` overload routes to disk-backed chunking above FluidAudio's
    /// streaming threshold; this one has no such fallback, so an hour-long recording would sit in
    /// memory in full.
    ///
    /// `AsrManager.transcribe(_ buffer:)` resamples to the model's rate itself, so the caller can hand
    /// over whatever the microphone produced. No progress callback: FluidAudio only emits progress for
    /// audio over ~15s and a dictation is transcribed in roughly 0.004s per second of speech, so a
    /// 5-minute one finishes in about 1.2s -- there is nothing to report.
    func transcribe(audio: CapturedAudio, locale: Locale? = nil) async throws -> Transcript {
        let (manager, layers) = try await prepared()
        let audioDuration = audio.duration

        var decoderState = TdtDecoderState.make(decoderLayers: layers)
        let result: ASRResult
        do {
            result = try await manager.transcribe(audio.buffer, decoderState: &decoderState)
        } catch {
            throw TranscriptionError.engineFailure("\(error)")
        }

        let words = Self.words(from: result)
        return Transcript(
            text: result.text,
            phrases: PhraseSegmentation.phrases(from: words),
            words: words,
            audioDuration: audioDuration > 0 ? audioDuration : result.duration,
            engineID: engineID
        )
    }

    /// Release the loaded models. A later `transcribe` reloads them from disk (or re-downloads).
    ///
    /// Cancels any in-flight preparation first, otherwise a download racing this call would land its
    /// result into `manager` immediately afterwards and quietly undo the unload.
    func unload() async {
        preparing?.cancel()
        preparing = nil
        // Also stop any download the store has in flight. Cancelling only `preparing` would leave the
        // fetch running and land `.installed` afterwards, so the phase would claim models the caller
        // just asked to release.
        await store.cancel()
        manager = nil
        decoderLayers = 2
        Logger.log("ASR", "Parakeet models unloaded")
    }

    // MARK: - Preparation

    private func prepared() async throws -> (AsrManager, Int) {
        if let manager { return (manager, decoderLayers) }
        let task = preparing ?? Task { try await self.makeManager() }
        preparing = task
        do {
            let (fresh, layers) = try await task.value
            manager = fresh
            decoderLayers = layers
            preparing = nil
            return (fresh, layers)
        } catch {
            preparing = nil
            throw error
        }
    }

    private func makeManager() async throws -> (AsrManager, Int) {
        // The store owns the fetch: it single-flights across the launch warm-up and a first import,
        // survives one caller walking away, and — the point of routing through it — publishes a phase
        // the hotkey path can read before deciding whether to open the mic.
        do {
            try await store.prepare()
        } catch {
            throw TranscriptionError.modelUnavailable("\(error)")
        }

        // A download stashes the set it loaded on the way past; an already-installed cache
        // short-circuits `prepare()` without running one, so load from disk in that case.
        let models: AsrModels
        if let stashed = downloader.take() {
            models = stashed
        } else {
            do {
                models = try await downloader.loadInstalled()
            } catch {
                throw TranscriptionError.modelUnavailable("\(error)")
            }
        }

        let manager = AsrManager(models: models)
        guard await manager.isAvailable else {
            throw TranscriptionError.modelUnavailable("manager reported unavailable after load")
        }
        return (manager, await manager.decoderLayerCount)
    }

    // MARK: - Words

    /// Fold token timings into words using FluidAudio's own `buildWordTimings`.
    ///
    /// Deliberately not a hand-rolled SentencePiece splitter: the library owns its tokenizer's
    /// word-boundary convention, and duplicating it here would drift the moment a model version
    /// changes its vocabulary.
    ///
    /// `tokenTimings` is optional and can be nil. Nil yields no words, hence no phrases, surfaced as
    /// such rather than faked — `Transcript.hasWordTimings` exists for exactly this.
    ///
    /// `WordTiming` carries no confidence, so `TimedWord.confidence` is nil. `ASRResult.confidence` is
    /// one utterance-level figure, and spreading it across every word would invent per-word precision
    /// the engine never reported.
    private static func words(from result: ASRResult) -> [TimedWord] {
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        return buildWordTimings(from: timings).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime, confidence: nil)
        }
    }

    private static func duration(of url: URL) throws -> TimeInterval {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.processingFormat.sampleRate
        } catch {
            throw TranscriptionError.unreadableAudio("\(url.lastPathComponent): \(error)")
        }
    }
}
