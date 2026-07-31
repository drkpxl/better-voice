import Foundation

/// History record for each dictation, written to ~/Library/Logs/BetterVoice2/voice-history.jsonl.
///
/// `rawText` vs `finalText` is the one comparison worth keeping: it shows what the deterministic
/// stages (`FillerStripper`, then `Vocabulary`) changed, which is the only transformation left on this
/// path. Four other fields came out — `polishedText` (always nil since the LLM cleanup stage was
/// deleted), `words` and `audioPath` (see `TranscriptionResult`), and `l1Text`, which was not merely
/// vestigial but a duplicate: it and `rawSA` were both assigned `transcription.fullText`.
///
/// Write-only, like `meeting-history.jsonl` — `JSONLWriter.append` is `Encodable`-only and nothing
/// reads either file, which is why renaming and dropping columns needed no migration.
struct VoiceHistoryEntry: Codable {
    let timestamp: Date
    let rawText: String
    let finalText: String
    let appBundleID: String?
    let appName: String?
}

@MainActor
final class VoiceHistory {
    // Dictation history lives in the fixed log dir (not the user's workspace folder): it is a
    // debugging artifact, and dictation must work before any workspace is configured.
    private let writer = JSONLWriter(fileURL: Logger.logDirectory.appendingPathComponent("voice-history.jsonl"))

    func save(transcription: TranscriptionResult, finalText: String, app: AppIdentity?) {
        let entry = VoiceHistoryEntry(
            timestamp: transcription.timestamp,
            rawText: transcription.fullText,
            finalText: finalText,
            appBundleID: app?.bundleID,
            appName: app?.appName
        )
        writer.append(entry)
        Logger.log("History", "Saved voice history entry")
    }
}
