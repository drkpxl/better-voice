@preconcurrency import AVFoundation
import Speech

/// B4: Sample-level mixer
///
/// Used for meeting mode, which records mic + system simultaneously. After both
/// 16kHz Float32 mono sample streams arrive, a timed window (100ms) drains them,
/// sums them sample-by-sample, and yields the result to SpeechAnalyzer.
///
/// Time alignment strategy: timed drain (not strict alignment). The two streams arrive
/// asynchronously; each drain window takes whatever samples are available, padding the
/// shorter one with zeros. A timing error on the order of ~100ms is acceptable for SA
/// transcription and avoids the complexity of strict host-time alignment.
///
/// Mixing rule: `mixed = (mic + system) * 0.5`, a 50-50 blend to prevent overload.
///
/// Threading model:
/// - feed is called synchronously from the capturer's background queue (nonisolated + protected by NSLock)
/// - drainAndMix fires on a timer on the MainActor; internally it grabs a sample snapshot via the
///   nonisolated drainBuffers() (sync + lock), then performs the mix + yield on the MainActor
@MainActor
final class AudioMixer {

    private let analyzerFormat: AVAudioFormat?
    private let diarizationFormat: AVAudioFormat
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let onDiarizationSamples: @Sendable ([Float]) -> Void

    /// Shared sample buffer (nonisolated + NSLock)
    private nonisolated(unsafe) var micBuffer: [Float] = []
    private nonisolated(unsafe) var sysBuffer: [Float] = []
    private nonisolated(unsafe) var _micSamplesFed: Int = 0
    private nonisolated(unsafe) var _sysSamplesFed: Int = 0
    private let bufferLock = NSLock()

    /// MainActor-exclusive
    private var drainTask: Task<Void, Never>?
    private var mixOutputCount: Int = 0
    private let windowMs: Int = 100

    init(
        analyzerFormat: AVAudioFormat?,
        diarizationFormat: AVAudioFormat,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        onDiarizationSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        self.analyzerFormat = analyzerFormat
        self.diarizationFormat = diarizationFormat
        self.inputBuilder = inputBuilder
        self.onDiarizationSamples = onDiarizationSamples
    }

    func start() {
        let interval = windowMs
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
                guard let self else { return }
                await self.drainAndMix()
            }
        }
        Logger.log("Meeting", "AudioMixer started, window=\(windowMs)ms")
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        // Final drain to flush any remaining samples
        await drainAndMix()
        let (micFed, sysFed) = readCounts()
        Logger.log("Meeting", "AudioMixer stopped. micFed=\(micFed) sysFed=\(sysFed) mixed=\(mixOutputCount)")
    }

    // MARK: - Sample delivery (nonisolated, called from background queue)

    nonisolated func feedMic(_ samples: [Float]) {
        bufferLock.lock()
        micBuffer.append(contentsOf: samples)
        _micSamplesFed += samples.count
        bufferLock.unlock()
    }

    nonisolated func feedSystem(_ samples: [Float]) {
        bufferLock.lock()
        sysBuffer.append(contentsOf: samples)
        _sysSamplesFed += samples.count
        bufferLock.unlock()
    }

    // MARK: - Drain + Mix

    /// Drain and clear both buffers (sync, lock-protected, async-safe)
    private nonisolated func drainBuffers() -> (mic: [Float], sys: [Float]) {
        bufferLock.lock()
        let m = micBuffer
        let s = sysBuffer
        micBuffer.removeAll(keepingCapacity: true)
        sysBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        return (m, s)
    }

    /// Read the sample counts (sync, lock-protected)
    private nonisolated func readCounts() -> (mic: Int, sys: Int) {
        bufferLock.lock()
        let r = (_micSamplesFed, _sysSamplesFed)
        bufferLock.unlock()
        return r
    }

    private func drainAndMix() async {
        let (mic, sys) = drainBuffers()

        if mic.isEmpty && sys.isEmpty {
            return
        }

        // Align to whichever stream is longer, padding the shorter one with zeros
        let len = max(mic.count, sys.count)
        var mixed = [Float](repeating: 0, count: len)
        for i in 0..<len {
            let m = i < mic.count ? mic[i] : 0
            let s = i < sys.count ? sys[i] : 0
            mixed[i] = (m + s) * 0.5
        }

        mixOutputCount += 1

        // Send to SA (converted to an analyzerFormat PCM buffer)
        if let analyzerFormat,
           let pcmBuffer = makeAnalyzerBuffer(from: mixed, targetFormat: analyzerFormat) {
            inputBuilder.yield(AnalyzerInput(buffer: pcmBuffer))
        }

        // Send to diarization
        onDiarizationSamples(mixed)
    }

    /// 16kHz Float32 mono samples → analyzerFormat AVAudioPCMBuffer
    private func makeAnalyzerBuffer(from samples: [Float], targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let srcFormat = diarizationFormat
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        srcBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = srcBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                dst[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        // If the target format is already Float32 mono 16kHz, return it directly
        if srcFormat.sampleRate == targetFormat.sampleRate
            && srcFormat.commonFormat == targetFormat.commonFormat
            && srcFormat.channelCount == targetFormat.channelCount {
            return srcBuffer
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat),
              let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count * 2)) else {
            return nil
        }

        var error: NSError?
        let consumed = Box(false)
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        return (error == nil && outBuf.frameLength > 0) ? outBuf : nil
    }
}
