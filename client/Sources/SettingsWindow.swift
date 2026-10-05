import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BetterVoiceCore

/// Settings, shown by the `Settings` scene.
///
/// Exposes the Meeting Summarization provider config, meeting defaults, the dictation hotkey, and
/// the data editors. Saves by reading-modifying-writing each config section, avoiding overwriting
/// keys not managed by this window.
///
/// A fresh view model is built on every window appearance, so reopening always reflects the
/// on-disk (UserDefaults) config. Like every macOS Settings window, changes apply as they're made
/// (text fields after a short pause, everything on close) — there is no Save button.
///
/// v2 trim vs. v1: the meeting-audio controls (audio source, auto-delete, per-meeting save
/// folder) are gone — those config keys are retired. The old "Edit Config File…" is gone too:
/// preferences live in `UserDefaults` now, not an editable JSON file. The support directory
/// (see `SupportDir`) is fixed and hidden, so there's no folder picker here either.
struct SettingsRootView: View {
    @State private var viewModel: SettingsViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let viewModel {
                SettingsContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .frame(width: 560, height: 580)
        .onAppear {
            // Accessory apps don't come forward just by opening a window, so the Settings scene
            // (opened via SettingsLink, which has no window id to route through WindowRouter)
            // activates itself here. onDisappear tears the content down, so this re-fires each
            // time Settings is reopened.
            NSApp.activate(ignoringOtherApps: true)
            viewModel = SettingsViewModel()
        }
        .onDisappear {
            viewModel?.flush()
            viewModel = nil
        }
    }
}

// MARK: - ViewModel

// Edits persist on their own: every editable property schedules a debounced `persist()`, and
// closing the window flushes it.
@Observable
@MainActor
final class SettingsViewModel {
    // Summarization provider
    var summarizationProvider: String { didSet { scheduleSave() } }
    var summarizationEndpoint: String { didSet { scheduleSave() } }
    var summarizationApiKey: String { didSet { scheduleSave() } }
    var summarizationModel: String { didSet { scheduleSave() } }
    var summarizationAvailableModels: [String] = []

    // Summarization (non-provider)
    var summarizationEnabled: Bool { didSet { scheduleSave() } }
    var numCtx: Int { didSet { scheduleSave() } }

    // Meeting
    var defaultType: MeetingType { didSet { scheduleSave() } }
    // Label for the local ("me") speaker in transcripts/summaries; blank = "You".
    var userName: String { didSet { scheduleSave() } }
    // Language ("" = follow system)
    var language: String { didSet { scheduleSave() } }

    // Read-only state (see ModelServer.checkHealth())
    var serverStatus: ModelServer.Status = ModelServer.shared.status
    var isCheckingConnection = false

    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    var hotkeyDisplayName: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig).displayName
    }

    var meetingHotkeyDisplayName: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.meetingHotKeyConfig, fallback: .meetingDefault).displayName
    }

    /// Reads the shared `PermissionStore` (same source as the menu bar and onboarding) so the row
    /// re-renders when the permission changes — an imperative `PermissionKind.isGranted` read here
    /// is untracked by SwiftUI, the exact frozen-status bug the store exists to fix. Refreshed by
    /// app activation (returning from System Settings) and the Notes picker sheet's dismissal.
    var notesAutomationGranted: Bool {
        PermissionStore.shared.automation
    }

    var serverStatusText: String {
        switch serverStatus {
        case .connected: return t("Connected")
        case .disconnected: return t("Disconnected")
        case .unknown: return t("Unknown")
        }
    }

    init() {
        let cfg = RuntimeConfig.shared
        let summ = cfg.summarizationServerConfig
        let meeting = cfg.meetingConfig
        let summCfg = cfg.meetingSummarizationConfig

        summarizationProvider = summ.api
        summarizationEndpoint = summ.endpoint
        summarizationApiKey = summ.apiKey
        summarizationModel = summ.model

        summarizationEnabled = summCfg["enabled"] as? Bool ?? true
        numCtx = summCfg["num_ctx"] as? Int ?? 32768

        defaultType = MeetingType.from(configKey: meeting["default_type"] as? String ?? "general") ?? .general
        userName = cfg.userName ?? ""

        language = cfg.language ?? ""
    }

    /// Persist shortly after the last edit, so typing in a field doesn't write on every keystroke.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Persist now (window closing).
    func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        persist()
    }

    /// Reads-modifies-writes each config section, preserving unmanaged keys.
    func persist() {
        pendingSave = nil
        let cfg = RuntimeConfig.shared

        var meeting = cfg.meetingConfig
        meeting["default_type"] = defaultType.configKey
        var summ = meeting["summarization"] as? [String: Any] ?? [:]
        summ["enabled"] = summarizationEnabled
        summ["num_ctx"] = max(1024, numCtx)
        summ["server"] = [
            "api": summarizationProvider,
            "endpoint": summarizationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": summarizationModel.trimmingCharacters(in: .whitespacesAndNewlines),
            "api_key": summarizationApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        meeting["summarization"] = summ
        cfg.updateSection("meeting", meeting)

        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.updateTopLevel("language", lang.isEmpty ? nil : lang)

        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.updateTopLevel("user_name", name.isEmpty ? nil : name)
    }

    /// Refreshes the status indicator against the summarization provider.
    func checkConnection() {
        isCheckingConnection = true
        Task {
            await ModelServer.shared.checkHealth()
            self.serverStatus = ModelServer.shared.status
            self.isCheckingConnection = false
        }
    }

    /// Fetches the summarization provider's model list, using the form's (possibly unsaved)
    /// endpoint/provider/key so the list matches what the user just typed.
    func loadSummarizationModels() async {
        let requestedProvider = summarizationProvider
        let server = ServerConnectionConfig(api: summarizationProvider, endpoint: summarizationEndpoint, model: summarizationModel, apiKey: summarizationApiKey)
        let models = await ModelServer.shared.availableModels(server: server)
        guard summarizationProvider == requestedProvider else { return }   // provider changed mid-fetch; discard stale result
        summarizationAvailableModels = models
        Logger.log("Settings", "loadSummarizationModels: \(models.count) models from \(summarizationEndpoint) (api=\(summarizationProvider))")
    }

    func openDataFolder() {
        NSWorkspace.shared.open(SupportDir.url)
    }

    /// Imports "from,to" CSV rows into the vocabulary's replacements.
    func importVocabularyCSV() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = Vocabulary.shared.importCSV(from: url)
        if count > 0 {
            Notify.warn(t("Vocabulary import"), t("Imported \(count) replacements from \(url.lastPathComponent)."))
        } else {
            Notify.warn(t("Vocabulary import"), t("No \"from,to\" rows found in \(url.lastPathComponent)."))
        }
    }

    func viewLogs() {
        let url = Logger.logDirectory.appendingPathComponent("debug.log")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: Logger.logDirectory.path) {
            NSWorkspace.shared.open(Logger.logDirectory)
        }
    }
}

// MARK: - SwiftUI View

struct SettingsContentView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showNotesPicker = false
    /// Model picked per provider this session, so a provider misclick (Ollama → Apple → Ollama)
    /// doesn't lose the model — Settings saves as you go, with no Cancel.
    @State private var modelByProvider: [String: String] = [:]

    /// Options for a model dropdown: the server-reported models, guaranteeing `current` is present so a
    /// configured-but-unlisted model (not pulled yet, remote, or list unavailable) isn't silently lost.
    private func modelOptions(current: String, available: [String]) -> [String] {
        var opts = available
        let c = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty, !opts.contains(c) { opts.insert(c, at: 0) }
        return opts
    }

    /// One section's model field. When the provider has reported models, this is a dropdown of
    /// them (plus `current`); when discovery has returned nothing — provider unreachable, or
    /// simply hasn't answered yet — it falls back to a free-text field instead so an empty Picker
    /// is never a dead end.
    @ViewBuilder
    private func modelField(label: String, selection: Binding<String>, available: [String], idPrefix: String) -> some View {
        if available.isEmpty {
            TextField(label, text: selection)
        } else {
            Picker(selection: selection) {
                ForEach(modelOptions(current: selection.wrappedValue, available: available), id: \.self) { m in
                    Text(m).tag(m)
                }
            } label: {
                Text(label)
            }
            // The rebuild-key hack: NSPopUpButton doesn't reliably refresh its menu when the
            // underlying options change out from under it — forcing a new `.id()` when the
            // available list loads makes AppKit rebuild the menu instead of showing stale entries.
            .id("\(idPrefix):\(available.joined(separator: "|"))")
        }
    }

    var body: some View {
        TabView {
            Tab(t("General"), systemImage: "gearshape") { generalTab }
            Tab(t("Dictation"), systemImage: "mic") { dictationTab }
            Tab(t("Meetings"), systemImage: "person.2") { meetingsTab }
            Tab(t("Summaries"), systemImage: "text.badge.star") { summariesTab }
        }
        .tint(Color.brandAccent)
        .task { await viewModel.loadSummarizationModels() }
        // The picker's account scan (osascript) is what fires the Automation consent prompt, so
        // the grant can land while the sheet is up with no app re-activation to refresh the store
        // — re-query on dismissal so the "Automation" row is current.
        .sheet(isPresented: $showNotesPicker, onDismiss: { PermissionStore.shared.refresh() }) {
            NotesDestinationPickerView()
        }
    }

    // MARK: Tabs

    private var generalTab: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
            }
            Section {
                TextField(t("Your name"), text: $viewModel.userName)
                Text(t("Appears as the speaker label for your own voice in transcripts and summaries. Leave blank to use \"You\"."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(t("Data")) {
                Button(t("Open Data Folder...")) { viewModel.openDataFolder() }
                Button(t("View Logs...")) { viewModel.viewLogs() }
            }
        }
        .formStyle(.grouped)
    }

    private var dictationTab: some View {
        Form {
            Section {
                hotkeyRow(t("Dictation hotkey"), viewModel.hotkeyDisplayName)
                Text(t("Tap to start and tap again to stop, or hold while you talk. Esc cancels."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ImmediateToggle(t("Show live transcript while dictating"), key: "live_preview", default: true)
                ImmediateToggle(t("Remove filler words (um, uh)"), key: "strip_fillers", default: true)
            }
            Section(t("Language")) {
                SpeechLanguagePicker()
            }
            Section(t("Vocabulary")) {
                Button(t("Edit Vocabulary...")) { WindowRouter.shared.open(id: WindowID.vocabulary) }
                Button(t("Import Vocabulary CSV...")) { viewModel.importVocabularyCSV() }
                ImmediateToggle(t("Boost vocabulary recognition"), key: "vocab_boost", default: true)
                Text(t("Listens for your vocabulary terms in the audio itself, so names and jargon are caught even when misheard. Uses a one-time ~100 MB download and adds a fraction of a second to each dictation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var meetingsTab: some View {
        Form {
            Section {
                hotkeyRow(t("Meeting hotkey"), viewModel.meetingHotkeyDisplayName)
                Picker(selection: $viewModel.defaultType) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.defaultDisplayName).tag(type)
                    }
                } label: {
                    Text(t("Default meeting type"))
                }
                Button(t("Edit Personal Context...")) { WindowRouter.shared.open(id: WindowID.personalContext) }
            }
            Section(t("Apple Notes")) {
                HStack {
                    Text(t("Destination"))
                    Spacer()
                    Text(notesDestinationSummary())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Button(t("Choose...")) { showNotesPicker = true }
                }
                HStack {
                    Text(t("Automation access"))
                    Spacer()
                    Text(viewModel.notesAutomationGranted ? t("Granted") : t("Not granted"))
                        .foregroundStyle(viewModel.notesAutomationGranted ? .green : .orange)
                    if !viewModel.notesAutomationGranted {
                        Button(t("Open Settings…")) { PermissionManager.openSettings(for: .automation) }
                    }
                }
            }
            Section(t("Live recording")) {
                HStack {
                    Text(t("System audio recording"))
                    Spacer()
                    Button(t("Open Settings…")) { PermissionManager.openSettings(for: .systemAudio) }
                }
                Text(t("macOS asks for this permission automatically the first time you start a meeting recording — there's no live status to show here. If a recording comes out silent, allow it in Settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var summariesTab: some View {
        Form {
            Section {
                Toggle(t("Summarize meetings"), isOn: $viewModel.summarizationEnabled)
                LLMProviderPicker(selection: $viewModel.summarizationProvider)
                    .onChange(of: viewModel.summarizationProvider) { oldValue, newValue in
                        viewModel.summarizationAvailableModels = []
                        modelByProvider[oldValue] = viewModel.summarizationModel
                        if newValue == "apple" {
                            viewModel.summarizationModel = FoundationModelsBackend.modelName
                            // Endpoint and API key are kept (Apple ignores both): Settings saves as
                            // you go, so clearing them here would lose them on a misclick.
                        } else {
                            // A model name from another provider is never valid here; restore the
                            // one picked for this provider earlier, if any.
                            viewModel.summarizationModel = modelByProvider[newValue] ?? ""
                            if viewModel.summarizationEndpoint.isEmpty {
                                viewModel.summarizationEndpoint = LLMProvider.defaultEndpoint(forTag: newValue)
                            }
                        }
                    }
                if viewModel.summarizationProvider == "apple" {
                    if let reason = FoundationModelsBackend.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(t("Uses Apple Intelligence on this Mac — nothing to install."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField(t("Endpoint"), text: $viewModel.summarizationEndpoint)
                    if viewModel.summarizationProvider == "openai" {
                        SecureField(t("API key (optional)"), text: $viewModel.summarizationApiKey)
                    }
                    modelField(label: t("Model"), selection: $viewModel.summarizationModel, available: viewModel.summarizationAvailableModels, idPrefix: "summ")
                    Button(t("Load Models")) { Task { await viewModel.loadSummarizationModels() } }
                }
                HStack {
                    Text(t("Status"))
                    Spacer()
                    Text(viewModel.serverStatusText)
                        .foregroundStyle(
                            viewModel.serverStatus == .connected ? .green :
                            viewModel.serverStatus == .disconnected ? .red : .secondary
                        )
                    Button(t("Check")) { viewModel.checkConnection() }
                        .disabled(viewModel.isCheckingConnection)
                }
            }
            Section {
                HStack {
                    Text(t("Context window (num_ctx)"))
                    Spacer()
                    TextField("", value: $viewModel.numCtx, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
                // Warn at input time rather than silently rewriting what's typed — persist()
                // still clamps below 1024 (max(1024, …)).
                if viewModel.numCtx < 1024 {
                    Text(t("Minimum is 1024 — smaller values are raised when saved."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(t("Long meetings need a large-context model. A tiny default model may truncate."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(selection: $viewModel.language) {
                    Text(t("Follow system")).tag("")
                    Text("English").tag("en")
                } label: {
                    Text(t("Summary language"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func hotkeyRow(_ title: String, _ display: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(display)
                .foregroundStyle(.secondary)
            Button(t("Change...")) { WindowRouter.shared.open(id: WindowID.hotkey) }
        }
    }
}
