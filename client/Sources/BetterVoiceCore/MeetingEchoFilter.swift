import Foundation

/// Removes the far side of a call from the mic channel when the call played through speakers.
///
/// The mic WAV is assumed to be only the local user (`mergeSpeakerTimelines`), but on laptop
/// speakers it also hears everyone else, so each remote line came out twice: once under its
/// speaker from the system channel, and again under the local user. Measured on a 23-minute
/// speakerphone call: most of the "local" transcript was echo, often inside the same mic turn as
/// the user's own words ("…alignment up front is critical. Sure. But now for an RFP…").
///
/// So echo is removed word by word, not turn by turn: a run of mic words is dropped when it
/// matches the system channel's transcript around the same time. Both channels are transcribed
/// separately, so the two copies differ slightly ("I want" / "I wanna", "24" / "twenty-four");
/// matching on 3-word shingles and bridging short unmatched gaps absorbs that. Short matched runs
/// are kept, since a few common words ("I think that") match by chance. With headphones nothing
/// matches and this is a no-op.
public enum MeetingEchoFilter {
    /// Words per shingle compared between channels.
    static let shingle = 3
    /// A matched run shorter than this is coincidence, not echo.
    static let minimumRun = 4
    /// Unmatched words between two matched ones still count as echo: transcription differences.
    static let maximumGap = 2
    /// How far apart in time the two copies may be. Turn timestamps are only turn starts, and the
    /// measured copies drifted up to ~16 s apart.
    static let window: TimeInterval = 30

    /// `localSegments` with echo of `remoteSegments` removed. A mic turn left with own speech on
    /// both sides of removed echo is split, so the pieces interleave correctly with the remote turns.
    public static func apply(localSegments: [MeetingSegment], remoteSegments: [MeetingSegment]) -> [MeetingSegment] {
        guard !remoteSegments.isEmpty else { return localSegments }
        let remote = remoteSegments.map { (seg: $0, words: words(in: $0.text).map(\.key)) }
        return localSegments.flatMap { local -> [MeetingSegment] in
            let nearby = remote.filter {
                $0.seg.endTime >= local.startTime - window && $0.seg.startTime <= local.endTime + window
            }
            var shingles = Set<[String]>()
            for r in nearby where r.words.count >= shingle {
                for i in 0...(r.words.count - shingle) { shingles.insert(Array(r.words[i..<(i + shingle)])) }
            }
            return strip(local, shingles: shingles)
        }
    }

    private static func strip(_ local: MeetingSegment, shingles: Set<[String]>) -> [MeetingSegment] {
        let tokens = words(in: local.text)
        guard !shingles.isEmpty, tokens.count >= shingle else { return [local] }

        var echo = [Bool](repeating: false, count: tokens.count)
        let keys = tokens.map(\.key)
        for i in 0...(keys.count - shingle) where shingles.contains(Array(keys[i..<(i + shingle)])) {
            for j in i..<(i + shingle) { echo[j] = true }
        }
        bridgeGaps(&echo)
        // Unmark matched runs too short to be echo.
        var i = 0
        while i < echo.count {
            guard echo[i] else { i += 1; continue }
            var end = i
            while end < echo.count, echo[end] { end += 1 }
            if end - i < minimumRun { for j in i..<end { echo[j] = false } }
            i = end
        }
        guard echo.contains(true) else { return [local] }

        // Each surviving run of own speech becomes a segment, timed by its position in the turn.
        var pieces: [MeetingSegment] = []
        let duration = local.endTime - local.startTime
        i = 0
        while i < tokens.count {
            guard !echo[i] else { i += 1; continue }
            var end = i
            while end < tokens.count, !echo[end] { end += 1 }
            pieces.append(MeetingSegment(
                text: tokens[i..<end].map(\.raw).joined(separator: " "),
                startTime: local.startTime + duration * Double(i) / Double(tokens.count),
                endTime: local.startTime + duration * Double(end) / Double(tokens.count),
                speakerId: local.speakerId,
                isFinal: local.isFinal,
                speakerName: local.speakerName,
                speakerEmbedding: local.speakerEmbedding,
                speakerConfidence: local.speakerConfidence
            ))
            i = end
        }
        return pieces
    }

    /// Marks unmatched gaps of up to `maximumGap` words that sit between matched words.
    private static func bridgeGaps(_ echo: inout [Bool]) {
        var lastMatched: Int?
        for i in echo.indices where echo[i] {
            if let last = lastMatched, i - last - 1 <= maximumGap {
                for j in (last + 1)..<i { echo[j] = true }
            }
            lastMatched = i
        }
    }

    /// Whitespace-separated words, each with a comparison key of lowercased letters and digits.
    /// Bare punctuation ("—") is dropped, so it can't break a shingle.
    private static func words(in text: String) -> [(raw: String, key: String)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { word in
            let key = String(word.lowercased().filter { $0.isLetter || $0.isNumber })
            return key.isEmpty ? nil : (String(word), key)
        }
    }
}
