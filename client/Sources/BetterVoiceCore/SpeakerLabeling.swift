import Foundation

/// Deterministic speaker id constants shared by the app and Core label logic, so the
/// mic-channel local-user id has a single source of truth.
public enum SpeakerIds {
    /// Deterministic id for the local user's mic-channel speech (derived from VAD, not
    /// FluidAudio clustering). FluidAudio ids are numeric strings ("1", "2", ...), so
    /// "me" never collides with a clustered remote speaker.
    public static let local = "me"
}

/// Prefer a user-supplied name; then the local-user label for the local speaker id;
/// otherwise fall back to "<prefix> <id>". Returns nil when there is no speaker id.
///
/// `prefix` and `localLabel` are passed in by the caller (already localized), keeping
/// BetterVoiceCore free of the localization layer. `localLabel` defaults to "You"; a UI
/// caller should pass `t("You")`.
// TODO: A future enhancement could resolve the local speaker to the user's real name
// from personal context instead of the second-person "You".
public func resolveSpeakerLabel(
    speakerId: String?,
    speakerName: String?,
    prefix: String,
    localLabel: String = "You"
) -> String? {
    if let name = speakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        return name
    }
    guard let speakerId else { return nil }
    if speakerId == SpeakerIds.local { return localLabel }
    return "\(prefix) \(speakerId)"
}

/// Apply a [speakerId: name] map onto segments, leaving unmatched ones untouched.
public func applySpeakerNames(_ names: [String: String], to segments: [MeetingSegment]) -> [MeetingSegment] {
    guard !names.isEmpty else { return segments }
    return segments.map { seg in
        guard let id = seg.speakerId,
              let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return seg
        }
        return MeetingSegment(
            text: seg.text,
            rawText: seg.rawText,
            startTime: seg.startTime,
            endTime: seg.endTime,
            speakerId: seg.speakerId,
            l2Kind: seg.l2Kind,
            isFinal: seg.isFinal,
            speakerName: name,
            speakerEmbedding: seg.speakerEmbedding,
            speakerConfidence: seg.speakerConfidence
        )
    }
}

/// Unique speaker ids in first-appearance order (nil speakers skipped).
public func orderedUniqueSpeakerIds(_ segments: [MeetingSegment]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for seg in segments {
        guard let id = seg.speakerId, !seen.contains(id) else { continue }
        seen.insert(id)
        ordered.append(id)
    }
    return ordered
}

/// For each speaker, pick their longest turn as a sample snippet, truncated to maxLen.
public func sampleSnippets(_ segments: [MeetingSegment], maxLen: Int = 80) -> [String: String] {
    var longest: [String: String] = [:]
    for seg in segments {
        guard let id = seg.speakerId else { continue }
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if let existing = longest[id], existing.count >= text.count { continue }
        longest[id] = text
    }
    return longest.mapValues { truncate($0, maxLen: maxLen) }
}

private func truncate(_ s: String, maxLen: Int) -> String {
    guard maxLen > 0, s.count > maxLen else { return s }
    let idx = s.index(s.startIndex, offsetBy: maxLen)
    return String(s[s.startIndex..<idx]).trimmingCharacters(in: .whitespaces) + "…"
}
