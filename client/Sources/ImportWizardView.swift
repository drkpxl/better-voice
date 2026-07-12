import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BetterVoiceCore

/// The 5-step import wizard UI. A thin, declarative shell over `ImportSession` (the state
/// machine): every step is just a view of `session.step`, and user actions call the session's
/// `begin()` / `confirmNaming()` / `finish()`. No window/continuation machinery — the host
/// (`MeetingsRootView`) is a thin host that resets the session to a fresh import when it finishes.
struct ImportWizardView: View {
    @Bindable var session: ImportSession

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Color.brandAccent)
        // Finished-but-unsaved work only exists in this session's memory — confirm before
        // letting a window close (red button / ⌘W) silently discard it.
        .background(WizardCloseGuard(shouldConfirm: { session.hasUnsavedFinishedWork }))
    }

    @ViewBuilder
    private var content: some View {
        switch session.step {
        case .setup:
            SetupStepView(session: session)
        case .processing:
            ProcessingStepView(session: session)
        case .naming:
            SpeakersStepView(session: session)
        case .summarizing:
            SummarizingStepView(session: session)
        case .review:
            ReviewStepView(session: session)
        case .failed(let msg):
            FailedStepView(session: session, message: msg)
        case .blocked(let msg):
            BlockedStepView(session: session, message: msg)
        case .saveFailed(let msg):
            SaveFailedStepView(session: session, message: msg)
        }
    }
}

// MARK: - Step header

/// "Step N of 5" + a title, shown atop the setup/naming/review steps.
private struct StepHeader: View {
    let step: Int
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Step \(step) of 5"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brandAccent)
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 1: Setup

struct SetupStepView: View {
    @Bindable var session: ImportSession
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(
                step: 1,
                title: t("Import a recording"),
                subtitle: t("Transcribe an audio file, or paste a transcript you already have.")
            )

            Picker("", selection: $session.inputMode) {
                Text(t("Audio file")).tag(ImportInputMode.audio)
                Text(t("Paste transcript")).tag(ImportInputMode.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if session.inputMode == .audio {
                dropZone
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Who's talking?"))
                        .font(.subheadline.weight(.semibold))
                    Picker("", selection: $session.speakerMode) {
                        Text(t("Multiple speakers")).tag(SpeakerMode.multi)
                        Text(t("Just me / single speaker")).tag(SpeakerMode.single)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Spacer()
            } else {
                transcriptEntry
            }

            HStack {
                Spacer()
                Button(t("Continue")) { session.begin() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            }
        }
        .padding(28)
    }

    private var canContinue: Bool {
        switch session.inputMode {
        case .audio:
            return session.fileURL != nil
        case .transcript:
            return !session.pastedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .liveMeeting:
            // Unreachable: `beginLiveMeeting(micFileURL:systemFileURL:)` jumps straight to
            // `.processing`, so Step 1 (and this Continue button) is never shown for a
            // live-meeting session.
            return true
        }
    }

    /// Paste-transcript entry: a text area + a meeting-type picker (no speaker step — the pasted
    /// text keeps whatever speaker labels it already has).
    private var transcriptEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Paste the transcript text (e.g. a Teams or Zoom export). Any speaker names in the text are kept as-is."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $session.pastedTranscript)
                .font(.body)
                .frame(minHeight: 200, maxHeight: .infinity)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )

            HStack(spacing: 10) {
                Text(t("Meeting type"))
                    .font(.subheadline.weight(.semibold))
                Picker(selection: $session.selectedType) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.defaultDisplayName).tag(type)
                    }
                } label: {
                    Text(t("Meeting type"))
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(t("Paste from clipboard")) {
                    if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                        session.pastedTranscript = s
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The chosen file (or a drop/choose prompt). Doubles as a drop target for audio files.
    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: session.fileURL == nil ? "waveform.badge.plus" : "waveform")
                .font(.system(size: 34))
                .foregroundStyle(Color.brandAccent)
            if let url = session.fileURL {
                Text(url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(t("Choose a different file…")) { chooseFile() }
                    .buttonStyle(.link)
            } else {
                Text(t("Drop an audio file here"))
                    .foregroundStyle(.secondary)
                Button(t("Choose File…")) { chooseFile() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.brandAccent.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.brandAccent : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.fileURL = url
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.prompt = t("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.fileURL = url
    }
}

// MARK: - Step 2: Processing

struct ProcessingStepView: View {
    @Bindable var session: ImportSession

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            BrandWaveform(height: 44)
            Text(session.phase.label)
                .font(.title3.weight(.medium))
            // Transcription has true end-to-end progress (endTime/duration), so show a determinate
            // bar. Diarization only reports its *segmentation* sub-phase — embedding, clustering,
            // and phrase→speaker alignment all run AFTER that hits 100%, so a determinate bar would
            // sit misleadingly full while work continues. Use an indeterminate (animated) bar there.
            if case .identifyingSpeakers = session.phase {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
            } else {
                ProgressView(value: session.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
            }
            Text(t("This can take a while for long recordings."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

// MARK: - Step 3: Name the speakers

struct SpeakersStepView: View {
    @Bindable var session: ImportSession
    @FocusState private var focusedSpeaker: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(
                    step: 3,
                    title: t("Name the speakers"),
                    subtitle: t("Match each voice to a name. You can leave any blank — a summary is generated either way.")
                )

                Picker(selection: $session.selectedType) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.defaultDisplayName).tag(type)
                    }
                } label: {
                    Text(t("Meeting type"))
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($session.speakers) { $speaker in
                        speakerCard($speaker)
                    }
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button(t("Continue")) { session.confirmNaming() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private func speakerCard(_ speaker: Binding<ImportSession.SpeakerDraft>) -> some View {
        let quotes = speaker.wrappedValue.quotes
        VStack(alignment: .leading, spacing: 10) {
            if !quotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                        Text("“\(quote)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("\(t("Speaker")) \(speaker.wrappedValue.id)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandAccent)
                    .fixedSize()
                TextField(t("is…  (type a name)"), text: speaker.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedSpeaker, equals: speaker.wrappedValue.id)
                    .onSubmit { advanceFocus(after: speaker.wrappedValue.id) }
            }

            if speaker.wrappedValue.suggestedName != nil {
                Text(t("Recognized from a previous meeting — edit if this is wrong."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Return in a name field jumps to the next speaker, or drops focus (so the default
    /// Continue button can take Return) once at the last one.
    private func advanceFocus(after id: String) {
        let ids = session.speakers.map(\.id)
        guard let idx = ids.firstIndex(of: id), idx + 1 < ids.count else {
            focusedSpeaker = nil
            return
        }
        focusedSpeaker = ids[idx + 1]
    }
}

// MARK: - Step 4: Summarizing

struct SummarizingStepView: View {
    @Bindable var session: ImportSession

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // Summarization has no measurable progress — an indeterminate spinner. The Notes
            // write that follows can itself take a while (blocking osascript), so the caption
            // switches rather than claiming to still be summarizing.
            ProgressView()
                .controlSize(.large)
            Text(session.isSavingToNotes ? t("Saving to Apple Notes…") : session.phase.label)
                .font(.title3.weight(.medium))
            Text(session.isSavingToNotes
                 ? t("Adding this meeting to your Notes folders.")
                 : t("Writing a summary of the conversation."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

// MARK: - Step 5: Completion

/// Replaces the old editor/tabs review step: the meeting is already saved to Apple Notes by the
/// time this shows, so there's nothing left to review in-app — just confirm it landed and offer
/// "Show in Notes" to jump to it.
struct ReviewStepView: View {
    @Bindable var session: ImportSession

    private var openedSummary: Bool { session.summaryNoteId != nil }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(Color.brandAccent)
            Text(openedSummary ? t("Added to Notes — opened the summary.") : t("Added to Notes — opened the transcript."))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let title = session.noteTitle {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let reason = session.summaryFailureReason {
                Text(summaryFailureCaption(reason))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            Button(t("Show in Notes")) { session.showInNotes() }
                .buttonStyle(.bordered)

            Spacer()

            HStack {
                Spacer()
                Button(t("Done")) { session.finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    /// The two no-summary-note causes read very differently to the user: generation failure
    /// means no summary exists anywhere; a note-write failure means the summary was produced
    /// but Apple Notes rejected it (misdirecting the user at their model server would be wrong).
    private func summaryFailureCaption(_ reason: NotesMeetingWriter.SummaryFailureReason) -> String {
        switch reason {
        case .generationFailed:
            return t("The summary couldn't be generated (model server unreachable?). Your transcript was still saved.")
        case .noteWriteFailed:
            return t("Your summary couldn't be saved to Notes — the transcript was. If this keeps happening, check your Notes setup in Settings.")
        }
    }
}

// MARK: - Failed (pre-processing: unreadable audio / transcription error)

struct FailedStepView: View {
    @Bindable var session: ImportSession
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(t("Import failed"))
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            // Nothing was produced; finishing just starts a fresh import.
            Button(t("Close")) { session.finish() }
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

// MARK: - Blocked (pre-flight: Apple Notes not configured / Automation not granted)

/// Shown by `begin()`'s up-front gate — no processing was attempted. Offers the two settings
/// surfaces that could be the problem; either one may be all that's needed, so both are always
/// offered rather than trying to guess which one applies from the message alone.
struct BlockedStepView: View {
    @Bindable var session: ImportSession
    let message: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(t("Apple Notes isn't ready"))
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button(t("Open Notes setup")) { openSettings() }
                Button(t("Open Automation Settings")) { PermissionManager.openSettings(for: .automation) }
            }

            Button(t("Try Again")) { session.begin() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            // Nothing was processed yet — closing loses nothing.
            Button(t("Close")) { session.finish() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

// MARK: - Save failed (rescue: processing finished, the Apple Notes write failed)

/// Processing (transcription/diarization/summarization) already completed — that work is never
/// repeated here. "Try again" only re-invokes the Notes write; the copy buttons are the fallback
/// if Notes still won't cooperate.
struct SaveFailedStepView: View {
    @Bindable var session: ImportSession
    let message: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(t("Couldn't save to Apple Notes"))
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            Text(t("Your transcript and summary are kept — nothing was lost. Try again, or copy them out."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            if session.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(t("Try Again")) { session.retryNotesWrite() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }

            // The write can fail because Notes got unconfigured or Automation got revoked
            // mid-flight — cases Try Again alone can never fix, so both settings surfaces are
            // offered here too, same as the pre-flight blocked screen.
            HStack(spacing: 12) {
                Button(t("Open Notes setup")) { openSettings() }
                Button(t("Open Automation Settings")) { PermissionManager.openSettings(for: .automation) }
            }
            .disabled(session.isBusy)

            HStack(spacing: 12) {
                Button(t("Copy transcript")) { copy(session.pendingTranscriptText ?? "") }
                    .disabled(session.pendingTranscriptText == nil)
                Button(t("Copy summary")) { copy(session.pendingSummary ?? "") }
                    .disabled(session.pendingSummary == nil)
            }
            .disabled(session.isBusy)

            // Closing here discards the finished (unsaved) import — confirm first, same
            // alert the window-close guard uses.
            Button(t("Close")) {
                if confirmDiscardUnsavedImport() { session.finish() }
            }
            .disabled(session.isBusy)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func copy(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Unsaved-import close guard

/// Confirm discarding an import whose finished content exists only in the session's memory
/// (`.saveFailed` / mid Notes write). Returns true when the user chose to close anyway. Shared
/// by the rescue screen's Close button, the window-close guard below, and `AppDelegate`'s
/// `applicationShouldTerminate` (⌘Q / menu Quit — see `BetterVoice2App.swift`). Not `private` so
/// that quit path can reuse the exact same copy instead of a second, driftable alert.
@MainActor
func confirmDiscardUnsavedImport() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = t("Meeting not saved to Notes")
    alert.informativeText = t("Your imported meeting hasn't been saved to Notes yet. Close anyway?")
    alert.addButton(withTitle: t("Close Anyway"))
    alert.addButton(withTitle: t("Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
}

/// Intercepts the hosting window's close (red button / ⌘W) while the wizard holds finished but
/// unsaved work — the main window's SwiftUI state (and with it this session) dies on close, so
/// closing in `.saveFailed` or mid Notes-write would silently discard an hour of processing.
/// Installs itself as the window's `NSWindowDelegate`, forwarding everything except
/// `windowShouldClose` to whatever delegate SwiftUI had installed; the original delegate is
/// restored when the wizard leaves the window (view removal → `viewDidMoveToWindow(nil)`).
struct WizardCloseGuard: NSViewRepresentable {
    let shouldConfirm: @MainActor () -> Bool

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.delegateProxy.shouldConfirm = shouldConfirm
        return view
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.delegateProxy.shouldConfirm = shouldConfirm
    }

    final class GuardView: NSView {
        let delegateProxy = CloseGuardDelegate()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            delegateProxy.attach(to: window)
        }

        // Purely a window-delegate hook — must never intercept clicks meant for the UI.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class CloseGuardDelegate: NSObject, NSWindowDelegate {
        var shouldConfirm: @MainActor () -> Bool = { false }
        // nonisolated(unsafe): read from the nonisolated NSObject forwarding overrides below.
        // All real access happens on the main thread (NSWindow delegate machinery + attach from
        // viewDidMoveToWindow), the annotation just reflects that NSObject's responds(to:)/
        // forwardingTarget(for:) can't be actor-isolated.
        private nonisolated(unsafe) weak var original: NSWindowDelegate?
        private weak var attachedWindow: NSWindow?

        /// Moves the guard between windows: restores the previous window's original delegate,
        /// then chains in front of the new window's.
        func attach(to window: NSWindow?) {
            if let attachedWindow, attachedWindow !== window, attachedWindow.delegate === self {
                attachedWindow.delegate = original
                original = nil
            }
            attachedWindow = window
            guard let window, window.delegate !== self else { return }
            original = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldConfirm(), !confirmDiscardUnsavedImport() {
                return false
            }
            if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
                return original.windowShouldClose?(sender) ?? true
            }
            return true
        }

        // Everything except windowShouldClose passes straight through to SwiftUI's delegate.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
