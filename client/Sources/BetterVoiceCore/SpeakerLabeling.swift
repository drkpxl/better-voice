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
/// caller should pass `RuntimeConfig.shared.userName ?? t("You")` so the local speaker is
/// labeled with the user's real name when they've set one (Settings > Meetings > Your name).
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

/// Mean voice embedding per speakerId across a meeting's segments, for cross-meeting
/// fingerprinting (`KnownSpeakers`). Segments with a nil `speakerEmbedding` are skipped; a
/// speaker with no embedded segments at all is simply absent from the result (not zero-filled).
/// Uses `meanEmbedding(_:)` (`SpeakerAlignment.swift`) for the per-speaker average.
///
/// Deliberately unopinionated about `SpeakerIds.local`: it is included here like any other
/// speaker id (the mic channel does carry an embedding when diarization runs on "both" audio
/// mode) — callers that only want remote speakers filter it out themselves.
public func speakerEmbeddings(from segments: [MeetingSegment]) -> [String: [Float]] {
    var bySpeaker: [String: [[Float]]] = [:]
    for seg in segments {
        guard let id = seg.speakerId, let embedding = seg.speakerEmbedding else { continue }
        bySpeaker[id, default: []].append(embedding)
    }
    return bySpeaker.compactMapValues { meanEmbedding($0) }
}

/// For each speaker, pick their N longest turns (deduped), returned in
/// chronological order, each truncated to maxLen. Longest turns carry the most
/// identifying content; chronological order reads naturally in the UI.
public func sampleQuotes(_ segments: [MeetingSegment], perSpeaker: Int = 3, maxLen: Int = 160) -> [String: [String]] {
    // Bucket non-empty turns per speaker, keeping (startTime, text) so we can
    // re-sort chronologically after selecting the longest.
    var bySpeaker: [String: [(start: TimeInterval, text: String)]] = [:]
    for seg in segments {
        guard let id = seg.speakerId else { continue }
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        bySpeaker[id, default: []].append((seg.startTime, text))
    }
    return bySpeaker.mapValues { turns in
        // Dedupe by text, keeping the earliest occurrence, then take the N longest.
        var seenText = Set<String>()
        let distinct = turns.filter { seenText.insert($0.text).inserted }
        let longest = distinct.sorted { $0.text.count > $1.text.count }.prefix(perSpeaker)
        return longest.sorted { $0.start < $1.start }.map { truncate($0.text, maxLen: maxLen) }
    }
}

/// Merges a mic-channel (local user) segment list with a system-channel (remote/diarized)
/// segment list into one chronological, speaker-labeled timeline — the core of the two-file
/// meeting-capture design (mic + system audio recorded, transcribed, and diarized as two
/// independently-clocked native-rate WAVs instead of mixed into one file; see
/// `MeetingCoordinator`'s doc comment for why).
///
/// `localSegments` is the output of running `ImportPipeline` in `.single` mode (no diarization)
/// on the mic-only WAV — flat, unlabeled turns that are unambiguously the local user's own
/// speech, since nothing else is ever on that channel. Every segment is stamped with
/// `SpeakerIds.local` here (overwriting whatever `speakerId` it already carries — always nil for
/// `.single`-mode output, but making the contract explicit regardless of caller), so every
/// existing "local speaker" codepath (`resolveSpeakerLabel`'s local-label special case, the
/// naming step's `!= SpeakerIds.local` filter, `speakerEmbeddings`'s matching filter) picks it up
/// for free with zero further plumbing — the local user shows up already labeled with their
/// configured name, never as an unnamed speaker to confirm.
///
/// `remoteSegments` is the output of running `ImportPipeline` in `.multi` mode (FluidAudio
/// diarization) on the system-audio WAV, and passes through untouched — its speaker ids are
/// already ground-truth "everyone else on the call".
///
/// Both segment lists' timestamps are relative to their own file's start. Since both files begin
/// recording together (`MeetingCoordinator` starts system capture, then mic capture, back to
/// back), a plain start-time sort produces a correctly-ordered merged timeline without any
/// cross-clock sample alignment. Native-clock drift between the two independently clocked devices
/// over a long meeting only fuzzes relative turn ordering by tens of milliseconds — an accepted
/// trade-off for transcript readability in exchange for eliminating cross-clock sample-level
/// drift entirely (the reason this is two files instead of one mixed file in the first place).
public func mergeSpeakerTimelines(
    localSegments: [MeetingSegment],
    remoteSegments: [MeetingSegment]
) -> [MeetingSegment] {
    let labeledLocal = localSegments.map { seg -> MeetingSegment in
        MeetingSegment(
            text: seg.text,
            rawText: seg.rawText,
            startTime: seg.startTime,
            endTime: seg.endTime,
            speakerId: SpeakerIds.local,
            l2Kind: seg.l2Kind,
            isFinal: seg.isFinal,
            speakerName: seg.speakerName,
            speakerEmbedding: seg.speakerEmbedding,
            speakerConfidence: seg.speakerConfidence
        )
    }
    // `sorted` is a stable sort (guaranteed since Swift 5), so segments that tie on startTime
    // keep their relative order from the concatenation (local, then remote) rather than being
    // shuffled arbitrarily.
    return (labeledLocal + remoteSegments).sorted { $0.startTime < $1.startTime }
}

private func truncate(_ s: String, maxLen: Int) -> String {
    guard maxLen > 0, s.count > maxLen else { return s }
    let idx = s.index(s.startIndex, offsetBy: maxLen)
    return String(s[s.startIndex..<idx]).trimmingCharacters(in: .whitespaces) + "…"
}
