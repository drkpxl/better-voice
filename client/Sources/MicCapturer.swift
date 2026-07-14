@preconcurrency import AVFoundation
import CoreMedia
import BetterVoiceCore

/// Mic-only audio capture for meeting recording (Bug 1: a meeting recording needs the user's OWN
/// voice, not just the far side of a call — `SystemAudioCapturer` alone taps only the Mac's
/// system audio OUTPUT, so a user talking into their mic with nothing playing captured zero
/// buffers → an empty WAV).
///
/// Mirrors `VoiceSession`'s `AVCaptureSession`-based capture (proven Bluetooth/AirPods-compatible
/// — `AVAudioEngine`'s `installTap` doesn't fire callbacks on Bluetooth input devices) but writes
/// its own WAV at the mic's native rate/format instead of feeding a `SpeechAnalyzer`: v2's
/// meeting pipeline is offline/batch (see `SystemAudioCapturer`'s doc comment), so there is no
/// live transcriber to feed here.
///
/// **Two-file design**: this capturer and `SystemAudioCapturer` each write their OWN WAV at their
/// own native rate — `MeetingCoordinator` hands BOTH files to `ImportSession`, which transcribes
/// (and, for the system file, diarizes) each independently and merges the results by timestamp
/// (`mergeSpeakerTimelines`, Core). Two independently-clocked WAVs, transcribed independently,
/// eliminates cross-clock sample drift by construction — no mixing/resampling stage exists to
/// drift in the first place — and gives ground-truth speaker attribution for free: everything on
/// this file IS the local user.
///
/// **v1 provenance** (`git show origin/v1-archive:client/Sources/MeetingSession.swift`): v1's
/// "both" mode captured the mic with exactly this same `AVCaptureSession` pattern
/// (`MeetingCaptureDelegate`, `captureOnly: true`) run alongside its system tap, kept mic and
/// system audio as two SEPARATE WAV files, transcribed independently and merged by timestamp —
/// this is that same design, restored after v2 briefly mixed the two into one file
/// (`MeetingAudioMixer`, since removed) to work around a since-lifted one-file assumption in the
/// import pipeline.
final class MicCapturer: NSObject, @unchecked Sendable {

    enum CaptureError: Error {
        case notAuthorized
        case noAudioDevice
        case alreadyCapturing
    }

    /// Normalized (0...1) amplitude per buffer, hopped to the main queue before invocation — same
    /// contract as `SystemAudioCapturer.onAudioLevel`.
    var onAudioLevel: (@Sendable (Float) -> Void)?

    private let audioFileURL: URL
    private lazy var wavWriter = PCMWavWriter(url: audioFileURL, logLabel: "Meeting mic WAV saved")

    private var captureSession: AVCaptureSession?
    private var captureDelegate: MicCaptureDelegate?
    /// The serial queue buffers are delivered (and `wavWriter.write` is called) on. Kept as a
    /// property so `stop()`/`close()` can synchronously order `wavWriter.finalize()` strictly
    /// after any in-flight `write()` — mirrors `SystemAudioCapturer.stop()`'s
    /// `sampleQueue.sync { wavWriter.finalize() }`.
    private var captureQueue: DispatchQueue?

    /// Guards `start()`/`stop()`/`close()` against misordered or re-entrant calls, matching
    /// `SystemAudioCapturer`'s state-lock discipline.
    private let stateLock = NSLock()
    private var isCapturing = false

    /// - Parameter audioFileURL: destination for the captured audio; the `.wav` extension is
    ///   enforced regardless of what's passed (matches `SystemAudioCapturer`'s init contract).
    init(audioFileURL: URL) {
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        super.init()
    }

    /// Starts mic capture. Throws `.notAuthorized` if the microphone TCC permission isn't
    /// granted. Callers (`MeetingCoordinator`) should treat any thrown error here as "continue
    /// the meeting without mic audio" (system audio alone — the pre-fix behavior), not as a
    /// fatal meeting-start failure: unlike System Audio Recording, mic permission is a normal
    /// queryable/promptable TCC permission the app already requests at launch for dictation, but
    /// a user can still have it undetermined or denied when a meeting starts.
    func start() async throws {
        let canStart = stateLock.withLock { () -> Bool in
            if isCapturing { return false }
            isCapturing = true
            return true
        }
        guard canStart else { throw CaptureError.alreadyCapturing }

        var started = false
        defer { if !started { stateLock.withLock { isCapturing = false } } }

        guard VoiceSession.isAuthorized else {
            throw CaptureError.notAuthorized
        }
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noAudioDevice
        }

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        let captureQueue = DispatchQueue(label: "com.baselinemakes.bettervoice2.meeting-mic-capture")

        let delegate = MicCaptureDelegate(
            onPCMBuffer: { [weak self] buffer in self?.wavWriter.write(buffer: buffer) },
            onAudioLevel: { [weak self] level in
                guard let onAudioLevel = self?.onAudioLevel else { return }
                DispatchQueue.main.async { onAudioLevel(level) }
            }
        )
        audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.addOutput(audioOutput)

        self.captureDelegate = delegate
        self.captureSession = session
        self.captureQueue = captureQueue
        session.startRunning()

        started = true
        Logger.log("Meeting", "MicCapturer started (\(audioDevice.localizedName)) → \(audioFileURL.lastPathComponent)")
    }

    /// Stops capture + finalizes the WAV. No-op if not currently capturing.
    func stop() async {
        let wasCapturing = stateLock.withLock { () -> Bool in
            if isCapturing { isCapturing = false; return true }
            return false
        }
        guard wasCapturing else { return }
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        // Finalize ON the capture queue so it's ordered strictly after any write() the delegate
        // may still be executing — `stopRunning()` doesn't guarantee an in-flight callback
        // returned first.
        if let captureQueue {
            captureQueue.sync { wavWriter.finalize() }
        } else {
            wavWriter.finalize()
        }
        self.captureQueue = nil
        Logger.log("Meeting", "MicCapturer stopped")
    }

    /// Synchronous teardown for the app-quitting path — mirrors `SystemAudioCapturer.close()`.
    /// Idempotent; safe even if `start()` never fully completed.
    func close() {
        stateLock.withLock { isCapturing = false }
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        if let captureQueue {
            captureQueue.sync { wavWriter.finalize() }
        } else {
            wavWriter.finalize()
        }
        self.captureQueue = nil
    }
}

/// Receives `CMSampleBuffer`s from `AVCaptureSession`, converts to `AVAudioPCMBuffer` (reusing
/// `CMSampleBuffer.toPCMBuffer()` from VoiceSession.swift), and forwards each buffer — no
/// `SpeechAnalyzer` involved here, unlike `VoiceSession`'s own `AudioCaptureDelegate`.
private final class MicCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let onAudioLevel: (@Sendable (Float) -> Void)?
    private var bufferCount = 0

    init(onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?, onAudioLevel: (@Sendable (Float) -> Void)?) {
        self.onPCMBuffer = onPCMBuffer
        self.onAudioLevel = onAudioLevel
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Meeting", "Mic #\(bufferCount): failed to convert CMSampleBuffer") }
            return
        }
        if bufferCount <= 3 {
            Logger.log("Meeting", "Mic #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        if let onAudioLevel {
            onAudioLevel(Self.rmsLevel(of: pcmBuffer))
        }

        onPCMBuffer?(pcmBuffer)
    }

    /// Normalized (0...1) RMS of channel 0, handling both Int16 (matches `WaveformMath.rms`) and
    /// Float32 capture formats — the built-in mic and a Bluetooth mic can differ here.
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        if let channelData = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            return WaveformMath.rms(int16: samples)
        }
        if let channelData = buffer.floatChannelData {
            var sumSquares: Double = 0
            for i in 0..<frameCount {
                let s = Double(channelData[0][i])
                sumSquares += s * s
            }
            return Float((sumSquares / Double(frameCount)).squareRoot())
        }
        return 0
    }
}
