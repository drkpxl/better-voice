import Foundation
import BetterVoiceCore

/// Segment buffer for meeting mode.
/// Accumulates SA final segments and flushes whenever any of the following triggers fires:
///   1. The gap between this segment's audioTimeRange and the previous one is >= pauseThresholdSec, and the buffer's char count >= minChars
///   2. The buffer's char count >= maxChars (circuit breaker, ensures L2 doesn't exceed the model's training window)
///   3. Manual flush (meeting ended)
///
/// Flush output: a FlushBatch containing this batch's rawText (all segment texts concatenated) + time range + trigger reason
/// Downstream (MeetingSession) takes the batch, runs L2 polishing, and assembles a MeetingSegment
@MainActor
final class SegmentBuffer {
    struct Entry {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    struct FlushBatch {
        let entries: [Entry]
        let rawText: String           // All entry.text concatenated
        let startTime: TimeInterval
        let endTime: TimeInterval
        let triggerReason: String     // "pause" / "maxChars" / "final"
        let pauseGapSec: Double?      // Only set when trigger=pause
    }

    // Thresholds (read from config)
    private let pauseThresholdSec: Double
    private let maxChars: Int
    private let minChars: Int

    private var buffer: [Entry] = []
    private var flushCounter = 0

    /// Flush callback (invoked on MainActor)
    var onFlush: ((FlushBatch) async -> Void)?

    init(pauseThresholdSec: Double, maxChars: Int, minChars: Int) {
        self.pauseThresholdSec = pauseThresholdSec
        self.maxChars = maxChars
        self.minChars = minChars
        Logger.log("SegBuf", "init pauseSec=\(pauseThresholdSec) maxChars=\(maxChars) minChars=\(minChars)")
    }

    /// Feeds in a final segment. Internally decides whether a flush is needed.
    /// Trigger priority: first check the pause (relative to the already-buffered segments), then append, then check the circuit breaker.
    func feed(_ entry: Entry) async {
        // Check the pause first (compare the new segment's startTime against the buffer's last segment's endTime)
        if let last = buffer.last {
            let gap = entry.startTime - last.endTime
            let bufChars = currentCharCount()
            if gap >= pauseThresholdSec, bufChars >= minChars {
                await flushInternal(trigger: "pause", pauseGap: gap)
            }
        }

        buffer.append(entry)

        // Then check the circuit breaker
        if currentCharCount() >= maxChars {
            await flushInternal(trigger: "maxChars", pauseGap: nil)
        }
    }

    /// Flushes the tail when the meeting ends (flushes even if shorter than minChars)
    func flushFinal() async {
        if !buffer.isEmpty {
            await flushInternal(trigger: "final", pauseGap: nil)
        }
    }

    private func currentCharCount() -> Int {
        buffer.reduce(0) { $0 + $1.text.count }
    }

    private func flushInternal(trigger: String, pauseGap: Double?) async {
        guard !buffer.isEmpty else { return }
        let entries = buffer
        buffer.removeAll(keepingCapacity: true)
        flushCounter += 1

        let rawText = entries.map(\.text).joined()
        let start = entries.first?.startTime ?? 0
        let end = entries.last?.endTime ?? start

        let gapStr = pauseGap.map { String(format: "%.2f", $0) } ?? "-"
        Logger.log("SegBuf", "flush seg=\(flushCounter) trigger=\(trigger) entries=\(entries.count) chars=\(rawText.count) gap=\(gapStr)s range=[\(String(format: "%.1f", start))-\(String(format: "%.1f", end))s]")

        let batch = FlushBatch(
            entries: entries,
            rawText: rawText,
            startTime: start,
            endTime: end,
            triggerReason: trigger,
            pauseGapSec: pauseGap
        )
        await onFlush?(batch)
    }

    /// Current buffer state (for debugging)
    var currentState: (entries: Int, chars: Int) {
        (buffer.count, currentCharCount())
    }

    /// Cumulative flush count for this meeting (= segment count)
    var flushCount: Int { flushCounter }
}
