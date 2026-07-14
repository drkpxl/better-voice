import Foundation
import BetterVoiceCore

/// The 5-step import wizard's state machine. Reuses `ImportPipeline` as the engine and absorbs
/// v1's `MeetingCoordinator.finishMeeting` orchestration (classify → name → summarize → learn
/// voice-prints → save to Apple Notes), but the "pauses" (setup, naming, review) are just the
/// machine resting in a step until the user taps Continue — no modal/continuation.
///
/// Phase 3b: the only durable output is Apple Notes (via `NotesMeetingWriter`) — there is no more
/// in-app file export. `begin()` gates on Notes being configured + Automation being granted
/// *before* any processing starts (`.blocked`); a Notes-write failure *after* processing
/// completes (transcription/diarization/summarization already done) never loses that work — it's
/// kept in memory and offered back via `.saveFailed` (retry / copy transcript / copy summary).
///
/// One `ImportSession` per import. The host (main window) sets `onFinish` to start a fresh
/// session (Apple Notes is the archive now, not the in-app window — see `MeetingsRootView`).
enum ImportStep: Equatable {
    case setup          // Step 1: choose file + single/multi
    case processing     // Step 2: transcribe (+ diarize) with live progress
    case naming         // Step 3: name speakers + confirm type (multi only)
    case summarizing    // Step 4: summarize with progress
    case review         // Step 5: completion screen — the meeting is in Apple Notes
    case failed(String) // unreadable audio / transcription error (nothing produced yet)
    case blocked(String)    // Notes destination not configured / Automation not granted — no processing attempted
    case saveFailed(String) // processing finished but the Notes write failed/threw — content is kept in memory
}

/// How the recording enters the wizard: an audio file to transcribe, an already-made transcript
/// pasted as text (skips transcription + diarization → straight to summarize), or the two WAVs
/// (mic + system) just finalized by `MeetingCoordinator`'s live "Start Meeting Recording" capture.
/// `.liveMeeting` skips Step 1 (setup) entirely and drives its own two-file processing — it exists
/// as its own case so the UI/state can tell "the user picked a file in Step 1" apart from "a live
/// recording skipped Step 1 entirely" (see `beginLiveMeeting(micFileURL:systemFileURL:)`).
enum ImportInputMode: Equatable {
    case audio
    case transcript
    case liveMeeting
}

@MainActor
@Observable
final class ImportSession {

    /// Weak pointer to whichever `ImportSession` is currently live (there is only ever one — the
    /// main window runs one import at a time, see `MeetingsRootView`). Kept up to date by
    /// `init()` below.
    ///
    /// `WizardCloseGuard` (ImportWizardView.swift) already confirms before a window close
    /// discards unsaved finished work, but ⌘Q / the menu-bar Quit terminate the app directly
    /// without closing any window first, bypassing that guard entirely. `AppDelegate.
    /// applicationShouldTerminate` (BetterVoice2App.swift) reads `activeSession?.
    /// hasUnsavedFinishedWork` through this pointer to apply the same confirmation there. `weak`
    /// means it self-clears once the session is released (the host replaces it with a fresh one
    /// in `finish()`) — no manual teardown needed.
    static weak var activeSession: ImportSession?

    init() {
        ImportSession.activeSession = self
    }

    /// Per-speaker draft for the naming step (salvaged from v1's wrap-up `Speaker`).
    struct SpeakerDraft: Identifiable {
        let id: String            // speakerId, e.g. "1"
        let quotes: [String]      // representative turns to help identify the voice
        let suggestedName: String?
        var name: String

        init(id: String, quotes: [String], suggestedName: String?) {
            self.id = id
            self.quotes = quotes
            self.suggestedName = suggestedName
            self.name = suggestedName ?? ""
        }
    }

    // Inputs (Step 1)
    var inputMode: ImportInputMode = .audio
    var fileURL: URL?
    var speakerMode: SpeakerMode = .multi
    /// Pasted transcript text (used when `inputMode == .transcript`).
    var pastedTranscript: String = ""

    // Progress
    private(set) var step: ImportStep = .setup
    private(set) var phase: ImportPhase = .transcribing
    private(set) var progress: Double = 0
    private(set) var isBusy = false
    /// True while the (potentially slow — up to ~50s of blocking osascript) Apple Notes write is
    /// in flight, so the summarizing step can switch its caption from "writing a summary" to
    /// "saving to Notes" instead of lying about what's taking so long.
    private(set) var isSavingToNotes = false

    // Results
    private(set) var result: MeetingResult?
    private(set) var inferredType: MeetingType = .general
    var selectedType: MeetingType = .general
    var speakers: [SpeakerDraft] = []

    // Apple Notes write outcome (Step 5 / completion screen)
    private(set) var transcriptNoteId: String?
    private(set) var summaryNoteId: String?
    private(set) var noteTitle: String?
    /// Set when summarization was expected but produced nothing (`.generationFailed`), OR the
    /// summary note itself failed to write after the transcript note succeeded
    /// (`.noteWriteFailed`). Either way the transcript is safely in Notes; the completion screen
    /// shows a cause-appropriate caption.
    private(set) var summaryFailureReason: NotesMeetingWriter.SummaryFailureReason?

    /// Called when the user finishes the wizard (Done / Close) so the host starts a fresh import.
    var onFinish: (() -> Void)?

    private let pipeline = ImportPipeline()
    private let prefix = t("Speaker")
    private var localLabel: String { RuntimeConfig.shared.userName ?? t("You") }

    // MARK: - Rescue state (kept in memory so a Notes-write failure never loses finished work)

    /// What the (eventual) `NotesMeetingWriter` call needs — filled in once processing +
    /// summarization finish, before the write is attempted. Kept around so `retryNotesWrite()`
    /// can re-invoke just the write, without repeating transcription/diarization/summarization.
    private enum PendingWrite {
        case audio(segments: [MeetingSegment], date: Date, duration: TimeInterval)
        case transcriptText(String, date: Date)
    }
    private var pendingWrite: PendingWrite?
    private var pendingLLMTitle: String?
    /// Upstream summarization failure (`.generationFailed` when the server produced nothing),
    /// independent of whether the eventual Notes write itself later succeeds or fails.
    private var pendingSummaryFailure: NotesMeetingWriter.SummaryFailureReason?

    /// The finished summary text, if any — kept for both the eventual write and the rescue
    /// screen's "Copy summary" (nil when summarization was disabled or failed).
    private(set) var pendingSummary: String?
    /// The transcript document as the note would contain it (rendered markdown with title,
    /// metadata, and speaker headings for audio imports; the pasted text as-is for the paste
    /// path) — kept for the rescue screen's "Copy transcript".
    private(set) var pendingTranscriptText: String?

    // MARK: - Step 1 → 2

    func begin() {
        guard gateNotesReady() else { return }
        switch inputMode {
        case .audio:
            guard let fileURL else { return }
            step = .processing
            phase = .transcribing
            progress = 0
            isBusy = true
            Task { await runProcessing(fileURL) }
        case .liveMeeting:
            // Driven by `beginLiveMeeting(micFileURL:systemFileURL:)` instead, which runs its own
            // two-file processing (see that method) — `begin()` is never invoked directly with
            // this inputMode.
            return
        case .transcript:
            let text = pastedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            step = .summarizing
            phase = .summarizing
            progress = 0
            isBusy = true
            Task { await runPastedTranscript(text) }
        }
    }

    /// Gates BEFORE any processing starts: the same Notes-configured + Automation-granted check,
    /// shared by `begin()` and `beginLiveMeeting(micFileURL:systemFileURL:)` so both entry points
    /// show identical `.blocked` guidance. Sets `step = .blocked(...)` and returns false on
    /// failure; leaves `step` untouched and returns true otherwise.
    private func gateNotesReady() -> Bool {
        if !RuntimeConfig.shared.notesConfigured {
            step = .blocked(t("Apple Notes isn't set up yet. Choose an Apple Notes account and folders in Settings before importing."))
            return false
        }
        // Just-in-time request (no onboarding step): when the Automation state is undetermined,
        // `requestAutomation()` fires the system consent dialog right here at the point of use;
        // once denied it's a quick no-op and the `.blocked` guidance below (deep link to the pane,
        // where the row now exists because the app has asked) is the way back.
        if !PermissionManager.isAutomationGranted(), !PermissionManager.requestAutomation() {
            step = .blocked(t("Better Voice needs permission to control Apple Notes. Grant Automation access in System Settings, then try again."))
            return false
        }
        return true
    }

    /// `MeetingCoordinator`'s Stop Meeting hand-off for the two-file (mic + system) meeting
    /// capture — see `MeetingCoordinator`'s doc comment for why a live meeting records mic and
    /// system audio as two independently-clocked, native-rate WAVs instead of one mixed file.
    /// Skips Step 1 (setup) entirely, same as the old single-file live path, and drops into
    /// `runLiveMeetingProcessing`, which runs each file through `ImportPipeline` independently
    /// and merges the results before continuing into the SAME naming → summarizing → Notes chain
    /// `.audio` imports use — zero duplication there either.
    ///
    /// `micFileURL` is nil when `MeetingCoordinator` already determined the mic channel was
    /// absent (denied/failed to start) or effectively silent — `runLiveMeetingProcessing` falls
    /// back to system-only `.multi` diarization in that case, matching pre-two-file behavior.
    func beginLiveMeeting(micFileURL: URL?, systemFileURL: URL) {
        inputMode = .liveMeeting
        fileURL = systemFileURL
        speakerMode = .multi
        guard gateNotesReady() else { return }
        step = .processing
        phase = .transcribing
        progress = 0
        isBusy = true
        Task { await runLiveMeetingProcessing(micFileURL: micFileURL, systemFileURL: systemFileURL) }
    }

    // MARK: - Pasted-transcript path (no audio → no transcription/diarization)

    /// Summarize the pasted transcript (using the type the user chose in setup), then save both
    /// to Apple Notes. Speaker naming is skipped entirely — a pasted transcript already carries
    /// whatever speaker labels it has.
    private func runPastedTranscript(_ text: String) async {
        let client = SummarizationClient.shared
        let date = Date()

        var summary: String?
        var llmTitle: String?
        var summaryFailure: NotesMeetingWriter.SummaryFailureReason?
        if client.summarizationEnabled {
            if let summarized = await client.summarizeWithTitle(transcript: text, type: selectedType) {
                summary = summarized.summary
                llmTitle = summarized.title
            } else {
                summaryFailure = .generationFailed
                Logger.log("Import", "Pasted-transcript summary not produced (server unreachable?)")
            }
        }

        pendingWrite = .transcriptText(text, date: date)
        pendingTranscriptText = text
        pendingSummary = summary
        pendingLLMTitle = llmTitle
        pendingSummaryFailure = summaryFailure

        await writeToNotes()
    }

    private func runProcessing(_ fileURL: URL) async {
        do {
            let res = try await pipeline.run(fileURL, speakerMode: speakerMode) { [weak self] phase, frac in
                guard let self else { return }
                self.phase = phase
                self.progress = frac
            }
            result = res
            await afterProcessing(res)
        } catch {
            isBusy = false
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            step = .failed(msg)
        }
    }

    /// The two-file live-meeting path: transcribe+diarize the system file (`.multi` — remote
    /// speakers), transcribe the mic file flat (`.single` — no diarization, since nothing but the
    /// local user is ever on that channel), then merge the two into one chronological timeline
    /// via `mergeSpeakerTimelines` (Core) — the mic segments come back already resolvable to the
    /// user's configured name (`SpeakerIds.local`; see that function's doc comment), so the
    /// naming step below only ever prompts for the system file's diarized remote speakers.
    ///
    /// Both files are run through the SAME `pipeline` instance sequentially (never concurrently)
    /// — `ImportPipeline.run` resets all of its per-run state at the top of each call, so two
    /// awaited-in-order calls are safe; concurrent calls would not be.
    ///
    /// A missing `micFileURL` (mic denied/failed/silent — screened by `MeetingCoordinator`) falls
    /// back to system-only `.multi`, identical to the pre-two-file live-meeting behavior.
    private func runLiveMeetingProcessing(micFileURL: URL?, systemFileURL: URL) async {
        do {
            let systemResult = try await pipeline.run(systemFileURL, speakerMode: .multi) { [weak self] phase, frac in
                guard let self else { return }
                self.phase = phase
                // Reserve the back half of the progress bar for the mic pass (when there is one)
                // so it doesn't visually complete twice.
                self.progress = micFileURL != nil ? frac * 0.5 : frac
            }

            var mergedSegments = systemResult.segments
            if let micFileURL {
                let micResult = try await pipeline.run(micFileURL, speakerMode: .single) { [weak self] phase, frac in
                    guard let self else { return }
                    self.phase = phase
                    self.progress = 0.5 + frac * 0.5
                }
                mergedSegments = mergeSpeakerTimelines(localSegments: micResult.segments, remoteSegments: systemResult.segments)
            }

            let merged = MeetingResult(
                segments: mergedSegments,
                // Duration comes from the system channel. If the mic ran materially longer (e.g.
                // system-audio capture was silently denied mid-meeting while the mic kept going),
                // this under-counts — acceptable: the merged segments still carry the true tail.
                duration: systemResult.duration,
                audioPath: systemFileURL.path,
                date: systemResult.date
            )
            result = merged
            await afterProcessing(merged)
        } catch {
            isBusy = false
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            step = .failed(msg)
        }
    }

    // MARK: - After processing: classify + branch to naming or straight to summary

    private func afterProcessing(_ res: MeetingResult) async {
        let client = SummarizationClient.shared
        let raw = buildSummarizationTranscript(segments: res.segments, speakerPrefix: prefix, localLabel: localLabel)
        if client.classifyEnabled, !raw.isEmpty {
            inferredType = await client.classifyType(transcript: raw)
        } else {
            inferredType = client.defaultType
        }
        selectedType = inferredType

        // Build speaker drafts (multi only). Imports have no local "me" speaker, but filter for safety.
        if speakerMode == .multi {
            let ids = orderedUniqueSpeakerIds(res.segments).filter { $0 != SpeakerIds.local }
            let quotes = sampleQuotes(res.segments)
            let embeddings = speakerEmbeddings(from: res.segments).filter { $0.key != SpeakerIds.local }
            let suggested = SpeakerStore.shared.suggestions(for: embeddings)
            speakers = ids.map { SpeakerDraft(id: $0, quotes: quotes[$0] ?? [], suggestedName: suggested[$0]) }
        } else {
            speakers = []
        }

        isBusy = false
        if speakerMode == .multi, !speakers.isEmpty {
            step = .naming
        } else {
            // Single speaker, or clustering found no distinct speakers → skip naming.
            await finalize(names: [:])
        }
    }

    // MARK: - Step 3 → 4

    /// Confirm the entered speaker names + type, then summarize + save.
    func confirmNaming() {
        var names: [String: String] = [:]
        for s in speakers {
            let n = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { names[s.id] = n }
        }
        step = .summarizing
        isBusy = true
        Task { await finalize(names: names) }
    }

    // MARK: - Finalize: learn voices, summarize, save to Apple Notes

    private func finalize(names: [String: String]) async {
        guard let res = result else { return }
        step = .summarizing
        isBusy = true
        phase = .summarizing
        progress = 0

        let embeddings = speakerEmbeddings(from: res.segments).filter { $0.key != SpeakerIds.local }

        // Learn/refresh voice profiles from confirmed names (empty names learns nothing).
        SpeakerStore.shared.learn(names: names, embeddings: embeddings)

        // Names applied; empty names = unchanged flat transcript.
        let named = applySpeakerNames(names, to: res.segments)
        let namedTranscript = buildSummarizationTranscript(segments: named, speakerPrefix: prefix, localLabel: localLabel)

        // Summarize (indeterminate progress; UI shows a spinner).
        let client = SummarizationClient.shared
        var summary: String?
        var llmTitle: String?
        var summaryFailure: NotesMeetingWriter.SummaryFailureReason?
        if client.summarizationEnabled {
            if let summarized = await client.summarizeWithTitle(transcript: namedTranscript, type: selectedType) {
                summary = summarized.summary
                llmTitle = summarized.title
            } else {
                summaryFailure = .generationFailed
                Logger.log("Import", "Summary expected but not produced (server unreachable?)")
            }
        }

        pendingWrite = .audio(segments: named, date: res.date, duration: res.duration)
        // The rescue "Copy transcript" must match what the note would contain — the rendered
        // document (title/metadata/speaker headings/timestamps), not the flat summarization input.
        pendingTranscriptText = NotesMeetingWriter.shared.transcriptMarkdown(
            segments: named, llmTitle: llmTitle, type: selectedType, date: res.date, duration: res.duration
        )
        pendingSummary = summary
        pendingLLMTitle = llmTitle
        pendingSummaryFailure = summaryFailure

        await writeToNotes()
    }

    // MARK: - Apple Notes write (+ rescue retry)

    /// Runs the actual `NotesMeetingWriter` call from `pendingWrite`. On success, lands on the
    /// completion screen; on failure (including Notes getting unconfigured/revoked mid-flight),
    /// lands on `.saveFailed` — `pendingWrite`/`pendingSummary`/`pendingTranscriptText` are left
    /// intact so `retryNotesWrite()` can try again without repeating any earlier work.
    private func writeToNotes() async {
        guard let pendingWrite else {
            isBusy = false // unreachable in practice, but never strand the UI on a spinner
            return
        }
        isSavingToNotes = true
        defer { isSavingToNotes = false }
        do {
            let written: NotesMeetingWriter.Result
            switch pendingWrite {
            case .audio(let segments, let date, let duration):
                written = try await NotesMeetingWriter.shared.write(
                    segments: segments,
                    summary: pendingSummary,
                    llmTitle: pendingLLMTitle,
                    type: selectedType,
                    date: date,
                    duration: duration,
                    summaryFailure: pendingSummaryFailure
                )
            case .transcriptText(let text, let date):
                written = try await NotesMeetingWriter.shared.writeTranscriptText(
                    text,
                    summary: pendingSummary,
                    llmTitle: pendingLLMTitle,
                    type: selectedType,
                    date: date,
                    summaryFailure: pendingSummaryFailure
                )
            }
            transcriptNoteId = written.transcriptNoteId
            summaryNoteId = written.summaryNoteId
            noteTitle = written.title
            summaryFailureReason = written.summaryFailureReason
            isBusy = false
            step = .review
        } catch {
            isBusy = false
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            step = .saveFailed(msg)
        }
    }

    /// True while finished work exists ONLY in this session's memory: the Notes write failed
    /// (`.saveFailed`) or is still in flight. Closing the main window in this state would
    /// silently discard the import (the wizard's state dies with the window), so the close
    /// guard confirms first.
    var hasUnsavedFinishedWork: Bool {
        if case .saveFailed = step { return true }
        return isSavingToNotes
    }

    /// Rescue screen's "Try again": re-invokes just the Notes write with the content already kept
    /// in memory. Not a full re-import — transcription/diarization/summarization already happened.
    func retryNotesWrite() {
        guard pendingWrite != nil, !isBusy else { return }
        isBusy = true
        Task { await writeToNotes() }
    }

    /// Re-shows the note created for this meeting (summary preferred, transcript otherwise) —
    /// the completion screen's "Show in Notes" button.
    func showInNotes() {
        guard let transcriptNoteId else { return }
        Task { await NotesMeetingWriter.shared.showNote(transcriptNoteId: transcriptNoteId, summaryNoteId: summaryNoteId) }
    }

    // MARK: - Step 5

    /// Finish the wizard; the host just starts a fresh import (nothing to select — Apple Notes
    /// is the archive now, not an in-app library).
    func finish() {
        // `activeSession` is weak and normally self-clears when the host drops the session, but
        // clear it eagerly too — cheap insurance against a future strong reference keeping a
        // finished "zombie" session alive whose stale state could block quitting.
        if ImportSession.activeSession === self { ImportSession.activeSession = nil }
        onFinish?()
    }
}
