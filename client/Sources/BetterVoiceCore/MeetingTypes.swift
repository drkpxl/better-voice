import Foundation

/// Meeting transcript segment. One per `SegmentBuffer` flush.
///
/// `rawText` and `l2Kind` used to sit here, carrying the before/after of an LLM cleanup pass that
/// ran between transcription and summarization. That stage is gone, so `rawText` always equalled
/// `text` and `l2Kind` was always `.skipped` -- two fields whose only remaining function was to make
/// a reader think a third stage still existed. Removing them was budgeted as a persisted-format
/// migration; it was not one. `MeetingSegmentRecord` is written through `JSONLWriter.append`, which
/// is `Encodable`-only, and nothing in the app or in `bench/` ever decodes those files, so old lines
/// simply carry JSON keys that no reader looks for.
///
/// - speakerName: assigned by the user in the wrap-up panel (session-level, not persisted)
public struct MeetingSegment: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let startTime: TimeInterval   // Seconds relative to the start of the meeting
    public let endTime: TimeInterval
    public let speakerId: String?        // Speaker ID assigned by FluidAudio
    public let isFinal: Bool
    public let speakerName: String?      // User-specified speaker name (nullable)
    /// The speaker's voice embedding from diarization (nil for the local "me" speaker
    /// or when diarization didn't run), retained for cross-meeting fingerprinting.
    public let speakerEmbedding: [Float]?
    /// Alignment confidence 0…1 (nil when unknown).
    public let speakerConfidence: Double?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerId: String?,
        isFinal: Bool,
        speakerName: String? = nil,
        speakerEmbedding: [Float]? = nil,
        speakerConfidence: Double? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerId = speakerId
        self.isFinal = isFinal
        self.speakerName = speakerName
        self.speakerEmbedding = speakerEmbedding
        self.speakerConfidence = speakerConfidence
    }

    /// Display label for the speaker. Prefers the user-specified name, then the local-user
    /// label for the local speaker id, otherwise "<prefix> <id>".
    /// `prefix` and `localLabel` are passed in by the caller (already localized), keeping
    /// BetterVoiceCore independent of the localization layer. `localLabel` defaults to "You".
    public func speakerLabel(prefix: String, localLabel: String = "You") -> String? {
        resolveSpeakerLabel(speakerId: speakerId, speakerName: speakerName, prefix: prefix, localLabel: localLabel)
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
