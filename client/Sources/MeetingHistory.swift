import Foundation
import BetterVoiceCore

/// Streaming segment-level persistence for meeting mode
///
/// Every time a SegmentBuffer flush completes, a line is immediately appended to
/// `meeting-history.jsonl` in the app's support directory.
///
/// Data uses:
/// - Evaluation / A-B comparison of transcripts
/// - Data preservation in case of a mid-meeting crash (streaming writes, not dependent on the meeting ending normally)
///
/// Write-only by construction: `JSONLWriter.append` takes an `Encodable`, and nothing in the app or
/// in `bench/` decodes this file. That is why dropping the retired cleanup stage's columns
/// (`rawText`, `polishedText`, `l2Kind`, `l2ElapsedMs`) needed no format migration -- there is no
/// reader to migrate. Anything that starts reading these lines has to tolerate both shapes itself.
///
/// `speakerId` is left empty: diarization hasn't run yet while the meeting is in progress
/// (FluidAudio processes it all at once on stop). When a consumer needs speaker labels, backfill
/// them using `audioPath + startTime/endTime`.
struct MeetingSegmentRecord: Codable, Sendable {
    let timestamp: Date
    let meetingId: String
    let audioPath: String
    let segIndex: Int
    let startTime: TimeInterval     // Seconds relative to the meeting start
    let endTime: TimeInterval
    let triggerReason: String       // "pause" / "maxChars" / "final"
    let text: String                // The segment text, post-vocabulary
}

@MainActor
final class MeetingHistory {
    /// Built lazily so the URL is only resolved on the first `append` — harmless either way
    /// since `SupportDir` is auto-created at app launch, but keeps this consistent with the
    /// other stores' lazy-resolution pattern.
    private lazy var writer = JSONLWriter(fileURL: SupportDir.meetingHistoryURL)

    func append(_ record: MeetingSegmentRecord) {
        writer.append(record)
        Logger.log("MeetingHistory", "appended seg=\(record.segIndex) trigger=\(record.triggerReason) chars=\(record.text.count)")
    }
}
