import AVFoundation
import Foundation

/// Microphone authorization, and the one buffer conversion every capture path needs.
///
/// Both previously lived in `VoiceSession.swift` and outlived it: they are about *capturing* audio,
/// which the app still does, not about Apple's speech recognizer, which it no longer uses. Extracted
/// here when the Apple ASR stack was deleted so neither had to drag `import Speech` along.
enum AudioCapture {

    /// Whether the microphone TCC permission is granted.
    ///
    /// Queries rather than prompts, so it is safe to call on any path -- including at launch, where a
    /// prompt would stack dialogs on a returning user.
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Fire the system microphone prompt. A no-op once the user has answered it, in either direction:
    /// macOS shows the dialog only while the decision is undetermined.
    static func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Logger.log("Voice", "Microphone auth: \(granted)")
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    /// Convert a capture callback's sample buffer into an `AVAudioPCMBuffer`.
    ///
    /// Returns nil rather than trapping when the format description is missing or unusable: a capture
    /// session can hand over a buffer mid-route-change (a Bluetooth mic switching into SCO), and
    /// dropping one buffer is far better than crashing a recording.
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
