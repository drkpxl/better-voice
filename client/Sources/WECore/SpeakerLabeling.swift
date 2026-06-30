import Foundation

/// 说话人标签解析：优先用用户指定的名字，否则回退到 "<prefix> <id>"。
/// Prefer a user-supplied name; otherwise fall back to "<prefix> <id>". Returns
/// nil when there is no speaker id at all.
public func resolveSpeakerLabel(speakerId: String?, speakerName: String?, prefix: String) -> String? {
    if let name = speakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        return name
    }
    guard let speakerId else { return nil }
    return "\(prefix) \(speakerId)"
}

/// 把 [speakerId: name] 映射应用到片段上，只改有匹配名字的片段。
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
            speakerName: name
        )
    }
}

/// 按首次出现顺序返回去重后的说话人 ID 列表（nil 说话人忽略）。
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

/// 每个说话人取「最长一段发言」作为收尾面板的示例片段，截断到 maxLen。
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
