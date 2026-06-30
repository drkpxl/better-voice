import Foundation
import BetterVoiceCore

/// Streaming segment-level persistence for meeting mode
///
/// Every time a SegmentBuffer flush + L2 call completes (changed/identity/failed/skipped all get written),
/// a line is immediately appended to `~/.better-voice/meeting-history.jsonl`.
///
/// Data uses:
/// - Distillation / evaluation / A-B comparison (rawText vs polishedText)
/// - L2 behavior monitoring (kind distribution, avgMs)
/// - Data preservation in case of a mid-meeting crash (streaming writes, not dependent on the meeting ending normally)
///
/// `speakerId` is left empty: diarization hasn't run yet while the meeting is in progress
/// (FluidAudio processes it all at once on stop). When distillation needs speaker labels,
/// backfill them using `audioPath + startTime/endTime`.
struct MeetingSegmentRecord: Codable, Sendable {
    let timestamp: Date
    let meetingId: String
    let audioPath: String
    let segIndex: Int
    let startTime: TimeInterval     // Seconds relative to the meeting start
    let endTime: TimeInterval
    let triggerReason: String       // "pause" / "maxChars" / "final"
    let rawText: String             // SA's raw concatenation (L2 input)
    let polishedText: String?       // L2 output, nil indicates failure
    let finalText: String           // Final text used (polished ?? rawText)
    let l2Kind: String              // "changed" / "identity" / "failed" / "skipped"
    let l2ElapsedMs: Int
}

@MainActor
final class MeetingHistory {
    private let writer = JSONLWriter(filename: "meeting-history.jsonl")

    func append(_ record: MeetingSegmentRecord) {
        writer.append(record)
        Logger.log("MeetingHistory", "appended seg=\(record.segIndex) kind=\(record.l2Kind) chars=\(record.rawText.count)")
    }
}
