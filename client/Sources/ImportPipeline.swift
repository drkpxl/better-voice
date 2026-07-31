@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import BetterVoiceCore

// MARK: - Import phase / mode

/// Coarse progress stage for the import wizard. Ordered by the offline pipeline:
/// transcription → speaker diarization → LLM summary. (Summarization is driven by
/// `ImportSession`, not this file, but shares the enum so the UI has one progress vocabulary.)
enum ImportPhase {
    /// First-run model download and CoreML compile. Its own phase because it is the longest single
    /// wait in the whole product and it happens exactly once: measured on this hardware, a cold
    /// 470 MB fetch plus compile added **132s** before transcription could begin (174.4s cold against
    /// 42.4s warm on the 57-minute fixture). Without a phase of its own it was reported as nothing at
    /// all — the bar sat at zero for over two minutes, which is precisely the first-run abandonment
    /// risk the migration plan flags.
    case preparingModels
    case transcribing
    case identifyingSpeakers
    case summarizing

    var label: String {
        switch self {
        case .preparingModels:     return t("Downloading speech model…")
        case .transcribing:        return t("Transcribing…")
        case .identifyingSpeakers: return t("Identifying speakers…")
        case .summarizing:         return t("Summarizing…")
        }
    }
}

/// Whether the imported recording has multiple speakers (run diarization) or is a single
/// speaker (skip the FluidAudio pass entirely → a flat, speaker-less transcript).
enum SpeakerMode {
    case single
    case multi
}

enum ImportError: LocalizedError {
    case unreadableAudio(String)
    case transcriptionFailed(String)
    /// The file decoded fine but carries no audible signal. Its own case because the fix is "record
    /// again / check the source", not "try another format" — and because without it a silent file
    /// produced a zero-segment `MeetingResult` with no error at all, the exact "empty successful
    /// transcript" this type exists to prevent.
    case silentAudio(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let detail):
            return t("Couldn't read that audio file. It may be an unsupported or protected format.") + " (\(detail))"
        case .transcriptionFailed(let detail):
            return t("Transcription failed.") + " (\(detail))"
        case .silentAudio(let detail):
            return t("That recording has no audible speech in it.") + " (\(detail))"
        }
    }
}

// MARK: - Import Pipeline

/// The engine: turn an imported audio file into a diarized `MeetingResult`.
///
/// Stage 1 of two, and the whole of it: transcribe → offline FluidAudio diarization → phrase→speaker
/// alignment → deterministic vocabulary replacement. No model runs on the text. What crosses into
/// stage 2 is one speaker-labeled `String`, built by `buildSummarizationTranscript` and handed to
/// `SummarizationClient` in `ImportSession`.
///
/// Extracted from v1's `MeetingSession.runFromFile`, which also ran a per-turn LLM cleanup pass
/// between transcription and diarization. All live-capture code (AVCaptureSession,
/// the system-audio process tap, mic VAD, both-mode) is intentionally left behind — the input is
/// a decoded file URL that `AVAudioFile`/FluidAudio read directly, no transcode stage needed.
@MainActor
final class ImportPipeline {

    // MARK: State (reset per run)

    /// The ASR engine. The shared instance, not an injected one: see `ParakeetTranscriber`.
    private let transcriber = ParakeetTranscriber.shared

    private var segmentBuffer: SegmentBuffer?
    /// Batched segments, used only for the flat (single-speaker) transcript. On the labeled
    /// multi-speaker path these are discarded and turns are rebuilt from `allPhraseEntries`.
    private var batchedSegments: [MeetingSegment] = []
    /// Phrase-level transcript entries (with timestamps), used for fine-grained per-speaker grouping.
    private var allPhraseEntries: [SegmentBuffer.Entry] = []
    private(set) var duration: TimeInterval = 0

    /// The system-audio WAV/URL fed to FluidAudio's offline clustering. Set to the input file for
    /// `.multi`; nil for `.single` (no diarization pass runs).
    private var systemAudioFileURL: URL?
    private var audioFileURL: URL?
    private var meetingId: String = ""

    /// Streamed to disk (one line per segment) for crash durability while a long import runs.
    private let meetingHistory = MeetingHistory()

    /// Held as a property (not captured in the @Sendable result Task) so progress updates don't
    /// require the callback itself to be Sendable — the Task touches `self.progressHandler` on the
    /// main actor instead. Never call it directly; go through `report(_:_:)`.
    private var progressHandler: ((ImportPhase, Double) -> Void)?

    /// Incremented on every `run`. Progress arrives from detached tasks that can outlive the run that
    /// started them — the live-meeting path calls `run` twice on the *same* instance
    /// (`ImportSession.swift:263-286`), so a late tick from the first pass could otherwise land on the
    /// second pass's handler and rewind its bar. A task captures the token it was created under and
    /// reports nothing once it no longer matches.
    private var runToken = 0

    /// Highest fraction reported for the current phase, so progress can never go backwards.
    private var reportedPhase: ImportPhase?
    private var reportedFraction: Double = 0

    // MARK: - Run

    /// Transcribe + (for `.multi`) diarize the file, returning speaker-labeled segments.
    /// `onProgress` reports (`.transcribing`, 0…1) during transcription and
    /// (`.identifyingSpeakers`, 0…1) during diarization. Throws `ImportError` on unreadable audio
    /// or a transcription-stream failure (so the wizard can show a real error instead of an empty
    /// "successful" transcript).
    func run(
        _ fileURL: URL,
        speakerMode: SpeakerMode,
        locale: String? = nil,
        onProgress: (@MainActor (ImportPhase, Double) -> Void)? = nil
    ) async throws -> MeetingResult {
        // Reset state
        batchedSegments = []
        allPhraseEntries = []
        duration = 0
        setupSegmentBuffer()
        audioFileURL = fileURL
        meetingId = "import-" + fileURL.deletingPathExtension().lastPathComponent
        progressHandler = onProgress
        runToken += 1
        reportedPhase = nil
        reportedFraction = 0
        let token = runToken

        // Single-speaker → no diarization source → FluidAudio never runs (flat transcript).
        systemAudioFileURL = (speakerMode == .multi) ? fileURL : nil

        // Locale is carried through but no longer resolved against a system speech catalogue: the only
        // engine left is English-only and ignores it (see `ParakeetTranscriber.transcribe`). The
        // parameter stays because the bench's `--locale` flag still passes one, and dropping it would
        // silently change that flag's meaning rather than remove it.
        let bestLocale: Locale? = locale.map { Locale(identifier: $0) }
        Logger.log("Import", "Locale: \(bestLocale?.identifier(.bcp47) ?? "(engine default)"), mode: \(speakerMode == .multi ? "multi" : "single")")

        // Read audio (decodes AAC/MP3/WAV/AIFF/CAF). A read failure is a real, user-facing error.
        // The transcriber probes the file itself for its own duration; this probe stays because
        // `duration` must be known before the first progress tick, and because an unreadable file is an
        // `ImportError` here rather than a `TranscriptionError`.
        let probeFile: AVAudioFile
        do {
            probeFile = try AVAudioFile(forReading: fileURL)
        } catch {
            Logger.log("Import", "Unreadable audio \(fileURL.lastPathComponent): \(error)")
            throw ImportError.unreadableAudio(fileURL.lastPathComponent)
        }
        duration = Double(probeFile.length) / probeFile.processingFormat.sampleRate
        Logger.log("Import", "Audio: \(String(format: "%.1f", duration))s, \(Int(probeFile.processingFormat.sampleRate))Hz, \(probeFile.processingFormat.channelCount)ch")

        // Silence gate. `MeetingCoordinator.stopMeeting` already ran this for live recordings
        // (`MeetingCoordinator.swift:250-256`) but nothing covered a user-chosen *file*, so a silent
        // import ran the full pipeline and came back with zero segments and no error. Detached because
        // the check does bounded-chunk blocking reads and must not block the main actor.
        let silent = await Task.detached(priority: .utility) {
            isRecordingEffectivelyEmpty(at: fileURL)
        }.value
        if silent {
            Logger.log("Import", "Silent audio \(fileURL.lastPathComponent); refusing to transcribe")
            throw ImportError.silentAudio(fileURL.lastPathComponent)
        }

        // Prepare the engine BEFORE transcribing, and report it as its own phase.
        //
        // `transcribe` would prepare lazily anyway -- `prepare` is idempotent, so this is not
        // duplicated work -- but doing it implicitly meant a first-run 470 MB download happened inside
        // the transcription call with no progress reported at all. Measured: 132s of silence with the
        // bar at zero. Hoisting it here is the whole point of `.preparingModels`.
        if await !transcriber.isReady {
            Logger.log("Import", "Engine not ready; preparing (first run downloads ~470 MB)")
            report(.preparingModels, 0)
            do {
                try await transcriber.prepare(progress: { [weak self] fraction in
                    Task { @MainActor in self?.reportIfCurrent(token, .preparingModels, fraction) }
                })
            } catch {
                Logger.log("Import", "Model preparation failed: \(error)")
                throw ImportError.transcriptionFailed("\(error)")
            }
            report(.preparingModels, 1)
        }

        // Transcribe through the seam. Progress arrives on an arbitrary executor per the protocol, so
        // it hops to the main actor, and drops if a later `run` has superseded this one.
        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(
                fileURL: fileURL,
                locale: bestLocale,
                progress: { [weak self] fraction in
                    Task { @MainActor in self?.reportIfCurrent(token, .transcribing, fraction) }
                }
            )
        } catch {
            Logger.log("Import", "Transcription failed: \(error)")
            throw ImportError.transcriptionFailed("\(error)")
        }
        Logger.log("Import", "Transcribed: \(transcript.phrases.count) phrases via \(transcript.engineID)")

        // Replay phrases in emission order. `SegmentBuffer`'s thresholds are all measured in audio
        // timestamps and buffered characters, with no wall clock or timer, so feeding the same entries
        // in the same order after transcription yields bit-identical batches and trigger reasons.
        for phrase in transcript.phrases {
            let entry = SegmentBuffer.Entry(
                text: phrase.text,
                startTime: phrase.start,
                endTime: phrase.end
            )
            allPhraseEntries.append(entry)
            await segmentBuffer?.feed(entry)
        }

        // Flush the tail batch.
        await segmentBuffer?.flushFinal()
        report(.transcribing, 1)

        // Diarization (multi only) + phrase→speaker alignment.
        let diarized = await performDiarization(token: token)
        report(.identifyingSpeakers, 1)

        Logger.log("Import", "Complete: \(diarized.count) segments")
        return MeetingResult(segments: diarized, duration: duration, audioPath: fileURL.path)
    }

    // MARK: - Progress

    /// The only way progress reaches the caller. Clamps to `0...1` and ratchets within a phase.
    ///
    /// Both guards fix real defects. The fraction was previously `min(entry.endTime / duration, 1)`
    /// with no lower bound, so a phrase carrying no time range drove it to 0 and visibly rewound the
    /// wizard's bar mid-import. And nothing stopped a late or out-of-order tick from moving it
    /// backwards. Advancing to a new phase resets the ratchet, since each phase reports its own 0...1.
    private func report(_ phase: ImportPhase, _ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if reportedPhase != phase {
            reportedPhase = phase
            reportedFraction = clamped
        } else if clamped <= reportedFraction {
            return
        } else {
            reportedFraction = clamped
        }
        progressHandler?(phase, clamped)
    }

    /// Report from a detached context, dropping the tick if `run` has moved on since it was scheduled.
    private func reportIfCurrent(_ token: Int, _ phase: ImportPhase, _ fraction: Double) {
        guard token == runToken else { return }
        report(phase, fraction)
    }

    // MARK: - Diarization

    /// Cluster the imported track's remote speakers (`.multi`) and align each phrase to a speaker.
    /// For `.single` (or when clustering yields nothing) the batched segments are returned unlabeled —
    /// exactly the flat transcript we want.
    private func performDiarization(token: Int) async -> [MeetingSegment] {
        // Gate on the phrases, not on the batched segments. The old code tested
        // `polishedSegments.isEmpty`, which was equivalent only by accident: `flushFinal` flushes any
        // non-empty buffer, so a batch existed iff a phrase had been fed. That made the gate silently
        // wrong the moment the batch path was reordered -- which this phase does. `allPhraseEntries` is
        // the condition actually meant, and it is what the turn path consumes.
        guard !allPhraseEntries.isEmpty else {
            Logger.log("Import", "No phrases to diarize")
            return []
        }
        let segments = batchedSegments

        var intervals: [SpeakerInterval] = []
        if let sysURL = systemAudioFileURL {
            let sysSegments = await offlineDiarizeSystem(url: sysURL, token: token)
            Logger.log("Import", "Diarization: \(sysSegments.count) speaker segments")
            intervals.append(contentsOf: speakerIntervals(from: sysSegments))
        }

        // No intervals (single-speaker, or clustering unavailable) → unlabeled flat transcript.
        guard !intervals.isEmpty else {
            Logger.log("Import", "No speaker intervals; returning flat transcript")
            return segments
        }

        intervals.sort { $0.start < $1.start }
        Logger.log("Import", "Merged timeline: \(intervals.count) intervals, distinct speakers=\(Set(intervals.map(\.speakerId)).count)")

        // The file path always has phrase entries, so fine-grained turn building always applies.
        return await buildSpeakerTurns(entries: allPhraseEntries, intervals: intervals)
    }

    /// Post-hoc offline diarization via FluidAudio's VBx pipeline on `OfflineDiarizerHost` (the
    /// actor confining the non-Sendable manager). Any failure returns [] → flat transcript.
    /// Segmentation progress (chunks done/total) is forwarded to `.identifyingSpeakers`.
    private func offlineDiarizeSystem(url: URL, token: Int) async -> [TimedSpeakerSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.log("Import", "[Offline] audio missing at \(url.lastPathComponent); skipping diarization")
            return []
        }
        do {
            let segments = try await OfflineDiarizerHost.shared.process(url) { done, total in
                guard total > 0 else { return }
                let fraction = Double(done) / Double(total)
                Task { @MainActor in
                    self.reportIfCurrent(token, .identifyingSpeakers, fraction)
                }
            }
            Logger.log("Import", "[Offline] \(segments.count) speaker segments (VBx)")
            return segments
        } catch {
            Logger.log("Import", "[Offline] diarization failed: \(error); continuing without speakers")
            return []
        }
    }

    /// Convert FluidAudio diarization segments into pure-Core `SpeakerInterval`s.
    private func speakerIntervals(from diarization: [TimedSpeakerSegment]) -> [SpeakerInterval] {
        diarization.map { d in
            SpeakerInterval(
                speakerId: d.speakerId,
                start: TimeInterval(d.startTimeSeconds),
                end: TimeInterval(d.endTimeSeconds),
                embedding: d.embedding,
                quality: d.qualityScore
            )
        }
    }

    /// Assign each phrase to the max-overlap speaker, then group consecutive same-speaker phrases
    /// into turns (pure Core) → one `MeetingSegment` per turn.
    private func buildSpeakerTurns(
        entries: [SegmentBuffer.Entry],
        intervals: [SpeakerInterval]
    ) async -> [MeetingSegment] {
        let phrases = entries.map { (span: PhraseSpan(start: $0.startTime, end: $0.endTime), text: $0.text) }
        let turns = groupIntoTurns(phrases: phrases, intervals: intervals)

        var result: [MeetingSegment] = []
        for turn in turns {
            // Deterministic vocabulary replacement only. This used to be an awaited LLM call per turn
            // -- ~168 of them on the 57-minute fixture, which is where the bulk of import wall clock
            // went. The vocabulary channel does exact word-boundary replacement, so it carries none of
            // the false-substitution risk that made acoustic and LLM correction unattractive.
            result.append(MeetingSegment(
                text: Vocabulary.shared.apply(to: turn.text),
                startTime: turn.start,
                endTime: turn.end,
                speakerId: turn.speakerId,
                isFinal: true,
                speakerEmbedding: turn.embedding,
                speakerConfidence: turn.minConfidence
            ))
        }
        let speakerCount = Set(result.compactMap(\.speakerId)).count
        Logger.log("Import", "Speaker turns: \(result.count) turns from \(entries.count) phrases, \(speakerCount) distinct speakers")
        return result
    }

    // MARK: - Segmentation

    private func setupSegmentBuffer() {
        let cfg = RuntimeConfig.shared.meetingConfig
        let pauseSec = (cfg["segment_pause_sec"] as? Double) ?? 1.5
        let maxChars = (cfg["segment_max_chars"] as? Int) ?? 200
        let minChars = (cfg["segment_min_chars"] as? Int) ?? 30

        let buf = SegmentBuffer(pauseThresholdSec: pauseSec, maxChars: maxChars, minChars: minChars)
        buf.onFlush = { [weak self] batch in
            guard let self else { return }
            self.batchedSegments.append(self.makeSegment(from: batch))
        }
        self.segmentBuffer = buf
    }

    /// Turn one flush batch into a `MeetingSegment`, applying deterministic vocabulary replacements.
    ///
    /// This used to run an LLM polish pass per batch, deleted for two reasons — the larger one first:
    /// on the labeled multi-speaker path the result was **discarded**, because `performDiarization`
    /// rebuilds turns from `allPhraseEntries` and re-ran the pass per turn, so every batch's awaited
    /// LLM call was paid for, persisted, and thrown away. And the bake-off measured the stage as worth
    /// ~1 WER point on top of a good ASR engine while costing 90% of the wall clock
    /// (`bench/results/2026-07-30-results.json`).
    ///
    /// `SegmentBuffer` survives it for the *grouping* alone; see its own note.
    private func makeSegment(from batch: SegmentBuffer.FlushBatch) -> MeetingSegment {
        let segmentText = Vocabulary.shared.apply(to: batch.text)

        meetingHistory.append(MeetingSegmentRecord(
            timestamp: Date(),
            meetingId: meetingId,
            audioPath: audioFileURL?.path ?? "",
            segIndex: segmentBuffer?.flushCount ?? 0,
            startTime: batch.startTime,
            endTime: batch.endTime,
            triggerReason: batch.triggerReason,
            text: segmentText
        ))

        return MeetingSegment(
            text: segmentText,
            startTime: batch.startTime,
            endTime: batch.endTime,
            speakerId: nil,
            isFinal: true
        )
    }
}
