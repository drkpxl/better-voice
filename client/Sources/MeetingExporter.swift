import Foundation
import WECore

/// 会议转录导出器
/// 支持导出为 Markdown 格式，保存到 ~/.we/meetings/
@MainActor
final class MeetingExporter {

    /// 导出会议转录为 Markdown 文件
    /// - Returns: 导出文件的 URL
    static func exportMarkdown(
        segments: [MeetingSegment],
        duration: TimeInterval,
        date: Date = Date()
    ) -> URL? {
        try? FileManager.default.createDirectory(at: WEDataDir.meetings, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let fileURL = WEDataDir.meetingMarkdownURL(forName: formatter.string(from: date))

        var md = "# \(t("Meeting Transcript"))\n\n"
        md += "- " + t("Date: \(formatDate(date))") + "\n"
        md += "- " + t("Duration: \(formatDuration(duration))") + "\n"
        md += "- " + t("Total characters: \(String(segments.reduce(0) { $0 + $1.text.count }))") + "\n\n"
        md += "---\n\n"

        var currentSpeaker = ""
        for segment in segments where !segment.text.isEmpty {
            let time = formatTimestamp(segment.startTime)
            let speaker = segment.speakerLabel(prefix: t("Speaker")) ?? t("Unknown")

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                md += "\n### \(speaker)\n\n"
            }

            md += "`\(time)` \(segment.text)\n\n"
        }

        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            Logger.log("Meeting", "Exported to \(fileURL.lastPathComponent)")
            return fileURL
        } catch {
            Logger.log("Meeting", "Export failed: \(error)")
            return nil
        }
    }

    // MARK: - 格式化

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: t("%dh %dm %ds"), h, m, s)
        }
        return String(format: t("%dm %ds"), m, s)
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = t("yyyy-MM-dd HH:mm")
        return f.string(from: date)
    }
}
