import Foundation

/// Plain, Foundation-only diarizer settings. `BetterVoiceCore` cannot import FluidAudio,
/// so the app maps these values onto FluidAudio's `DiarizerConfig` at the call site.
public struct DiarizationSettings: Sendable, Equatable {
    /// Speaker clustering threshold, 0.5…0.9. Lower = more speakers.
    /// FluidAudio's own default is 0.7 (over-merges); we default to 0.55.
    public let clusteringThreshold: Float
    /// Minimum speech duration in seconds (FluidAudio default 1.0).
    public let minSpeechDuration: Float
    /// Minimum silence gap in seconds (FluidAudio default 0.5).
    public let minSilenceGap: Float

    public init(
        clusteringThreshold: Float = 0.55,
        minSpeechDuration: Float = 1.0,
        minSilenceGap: Float = 0.5
    ) {
        self.clusteringThreshold = clusteringThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceGap = minSilenceGap
    }
}

/// Valid range for the clustering threshold. Out-of-range values are pinned, not rejected.
private let clusteringThresholdRange: ClosedRange<Float> = 0.5...0.9

/// Coerce a JSON value (Double / Float / Int) to Float; nil for anything else (e.g. String, Bool).
private func floatValue(_ any: Any?) -> Float? {
    switch any {
    case let d as Double: return Float(d)
    case let f as Float: return f
    case let i as Int: return Float(i)
    default: return nil
    }
}

/// Parses the `meeting.diarization` config dict. Missing/wrong-type keys fall back to defaults.
/// `clusteringThreshold` is CLAMPED to 0.5…0.9 (out-of-range values are pinned, not rejected).
public func parseDiarizationSettings(_ dict: [String: Any]) -> DiarizationSettings {
    let defaults = DiarizationSettings()

    let threshold: Float
    if let raw = floatValue(dict["clustering_threshold"]) {
        threshold = min(max(raw, clusteringThresholdRange.lowerBound), clusteringThresholdRange.upperBound)
    } else {
        threshold = defaults.clusteringThreshold
    }

    let minSpeech = floatValue(dict["min_speech_duration"]) ?? defaults.minSpeechDuration
    let minSilence = floatValue(dict["min_silence_gap"]) ?? defaults.minSilenceGap

    return DiarizationSettings(
        clusteringThreshold: threshold,
        minSpeechDuration: minSpeech,
        minSilenceGap: minSilence
    )
}
