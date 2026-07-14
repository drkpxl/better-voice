import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BetterVoiceCore

/// Settings, shown by the `Settings` scene.
///
/// Exposes independent Dictation Polish / Meeting Summarization provider configs, meeting
/// defaults, the dictation hotkey, and the data editors. Saves by reading-modifying-writing
/// each config section, avoiding overwriting keys not managed by this window.
///
/// A fresh view model is built on every window appearance, so reopening always reflects the
/// on-disk (UserDefaults) config. Save/Cancel dismiss the window.
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
        .frame(width: 520, height: 640)
        .onAppear {
            // Accessory apps don't come forward just by opening a window, so the Settings scene
            // (opened via SettingsLink, which has no window id to route through WindowRouter)
            // activates itself here. onDisappear tears the content down, so this re-fires each
            // time Settings is reopened.
            NSApp.activate(ignoringOtherApps: true)
            let vm = SettingsViewModel()
            vm.onSave = { [weak vm] in
                vm?.persist()
                Logger.log("Settings", "User saved settings")
                dismiss()
            }
            vm.onCancel = { dismiss() }
            viewModel = vm
        }
        .onDisappear { viewModel = nil }
    }
}

// MARK: - ViewModel

// Commit-semantics rule: windows WITH a Save button — Settings (here) — batch edits in the form
// fields and persist only when the user clicks Save (persist() below); windows WITHOUT one —
// Welcome — persist each field immediately.
@Observable
@MainActor
final class SettingsViewModel {
    // Dictation Polish provider
    var polishProvider: String
    var polishEndpoint: String
    var polishApiKey: String
    var polishModel: String
    var polishAvailableModels: [String] = []

    // Summarization provider
    var summarizationProvider: String
    var summarizationEndpoint: String
    var summarizationApiKey: String
    var summarizationModel: String
    var summarizationAvailableModels: [String] = []

    // Summarization (non-provider)
    var summarizationEnabled: Bool
    var numCtx: Int

    // Meeting
    var defaultType: MeetingType
    // Label for the local ("me") speaker in transcripts/summaries; blank = "You".
    var userName: String
    // Language ("" = follow system)
    var language: String

    // Read-only state — combined across both sections (see ModelServer.checkHealth())
    var serverStatus: ModelServer.Status = ModelServer.shared.status
    var isCheckingConnection = false

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

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
        let polish = cfg.polishServerConfig
        let summ = cfg.summarizationServerConfig
        let meeting = cfg.meetingConfig
        let summCfg = cfg.meetingSummarizationConfig

        polishProvider = polish.api
        polishEndpoint = polish.endpoint
        polishApiKey = polish.apiKey
        polishModel = polish.model

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

    /// Reads-modifies-writes each config section, preserving unmanaged keys.
    func persist() {
        let cfg = RuntimeConfig.shared

        var polish = cfg.polishConfig
        polish["server"] = [
            "api": polishProvider,
            "endpoint": polishEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": polishModel.trimmingCharacters(in: .whitespacesAndNewlines),
            "api_key": polishApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        cfg.updateSection("polish", polish)

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

    /// Combined health check (both sections) — refreshes the one shared status indicator.
    func checkConnection() {
        isCheckingConnection = true
        Task {
            await ModelServer.shared.checkHealth()
            self.serverStatus = ModelServer.shared.status
            self.isCheckingConnection = false
        }
    }

    /// Fetches Polish's own provider's model list, using the form's (possibly unsaved)
    /// endpoint/provider/key so the list matches what the user just typed.
    func loadPolishModels() async {
        let requestedProvider = polishProvider
        let server = ServerConnectionConfig(api: polishProvider, endpoint: polishEndpoint, model: polishModel, apiKey: polishApiKey)
        let models = await ModelServer.shared.availableModels(server: server)
        guard polishProvider == requestedProvider else { return }   // provider changed mid-fetch; discard stale result
        polishAvailableModels = models
        Logger.log("Settings", "loadPolishModels: \(models.count) models from \(polishEndpoint) (api=\(polishProvider))")
    }

    /// Fetches Summarization's own provider's model list — independent of Polish's.
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

    @ViewBuilder
    private func providerPicker(_ selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            Text(t("Apple on-device")).tag("apple")
            Text("Ollama").tag("ollama")
            Text(t("OpenAI-compatible")).tag("openai")
        } label: {
            Text(t("Provider"))
        }
    }

    /// Ollama's well-known local default; no such universal default exists for arbitrary
    /// OpenAI-compatible servers, so those are left blank for the user to fill in.
    private func defaultEndpoint(for provider: String) -> String {
        provider == "ollama" ? "http://localhost:11434" : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(t("Connection")) {
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
                    Text(t("Reflects whichever of Dictation Polish / Summarization below are enabled — red if either is unreachable."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(t("Dictation Polish")) {
                    providerPicker($viewModel.polishProvider)
                        .onChange(of: viewModel.polishProvider) { _, newValue in
                            viewModel.polishAvailableModels = []
                            if newValue == "apple" {
                                viewModel.polishModel = FoundationModelsBackend.modelName
                                viewModel.polishEndpoint = ""
                                viewModel.polishApiKey = ""
                            } else {
                                // Leaving Apple (or switching between Ollama/OpenAI-compatible):
                                // the old model name belongs to a different provider, so it's
                                // never valid here — clear it rather than leave a stale value.
                                viewModel.polishModel = ""
                                if viewModel.polishEndpoint.isEmpty {
                                    viewModel.polishEndpoint = defaultEndpoint(for: newValue)
                                }
                            }
                        }
                    if viewModel.polishProvider == "apple" {
                        Text(t("Uses Apple Intelligence on this Mac — nothing to install. Requires Apple Intelligence to be enabled in System Settings."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField(t("Endpoint"), text: $viewModel.polishEndpoint)
                        if viewModel.polishProvider == "openai" {
                            SecureField(t("API key (optional)"), text: $viewModel.polishApiKey)
                        }
                        modelField(label: t("Model"), selection: $viewModel.polishModel, available: viewModel.polishAvailableModels, idPrefix: "polish")
                        Button(t("Load Models")) { Task { await viewModel.loadPolishModels() } }
                    }
                    Text(t("Cleans up what you dictate before it's inserted. A small model here makes dictation inject faster."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(t("Summarization")) {
                    Toggle(t("Summarize meetings"), isOn: $viewModel.summarizationEnabled)
                    providerPicker($viewModel.summarizationProvider)
                        .onChange(of: viewModel.summarizationProvider) { _, newValue in
                            viewModel.summarizationAvailableModels = []
                            if newValue == "apple" {
                                viewModel.summarizationModel = FoundationModelsBackend.modelName
                                viewModel.summarizationEndpoint = ""
                                viewModel.summarizationApiKey = ""
                            } else {
                                viewModel.summarizationModel = ""
                                if viewModel.summarizationEndpoint.isEmpty {
                                    viewModel.summarizationEndpoint = defaultEndpoint(for: newValue)
                                }
                            }
                        }
                    if viewModel.summarizationProvider == "apple" {
                        Text(t("Uses Apple Intelligence on this Mac — nothing to install. Requires Apple Intelligence to be enabled in System Settings."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField(t("Endpoint"), text: $viewModel.summarizationEndpoint)
                        if viewModel.summarizationProvider == "openai" {
                            SecureField(t("API key (optional)"), text: $viewModel.summarizationApiKey)
                        }
                        modelField(label: t("Model"), selection: $viewModel.summarizationModel, available: viewModel.summarizationAvailableModels, idPrefix: "summ")
                        Button(t("Load Models")) { Task { await viewModel.loadSummarizationModels() } }
                    }
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
                }

                Section(t("Meetings")) {
                    TextField(t("Your name"), text: $viewModel.userName)
                    Text(t("Appears as the speaker label for your own voice in transcripts and summaries. Leave blank to use \"You\"."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(selection: $viewModel.defaultType) {
                        ForEach(MeetingType.allCases) { type in
                            Text(type.defaultDisplayName).tag(type)
                        }
                    } label: {
                        Text(t("Default meeting type"))
                    }
                }

                Section(t("Language")) {
                    Picker(selection: $viewModel.language) {
                        Text(t("Follow system")).tag("")
                        Text("English").tag("en")
                    } label: {
                        Text(t("Language"))
                    }
                }

                Section(t("Hotkey")) {
                    HStack {
                        Text(t("Dictation hotkey"))
                        Spacer()
                        Text(viewModel.hotkeyDisplayName)
                            .foregroundStyle(.secondary)
                        Button(t("Change...")) { WindowRouter.shared.open(id: WindowID.hotkey) }
                    }
                    HStack {
                        Text(t("Meeting hotkey"))
                        Spacer()
                        Text(viewModel.meetingHotkeyDisplayName)
                            .foregroundStyle(.secondary)
                        Button(t("Change...")) { WindowRouter.shared.open(id: WindowID.hotkey) }
                    }
                }

                Section(t("Apple Notes")) {
                    HStack {
                        Text(t("System audio recording"))
                        Spacer()
                        Button(t("Open Settings…")) { PermissionManager.openSettings(for: .systemAudio) }
                    }
                    Text(t("macOS asks for this permission automatically the first time you start a meeting recording — there's no live status to show here. If a recording comes out silent, allow it in Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(t("Automation access"))
                        Spacer()
                        Text(viewModel.notesAutomationGranted ? t("Granted") : t("Not granted"))
                            .foregroundStyle(viewModel.notesAutomationGranted ? .green : .orange)
                        if !viewModel.notesAutomationGranted {
                            Button(t("Open Settings…")) { PermissionManager.openSettings(for: .automation) }
                        }
                    }
                    HStack {
                        Text(t("Destination"))
                        Spacer()
                        Text(notesDestinationSummary())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        Button(t("Choose...")) { showNotesPicker = true }
                    }
                }

                Section(t("Data")) {
                    Button(t("Edit Personal Context...")) { WindowRouter.shared.open(id: WindowID.personalContext) }
                    Button(t("Edit Vocabulary...")) { WindowRouter.shared.open(id: WindowID.vocabulary) }
                    Button(t("Import Vocabulary CSV...")) { viewModel.importVocabularyCSV() }
                    Button(t("Open Data Folder...")) { viewModel.openDataFolder() }
                    Button(t("View Logs...")) { viewModel.viewLogs() }
                }
            }
            .formStyle(.grouped)
            .task {
                async let polish: Void = viewModel.loadPolishModels()
                async let summarization: Void = viewModel.loadSummarizationModels()
                _ = await (polish, summarization)
            }

            Divider()

            HStack {
                Spacer()
                Button(t("Cancel")) { viewModel.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button(t("Save")) { viewModel.onSave?() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .tint(Color.brandAccent)
        // The picker's account scan (osascript) is what fires the Automation consent prompt, so
        // the grant can land while the sheet is up with no app re-activation to refresh the store
        // — re-query on dismissal so the "Automation" row above is current.
        .sheet(isPresented: $showNotesPicker, onDismiss: { PermissionStore.shared.refresh() }) {
            NotesDestinationPickerView()
        }
    }
}
