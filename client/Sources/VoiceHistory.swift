import Foundation
import Observation

/// History record for each dictation, written to ~/Library/Logs/BetterVoice2/voice-history.jsonl.
///
/// `rawText` vs `finalText` is the one comparison worth keeping: it shows what the deterministic
/// stages (`FillerStripper`, then `Vocabulary`) changed, which is the only transformation left on this
/// path.
struct VoiceHistoryEntry: Codable, Sendable, Identifiable {
    let timestamp: Date
    let rawText: String
    let finalText: String
    let appBundleID: String?
    let appName: String?

    var id: Date { timestamp }
}

/// The dictation log, and the menu bar's "Recent Dictations" list read from it — the way back
/// when a paste landed in the wrong field (or nowhere).
@MainActor
@Observable
final class VoiceHistory {
    static let shared = VoiceHistory()

    /// How many entries the menu offers.
    static let recentLimit = 10

    /// Newest first, at most `recentLimit`.
    private(set) var recent: [VoiceHistoryEntry] = []

    // Dictation history lives in the fixed log dir (not the user's workspace folder): it is a
    // debugging artifact, and dictation must work before any workspace is configured.
    private static let fileURL = Logger.logDirectory.appendingPathComponent("voice-history.jsonl")
    @ObservationIgnored private let writer = JSONLWriter(fileURL: VoiceHistory.fileURL)

    private init() {
        recent = Self.loadTail()
    }

    func save(transcription: TranscriptionResult, finalText: String, app: AppIdentity?) {
        let entry = VoiceHistoryEntry(
            timestamp: transcription.timestamp,
            rawText: transcription.fullText,
            finalText: finalText,
            appBundleID: app?.bundleID,
            appName: app?.appName
        )
        writer.append(entry)
        recent.insert(entry, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        Logger.log("History", "Saved voice history entry")
    }

    /// Forget every dictation — the menu list and the log file.
    func clear() {
        recent = []
        writer.clear()
        Logger.log("History", "Cleared voice history")
    }

    /// The last `recentLimit` entries of the log, newest first. Reads only the file's tail: the log
    /// is append-only and never rotated, so it can grow without bound.
    private static func loadTail() -> [VoiceHistoryEntry] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        // Lossy decode: a read that starts mid-file can also start mid-character.
        let text = String(decoding: data, as: UTF8.self)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // When the read started mid-file the first line is partial and simply fails to decode.
        let entries = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(VoiceHistoryEntry.self, from: Data(line.utf8))
        }
        return Array(entries.suffix(recentLimit).reversed())
    }
}
