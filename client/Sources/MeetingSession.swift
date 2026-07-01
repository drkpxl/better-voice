@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import BetterVoiceCore
import Speech

// MARK: - Meeting Recording Session

/// Long-running meeting recording session: continuous transcription + batch speaker diarization.
/// Audio capture reuses VoiceSession's AVCaptureSession approach (Bluetooth-device compatible).
/// Transcription runs in real time via SpeechAnalyzer streaming; diarization runs in a batch after recording stops.
@MainActor
final class MeetingSession {

    // MARK: - Public State

    private(set) var isRunning = false
    private(set) var transcriptSegments: [MeetingSegment] = []
    private(set) var duration: TimeInterval = 0

    // MARK: - Callbacks

    /// Real-time transcript update (text, isFinal)
    var onTranscriptUpdate: ((String, Bool) -> Void)?

    /// Periodic duration update (fires every second)
    var onDurationUpdate: ((TimeInterval) -> Void)?

    // MARK: - Audio Capture

    private var captureSession: AVCaptureSession?
    private var captureDelegate: MeetingCaptureDelegate?
    private var systemAudioCapturer: SystemAudioCapturer?
    private var audioMixer: AudioMixer?

    // MARK: - SpeechAnalyzer Transcription

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?

    // MARK: - Diarization Buffer (16kHz Float32 mono)

    private var diarizationBuffer: [Float] = []

    /// Phrase-level transcript entries (with timestamps), used at stop() for fine-grained per-speaker grouping.
    /// Phrase-level transcript entries with timestamps; used at stop() for
    /// fine-grained per-speaker grouping. Populated only on the live start() path.
    private var allPhraseEntries: [SegmentBuffer.Entry] = []
    private let diarizationSampleRate: Int = 16000

    // MARK: - Duration Timer

    private var durationTimer: Task<Void, Never>?
    private var startDate: Date?

    // MARK: - Audio File

    private var audioFileURL: URL?

    // MARK: - Interruption Recovery

    private var interruptionObservers: [NSObjectProtocol] = []

    // MARK: - Segmentation / L2 Pipeline

    private var segmentBuffer: SegmentBuffer?
    private var polishedSegments: [MeetingSegment] = []
    private var currentVolatileText: String = ""

    // Streamed to disk (one line written immediately after each segment's L2 completes)
    private let meetingHistory = MeetingHistory()
    private var meetingId: String = ""

    // L2 stats (summary logged at stop)
    private var l2Changed = 0
    private var l2Identity = 0
    private var l2Failed = 0
    private var l2Skipped = 0
    private var l2TotalElapsedMs = 0
    private var l2CallCount = 0

    init() {}

    // MARK: - File Input Mode (for evaluation)

    /// Run the full meeting pipeline (transcription + diarization + alignment) from a WAV file.
    /// Substitutes for AVCaptureSession; the rest of the pipeline is identical.
    func runFromFile(_ fileURL: URL, locale: String = "zh-CN") async -> MeetingResult {
        // Reset state
        transcriptSegments = []
        polishedSegments = []
        currentVolatileText = ""
        diarizationBuffer = []
        allPhraseEntries = []
        duration = 0
        resetL2Stats()
        setupSegmentBuffer()
        audioFileURL = fileURL
        meetingId = "bench-" + fileURL.deletingPathExtension().lastPathComponent

        let localeObj = Locale(identifier: locale)

        do {
            // 1. Configure SpeechTranscriber (identical to start())
            let bestLocale = await findChineseLocale() ?? localeObj
            Logger.log("Meeting", "[Bench] Using locale: \(bestLocale.identifier(.bcp47))")

            let transcriber = SpeechTranscriber(
                locale: bestLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            self.transcriber = transcriber
            try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

            // 2. Create SpeechAnalyzer (processLifetime keeps the model resident for the process lifetime)
            let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
            self.analyzer = analyzer

            // 2.5 Contextual injection (dictionary + optional OCR), unified with the Remote/Voice paths
            await injectContextualStrings(analyzer: analyzer)

            // 3. Start result handling (resultTask identical to start())
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)

                        if result.isFinal {
                            let timeRange = self.extractTimeRange(from: result.text)
                            let entry = SegmentBuffer.Entry(
                                text: text,
                                startTime: timeRange.start,
                                endTime: timeRange.start + timeRange.duration
                            )
                            self.allPhraseEntries.append(entry)
                            self.currentVolatileText = ""

                            Logger.log("Meeting", "[Bench] Final: \"\(text.prefix(40))\" [\(String(format: "%.1f", timeRange.start))-\(String(format: "%.1f", timeRange.start + timeRange.duration))s]")
                            self.onTranscriptUpdate?(text, true)
                            await self.segmentBuffer?.feed(entry)
                        } else {
                            self.currentVolatileText = text
                            self.onTranscriptUpdate?(text, false)
                        }
                    }
                } catch {
                    Logger.log("Meeting", "[Bench] Result stream error: \(error)")
                }
            }

            // 4. Read audio from file to fill diarizationBuffer (16kHz Float32 mono)
            Logger.log("Meeting", "[Bench] Loading audio: \(fileURL.lastPathComponent)")
            let audioFile = try AVAudioFile(forReading: fileURL)
            let fileFormat = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            duration = Double(frameCount) / fileFormat.sampleRate
            Logger.log("Meeting", "[Bench] Audio: \(String(format: "%.1f", duration))s, \(Int(fileFormat.sampleRate))Hz, \(fileFormat.channelCount)ch")

            // Convert to 16kHz Float32 mono for diarization
            let diaFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(diarizationSampleRate),
                channels: 1,
                interleaved: false
            )!

            let fullBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount)!
            try audioFile.read(into: fullBuffer)

            if fileFormat.sampleRate != diaFormat.sampleRate
                || fileFormat.commonFormat != diaFormat.commonFormat
                || fileFormat.channelCount != diaFormat.channelCount {
                let converter = AVAudioConverter(from: fileFormat, to: diaFormat)!
                let ratio = diaFormat.sampleRate / fileFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
                let outBuffer = AVAudioPCMBuffer(pcmFormat: diaFormat, frameCapacity: outCapacity)!

                var error: NSError?
                let consumed = Box(false)
                converter.convert(to: outBuffer, error: &error) { _, outStatus in
                    if consumed.value {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed.value = true
                    outStatus.pointee = .haveData
                    return fullBuffer
                }

                if let floatData = outBuffer.floatChannelData {
                    diarizationBuffer = Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
                }
            } else {
                if let floatData = fullBuffer.floatChannelData {
                    diarizationBuffer = Array(UnsafeBufferPointer(start: floatData[0], count: Int(fullBuffer.frameLength)))
                }
            }
            Logger.log("Meeting", "[Bench] Diarization buffer: \(diarizationBuffer.count) samples")

            // 5. Use SpeechAnalyzer's file input API (Apple-native, replaces AVCaptureSession)
            Logger.log("Meeting", "[Bench] Starting SpeechAnalyzer from file...")
            let inputFile = try AVAudioFile(forReading: fileURL)
            let startTime = CFAbsoluteTimeGetCurrent()
            try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)

            // start returns immediately; results arrive asynchronously via transcriber.results
            // Wait for resultTask to finish (the for-await loop ends once the analyzer finalizes)
            await resultTask?.value
            let transcribeTime = CFAbsoluteTimeGetCurrent() - startTime
            Logger.log("Meeting", "[Bench] Transcription done in \(String(format: "%.1f", transcribeTime))s (RTFx: \(String(format: "%.1f", duration / transcribeTime)))")

            resultTask = nil
            self.analyzer = nil
            self.transcriber = nil

            // Flush the tail: last buffer batch → L2
            await segmentBuffer?.flushFinal()
            logL2Summary()

            Logger.log("Meeting", "[Bench] L2 pipeline: \(polishedSegments.count) segments produced")

            // 6. Run speaker diarization (identical to stop())
            let diarizedSegments = await performDiarization()

            // 7. Build the result
            let result = MeetingResult(
                segments: diarizedSegments,
                duration: duration,
                audioPath: fileURL.path
            )

            // DER-proxy scoring against the optional <wav>.speakers.json ground-truth sidecar.
            if let score = MeetingBenchmark.benchDiarizationScore(segments: diarizedSegments, audioPath: fileURL.path) {
                Logger.log("Meeting", "[Bench] DER-proxy: fer=\(String(format: "%.3f", score.frameErrorRate)) scErr=\(score.speakerCountError)")
            }

            // Cleanup
            diarizationBuffer = []
            polishedSegments = []
            segmentBuffer = nil

            Logger.log("Meeting", "[Bench] Complete: \(diarizedSegments.count) segments with speaker labels")
            return result

        } catch {
            Logger.log("Meeting", "[Bench] Error: \(error)")
            return MeetingResult(segments: [], duration: 0, audioPath: fileURL.path)
        }
    }

    // MARK: - Microphone Start (normal usage)

    func start() async throws {
        guard !isRunning else { return }

        guard VoiceSession.isAuthorized else {
            throw VoiceError.notAuthorized
        }

        // Reset state
        transcriptSegments = []
        polishedSegments = []
        currentVolatileText = ""
        diarizationBuffer = []
        allPhraseEntries = []
        duration = 0
        resetL2Stats()
        setupSegmentBuffer()

        // 1. Find the best Chinese locale
        let bestLocale = await findChineseLocale()
        guard let bestLocale else {
            throw VoiceError.recognizerUnavailable
        }
        Logger.log("Meeting", "Using locale: \(bestLocale.identifier(.bcp47))")

        // 2. Configure SpeechTranscriber (with volatile + audioTimeRange, consistent with VoiceSession)
        let transcriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // 3. Ensure the speech model is installed
        try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

        // 4. Create SpeechAnalyzer (processLifetime keeps the model from being unloaded during a long meeting)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        self.analyzer = analyzer

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        Logger.log("Meeting", "Analyzer format: \(analyzerFormat as Any)")

        // 4.5 Warm up the model (cuts the first segment's transcription latency from ~800ms to <100ms)
        let prepareT0 = CFAbsoluteTimeGetCurrent()
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)
        Logger.log("Meeting", "prepareToAnalyze took \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - prepareT0))s")

        // 4.6 Contextual injection (dictionary + optional OCR), unified with the Remote/Voice paths
        await injectContextualStrings(analyzer: analyzer)

        // 5. Create the AsyncStream input channel
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // 6. Start the analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // 7. Start the result handling task
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)

                    if result.isFinal {
                        // Extract audioTimeRange
                        let timeRange = self.extractTimeRange(from: result.text)
                        let entry = SegmentBuffer.Entry(
                            text: text,
                            startTime: timeRange.start,
                            endTime: timeRange.start + timeRange.duration
                        )
                        self.allPhraseEntries.append(entry)
                        self.currentVolatileText = ""

                        Logger.log("Meeting", "Final: \"\(text)\" [\(String(format: "%.1f", timeRange.start))-\(String(format: "%.1f", timeRange.start + timeRange.duration))s]")
                        self.onTranscriptUpdate?(text, true)
                        await self.segmentBuffer?.feed(entry)
                    } else {
                        self.currentVolatileText = text
                        self.onTranscriptUpdate?(text, false)
                    }
                }
            } catch {
                Logger.log("Meeting", "Result stream error: \(error)")
            }
        }

        // 8. Prepare the audio file path
        let fileName = "meeting-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = BetterVoiceDataDir.audioURL(forName: fileName)
        audioFileURL = url
        meetingId = fileName  // used as the unique meeting ID for the streamed jsonl

        // 9. Start audio capture (mic / system / both, chosen from config)
        let audioSource = (RuntimeConfig.shared.meetingConfig["audio_source"] as? String) ?? "mic"
        Logger.log("Meeting", "Audio source: \(audioSource)")

        // Diarization target format (shared by the mixer / capturer)
        let diarizationFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(diarizationSampleRate),
            channels: 1,
            interleaved: false
        )!

        // Diarization callback (shared)
        let onDiaSamples: @Sendable ([Float]) -> Void = { [weak self] samples in
            DispatchQueue.main.async {
                self?.diarizationBuffer.append(contentsOf: samples)
            }
        }

        switch audioSource {
        case "system":
            let cap = SystemAudioCapturer(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: url,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples
            )
            try await cap.start()
            self.systemAudioCapturer = cap

        case "both":
            // B4: mic + system captured in parallel → AudioMixer sample-level mixing → SA
            let mixer = AudioMixer(
                analyzerFormat: analyzerFormat,
                diarizationFormat: diarizationFormat,
                inputBuilder: inputBuilder,
                onDiarizationSamples: onDiaSamples
            )
            mixer.start()
            self.audioMixer = mixer

            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw VoiceError.noAudioDevice
            }
            Logger.log("Meeting", "[both] Mic device: \(audioDevice.localizedName)")

            let micFileURL = url.deletingPathExtension().appendingPathExtension("mic.wav")
            let session = AVCaptureSession()
            let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
            session.addInput(deviceInput)

            let audioOutput = AVCaptureAudioDataOutput()
            let captureQueue = DispatchQueue(label: "com.antigravity.we.meeting-capture")

            let delegate = MeetingCaptureDelegate(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: micFileURL,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples,
                mixer: mixer
            )
            audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
            session.addOutput(audioOutput)

            self.captureDelegate = delegate
            self.captureSession = session
            session.startRunning()
            observeInterruptions(on: session)

            let sysFileURL = url.deletingPathExtension().appendingPathExtension("system.wav")
            let sysCap = SystemAudioCapturer(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: sysFileURL,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples,
                mixer: mixer
            )
            try await sysCap.start()
            self.systemAudioCapturer = sysCap

        default:  // "mic"
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw VoiceError.noAudioDevice
            }
            Logger.log("Meeting", "Audio device: \(audioDevice.localizedName)")

            let session = AVCaptureSession()
            let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
            session.addInput(deviceInput)

            let audioOutput = AVCaptureAudioDataOutput()
            let captureQueue = DispatchQueue(label: "com.antigravity.we.meeting-capture")

            let delegate = MeetingCaptureDelegate(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: url,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples
            )
            audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
            session.addOutput(audioOutput)

            self.captureDelegate = delegate
            self.captureSession = session
            session.startRunning()
            observeInterruptions(on: session)
        }

        isRunning = true
        startDate = Date()

        // 10. Start the duration timer (updates every second)
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.startDate else { return }
                self.duration = Date().timeIntervalSince(start)
                self.onDurationUpdate?(self.duration)
            }
        }

        Logger.log("Meeting", "Session started")
    }

    // MARK: - Stop + Diarization

    /// Stop recording, run batch speaker diarization, and return the full result with speakerId
    func stop() async -> MeetingResult {
        guard isRunning else {
            return MeetingResult(segments: [], duration: 0, audioPath: nil)
        }

        isRunning = false

        // Stop the timer
        durationTimer?.cancel()
        durationTimer = nil
        let finalDuration = duration

        // Stop audio capture (cleans up all three modes)
        removeInterruptionObservers()
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate?.close()
        captureDelegate = nil
        if let cap = systemAudioCapturer {
            await cap.stop()
            systemAudioCapturer = nil
        }
        if let mixer = audioMixer {
            await mixer.stop()
            audioMixer = nil
        }

        // Tell SpeechAnalyzer the audio has ended
        inputBuilder?.finish()
        Logger.log("Meeting", "Input stream finished, waiting for analyzer...")

        do {
            // 60s circuit breaker: tail audio finalize can be much slower than real-time recording for long meetings
            try await withThrowingTimeout(seconds: 60) {
                try await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
            Logger.log("Meeting", "Analyzer finalized")
        } catch {
            Logger.log("Meeting", "Finalize timeout/error: \(error)")
        }

        // Give resultTask a brief moment to process the final results
        try? await Task.sleep(for: .milliseconds(500))
        resultTask?.cancel()
        resultTask = nil

        // Clean up SA resources
        analyzer = nil
        transcriber = nil

        // Flush the tail: last buffer batch → L2
        await segmentBuffer?.flushFinal()
        logL2Summary()

        Logger.log("Meeting", "Transcription complete: \(polishedSegments.count) L2 segments, \(diarizationBuffer.count) audio samples")

        // Run speaker diarization
        let diarizedSegments = await performDiarization()

        // Build the result
        let result = MeetingResult(
            segments: diarizedSegments,
            duration: finalDuration,
            audioPath: audioFileURL?.path
        )

        // Clean up buffers
        diarizationBuffer = []
        polishedSegments = []
        segmentBuffer = nil

        Logger.log("Meeting", "Session stopped, duration=\(String(format: "%.1f", finalDuration))s, segments=\(diarizedSegments.count)")
        return result
    }

    // MARK: - Speaker Diarization

    /// Run FluidAudio diarization in batch and align the result with L2-corrected batch segments.
    /// Note: Scheme D (one flush batch = one MeetingSegment) — diarization looks up speakers by each batch's time range.
    private func performDiarization() async -> [MeetingSegment] {
        let buffer = diarizationBuffer
        let segments = polishedSegments

        // If there are no L2 segments, return empty right away
        guard !segments.isEmpty else {
            Logger.log("Meeting", "No polished segments to diarize")
            return []
        }

        // Audio too short, skip diarization
        let audioDuration = Double(buffer.count) / Double(diarizationSampleRate)
        guard audioDuration >= 2.0 else {
            Logger.log("Meeting", "Audio too short for diarization (\(String(format: "%.1f", audioDuration))s), skipping")
            return segments
        }

        Logger.log("Meeting", "Starting diarization: \(String(format: "%.1f", audioDuration))s audio")

        do {
            // Download/load models
            Logger.log("Meeting", "Loading diarization models...")
            let models = try await DiarizerModels.downloadIfNeeded(
                progressHandler: { progress in
                    Logger.log("Meeting", "Model download progress: \(String(format: "%.0f%%", progress.fractionCompleted * 100))")
                }
            )

            let diarizer = DiarizerManager(config: DiarizerConfig())
            diarizer.initialize(models: models)

            Logger.log("Meeting", "Running diarization...")
            let result = try diarizer.performCompleteDiarization(buffer, sampleRate: diarizationSampleRate)

            Logger.log("Meeting", "Diarization complete: \(result.segments.count) speaker segments")
            for seg in result.segments {
                Logger.log("Meeting", "  Speaker \(seg.speakerId): \(String(format: "%.1f", seg.startTimeSeconds))-\(String(format: "%.1f", seg.endTimeSeconds))s")
            }

            // Fine-grained alignment: group phrases by speaker; each consecutive turn = one MeetingSegment.
            // Fine-grained: label each phrase by speaker, group consecutive phrases
            // into speaker turns, polish each turn. Falls back to the coarse
            // per-batch alignment when there are no phrase entries (bench path).
            let phraseEntries = allPhraseEntries
            if phraseEntries.isEmpty {
                return alignTranscriptionWithDiarization(segments: segments, diarization: result.segments)
            }
            return await buildSpeakerTurns(entries: phraseEntries, diarization: result.segments)

        } catch {
            Logger.log("Meeting", "Diarization failed: \(error), returning segments without speaker labels")
            // Diarization failed, keep the L2 segments with speakerId = nil
            return segments
        }
    }

    /// Align L2 batch segments with diarization segments based on time overlap.
    /// For each batch segment, find the diarization segment with the longest overlap and take its speakerId.
    private func alignTranscriptionWithDiarization(
        segments: [MeetingSegment],
        diarization: [TimedSpeakerSegment]
    ) -> [MeetingSegment] {
        return segments.map { tSeg in
            let tStart = tSeg.startTime
            let tEnd = tSeg.endTime

            // Find the diarization segment with the most overlap
            var bestSpeaker: String? = nil
            var maxOverlap: TimeInterval = 0

            for dSeg in diarization {
                let dStart = TimeInterval(dSeg.startTimeSeconds)
                let dEnd = TimeInterval(dSeg.endTimeSeconds)

                let overlapStart = max(tStart, dStart)
                let overlapEnd = min(tEnd, dEnd)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > maxOverlap {
                    maxOverlap = overlap
                    bestSpeaker = dSeg.speakerId
                }
            }

            return MeetingSegment(
                text: tSeg.text,
                rawText: tSeg.rawText,
                startTime: tSeg.startTime,
                endTime: tSeg.endTime,
                speakerId: bestSpeaker,
                l2Kind: tSeg.l2Kind,
                isFinal: tSeg.isFinal
            )
        }
    }

    /// Phrase-level speaker assignment + grouping: each consecutive same-speaker turn
    /// produces one MeetingSegment, and that turn's text gets a single L2 polish pass.
    /// Assign a speaker to each phrase (max time-overlap with diarization), group
    /// consecutive same-speaker phrases into turns, and polish each turn. This is
    /// what fixes "everything under one speaker": speaker changes mid-conversation
    /// now split the transcript instead of being flattened into coarse L2 chunks.
    private func buildSpeakerTurns(
        entries: [SegmentBuffer.Entry],
        diarization: [TimedSpeakerSegment]
    ) async -> [MeetingSegment] {
        // 1. label each phrase by speaker
        let labeled = entries.map { entry -> (entry: SegmentBuffer.Entry, speaker: String?) in
            (entry, speakerForTimeRange(start: entry.startTime, end: entry.endTime, in: diarization))
        }

        // 2. group consecutive phrases by speaker into turns
        var turns: [(speaker: String?, entries: [SegmentBuffer.Entry])] = []
        for item in labeled {
            if !turns.isEmpty, turns[turns.count - 1].speaker == item.speaker {
                turns[turns.count - 1].entries.append(item.entry)
            } else {
                turns.append((speaker: item.speaker, entries: [item.entry]))
            }
        }

        // 3. polish each turn → one MeetingSegment per speaker turn
        var result: [MeetingSegment] = []
        for turn in turns {
            guard let first = turn.entries.first, let last = turn.entries.last else { continue }
            let raw = turn.entries.map(\.text).joined()
            let polished = await polishTurnText(raw)
            result.append(MeetingSegment(
                text: polished.text,
                rawText: raw,
                startTime: first.startTime,
                endTime: last.endTime,
                speakerId: turn.speaker,
                l2Kind: polished.kind,
                isFinal: true
            ))
        }
        let speakerCount = Set(result.compactMap(\.speakerId)).count
        Logger.log("Meeting", "Speaker turns: \(result.count) turns from \(entries.count) phrases, \(speakerCount) distinct speakers")
        return result
    }

    /// Find the speakerId of the diarization segment with the longest overlap with the given time range.
    /// Speaker whose diarization segment overlaps this time range the most.
    private func speakerForTimeRange(start: TimeInterval, end: TimeInterval, in diarization: [TimedSpeakerSegment]) -> String? {
        var bestSpeaker: String? = nil
        var maxOverlap: TimeInterval = 0
        var nearestSpeaker: String? = nil
        var nearestDistance = TimeInterval.greatestFiniteMagnitude
        let mid = (start + end) / 2
        for d in diarization {
            let dStart = TimeInterval(d.startTimeSeconds)
            let dEnd = TimeInterval(d.endTimeSeconds)
            let overlap = max(0, min(end, dEnd) - max(start, dStart))
            if overlap > maxOverlap {
                maxOverlap = overlap
                bestSpeaker = d.speakerId
            }
            // Time distance to this diarization segment (0 if inside it); used as a fallback when there's no overlap.
            let distance = mid < dStart ? dStart - mid : (mid > dEnd ? mid - dEnd : 0)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestSpeaker = d.speakerId
            }
        }
        // Prefer the most-overlapping speaker; otherwise take the temporally nearest speaker, eliminating "Unknown" for brief interjections.
        // Prefer the most-overlapping speaker; otherwise snap to the nearest one
        // so brief interjections in diarization gaps aren't labelled "Unknown".
        return bestSpeaker ?? nearestSpeaker
    }

    /// Run a single L2 polish pass on a chunk of text (reusing PolishClient); falls back to the raw text when disabled or on failure.
    /// Polish a turn's text via PolishClient; falls back to raw on disabled/failure.
    private func polishTurnText(_ raw: String) async -> (text: String, kind: L2Kind) {
        let polishEnabled = (RuntimeConfig.shared.polishConfig["enabled"] as? Bool) == true
        guard polishEnabled, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (raw, .skipped)
        }
        if let p = await PolishClient.shared.polish(text: raw, words: [], app: nil) {
            return (p, p == raw ? .identity : .changed)
        }
        return (raw, .failed)
    }

    // MARK: - B3.1 Interruption Recovery

    /// Subscribe to AVCaptureSession interruption/resume notifications. Triggered by Bluetooth
    /// switches or audio route changes.
    /// Recovery strategy: on interruptionEnded, check whether the session is still running;
    /// call startRunning() if it isn't.
    /// Note: if a device switch changes the audio format (Bluetooth Int16 → built-in Float32),
    /// the existing AVAudioConverter may fail. That scenario is left for later — we'll decide
    /// whether to rebuild the capture chain once we observe it in real logs.
    private func observeInterruptions(on session: AVCaptureSession) {
        let center = NotificationCenter.default
        let obs1 = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { _ in
            // macOS has no InterruptionReasonKey, just log the event
            Logger.log("Meeting", "Capture interrupted (audio route changed / device removed)")
        }
        let obs2 = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            // queue: .main ensures the callback runs on the main queue, consistent with @MainActor isolation
            MainActor.assumeIsolated {
                guard let self, let s = self.captureSession else { return }
                Logger.log("Meeting", "Capture interruption ended, isRunning=\(s.isRunning)")
                if !s.isRunning {
                    s.startRunning()
                    Logger.log("Meeting", "Capture restarted: isRunning=\(s.isRunning)")
                }
            }
        }
        let obs3 = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey]
            Logger.log("Meeting", "Capture runtime error: \(String(describing: err))")
        }
        interruptionObservers = [obs1, obs2, obs3]
    }

    private func removeInterruptionObservers() {
        for obs in interruptionObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        interruptionObservers.removeAll()
    }

    // MARK: - B1 Helpers: Segmentation + L2

    /// Read thresholds from config, create a SegmentBuffer, and attach the flush callback
    private func setupSegmentBuffer() {
        let cfg = RuntimeConfig.shared.meetingConfig
        let pauseSec = (cfg["l2_flush_on_pause_sec"] as? Double) ?? 1.5
        let maxChars = (cfg["l2_flush_on_chars"] as? Int) ?? 200
        let minChars = (cfg["l2_min_chars"] as? Int) ?? 30

        let buf = SegmentBuffer(
            pauseThresholdSec: pauseSec,
            maxChars: maxChars,
            minChars: minChars
        )
        buf.onFlush = { [weak self] batch in
            guard let self else { return }
            let seg = await self.polishBatch(batch)
            self.polishedSegments.append(seg)
        }
        self.segmentBuffer = buf
    }

    /// ContextEnhancer call + analyzer.setContext (consistent with the Remote/Voice paths)
    private func injectContextualStrings(analyzer: SpeechAnalyzer) async {
        let polish = RuntimeConfig.shared.polishConfig
        let dictEnabled = polish["context_dictionary_enabled"] as? Bool ?? false
        let dictPath = polish["context_dictionary_path"] as? String
        let words = await ContextEnhancer.enhance(
            dictionaryEnabled: dictEnabled,
            dictionaryPath: dictPath
        )
        if !words.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = words
            try? await analyzer.setContext(ctx)
            let preview = words.prefix(5).joined(separator: ", ")
            let suffix = words.count > 5 ? "..." : ""
            Logger.log("Meeting", "SA context injected \(words.count) terms: [\(preview)\(suffix)]")
        }
    }

    /// Run L2 correction on one flush batch and return the final MeetingSegment.
    /// On L2 failure, text = rawText (fallback); each call's result is appended to meeting-history.jsonl immediately.
    private func polishBatch(_ batch: SegmentBuffer.FlushBatch) async -> MeetingSegment {
        let segNum = segmentBuffer?.flushCount ?? 0
        let polishCfg = RuntimeConfig.shared.polishConfig
        let polishEnabled = (polishCfg["enabled"] as? Bool) == true

        let rawText = batch.rawText
        let rawPreview = rawText.prefix(60)

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
            Logger.log("Meeting", "L2 seg=[\(segNum)] kind=skipped reason=polish.enabled=false chars=\(rawText.count)")
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
                    Logger.log("Meeting", "L2 seg=[\(segNum)] kind=identity elapsedMs=\(elapsedMs) chars=\(rawText.count) text=\"\(rawPreview)\"")
                } else {
                    l2Changed += 1
                    l2Kind = .changed
                    finalText = p
                    let polPreview = p.prefix(60)
                    Logger.log("Meeting", "L2 seg=[\(segNum)] kind=changed elapsedMs=\(elapsedMs) chars=\(rawText.count) raw=\"\(rawPreview)\" → polished=\"\(polPreview)\"")
                }
            } else {
                polishedText = nil
                l2Failed += 1
                l2Kind = .failed
                finalText = rawText
                Logger.log("Meeting", "L2 seg=[\(segNum)] kind=failed FAILED elapsedMs=\(elapsedMs) chars=\(rawText.count) using_raw=\"\(rawPreview)\"")
            }
        }

        // Streamed to meeting-history.jsonl (one line per segment, visible while the meeting is in progress)
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
            finalText: finalText,
            l2Kind: l2Kind.rawValue,
            l2ElapsedMs: elapsedMs
        )
        meetingHistory.append(record)

        return MeetingSegment(
            text: finalText,
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

    /// Log one summary line of stats when the meeting ends (for acceptance checks).
    /// If failed>0 or fallback_used>0, that's direct evidence the L2 pipeline is unhealthy.
    private func logL2Summary() {
        let total = l2Changed + l2Identity + l2Failed + l2Skipped
        let avgMs = l2CallCount > 0 ? l2TotalElapsedMs / l2CallCount : 0
        let fallback = l2Failed + l2Skipped
        Logger.log("Meeting", "L2 summary: total=\(total) changed=\(l2Changed) identity=\(l2Identity) failed=\(l2Failed) skipped=\(l2Skipped) avgMs=\(avgMs) fallback_used=\(fallback)")
    }

    // MARK: - Extracting audioTimeRange from AttributedString

    private func extractTimeRange(from attrText: AttributedString) -> (start: TimeInterval, duration: TimeInterval) {
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        // Walk the runs to find the time range covering the whole segment
        var earliest: TimeInterval = .infinity
        var latest: TimeInterval = 0

        for (timeRange, _) in attrText.runs[TimeKey.self] {
            guard let range = timeRange else { continue }
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if start < earliest { earliest = start }
            if end > latest { latest = end }
        }

        if earliest == .infinity {
            return (start: 0, duration: 0)
        }
        return (start: earliest, duration: latest - earliest)
    }

    // MARK: - Locale Lookup (same as VoiceSession)

    private func findChineseLocale() async -> Locale? {
        // Now follows the configured/system language (see SpeechUtils.bestLocale).
        await SpeechUtils.bestLocale()
    }

    // MARK: - Model Management (same as VoiceSession)

    private func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }

        if installedIDs.contains(localeID) {
            Logger.log("Meeting", "Speech model for \(localeID) already installed")
            return
        }

        Logger.log("Meeting", "Downloading speech model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Meeting", "Speech model downloaded")
        }
    }
}

// MARK: - Meeting Audio Capture Delegate

/// Receives audio from AVCaptureSession and fans it out to:
/// 1. SpeechAnalyzer (real-time transcription)
/// 2. diarization buffer (16kHz Float32 mono accumulation)
/// 3. WAV file (persistence)
final class MeetingCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    private let diarizationSampleRate: Int
    private let onDiarizationSamples: ([Float]) -> Void
    private let mixer: AudioMixer?

    // Format converters
    private var analyzerConverter: AVAudioConverter?
    private var diarizationConverter: AVAudioConverter?

    // Diarization target format: 16kHz Float32 mono
    private lazy var diarizationFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(diarizationSampleRate),
            channels: 1,
            interleaved: false
        )
    }()

    // WAV writing
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?

    private var bufferCount = 0

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat?,
        audioFileURL: URL,
        diarizationSampleRate: Int,
        onDiarizationSamples: @escaping ([Float]) -> Void,
        mixer: AudioMixer? = nil
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        self.diarizationSampleRate = diarizationSampleRate
        self.onDiarizationSamples = onDiarizationSamples
        self.mixer = mixer
        super.init()
    }

    func close() {
        finalizeWAV()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1

        // CMSampleBuffer → AVAudioPCMBuffer (reuses VoiceSession's extension method)
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Meeting", "Audio #\(bufferCount): CMSampleBuffer conversion failed") }
            return
        }

        if bufferCount <= 3 {
            Logger.log("Meeting", "Audio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // --- Branch 1: feed SpeechAnalyzer (may require format conversion) ---
        let analyzerBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat {

            if analyzerConverter == nil {
                analyzerConverter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Meeting", "Analyzer converter: \(pcmBuffer.format) → \(targetFormat)")
            }
            guard let converter = analyzerConverter,
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 3 { Logger.log("Meeting", "Audio #\(bufferCount): analyzer conversion failed") }
                return
            }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = pcmBuffer
        }

        // Feed SpeechAnalyzer (in B4 mixing mode the mixer yields uniformly; this delegate doesn't feed directly)
        if mixer == nil {
            let input = AnalyzerInput(buffer: analyzerBuffer)
            inputBuilder.yield(input)
        }

        // Write the WAV file (raw mic stream, kept even in mixing mode for later analysis)
        writeToWAV(buffer: analyzerBuffer)

        // --- Branch 2: 16kHz Float32 mono samples → mixer or diarization ---
        if let diaFmt = diarizationFormat {
            let diaBuffer: AVAudioPCMBuffer
            if pcmBuffer.format.sampleRate != diaFmt.sampleRate
                || pcmBuffer.format.commonFormat != diaFmt.commonFormat
                || pcmBuffer.format.channelCount != diaFmt.channelCount {

                if diarizationConverter == nil {
                    diarizationConverter = AVAudioConverter(from: pcmBuffer.format, to: diaFmt)
                    Logger.log("Meeting", "Diarization converter: \(pcmBuffer.format) → \(diaFmt)")
                }
                guard let converter = diarizationConverter,
                      let converted = convert(buffer: pcmBuffer, using: converter, to: diaFmt) else {
                    return
                }
                diaBuffer = converted
            } else {
                diaBuffer = pcmBuffer
            }

            if let floatData = diaBuffer.floatChannelData {
                let frameCount = Int(diaBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                if let mixer {
                    mixer.feedMic(samples)
                } else {
                    onDiarizationSamples(samples)
                }
            }
        }
    }

    // MARK: - Manual WAV Writing

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            fileHandle?.write(Data(count: 44)) // WAV header placeholder
            wavDataSize = 0
        }

        let abl = buffer.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return }
        let byteCount = Int(abl.mBuffers.mDataByteSize)
        let data = Data(bytes: mData, count: byteCount)
        fileHandle?.write(data)
        wavDataSize += UInt32(byteCount)
    }

    private func finalizeWAV() {
        guard let fh = fileHandle, let fmt = wavFormat else {
            fileHandle = nil
            return
        }

        let asbd = fmt.streamDescription.pointee
        let numChannels = UInt16(asbd.mChannelsPerFrame)
        let sampleRate = UInt32(asbd.mSampleRate)
        let bitsPerSample = UInt16(asbd.mBitsPerChannel)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.appendMeetingLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendMeetingLE(UInt32(16))
        header.appendMeetingLE(UInt16(1)) // PCM
        header.appendMeetingLE(numChannels)
        header.appendMeetingLE(sampleRate)
        header.appendMeetingLE(byteRate)
        header.appendMeetingLE(blockAlign)
        header.appendMeetingLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendMeetingLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Meeting", "WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - Format Conversion (same block-based API as VoiceSession)

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let consumed = Box(false)
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return buffer
        }

        return (error == nil && output.frameLength > 0) ? output : nil
    }
}

// MARK: - Data little-endian helpers (avoids conflicting with VoiceSession's private extension)

private extension Data {
    mutating func appendMeetingLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendMeetingLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
