import Foundation

/// Pure logic for deciding whether a captured meeting recording is empty/silent (Bug 2):
/// `MeetingCoordinator.stopMeeting()` must not hand an empty/near-silent WAV to `ImportPipeline`
/// — that surfaces as a confusing raw transcription error instead of a clear "nothing was
/// captured, check your permissions" message.
public enum AudioSilenceCheck {

    /// RMS (0...1 normalized) below which a recording counts as "effectively silent" even if it
    /// technically has non-zero frames — well below normal speech level (typically 0.02–0.3 RMS)
    /// but above pure digital silence / measurement noise floor, so a quiet room with faint
    /// background hum doesn't false-negative as "nothing captured".
    public static let defaultRMSThreshold: Float = 0.001

    /// True when there is nothing usable to transcribe: zero frames, or overall RMS below
    /// `rmsThreshold` across the whole file. Covers both "mic capture never started" (0 frames
    /// impossible once the WAV has a header, but frameCount can still be 0 for a header-only
    /// file) and "everything captured but it's silence" — e.g. a denied System Audio Recording
    /// permission, where `SystemAudioCapturer.start()` still returns `noErr` and the tap simply
    /// delivers silence (see its doc comment) — this amplitude check is the only way to detect
    /// that after the fact.
    public static func isEffectivelySilent(frameCount: Int, rms: Float, rmsThreshold: Float = defaultRMSThreshold) -> Bool {
        guard frameCount > 0 else { return true }
        return rms < rmsThreshold
    }
}

/// Streaming RMS accumulator: lets a caller compute one overall RMS across a whole file read in
/// bounded-memory chunks (e.g. one `AVAudioFile` read of ~1s at a time), instead of loading an
/// entire (potentially hours-long) recording into memory to compute RMS in one pass.
public struct RunningRMS {
    private var sumSquares: Double = 0
    private var count: Int = 0

    public init() {}

    public mutating func add(_ samples: [Float]) {
        for s in samples {
            sumSquares += Double(s) * Double(s)
        }
        count += samples.count
    }

    /// Normalized (0...1 for well-formed PCM float samples) root-mean-square across every
    /// sample seen so far via `add(_:)`. 0 when nothing has been added yet.
    public var rms: Float {
        guard count > 0 else { return 0 }
        return Float((sumSquares / Double(count)).squareRoot())
    }

    public var sampleCount: Int { count }
}
