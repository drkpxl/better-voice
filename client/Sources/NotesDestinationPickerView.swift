import AppKit
import SwiftUI
import BetterVoiceCore

/// Sheet-based Apple Notes destination picker: account, then pick-or-create the Transcripts and
/// Summaries folders. Shared by `WelcomeWindow`'s onboarding section and `SettingsWindow`'s
/// "Apple Notes" section — both present it via `.sheet(isPresented:)`.
///
/// Every `NotesScript` call (`listAccounts`/`listFolders`/`createFolder`) runs off-main through
/// `NotesQueue` (defined in `NotesMeetingWriter.swift`, reused here rather than duplicated). The
/// very first such call is what naturally triggers the macOS Automation consent prompt if it
/// hasn't fired yet — see `NotesScript`'s doc comment; this view just has to handle the denied
/// outcome gracefully.
struct NotesDestinationPickerView: View {
    @State private var viewModel = NotesDestinationPickerViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful save, before the sheet dismisses, so the presenting view (which
    /// reads `RuntimeConfig.shared.notesConfig` directly rather than caching it) knows to
    /// re-render with the new destination.
    var onSaved: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 440, height: 420)
        .tint(Color.brandAccent)
        .onAppear { viewModel.start() }
    }

    private var header: some View {
        Text(t("Apple Notes Destination"))
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loadingAccounts:
            loadingView(t("Looking for your Apple Notes accounts…"))
        case .loadingFolders:
            loadingView(t("Loading folders…"))
        case .error(let message, let automationDenied):
            errorView(message: message, automationDenied: automationDenied)
        case .ready:
            formView
        }
    }

    private func loadingView(_ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String, automationDenied: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if automationDenied {
                Button(t("Open Automation Settings")) { viewModel.openAutomationSettings() }
            }
            Button(t("Try Again")) { viewModel.start() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formView: some View {
        Form {
            Section(t("Account")) {
                if viewModel.accounts.count == 1, let only = viewModel.accounts.first {
                    Text(only)
                } else {
                    Picker(t("Account"), selection: $viewModel.selectedAccount) {
                        Text(t("Choose an account")).tag("")
                        ForEach(viewModel.accounts, id: \.self) { account in
                            Text(account).tag(account)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: viewModel.selectedAccount) { _, _ in
                        Task { await viewModel.loadFolders() }
                    }
                }
            }

            if !viewModel.selectedAccount.isEmpty {
                folderSection(
                    title: t("Transcripts folder"),
                    choice: $viewModel.transcriptsChoice,
                    newName: $viewModel.transcriptsNewName
                )
                folderSection(
                    title: t("Summaries folder"),
                    choice: $viewModel.summariesChoice,
                    newName: $viewModel.summariesNewName
                )
            }

            if let saveError = viewModel.saveError {
                Section {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        // Same data-integrity class as the loaders' generation guard: switching the account (or
        // editing folder choices) while save() is mid-createFolder could persist the new
        // account's name with the old account's folder ids. Freeze the form for the save.
        .disabled(viewModel.isSaving)
    }

    @ViewBuilder
    private func folderSection(title: String, choice: Binding<String>, newName: Binding<String>) -> some View {
        Section(title) {
            Picker(title, selection: choice) {
                ForEach(viewModel.folders) { folder in
                    Text(folder.name).tag(folder.id)
                }
                Text(t("Create new folder…")).tag(NotesDestinationPickerViewModel.newFolderTag)
            }
            .labelsHidden()
            if choice.wrappedValue == NotesDestinationPickerViewModel.newFolderTag {
                TextField(t("Folder name"), text: newName)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isSaving)
            if viewModel.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button(t("Save")) {
                Task {
                    await viewModel.save()
                    if viewModel.saveError == nil {
                        onSaved()
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canSave)
        }
        .padding(16)
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class NotesDestinationPickerViewModel {
    enum LoadPhase: Equatable {
        case loadingAccounts
        case loadingFolders
        case ready
        case error(message: String, automationDenied: Bool)
    }

    struct NotesFolder: Identifiable, Equatable, Hashable {
        let id: String
        let name: String
    }

    /// Picker tag for "create a new folder" — distinct from any real Notes folder id.
    static let newFolderTag = "__bv_new_folder__"

    /// Weak pointer to whichever picker view model is currently live (there is only ever one —
    /// the picker is a sheet, and Welcome/Settings never present it simultaneously). Same
    /// self-clearing pattern as `ImportSession.activeSession`: `AppDelegate.
    /// applicationShouldTerminate` (BetterVoice2App.swift) checks `activePicker?.isSaving` so ⌘Q
    /// can't kill the app mid-`save()` — after `createFolder` was sent but before the config
    /// write landed, quitting would orphan a just-created folder in Notes with no config
    /// pointing at it.
    static weak var activePicker: NotesDestinationPickerViewModel?

    init() {
        NotesDestinationPickerViewModel.activePicker = self
    }

    private(set) var phase: LoadPhase = .loadingAccounts
    private(set) var accounts: [String] = []
    private(set) var folders: [NotesFolder] = []

    /// Monotonic token guarding the two loaders against stale completions: switching accounts
    /// (or double-tapping Try Again) while a load is still blocked on osascript must not let the
    /// old call's result land under the new selection — worst case that would show account A's
    /// folders under an account-B selection and let the user save a cross-account folder id.
    /// Each load bumps this and captures the new value; every post-await state write checks the
    /// captured value is still current and bails otherwise.
    private var loadGeneration = 0

    var selectedAccount: String = ""

    var transcriptsChoice: String = NotesDestinationPickerViewModel.newFolderTag
    var transcriptsNewName: String = t("Transcripts")
    var summariesChoice: String = NotesDestinationPickerViewModel.newFolderTag
    var summariesNewName: String = t("Summaries")

    private(set) var isSaving = false
    var saveError: String?

    var canSave: Bool {
        guard phase == .ready, !selectedAccount.isEmpty, !isSaving else { return false }
        return isValidChoice(transcriptsChoice, newName: transcriptsNewName)
            && isValidChoice(summariesChoice, newName: summariesNewName)
    }

    private func isValidChoice(_ choice: String, newName: String) -> Bool {
        guard choice == Self.newFolderTag else { return true }
        return !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kicks off (or restarts, after an error) the account load. Idempotent to call from
    /// `.onAppear` and from the error screen's "Try Again".
    func start() {
        Task { await loadAccounts() }
    }

    private func loadAccounts() async {
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loadingAccounts
        saveError = nil
        do {
            let result = try await NotesQueue.run { try NotesScript.listAccounts() }
            guard gen == loadGeneration else { return }
            accounts = result

            // No accounts at all (Notes never signed in / all accounts removed): a bare `.ready`
            // form would be an unusable dead end. The error state's message + Try Again is the
            // right shape for "fix it in Notes, then come back".
            guard !accounts.isEmpty else {
                phase = .error(
                    message: t("No Apple Notes accounts found — add an account in the Notes app, then try again."),
                    automationDenied: false
                )
                return
            }

            let configuredAccount = RuntimeConfig.shared.notesConfig["account"] as? String
            if accounts.count == 1 {
                selectedAccount = accounts[0]
            } else if let configuredAccount, accounts.contains(configuredAccount) {
                selectedAccount = configuredAccount
            }

            if selectedAccount.isEmpty {
                phase = .ready
            } else {
                await loadFolders()
            }
        } catch {
            guard gen == loadGeneration else { return }
            phase = errorPhase(for: error)
        }
    }

    /// Re-fetches folders for `selectedAccount` — called after the initial account resolution and
    /// again whenever the user picks a different account. Resets both folder choices first: a
    /// folder id from a previous account is never valid for a different one.
    func loadFolders() async {
        guard !selectedAccount.isEmpty else {
            // Bump the generation here too: deselecting back to "Choose an account" must also
            // invalidate any in-flight load, or its stale result would land on the empty state.
            loadGeneration += 1
            folders = []
            return
        }
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loadingFolders
        transcriptsChoice = Self.newFolderTag
        summariesChoice = Self.newFolderTag
        let account = selectedAccount
        do {
            let result = try await NotesQueue.run { try NotesScript.listFolders(account: account) }
            guard gen == loadGeneration else { return }
            folders = result.map { NotesFolder(id: $0.id, name: $0.name) }
            seedFolderChoicesIfMatchingConfig()
            phase = .ready
        } catch {
            guard gen == loadGeneration else { return }
            phase = errorPhase(for: error)
        }
    }

    /// If the account currently being shown is the one already configured, preselect its saved
    /// Transcripts/Summaries folders (when they still resolve) instead of defaulting to "create
    /// new" — reopening the picker on an already-configured destination should show what's there.
    private func seedFolderChoicesIfMatchingConfig() {
        let cfg = RuntimeConfig.shared.notesConfig
        guard cfg["account"] as? String == selectedAccount else { return }
        if let id = cfg["transcriptsFolderId"] as? String, folders.contains(where: { $0.id == id }) {
            transcriptsChoice = id
        }
        if let id = cfg["summariesFolderId"] as? String, folders.contains(where: { $0.id == id }) {
            summariesChoice = id
        }
    }

    func openAutomationSettings() {
        PermissionManager.openSettings(for: .automation)
    }

    /// Resolves both folder choices (creating any picked as "new"), then persists all five
    /// `RuntimeConfig` notes keys in one write. Leaves `phase` at `.ready` on failure — the form
    /// stays visible with `saveError` set, rather than dropping to the full-screen error state,
    /// so the user doesn't lose their in-progress picks.
    ///
    /// Idempotent across retries: each successfully resolved folder is immediately adopted into
    /// `folders` and its picker choice flipped from "create new" to the created folder's id (see
    /// `adopt`). Without that, a Transcripts create that succeeds followed by a Summaries create
    /// that fails would leave `transcriptsChoice == newFolderTag` — and the retry would create a
    /// SECOND Transcripts folder in the user's real Notes, once per retry.
    func save() async {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let transcripts = try await resolveFolder(choice: transcriptsChoice, newName: transcriptsNewName)
            adopt(transcripts, into: &transcriptsChoice)
            let summaries = try await resolveFolder(choice: summariesChoice, newName: summariesNewName)
            adopt(summaries, into: &summariesChoice)
            let cfg: [String: Any] = [
                "account": selectedAccount,
                "transcriptsFolderId": transcripts.id,
                "transcriptsFolderName": transcripts.name,
                "summariesFolderId": summaries.id,
                "summariesFolderName": summaries.name,
            ]
            RuntimeConfig.shared.updateSection("notes", cfg)
        } catch {
            saveError = friendlyMessage(for: error)
        }
    }

    /// Marks a resolved folder as the current selection: appended to `folders` if it isn't there
    /// yet (a folder just created by `resolveFolder`) and its id written into the choice binding,
    /// so a subsequent `save()` retry — or just the form re-rendering — treats it as an existing
    /// pick instead of a pending "create new".
    private func adopt(_ folder: NotesFolder, into choice: inout String) {
        if !folders.contains(where: { $0.id == folder.id }) {
            folders.append(folder)
        }
        choice = folder.id
    }

    private func resolveFolder(choice: String, newName: String) async throws -> NotesFolder {
        guard choice == Self.newFolderTag else {
            guard let match = folders.first(where: { $0.id == choice }) else {
                throw NotesScript.NotesScriptError.parseFailure("Selected folder no longer exists")
            }
            return match
        }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse an existing folder with the same name (case-insensitive) instead of creating a
        // duplicate — covers users who already have e.g. a "Transcripts" folder, and the reopen-
        // after-partial-save-failure case where the folder was created but never persisted.
        if let existing = folders.first(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return existing
        }
        let account = selectedAccount
        let created = try await NotesQueue.run { try NotesScript.createFolder(account: account, name: trimmedName) }
        return NotesFolder(id: created.id, name: created.name)
    }

    // MARK: - Error mapping

    private func errorPhase(for error: Error) -> LoadPhase {
        let denied = !PermissionManager.isAutomationGranted()
        let message = denied
            ? t("Better Voice needs permission to control Apple Notes. Grant Automation access in System Settings, then try again.")
            : friendlyMessage(for: error)
        return .error(message: message, automationDenied: denied)
    }

    private func friendlyMessage(for error: Error) -> String {
        // Cause-neutral on purpose: the ~20-25s NotesScript timeout keeps ticking while the
        // macOS Automation consent dialog is on screen, so "answered the prompt slowly" is a
        // perfectly common way to land here — guidance like "make sure Notes is installed"
        // would be wrong for that case.
        if case NotesScript.NotesScriptError.timeout = error {
            return t("Apple Notes didn't respond in time. If a permission prompt is on screen, respond to it, then try again.")
        }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

// MARK: - Quit guard (mid-save)

/// Confirm quitting while the picker's `save()` is still in flight — a `createFolder` may have
/// been sent to Notes but the config write not landed yet, so killing the app here can orphan a
/// just-created folder with no config pointing at it. Returns true when the user chose to quit
/// anyway. Called from `AppDelegate.applicationShouldTerminate` (BetterVoice2App.swift) via
/// `NotesDestinationPickerViewModel.activePicker`; same shape as `confirmDiscardUnsavedImport()`
/// (ImportWizardView.swift).
@MainActor
func confirmQuitDuringNotesSetupSave() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = t("Notes setup is still saving")
    alert.informativeText = t("Your Apple Notes folders are still being set up. Quit anyway?")
    alert.addButton(withTitle: t("Quit Anyway"))
    alert.addButton(withTitle: t("Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
}

// MARK: - Shared status text (Welcome + Settings "Apple Notes" sections)

/// Human-readable summary of the current Apple Notes destination — "Not set up" when
/// `notesConfigured` is false, otherwise the account and both folder names. Shared by
/// `WelcomeWindow`'s and `SettingsWindow`'s "Apple Notes" sections so both read the same copy.
@MainActor
func notesDestinationSummary() -> String {
    guard RuntimeConfig.shared.notesConfigured else { return t("Not set up") }
    let cfg = RuntimeConfig.shared.notesConfig
    let account = cfg["account"] as? String ?? ""
    let transcripts = cfg["transcriptsFolderName"] as? String ?? ""
    let summaries = cfg["summariesFolderName"] as? String ?? ""
    return t("\(account) — Transcripts: \(transcripts), Summaries: \(summaries)")
}
