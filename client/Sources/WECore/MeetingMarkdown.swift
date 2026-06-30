import Foundation

/// 会议 Markdown 渲染（纯字符串，文件 IO 留在 WE 层）。
/// Pure Markdown rendering for transcript + summary. File IO stays in the WE layer;
/// all human-facing strings (title, metadata lines, labels) are passed in already
/// localized so WECore stays free of the localization layer.
public enum MeetingMarkdown {

    /// 渲染带说话人分组的转录 Markdown。
    /// Render the speaker-grouped transcript. `metadataLines` are emitted as `- line`.
    public static func renderTranscript(
        title: String,
        metadataLines: [String],
        segments: [MeetingSegment],
        speakerPrefix: String,
        unknownLabel: String
    ) -> String {
        var md = "# \(title)\n\n"
        for line in metadataLines {
            md += "- \(line)\n"
        }
        md += "\n---\n\n"

        var currentSpeaker = ""
        for segment in segments where !segment.text.isEmpty {
            let time = formatTimestamp(segment.startTime)
            let speaker = segment.speakerLabel(prefix: speakerPrefix) ?? unknownLabel

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                md += "\n### \(speaker)\n\n"
            }
            md += "`\(time)` \(segment.text)\n\n"
        }
        return md
    }

    /// 渲染摘要 Markdown。
    /// Render the summary document.
    public static func renderSummary(
        title: String,
        metadataLines: [String],
        summary: String
    ) -> String {
        var md = "# \(title)\n\n"
        for line in metadataLines {
            md += "- \(line)\n"
        }
        md += "\n---\n\n"
        md += summary.trimmingCharacters(in: .whitespacesAndNewlines)
        md += "\n"
        return md
    }

    /// MM:SS 时间戳。
    public static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
