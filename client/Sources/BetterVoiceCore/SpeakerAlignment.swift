import Foundation

/// A diarization interval attributed to a single speaker.
///
/// This is the pure-Core representation of one diarization segment (e.g. FluidAudio's
/// `TimedSpeakerSegment`). Keeping it independent of FluidAudio lets the alignment math
/// be unit-tested without pulling the ML stack into the test target.
///
/// - `embedding` / `quality` are retained for a later speaker-fingerprinting task; the
///   alignment functions here only use `embedding` (carried onto the winning assignment).
public struct SpeakerInterval: Sendable, Equatable {
    public let speakerId: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let embedding: [Float]?      // retained for a later fingerprinting task
    public let quality: Float?          // FluidAudio TimedSpeakerSegment.qualityScore
    public init(speakerId: String, start: TimeInterval, end: TimeInterval,
                embedding: [Float]? = nil, quality: Float? = nil) {
        self.speakerId = speakerId; self.start = start; self.end = end
        self.embedding = embedding; self.quality = quality
    }
}

/// A transcribed phrase's time span (the thing we want to attribute to a speaker).
public struct PhraseSpan: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
}

/// Result of attributing a phrase to a speaker.
///
/// - `speakerId`: the best-overlapping speaker, or `nil` when no interval overlaps the phrase.
/// - `embedding`: the embedding of the best speaker's single longest-overlapping interval.
/// - `confidence`: `overlappedDuration(bestSpeaker) / phraseDuration`, clamped to `0…1`.
/// - `overlapped`: `true` when at least two distinct speakers each meaningfully overlap the
///   phrase (an interruption / crosstalk marker).
public struct SpeakerAssignment: Sendable, Equatable {
    public let speakerId: String?
    public let embedding: [Float]?
    public let confidence: Double      // overlappedDuration(bestSpeaker) / phraseDuration, 0…1
    public let overlapped: Bool        // true when >=2 distinct speakers each overlap this phrase (interruption)
    public init(speakerId: String?, embedding: [Float]?, confidence: Double, overlapped: Bool) {
        self.speakerId = speakerId
        self.embedding = embedding
        self.confidence = confidence
        self.overlapped = overlapped
    }
}

/// A run of consecutive same-speaker phrases, merged into one transcript turn.
///
/// - `text`: concatenation of the turn's phrase texts (in order).
/// - `start` / `end`: span the turn (first phrase start … last phrase end).
/// - `embedding`: the element-wise mean of the turn's non-nil phrase embeddings.
/// - `minConfidence`: the minimum phrase confidence in the turn.
/// - `containedOverlap`: `true` if any phrase in the turn was flagged `overlapped`.
public struct SpeakerTurn: Sendable, Equatable {
    public let speakerId: String?
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let embedding: [Float]?
    public let minConfidence: Double
    public let containedOverlap: Bool
    public init(speakerId: String?, text: String, start: TimeInterval, end: TimeInterval,
                embedding: [Float]?, minConfidence: Double, containedOverlap: Bool) {
        self.speakerId = speakerId
        self.text = text
        self.start = start
        self.end = end
        self.embedding = embedding
        self.minConfidence = minConfidence
        self.containedOverlap = containedOverlap
    }
}

/// Element-wise mean of equal-length embedding vectors. Returns nil for an empty input
/// or if the vectors have differing lengths (ragged input is a programming error, not averaged).
public func meanEmbedding(_ embeddings: [[Float]]) -> [Float]? {
    guard let first = embeddings.first else { return nil }
    let dim = first.count
    guard embeddings.allSatisfy({ $0.count == dim }) else { return nil }
    var sums = [Double](repeating: 0, count: dim)
    for vec in embeddings {
        for i in 0..<dim { sums[i] += Double(vec[i]) }
    }
    let count = Double(embeddings.count)
    return sums.map { Float($0 / count) }
}

/// Duration of the temporal overlap between two `[start, end)` ranges (0 if disjoint).
private func overlapDuration(_ aStart: TimeInterval, _ aEnd: TimeInterval,
                             _ bStart: TimeInterval, _ bEnd: TimeInterval) -> TimeInterval {
    max(0, min(aEnd, bEnd) - max(aStart, bStart))
}

/// Attribute a phrase to the speaker whose intervals overlap it the most.
///
/// For each `speakerId`, the total overlap duration of its intervals with `phrase` is summed.
/// The speaker with the greatest total overlap wins `speakerId`, and the embedding carried is
/// from that speaker's single longest-overlapping interval.
///
/// `confidence = bestSpeakerOverlap / max(phraseDuration, epsilon)`, clamped to `0…1`; it is
/// `0` when `phraseDuration <= 0`.
///
/// When NO interval overlaps the phrase, the result is `speakerId = nil`, `embedding = nil`,
/// `confidence = 0`, `overlapped = false`. This intentionally does NOT snap to the temporally
/// nearest speaker — that former behavior mislabeled interruptions and has been removed.
///
/// `overlapped` is `true` when at least two distinct speakers each have total overlap
/// `>= minOverlapForConflict * phraseDuration` (an interruption / crosstalk signal).
///
/// - Parameters:
///   - phrase: the phrase span to attribute.
///   - intervals: the diarization intervals to attribute against.
///   - minOverlapForConflict: fraction of the phrase duration a second speaker must cover for
///     the phrase to be flagged `overlapped` (default `0.15`).
public func assignSpeaker(to phrase: PhraseSpan,
                          among intervals: [SpeakerInterval],
                          minOverlapForConflict: Double = 0.15,
                          nearestSnapSec: Double = 1.0) -> SpeakerAssignment {
    let phraseDuration = phrase.end - phrase.start

    // Sum total overlap per speaker, and track each speaker's single longest-overlapping interval.
    var totalOverlapBySpeaker: [String: TimeInterval] = [:]
    var bestIntervalOverlapBySpeaker: [String: TimeInterval] = [:]
    var bestEmbeddingBySpeaker: [String: [Float]?] = [:]

    for iv in intervals {
        let ov = overlapDuration(phrase.start, phrase.end, iv.start, iv.end)
        guard ov > 0 else { continue }
        totalOverlapBySpeaker[iv.speakerId, default: 0] += ov
        if ov > (bestIntervalOverlapBySpeaker[iv.speakerId] ?? 0) {
            bestIntervalOverlapBySpeaker[iv.speakerId] = ov
            bestEmbeddingBySpeaker[iv.speakerId] = iv.embedding
        }
    }

    // No interval overlaps. Recover from *small* timeline skew — the transcription and diarization
    // timelines can drift slightly relative to each other, leaving a phrase just outside its
    // speaker's interval → it would otherwise be "Unknown".
    // Snap to the nearest interval only when it's within `nearestSnapSec`; beyond that, stay
    // unattributed rather than guess (confidence stays 0 to mark it as a snap, not a real overlap).
    guard !totalOverlapBySpeaker.isEmpty else {
        var nearestId: String?
        var nearestEmbedding: [Float]?
        var nearestGap = Double.greatestFiniteMagnitude
        for iv in intervals {
            let gap = phrase.start >= iv.end ? phrase.start - iv.end : iv.start - phrase.end
            if gap >= 0, gap < nearestGap {
                nearestGap = gap
                nearestId = iv.speakerId
                nearestEmbedding = iv.embedding
            }
        }
        if let id = nearestId, nearestGap <= nearestSnapSec {
            return SpeakerAssignment(speakerId: id, embedding: nearestEmbedding, confidence: 0, overlapped: false)
        }
        return SpeakerAssignment(speakerId: nil, embedding: nil, confidence: 0, overlapped: false)
    }

    // Pick the speaker with the greatest total overlap. On an exact tie, break
    // deterministically by speakerId (the LOWER id wins) so results are stable run-to-run —
    // Dictionary iteration order is otherwise randomized. `.max(by:)` returns the element that is
    // not "less than" any other; with the tie predicate `lhs.key > rhs.key`, larger keys sort
    // earlier, so the smallest key is the maximum. (See testTieBreaksDeterministicallyBySpeakerId.)
    let best = totalOverlapBySpeaker.max { lhs, rhs in
        lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
    }!
    let bestSpeaker = best.key
    let bestOverlap = best.value
    let embedding = bestEmbeddingBySpeaker[bestSpeaker] ?? nil

    let confidence: Double
    if phraseDuration > 0 {
        confidence = min(1.0, max(0.0, bestOverlap / phraseDuration))
    } else {
        confidence = 0
    }

    // Interruption: >=2 distinct speakers each cover at least the conflict fraction of the phrase.
    let conflictThreshold = minOverlapForConflict * phraseDuration
    let distinctConflicting = totalOverlapBySpeaker.values.filter { $0 >= conflictThreshold }.count
    let overlapped = phraseDuration > 0 && distinctConflicting >= 2

    return SpeakerAssignment(speakerId: bestSpeaker, embedding: embedding,
                             confidence: confidence, overlapped: overlapped)
}

/// Assign a speaker to each phrase, then merge consecutive same-speaker phrases into turns.
///
/// This is the pure port of the former `MeetingSession.buildSpeakerTurns` grouping: each phrase
/// is attributed via `assignSpeaker`, and consecutive phrases sharing the same `speakerId`
/// (including consecutive `nil`) collapse into a single `SpeakerTurn`.
///
/// - Parameters:
///   - phrases: ordered `(span, text)` pairs to attribute and group.
///   - intervals: diarization intervals to attribute against.
///   - maxTurnGapSec: a silence longer than this between a phrase and the previous one ends the
///     current turn even when the speaker is unchanged. Without this, a run of same-speaker (or,
///     worse, consecutive unattributed `nil`) phrases separated by long silences would collapse
///     into a single turn whose span covers the gap and whose text concatenates utterances that
///     were minutes apart. Default `10`.
/// - Returns: one `SpeakerTurn` per consecutive same-speaker run (further split on long gaps), in order.
public func groupIntoTurns(phrases: [(span: PhraseSpan, text: String)],
                           intervals: [SpeakerInterval],
                           maxTurnGapSec: TimeInterval = 10) -> [SpeakerTurn] {
    // 1. Assign each phrase.
    let assigned = phrases.map { phrase -> (span: PhraseSpan, text: String, assignment: SpeakerAssignment) in
        (phrase.span, phrase.text, assignSpeaker(to: phrase.span, among: intervals))
    }

    // 2. Group consecutive phrases by speakerId, breaking a turn on a long silence.
    var groups: [[(span: PhraseSpan, text: String, assignment: SpeakerAssignment)]] = []
    for item in assigned {
        if let last = groups.last {
            let prev = last[last.count - 1]
            let sameSpeaker = prev.assignment.speakerId == item.assignment.speakerId
            let gap = item.span.start - prev.span.end
            if sameSpeaker && gap <= maxTurnGapSec {
                groups[groups.count - 1].append(item)
                continue
            }
        }
        groups.append([item])
    }

    // 3. Fold each group into a turn.
    return groups.compactMap { group in
        guard let first = group.first, let last = group.last else { return nil }
        let text = group.map(\.text).joined()
        let embedding = meanEmbedding(group.compactMap(\.assignment.embedding))
        let minConfidence = group.map(\.assignment.confidence).min() ?? 0
        let containedOverlap = group.contains { $0.assignment.overlapped }
        return SpeakerTurn(
            speakerId: first.assignment.speakerId,
            text: text,
            start: first.span.start,
            end: last.span.end,
            embedding: embedding,
            minConfidence: minConfidence,
            containedOverlap: containedOverlap
        )
    }
}
