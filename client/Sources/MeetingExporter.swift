import Foundation
import BetterVoiceCore

/// Meeting transcript exporter
/// Supports exporting to Markdown format, saved to ~/.better-voice/meetings/
@MainActor
final class MeetingExporter {

    /// Resolves the save folder: explicit saveFolder takes priority, otherwise uses config's meeting.save_folder (falls back to default meetings).
    static func configuredFolder() -> URL {
        BetterVoiceDataDir.resolveMeetingsFolder(RuntimeConfig.shared.meetingConfig["save_folder"] as? String)
    }

    /// Base file name (no extension), shared by transcript and summary: yyyy-MM-dd_HH-mm.
    static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: date)
    }

    /// Exports the meeting transcript to a Markdown file.
    /// - Parameter saveFolder: Explicit save folder; when nil, uses config / default folder.
    /// - Returns: URL of the exported file
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

    /// Exports the meeting summary as `<baseName>-summary.md`, in the same folder as the transcript.
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

    // MARK: - Formatting

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
