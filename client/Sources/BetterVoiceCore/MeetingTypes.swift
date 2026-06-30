import Foundation

/// Outcome of the L2 polish step for a segment (corresponds to the Pipeline's kind field).
public enum L2Kind: String, Sendable {
    case changed   // L2 changed the text
    case identity  // L2 output == input
    case failed    // L2 call failed or returned nil
    case skipped   // skipped when polish.enabled=false
}

/// Meeting transcript segment.
/// One MeetingSegment corresponds to a single flush of SegmentBuffer.
/// - text: final text shown to the user (= L2 output when L2 succeeds; = rawText when failed/skipped)
/// - rawText: concatenation of this batch's SA final segments (kept for debugging + distillation)
/// - l2Kind: result of L2 processing, used for QA and log tracing
/// - speakerName: name the user assigned to this speaker in the wrap-up panel (session-level, not persisted)
public struct MeetingSegment: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let rawText: String
    public let startTime: TimeInterval   // Seconds relative to the start of the meeting
    public let endTime: TimeInterval
    public let speakerId: String?        // Speaker ID assigned by FluidAudio
    public let l2Kind: L2Kind
    public let isFinal: Bool
    public let speakerName: String?      // User-specified speaker name (nullable)

    public init(
        text: String,
        rawText: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerId: String?,
        l2Kind: L2Kind,
        isFinal: Bool,
        speakerName: String? = nil
    ) {
        self.text = text
        self.rawText = rawText
        self.startTime = startTime
        self.endTime = endTime
        self.speakerId = speakerId
        self.l2Kind = l2Kind
        self.isFinal = isFinal
        self.speakerName = speakerName
    }

    /// Display label for the speaker. Prefers the user-specified name, otherwise "<prefix> <id>".
    /// `prefix` is passed in by the caller (already localized), keeping BetterVoiceCore independent of the localization layer.
    public func speakerLabel(prefix: String) -> String? {
        resolveSpeakerLabel(speakerId: speakerId, speakerName: speakerName, prefix: prefix)
    }
}

/// Meeting result.
public struct MeetingResult: Sendable {
    public let segments: [MeetingSegment]
    public let duration: TimeInterval
    public let audioPath: String?
    public let date: Date

    public init(segments: [MeetingSegment], duration: TimeInterval, audioPath: String?, date: Date = Date()) {
        self.segments = segments
        self.duration = duration
        self.audioPath = audioPath
        self.date = date
    }
}
