@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import BetterVoiceCore
import Speech

// MARK: - Import phase / mode

/// Coarse progress stage for the import wizard. Ordered by the offline pipeline:
/// transcription → speaker diarization → LLM summary. (Summarization is driven by
/// `ImportSession`, not this file, but shares the enum so the UI has one progress vocabulary.)
enum ImportPhase {
    case transcribing
    case identifyingSpeakers
    case summarizing

    var label: String {
        switch self {
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

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let detail):
            return t("Couldn't read that audio file. It may be an unsupported or protected format.") + " (\(detail))"
        case .transcriptionFailed(let detail):
            return t("Transcription failed.") + " (\(detail))"
        }
    }
}

// MARK: - Import Pipeline

/// The engine: turn an imported audio file into a diarized, L2-polished `MeetingResult`.
///
/// Extracted from v1's `MeetingSession.runFromFile` (transcribe → per-turn L2 polish → offline
/// FluidAudio diarization → phrase→speaker alignment). All live-capture code (AVCaptureSession,
/// the system-audio process tap, mic VAD, both-mode) is intentionally left behind — the input is
/// a decoded file URL that `AVAudioFile`/FluidAudio read directly, no transcode stage needed.
@MainActor
final class ImportPipeline {

    // MARK: State (reset per run)

    private var segmentBuffer: SegmentBuffer?
    private var polishedSegments: [MeetingSegment] = []
    /// Phrase-level transcript entries (with timestamps), used for fine-grained per-speaker grouping.
    private var allPhraseEntries: [SegmentBuffer.Entry] = []
    private(set) var duration: TimeInterval = 0

    /// The system-audio WAV/URL fed to FluidAudio's offline clustering. Set to the input file for
    /// `.multi`; nil for `.single` (no diarization pass runs).
    private var systemAudioFileURL: URL?
    private var audioFileURL: URL?
    private var meetingId: String = ""

    /// Streamed to disk (one line per L2 segment) for crash durability while a long import runs.
    private let meetingHistory = MeetingHistory()

    /// Held as a property (not captured in the @Sendable result Task) so progress updates don't
    /// require the callback itself to be Sendable — the Task touches `self.progressHandler` on the
    /// main actor instead.
    private var progressHandler: ((ImportPhase, Double) -> Void)?

    // L2 stats (summary logged at end)
    private var l2Changed = 0
    private var l2Identity = 0
    private var l2Failed = 0
    private var l2Skipped = 0
    private var l2TotalElapsedMs = 0
    private var l2CallCount = 0

    init() {}

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
        polishedSegments = []
        allPhraseEntries = []
        duration = 0
        resetL2Stats()
        setupSegmentBuffer()
        audioFileURL = fileURL
        meetingId = "import-" + fileURL.deletingPathExtension().lastPathComponent
        progressHandler = onProgress

        // Single-speaker → no diarization source → FluidAudio never runs (flat transcript).
        systemAudioFileURL = (speakerMode == .multi) ? fileURL : nil

        // Resolve locale (config/system best, or explicit override).
        let bestLocale: Locale
        if let locale {
            bestLocale = Locale(identifier: locale)
        } else {
            bestLocale = await SpeechUtils.bestLocale() ?? Locale(identifier: "en-US")
        }
        Logger.log("Import", "Locale: \(bestLocale.identifier(.bcp47)), mode: \(speakerMode == .multi ? "multi" : "single")")

        // Read audio (decodes AAC/MP3/WAV/AIFF/CAF). A read failure is a real, user-facing error.
        let probeFile: AVAudioFile
        do {
            probeFile = try AVAudioFile(forReading: fileURL)
        } catch {
            Logger.log("Import", "Unreadable audio \(fileURL.lastPathComponent): \(error)")
            throw ImportError.unreadableAudio(fileURL.lastPathComponent)
        }
        duration = Double(probeFile.length) / probeFile.processingFormat.sampleRate
        Logger.log("Import", "Audio: \(String(format: "%.1f", duration))s, \(Int(probeFile.processingFormat.sampleRate))Hz, \(probeFile.processingFormat.channelCount)ch")

        // Configure SpeechTranscriber + SpeechAnalyzer.
        let transcriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        try await SpeechUtils.ensureModelInstalled(transcriber: transcriber, locale: bestLocale)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)

        // Result handling: only final segments feed the buffer; volatile partials ignored.
        // Returns the stream error (if any) instead of swallowing it, so we can surface it.
        let resultTask = Task { [weak self] () -> Error? in
            do {
                for try await result in transcriber.results {
                    guard let self else { return nil }
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                    let timeRange = self.extractTimeRange(from: result.text)
                    let entry = SegmentBuffer.Entry(
                        text: text,
                        startTime: timeRange.start,
                        endTime: timeRange.start + timeRange.duration
                    )
                    self.allPhraseEntries.append(entry)
                    if self.duration > 0 {
                        self.progressHandler?(.transcribing, min(entry.endTime / self.duration, 1))
                    }
                    await self.segmentBuffer?.feed(entry)
                }
                return nil
            } catch {
                return error
            }
        }

        // A fresh AVAudioFile for the analyzer (the probe advanced no read cursor, but keep them separate).
        let inputFile = try AVAudioFile(forReading: fileURL)
        try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)

        // start() returns immediately; the results loop ends once the analyzer finalizes.
        let streamError = await resultTask.value
        if let streamError {
            Logger.log("Import", "Result stream error: \(streamError)")
            throw ImportError.transcriptionFailed("\(streamError)")
        }

        // Flush the tail batch → L2.
        await segmentBuffer?.flushFinal()
        logL2Summary()
        progressHandler?(.transcribing, 1)

        // Diarization (multi only) + phrase→speaker alignment.
        let diarized = await performDiarization()
        progressHandler?(.identifyingSpeakers, 1)

        Logger.log("Import", "Complete: \(diarized.count) segments")
        return MeetingResult(segments: diarized, duration: duration, audioPath: fileURL.path)
    }

    // MARK: - Diarization

    /// Cluster the imported track's remote speakers (`.multi`) and align each phrase to a speaker.
    /// For `.single` (or when clustering yields nothing) the L2 segments are returned unlabeled —
    /// exactly the flat transcript we want.
    private func performDiarization() async -> [MeetingSegment] {
        let segments = polishedSegments
        guard !segments.isEmpty else {
            Logger.log("Import", "No polished segments to diarize")
            return []
        }

        var intervals: [SpeakerInterval] = []
        if let sysURL = systemAudioFileURL {
            let sysSegments = await offlineDiarizeSystem(url: sysURL)
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
    private func offlineDiarizeSystem(url: URL) async -> [TimedSpeakerSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.log("Import", "[Offline] audio missing at \(url.lastPathComponent); skipping diarization")
            return []
        }
        do {
            let segments = try await OfflineDiarizerHost.shared.process(url) { done, total in
                guard total > 0 else { return }
                let fraction = Double(done) / Double(total)
                Task { @MainActor in
                    self.progressHandler?(.identifyingSpeakers, fraction)
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

    /// Assign each phrase to the max-overlap speaker, group consecutive same-speaker phrases into
    /// turns (pure Core), and L2-polish each turn → one `MeetingSegment` per turn.
    private func buildSpeakerTurns(
        entries: [SegmentBuffer.Entry],
        intervals: [SpeakerInterval]
    ) async -> [MeetingSegment] {
        let phrases = entries.map { (span: PhraseSpan(start: $0.startTime, end: $0.endTime), text: $0.text) }
        let turns = groupIntoTurns(phrases: phrases, intervals: intervals)

        var result: [MeetingSegment] = []
        for turn in turns {
            let raw = turn.text
            let polished = await polishTurnText(raw)
            result.append(MeetingSegment(
                text: polished.text,
                rawText: raw,
                startTime: turn.start,
                endTime: turn.end,
                speakerId: turn.speakerId,
                l2Kind: polished.kind,
                isFinal: true,
                speakerEmbedding: turn.embedding,
                speakerConfidence: turn.minConfidence
            ))
        }
        let speakerCount = Set(result.compactMap(\.speakerId)).count
        Logger.log("Import", "Speaker turns: \(result.count) turns from \(entries.count) phrases, \(speakerCount) distinct speakers")
        return result
    }

    /// Single L2 polish pass on a turn's text (reusing PolishClient); vocabulary replacements
    /// apply on every path. Falls back to raw text when polish is disabled or fails.
    private func polishTurnText(_ raw: String) async -> (text: String, kind: L2Kind) {
        let polishEnabled = (RuntimeConfig.shared.polishConfig["enabled"] as? Bool) == true
        guard polishEnabled, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (Vocabulary.shared.apply(to: raw), .skipped)
        }
        if let p = await PolishClient.shared.polish(text: raw, words: [], app: nil) {
            let final = Vocabulary.shared.apply(to: p)
            return (final, final == raw ? .identity : .changed)
        }
        return (Vocabulary.shared.apply(to: raw), .failed)
    }

    // MARK: - Segmentation / L2

    private func setupSegmentBuffer() {
        let cfg = RuntimeConfig.shared.meetingConfig
        let pauseSec = (cfg["l2_flush_on_pause_sec"] as? Double) ?? 1.5
        let maxChars = (cfg["l2_flush_on_chars"] as? Int) ?? 200
        let minChars = (cfg["l2_min_chars"] as? Int) ?? 30

        let buf = SegmentBuffer(pauseThresholdSec: pauseSec, maxChars: maxChars, minChars: minChars)
        buf.onFlush = { [weak self] batch in
            guard let self else { return }
            let seg = await self.polishBatch(batch)
            self.polishedSegments.append(seg)
        }
        self.segmentBuffer = buf
    }

    /// Run L2 correction on one flush batch and return the final MeetingSegment. On L2 failure,
    /// text = rawText; each call's result is appended to meeting-history.jsonl immediately.
    private func polishBatch(_ batch: SegmentBuffer.FlushBatch) async -> MeetingSegment {
        let segNum = segmentBuffer?.flushCount ?? 0
        let polishCfg = RuntimeConfig.shared.polishConfig
        let polishEnabled = (polishCfg["enabled"] as? Bool) == true

        let rawText = batch.rawText

        let finalText: String
        let polishedText: String?
        let l2Kind: L2Kind
        let elapsedMs: Int

        if !polishEnabled {
            l2Skipped += 1
            finalText = rawText
            polishedText = nil
            l2Kind = .skipped
            elapsedMs = 0
        } else {
            let t0 = CFAbsoluteTimeGetCurrent()
            let polished = await PolishClient.shared.polish(text: rawText, words: [], app: nil)
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            l2CallCount += 1
            l2TotalElapsedMs += elapsedMs

            if let p = polished {
                polishedText = p
                if p == rawText {
                    l2Identity += 1
                    l2Kind = .identity
                    finalText = p
                } else {
                    l2Changed += 1
                    l2Kind = .changed
                    finalText = p
                }
            } else {
                polishedText = nil
                l2Failed += 1
                l2Kind = .failed
                finalText = rawText
            }
        }

        // Deterministic vocabulary replacements, applied whatever the L2 outcome.
        let segmentText = Vocabulary.shared.apply(to: finalText)

        let record = MeetingSegmentRecord(
            timestamp: Date(),
            meetingId: meetingId,
            audioPath: audioFileURL?.path ?? "",
            segIndex: segNum,
            startTime: batch.startTime,
            endTime: batch.endTime,
            triggerReason: batch.triggerReason,
            rawText: rawText,
            polishedText: polishedText,
            finalText: segmentText,
            l2Kind: l2Kind.rawValue,
            l2ElapsedMs: elapsedMs
        )
        meetingHistory.append(record)

        return MeetingSegment(
            text: segmentText,
            rawText: rawText,
            startTime: batch.startTime,
            endTime: batch.endTime,
            speakerId: nil,
            l2Kind: l2Kind,
            isFinal: true
        )
    }

    private func resetL2Stats() {
        l2Changed = 0
        l2Identity = 0
        l2Failed = 0
        l2Skipped = 0
        l2TotalElapsedMs = 0
        l2CallCount = 0
    }

    private func logL2Summary() {
        let total = l2Changed + l2Identity + l2Failed + l2Skipped
        let avgMs = l2CallCount > 0 ? l2TotalElapsedMs / l2CallCount : 0
        let fallback = l2Failed + l2Skipped
        Logger.log("Import", "L2 summary: total=\(total) changed=\(l2Changed) identity=\(l2Identity) failed=\(l2Failed) skipped=\(l2Skipped) avgMs=\(avgMs) fallback_used=\(fallback)")
    }

    // MARK: - audioTimeRange extraction

    private func extractTimeRange(from attrText: AttributedString) -> (start: TimeInterval, duration: TimeInterval) {
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        var earliest: TimeInterval = .infinity
        var latest: TimeInterval = 0
        for (timeRange, _) in attrText.runs[TimeKey.self] {
            guard let range = timeRange else { continue }
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if start < earliest { earliest = start }
            if end > latest { latest = end }
        }
        if earliest == .infinity { return (start: 0, duration: 0) }
        return (start: earliest, duration: latest - earliest)
    }
}
