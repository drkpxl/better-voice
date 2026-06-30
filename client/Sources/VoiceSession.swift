@preconcurrency import AVFoundation
import CoreMedia
import Speech
import BetterVoiceCore

// MARK: - Transcription Data Types

/// Word-level info for a transcription result
struct WordInfo: Codable {
    let text: String
    let confidence: Float
    let alternatives: [String]
    let startTime: TimeInterval
    let duration: TimeInterval
}

/// Complete transcription result for a single voice session
struct TranscriptionResult: Codable {
    let fullText: String
    let words: [WordInfo]
    let audioPath: String?
    let timestamp: Date
}

// MARK: - VoiceSession

/// Voice session: uses Apple SpeechAnalyzer (WWDC 2025) for on-device real-time transcription
/// Audio capture uses AVCaptureSession (compatible with Bluetooth and other audio devices)
/// AVAudioEngine's installTap doesn't fire callbacks on Bluetooth devices
@MainActor
final class VoiceSession {
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?
    private var audioFileURL: URL?

    private(set) var isRunning = false

    // Accumulated transcription results
    private var finalizedText = ""
    private var volatileText = ""
    private var allWords: [WordInfo] = []

    /// Callback fired when recognition completes
    var onResult: ((TranscriptionResult) -> Void)?

    /// Real-time partial result callback (optional, for UI display)
    var onPartialResult: ((String) -> Void)?

    /// Real-time audio level callback (raw RMS before normalization, 0...1, used for the waveform indicator)
    var onAudioLevel: ((Float) -> Void)?

    init() {}

    nonisolated static func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Logger.log("Voice", "Microphone auth: \(granted)")
        }
    }

    nonisolated static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Start recording + real-time transcription
    func start() async throws {
        guard Self.isAuthorized else {
            throw VoiceError.notAuthorized
        }

        finalizedText = ""
        volatileText = ""
        allWords = []

        // 1. Find the best Chinese locale
        let bestLocale = await findChineseLocale()
        guard let bestLocale else {
            throw VoiceError.recognizerUnavailable
        }
        Logger.log("Voice", "Using locale: \(bestLocale.identifier(.bcp47))")

        // 2. Configure SpeechTranscriber (volatile for real-time UI echo, confidence for server-side distillation)
        let transcriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        self.transcriber = transcriber

        // 3. Ensure the speech model is installed
        try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

        // 4. Create SpeechAnalyzer (processLifetime keeps the model resident for the process's lifetime, avoiding unload between hotkey presses)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        self.analyzer = analyzer

        // Get the best audio format
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        Logger.log("Voice", "Analyzer format: \(analyzerFormat as Any)")

        // 5. Warm up the model (reduces first hotkey response from ~800ms to <100ms)
        let prepareT0 = CFAbsoluteTimeGetCurrent()
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)
        Logger.log("Voice", "prepareToAnalyze took \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - prepareT0))s")

        // 6. Create an AsyncStream for audio input
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // 7. Start the analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // 7. Start the result-processing task
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)

                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""

                        let words = self.extractWords(from: result.text)
                        self.allWords.append(contentsOf: words)

                        Logger.log("Voice", "Final segment: \(text) (\(words.count) words)")
                    } else {
                        self.volatileText = text
                        self.onPartialResult?(self.finalizedText + text)
                    }
                }
            } catch {
                Logger.log("Voice", "Result stream error: \(error)")
            }
        }

        // 8. Prepare the audio file
        let fileName = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = BetterVoiceDataDir.audioURL(forName: fileName)
        audioFileURL = url

        // 9. Start AVCaptureSession (replaces AVAudioEngine, compatible with Bluetooth devices)
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw VoiceError.noAudioDevice
        }
        Logger.log("Voice", "Audio device: \(audioDevice.localizedName)")

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        let captureQueue = DispatchQueue(label: "com.antigravity.we.audio-capture")

        // Create the delegate, capturing all needed local variables (avoids accessing @MainActor self)
        let delegate = AudioCaptureDelegate(
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioFileURL: url,
            onAudioLevel: { [weak self] level in
                DispatchQueue.main.async {
                    self?.onAudioLevel?(level)
                }
            }
        )
        audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.addOutput(audioOutput)

        self.captureDelegate = delegate
        self.captureSession = session

        session.startRunning()
        self.isRunning = true

        Logger.log("Voice", "Session started (AVCaptureSession + SpeechAnalyzer)")
    }

    /// Inject correction-dictionary keywords into SA at runtime (improves recognition accuracy for proper nouns/terminology)
    func updateContext(contextualWords: [String]) async {
        guard let analyzer, !contextualWords.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualWords
        do {
            try await analyzer.setContext(context)
            let preview = contextualWords.prefix(5).joined(separator: ", ")
            let suffix = contextualWords.count > 5 ? "..." : ""
            Logger.log("Voice", "SA context injected \(contextualWords.count) contextualStrings: [\(preview)\(suffix)]")
        } catch {
            Logger.log("Voice", "SA context update failed: \(error)")
        }
    }

    /// Stop recording and wait for the final result
    func stop() async -> TranscriptionResult {
        guard isRunning else {
            return TranscriptionResult(fullText: "", words: [], audioPath: nil, timestamp: Date())
        }

        let stopT0 = CFAbsoluteTimeGetCurrent()
        let bufferCountBefore = captureDelegate?.bufferCount ?? 0

        // Stop audio capture
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate?.close()
        captureDelegate = nil

        let stopT1 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: capture stopped in \(String(format: "%.3f", stopT1 - stopT0))s, buffers received: \(bufferCountBefore)")
        Logger.log("Voice", "[DIAG] stop: finalizedText=\(finalizedText.count) chars, volatileText=\(volatileText.count) chars, words=\(allWords.count)")

        // Tell the analyzer the audio has ended
        inputBuilder?.finish()
        Logger.log("Voice", "[DIAG] stop: inputBuilder.finish()")

        // Wait for the analyzer to finish (with timeout)
        let stopT2 = CFAbsoluteTimeGetCurrent()
        var finalizeTimedOut = false
        do {
            try await withThrowingTimeout(seconds: 5) {
                try await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
            let finalizeTime = CFAbsoluteTimeGetCurrent() - stopT2
            Logger.log("Voice", "[DIAG] stop: finalize completed in \(String(format: "%.3f", finalizeTime))s")
        } catch {
            let finalizeTime = CFAbsoluteTimeGetCurrent() - stopT2
            finalizeTimedOut = true
            Logger.log("Voice", "[DIAG] stop: finalize TIMEOUT/ERROR in \(String(format: "%.3f", finalizeTime))s: \(error)")
        }

        // Give resultTask a brief window to process the final result, then force-cancel
        let stopT3 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: post-finalize finalizedText=\(finalizedText.count) chars, volatileText=\(volatileText.count) chars")
        try? await Task.sleep(for: .milliseconds(500))
        resultTask?.cancel()
        resultTask = nil
        let stopT4 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: resultTask cancelled, sleep+cancel took \(String(format: "%.3f", stopT4 - stopT3))s")

        let fullText = finalizedText + volatileText
        isRunning = false

        // Clean up
        analyzer = nil
        transcriber = nil

        // Diagnostic summary
        let totalStopTime = CFAbsoluteTimeGetCurrent() - stopT0
        let lastWordEnd = allWords.last.map { $0.startTime + $0.duration } ?? 0
        Logger.log("Voice", "[DIAG] stop: SUMMARY | total=\(String(format: "%.3f", totalStopTime))s | timedOut=\(finalizeTimedOut) | finalizedText=\(finalizedText.count) chars | volatileText=\(volatileText.count) chars | fullText=\(fullText.count) chars | lastWordEnd=\(String(format: "%.1f", lastWordEnd))s | words=\(allWords.count)")
        Logger.log("Voice", "Session stopped, text: \(fullText)")

        return TranscriptionResult(
            fullText: fullText,
            words: allWords,
            audioPath: audioFileURL?.path,
            timestamp: Date()
        )
    }

    // MARK: - Locale Lookup

    private func findChineseLocale() async -> Locale? {
        // Now follows the configured/system language (see SpeechUtils.bestLocale).
        await SpeechUtils.bestLocale()
    }

    // MARK: - Word-Level Info Extraction

    private func extractWords(from attrText: AttributedString) -> [WordInfo] {
        var words: [WordInfo] = []
        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        for (confidence, timeRange, range) in attrText.runs[ConfKey.self, TimeKey.self] {
            let wordText = String(attrText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let startTime = timeRange?.start.seconds ?? 0
            let duration = timeRange?.duration.seconds ?? 0

            words.append(WordInfo(
                text: wordText,
                confidence: Float(confidence ?? 1.0),
                alternatives: [],
                startTime: startTime,
                duration: duration
            ))
        }
        return words
    }

    // MARK: - Model Management

    private func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)

        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }
        Logger.log("Voice", "Installed locales: \(installedIDs)")

        if installedIDs.contains(localeID) {
            Logger.log("Voice", "Model for \(localeID) already installed")
            return
        }

        Logger.log("Voice", "Downloading speech model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Voice", "Model downloaded")
        }
    }
}

// MARK: - Audio Capture Delegate (nonisolated, runs on a background queue)

/// Receives CMSampleBuffer from AVCaptureSession, converts it to AVAudioPCMBuffer, then
/// feeds it to SpeechAnalyzer's inputBuilder while also writing a WAV audio file
///
/// The audio file is written manually as WAV, completely avoiding the abort crash from AVAudioFile's internal AudioConverter
final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    private let onAudioLevel: (@Sendable (Float) -> Void)?
    private var converter: AVAudioConverter?
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?
    private(set) var bufferCount = 0

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat?,
        audioFileURL: URL,
        onAudioLevel: (@Sendable (Float) -> Void)? = nil
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        // Use a .wav extension instead
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        self.onAudioLevel = onAudioLevel
        super.init()
    }

    func close() {
        finalizeWAV()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1

        // CMSampleBuffer → AVAudioPCMBuffer
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Voice", "Audio #\(bufferCount): failed to convert CMSampleBuffer") }
            return
        }

        if bufferCount <= 5 {
            Logger.log("Voice", "Audio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // Format conversion (if the capture format != the analyzer format)
        let outputBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat {

            // Lazily create the converter (needs to know the input format)
            if converter == nil {
                converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Voice", "Created converter: \(pcmBuffer.format) → \(targetFormat)")
            }

            guard let converter,
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 5 { Logger.log("Voice", "Audio #\(bufferCount): conversion failed") }
                return
            }
            outputBuffer = converted
        } else {
            outputBuffer = pcmBuffer
        }

        // Write to the WAV file (using outputBuffer, format is always consistent: Int16 16kHz mono)
        writeToWAV(buffer: outputBuffer)

        // Compute the audio level (used for the waveform indicator), only computed for Int16 buffers
        if let onAudioLevel, let channelData = outputBuffer.int16ChannelData {
            let frameCount = Int(outputBuffer.frameLength)
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            let level = WaveformMath.rms(int16: samples)
            onAudioLevel(level)
        }

        // Send to SpeechAnalyzer
        let input = AnalyzerInput(buffer: outputBuffer)
        inputBuilder.yield(input)
    }

    // MARK: - Manual WAV Writing (bypasses AVAudioFile)

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        // First write: create the file + placeholder WAV header
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            // Write a 44-byte placeholder header
            fileHandle?.write(Data(count: 44))
            wavDataSize = 0
        }

        // Extract the PCM data
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
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16))            // chunk size
        header.appendLE(UInt16(1))             // PCM format
        header.appendLE(numChannels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        // data chunk
        header.append(contentsOf: "data".utf8)
        header.appendLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Voice", "WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - Format Conversion

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

// MARK: - Data little-endian helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        return pcmBuffer
    }
}

// MARK: - Errors & Helpers

enum VoiceError: Error {
    case recognizerUnavailable
    case notAuthorized
    case noAudioDevice
    case timeout
}

/// Async execution with a timeout (throwing version)
func withThrowingTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw VoiceError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Async execution with a timeout (non-throwing version)
func withTimeout(seconds: TimeInterval, operation: @Sendable @escaping () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
        }
        await group.next()
        group.cancelAll()
    }
}
