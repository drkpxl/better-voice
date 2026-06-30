import Foundation
import WECore

/// 会议转录导出器
/// 支持导出为 Markdown 格式，保存到 ~/.we/meetings/
@MainActor
final class MeetingExporter {

    /// 解析保存目录：显式 saveFolder 优先，否则取 config 的 meeting.save_folder（回退默认 meetings）。
    static func configuredFolder() -> URL {
        WEDataDir.resolveMeetingsFolder(RuntimeConfig.shared.meetingConfig["save_folder"] as? String)
    }

    /// 文件基名（不含扩展名），转录与摘要共用：yyyy-MM-dd_HH-mm。
    static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: date)
    }

    /// 导出会议转录为 Markdown 文件。
    /// - Parameter saveFolder: 显式保存目录；nil 时用 config / 默认目录。
    /// - Returns: 导出文件的 URL
    static func exportMarkdown(
        segments: [MeetingSegment],
        duration: TimeInterval,
        date: Date = Date(),
        saveFolder: URL? = nil
    ) -> URL? {
        let folder = saveFolder ?? configuredFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("\(baseName(for: date)).md")

        let totalChars = segments.reduce(0) { $0 + $1.text.count }
        let md = MeetingMarkdown.renderTranscript(
            title: t("Meeting Transcript"),
            metadataLines: [
                t("Date: \(formatDate(date))"),
                t("Duration: \(formatDuration(duration))"),
                t("Total characters: \(String(totalChars))"),
            ],
            segments: segments,
            speakerPrefix: t("Speaker"),
            unknownLabel: t("Unknown")
        )

        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            Logger.log("Meeting", "Exported transcript to \(fileURL.lastPathComponent)")
            return fileURL
        } catch {
            Logger.log("Meeting", "Transcript export failed: \(error)")
            return nil
        }
    }

    /// 导出会议摘要为 `<baseName>-summary.md`，与转录同目录。
    static func exportSummary(
        _ summary: String,
        baseName: String,
        type: MeetingType,
        duration: TimeInterval,
        date: Date = Date(),
        saveFolder: URL? = nil
    ) -> URL? {
        let folder = saveFolder ?? configuredFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("\(baseName)-summary.md")

        let md = MeetingMarkdown.renderSummary(
            title: t("Meeting Summary"),
            metadataLines: [
                t("Type: \(type.defaultDisplayName)"),
                t("Date: \(formatDate(date))"),
                t("Duration: \(formatDuration(duration))"),
            ],
            summary: summary
        )

        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            Logger.log("Meeting", "Exported summary to \(fileURL.lastPathComponent)")
            return fileURL
        } catch {
            Logger.log("Meeting", "Summary export failed: \(error)")
            return nil
        }
    }

    // MARK: - 格式化

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
