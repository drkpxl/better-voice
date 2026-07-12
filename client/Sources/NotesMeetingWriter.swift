import Foundation
import BetterVoiceCore

/// Writes a finished meeting (transcript + optional summary) to Apple Notes: renders the
/// Markdown bodies via `BetterVoiceCore` (`MeetingMarkdown`/`markdownToNotesHTML`), then creates
/// the notes via `NotesScript`. Two entry points cover Phase 3b's two callers: audio meetings
/// with diarized `MeetingSegment`s, and pasted transcripts that are already plain text.
///
/// Called from `ImportSession` (the import wizard's state machine): `write`/`writeTranscriptText`
/// at the end of processing, and `showNote(transcriptNoteId:summaryNoteId:)` from the completion
/// screen's "Show in Notes" button.
@MainActor
final class NotesMeetingWriter {
    static let shared = NotesMeetingWriter()

    /// Why there is no summary note, when there isn't one despite summarization being enabled.
    /// The two causes need different user-facing copy: `generationFailed` means the model never
    /// produced a summary (server unreachable), `noteWriteFailed` means the summary was generated
    /// fine but Apple Notes rejected the note write (the transcript note DID land).
    enum SummaryFailureReason: Sendable, Equatable {
        case generationFailed
        case noteWriteFailed
    }

    /// The notes created for a meeting, plus the title used. `summaryFailureReason` is non-nil
    /// when either summarization failed upstream (the caller passes `.generationFailed` in) OR
    /// the summary note itself failed to write after the transcript note succeeded (set here —
    /// see `writeNotes`); either way the wizard surfaces it and `summaryNoteId` is nil.
    struct Result {
        let transcriptNoteId: String
        let summaryNoteId: String?
        let title: String
        let summaryFailureReason: SummaryFailureReason?
    }

    enum WriterError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Apple Notes destination isn't configured yet."
            }
        }
    }

    private enum FolderKind {
        case transcripts
        case summaries
    }

    /// Tail of the single-flight write chain — see `serialized(_:)`.
    private var writeChain: Task<Void, Never>?

    // MARK: - Public API

    /// The exact transcript-note markdown `write(segments:...)` renders (title, metadata lines,
    /// speaker headings, timestamps) — exposed so the wizard's rescue screen can offer a "Copy
    /// transcript" identical to what the note would have contained, not the flat summarization
    /// input.
    func transcriptMarkdown(
        segments: [MeetingSegment],
        llmTitle: String?,
        type: MeetingType,
        date: Date,
        duration: TimeInterval
    ) -> String {
        MeetingMarkdown.renderTranscript(
            title: MeetingNoteTitle.transcriptTitle(date: date, llmTitle: llmTitle, typeDisplayName: type.defaultDisplayName),
            metadataLines: metadataLines(type: type, date: date, duration: duration),
            segments: segments,
            speakerPrefix: t("Speaker"),
            unknownLabel: t("Unknown"),
            localLabel: RuntimeConfig.shared.userName ?? t("You")
        )
    }

    /// Writes an audio/live meeting (has diarized segments) to Apple Notes.
    func write(
        segments: [MeetingSegment],
        summary: String?,
        llmTitle: String?,
        type: MeetingType,
        date: Date,
        duration: TimeInterval,
        summaryFailure: SummaryFailureReason? = nil
    ) async throws -> Result {
        try await serialized { [self] in
            let title = MeetingNoteTitle.title(date: date, llmTitle: llmTitle, typeDisplayName: type.defaultDisplayName)
            let transcriptTitle = MeetingNoteTitle.transcriptTitle(date: date, llmTitle: llmTitle, typeDisplayName: type.defaultDisplayName)

            return try await writeNotes(
                transcriptMarkdown: transcriptMarkdown(
                    segments: segments, llmTitle: llmTitle, type: type, date: date, duration: duration
                ),
                transcriptTitle: transcriptTitle,
                title: title,
                summary: summary,
                summaryMetadataLines: metadataLines(type: type, date: date, duration: duration),
                summaryFailure: summaryFailure
            )
        }
    }

    /// Writes a pasted transcript (plain text, no segments/diarization) to Apple Notes.
    func writeTranscriptText(
        _ text: String,
        summary: String?,
        llmTitle: String?,
        type: MeetingType,
        date: Date,
        summaryFailure: SummaryFailureReason? = nil
    ) async throws -> Result {
        try await serialized { [self] in
            let title = MeetingNoteTitle.title(date: date, llmTitle: llmTitle, typeDisplayName: type.defaultDisplayName)
            let transcriptTitle = MeetingNoteTitle.transcriptTitle(date: date, llmTitle: llmTitle, typeDisplayName: type.defaultDisplayName)
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcriptMarkdown = "# \(transcriptTitle)\n\n\(body)\n"

            return try await writeNotes(
                transcriptMarkdown: transcriptMarkdown,
                transcriptTitle: transcriptTitle,
                title: title,
                summary: summary,
                summaryMetadataLines: [
                    t("Type: \(type.defaultDisplayName)"),
                    t("Date: \(formatDate(date))"),
                ],
                summaryFailure: summaryFailure
            )
        }
    }

    /// Re-shows a previously created note (summary preferred, transcript otherwise) in Apple
    /// Notes — used by the wizard's completion screen "Show in Notes" button. Never throws, same
    /// as the reveal `writeNotes` does right after creating the notes (they already exist either
    /// way, so a show failure is just a missed nicety, not something to surface as an error).
    func showNote(transcriptNoteId: String, summaryNoteId: String?) async {
        await revealNote(id: summaryNoteId ?? transcriptNoteId)
    }

    /// Shared by the post-write reveal in `writeNotes` and the public `showNote(transcriptNoteId:summaryNoteId:)`.
    private func revealNote(id: String) async {
        do {
            try await NotesQueue.run { try NotesScript.showNote(id: id) }
        } catch {
            Logger.log("NotesMeetingWriter", "showNote failed (note was created fine): \(error.localizedDescription)")
        }
    }

    // MARK: - Single-flight

    /// Chains whole write bodies one after another: each write awaits the completion of the
    /// previous one before starting. `NotesQueue` only serializes individual `NotesScript`
    /// calls — without this, two overlapping `write()` calls could interleave the stale-folder
    /// recovery (list → maybe create → persist) and create duplicate folders in Notes. The
    /// chain-tail swap is synchronous main-actor code (this type is @MainActor), so there is no
    /// window for two writes to grab the same predecessor.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = writeChain
        let task = Task { () throws -> T in
            await previous?.value
            return try await body()
        }
        writeChain = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Shared write path

    private func writeNotes(
        transcriptMarkdown: String,
        transcriptTitle: String,
        title: String,
        summary: String?,
        summaryMetadataLines: [String],
        summaryFailure: SummaryFailureReason?
    ) async throws -> Result {
        let destination = try currentDestination()

        let transcriptHTML = markdownToNotesHTML(transcriptMarkdown)
        let transcriptId = try await createNoteResilient(
            kind: .transcripts,
            account: destination.account,
            folderId: destination.transcriptsFolderId,
            folderName: destination.transcriptsFolderName,
            title: transcriptTitle,
            html: transcriptHTML
        )

        // A nil/empty summary means summarization was disabled, failed upstream, or produced a
        // title-only response (SummarizationClient.summarizeWithTitle already returns nil for
        // that) — no summary note is created, and the caller is expected to have passed
        // `summaryFailure: .generationFailed` for the failure cases.
        var summaryId: String?
        var effectiveSummaryFailure = summaryFailure
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSummary, !trimmedSummary.isEmpty {
            let summaryMarkdown = MeetingMarkdown.renderSummary(
                title: title,
                metadataLines: summaryMetadataLines,
                summary: trimmedSummary
            )
            let summaryHTML = markdownToNotesHTML(summaryMarkdown)
            do {
                summaryId = try await createNoteResilient(
                    kind: .summaries,
                    account: destination.account,
                    folderId: destination.summariesFolderId,
                    folderName: destination.summariesFolderName,
                    title: title,
                    html: summaryHTML
                )
            } catch {
                // The transcript note already exists — throwing here would make the caller's
                // retry duplicate it. Degrade to "summary note write failed" instead; the wizard
                // surfaces it with note-write-specific copy (the summary WAS generated).
                Logger.log("NotesMeetingWriter", "Summary note write failed after transcript note succeeded: \(error.localizedDescription)")
                effectiveSummaryFailure = .noteWriteFailed
            }
        }

        // Revealing the note is a nicety — both notes are already durably created, so a show
        // failure is logged and swallowed, never thrown.
        await revealNote(id: summaryId ?? transcriptId)

        return Result(
            transcriptNoteId: transcriptId,
            summaryNoteId: summaryId,
            title: title,
            summaryFailureReason: effectiveSummaryFailure
        )
    }

    // MARK: - Stale-folder resilience

    /// Creates a note in the given folder, transparently re-resolving (and, failing that,
    /// recreating) the folder by name and retrying exactly once if the configured folder id no
    /// longer resolves in Notes (`BV_FOLDER_NOT_FOUND` — e.g. the user deleted/recreated the
    /// folder since it was chosen). This is why `RuntimeConfig.notesConfig` stores folder names
    /// alongside ids.
    private func createNoteResilient(
        kind: FolderKind,
        account: String,
        folderId: String,
        folderName: String,
        title: String,
        html: String
    ) async throws -> String {
        do {
            return try await NotesQueue.run {
                try NotesScript.createNote(account: account, folderId: folderId, name: title, html: html)
            }
        } catch let error as NotesScript.NotesScriptError {
            guard case .osascriptFailed(_, let stderr) = error, stderr.contains("BV_FOLDER_NOT_FOUND") else {
                throw error
            }
            Logger.log("NotesMeetingWriter", "Folder id stale for \(folderName), re-resolving")
            let freshId = try await resolveOrCreateFolder(account: account, name: folderName)
            persistFolderId(kind: kind, id: freshId, name: folderName)
            return try await NotesQueue.run {
                try NotesScript.createNote(account: account, folderId: freshId, name: title, html: html)
            }
        }
    }

    /// Looks up `name` among the account's folders; creates it if no folder with that name
    /// exists (e.g. the user deleted it entirely, not just recreated it under the same id).
    private func resolveOrCreateFolder(account: String, name: String) async throws -> String {
        let folders = try await NotesQueue.run { try NotesScript.listFolders(account: account) }
        if let match = folders.first(where: { $0.name == name }) {
            return match.id
        }
        let created = try await NotesQueue.run { try NotesScript.createFolder(account: account, name: name) }
        return created.id
    }

    private func persistFolderId(kind: FolderKind, id: String, name: String) {
        var cfg = RuntimeConfig.shared.notesConfig
        switch kind {
        case .transcripts:
            cfg["transcriptsFolderId"] = id
            cfg["transcriptsFolderName"] = name
        case .summaries:
            cfg["summariesFolderId"] = id
            cfg["summariesFolderName"] = name
        }
        RuntimeConfig.shared.updateSection("notes", cfg)
    }

    // MARK: - Config

    private struct NotesDestination {
        let account: String
        let transcriptsFolderId: String
        let transcriptsFolderName: String
        let summariesFolderId: String
        let summariesFolderName: String
    }

    /// Validity is defined once, by `RuntimeConfig.notesConfigured` (all five keys non-empty) —
    /// this just materializes the already-validated values, so the `?? ""` defaults below are
    /// unreachable in practice.
    private func currentDestination() throws -> NotesDestination {
        guard RuntimeConfig.shared.notesConfigured else {
            throw WriterError.notConfigured
        }
        let cfg = RuntimeConfig.shared.notesConfig
        return NotesDestination(
            account: cfg["account"] as? String ?? "",
            transcriptsFolderId: cfg["transcriptsFolderId"] as? String ?? "",
            transcriptsFolderName: cfg["transcriptsFolderName"] as? String ?? "",
            summariesFolderId: cfg["summariesFolderId"] as? String ?? "",
            summariesFolderName: cfg["summariesFolderName"] as? String ?? ""
        )
    }

    // MARK: - Formatting

    private func metadataLines(type: MeetingType, date: Date, duration: TimeInterval) -> [String] {
        [
            t("Type: \(type.defaultDisplayName)"),
            t("Date: \(formatDate(date))"),
            t("Duration: \(formatDuration(duration))"),
        ]
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: t("%dh %dm %ds"), h, m, s)
        }
        return String(format: t("%dm %ds"), m, s)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = t("yyyy-MM-dd HH:mm")
        return f.string(from: date)
    }
}

/// Serial background queue every `NotesScript` call is bridged through. `NotesScript`'s
/// functions are synchronous and block on an `osascript` subprocess for up to ~50s worst case
/// (see its own doc comment) — running them directly from an `async` context would tie up a
/// thread from Swift concurrency's cooperative pool (which is sized for CPU-bound work, not
/// long blocking calls) for that whole time, and running them on the main thread would freeze
/// the UI. Routing every call through one dedicated serial queue keeps them off both, and keeps
/// Notes writes for a single meeting strictly ordered relative to each other.
///
/// Not `private` — `NotesDestinationPickerView`'s view model (`NotesDestinationPickerView.swift`)
/// reuses this same queue for its `listAccounts`/`listFolders`/`createFolder` calls rather than
/// standing up a second one, so every `NotesScript` call in the app funnels through one place.
enum NotesQueue {
    private static let queue = DispatchQueue(label: "com.bettervoice.notes-writer", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
