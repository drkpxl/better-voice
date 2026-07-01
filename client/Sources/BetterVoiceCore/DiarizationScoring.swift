import Foundation

public struct LabeledInterval: Sendable, Equatable {
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval
    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

public struct DiarizationScore: Sendable, Equatable {
    public let frameErrorRate: Double   // fraction of frames whose majority hyp speaker != ref (after optimal label mapping)
    public let speakerCountError: Int   // |distinct(hyp) - distinct(ref)|
}

/// Frame-based speaker error with greedy label mapping (a lightweight DER proxy — good enough
/// to compare pipeline changes on the same fixture; not a formal DER implementation).
///
/// Note: the metric is scored only within reference speech — it captures misses and speaker
/// confusions inside ref intervals, but ignores false-alarm frames the hypothesis emits during
/// reference silence — so don't over-trust it as a formal DER.
public func scoreDiarization(reference: [LabeledInterval],
                             hypothesis: [LabeledInterval],
                             frameSec: TimeInterval = 0.1) -> DiarizationScore {
    let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
    guard end > 0 else { return .init(frameErrorRate: 0, speakerCountError: 0) }
    func speakerAt(_ t: TimeInterval, _ ivs: [LabeledInterval]) -> String? {
        ivs.first(where: { $0.start <= t && t < $0.end })?.speaker
    }
    // greedy map hyp labels -> ref labels by co-occurrence
    var pairCounts: [String: [String: Int]] = [:]
    var frames = 0
    var t = frameSec / 2
    while t < end {
        if let r = speakerAt(t, reference) {
            frames += 1
            if let h = speakerAt(t, hypothesis) {
                pairCounts[h, default: [:]][r, default: 0] += 1
            }
        }
        t += frameSec
    }
    var map: [String: String] = [:]
    // Deterministic tie-break: higher co-occurrence count wins; on an equal count the
    // lexicographically smaller ref label wins, so unstable dictionary order can't flip the mapping.
    for (h, refs) in pairCounts { map[h] = refs.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key }
    var wrong = 0; t = frameSec / 2
    while t < end {
        if let r = speakerAt(t, reference) {
            let h = speakerAt(t, hypothesis).flatMap { map[$0] }
            if h != r { wrong += 1 }
        }
        t += frameSec
    }
    let fer = frames > 0 ? Double(wrong) / Double(frames) : 0
    let scErr = abs(Set(hypothesis.map(\.speaker)).count - Set(reference.map(\.speaker)).count)
    return .init(frameErrorRate: fer, speakerCountError: scErr)
}

/// Decodes a diarization ground-truth sidecar (a JSON array of `{"speaker","start","end"}`) into a
/// reference and scores the given hypothesis intervals against it with `scoreDiarization`.
/// Returns nil when the JSON is missing/malformed/wrong-shaped or decodes to an empty reference, so
/// callers can skip scoring silently. Pure (no filesystem) so it is unit-testable in isolation.
public func scoreDiarizationAgainstSidecar(hypothesis: [LabeledInterval],
                                           sidecarJSONData: Data) -> DiarizationScore? {
    guard let raw = try? JSONSerialization.jsonObject(with: sidecarJSONData) as? [[String: Any]] else {
        return nil
    }
    let reference: [LabeledInterval] = raw.compactMap { obj in
        guard let speaker = obj["speaker"] as? String,
              let start = (obj["start"] as? NSNumber)?.doubleValue,
              let end = (obj["end"] as? NSNumber)?.doubleValue else { return nil }
        return LabeledInterval(speaker: speaker, start: start, end: end)
    }
    guard !reference.isEmpty else { return nil }
    return scoreDiarization(reference: reference, hypothesis: hypothesis)
}
