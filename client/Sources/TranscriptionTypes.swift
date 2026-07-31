import AVFoundation
import Foundation
import BetterVoiceCore

/// Captured audio on its way to an engine.
///
/// A box because `AVAudioPCMBuffer` is not `Sendable` and the engine is an actor. `@unchecked` is sound
/// here by ownership, not by luck: the buffer is built by `DictationRecorder.stop()` *after* the
/// capture session has been torn down and synchronised on its own queue, so nothing is still writing
/// to it, and nothing mutates it afterwards -- it is read once by the engine and dropped. Same
/// justification as `OfflineDiarizerHost.ManagerBox`.
struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    var duration: TimeInterval {
        buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
    }
}

/// Engine-neutral transcription failures.
///
/// Kept separate from `ImportError` so the seam stays usable from the dictation path in Phase 3
/// without dragging import-specific cases along.
enum TranscriptionError: LocalizedError {
    /// The engine's models are not installed and could not be prepared.
    case modelUnavailable(String)
    /// The file could not be read or decoded.
    case unreadableAudio(String)
    /// The engine started but failed partway.
    case engineFailure(String)
    /// The requested locale is not supported and no fallback applies.
    case unsupportedLocale(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let detail):
            return t("Speech model isn't ready.") + " (\(detail))"
        case .unreadableAudio(let detail):
            return t("Couldn't read that audio file. It may be an unsupported or protected format.") + " (\(detail))"
        case .engineFailure(let detail):
            return t("Transcription failed.") + " (\(detail))"
        case .unsupportedLocale(let detail):
            return t("That language isn't supported for transcription.") + " (\(detail))"
        }
    }
}
