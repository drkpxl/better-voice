import AppKit
import SwiftUI
import BetterVoiceCore

/// Settings window (Feature 0).
///
/// Embeds SwiftUI via NSWindow + NSHostingView (same approach as HotKeySettingsWindow).
/// Exposes config for new features plus key existing settings; "Edit Config File..." remains available for advanced users.
/// Saves by reading-modifying-writing each config section, avoiding overwriting keys not managed by this window (e.g. meeting.l2_*, server.timeout).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SettingsViewModel()
        viewModel.onSave = { [weak self] in
            viewModel.persist()
            Logger.log("Settings", "User saved settings")
            self?.close()
        }
        viewModel.onCancel = { [weak self] in
            self?.close()
        }

        let host = NSHostingView(rootView: SettingsContentView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 580)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = t("Settings")
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class SettingsViewModel {
    // Server
    var endpoint: String
    var model: String
    var api: String
    // Summarization
    var summarizationEnabled: Bool
    var summarizationModel: String
    var numCtx: Int
    // Meeting
    var saveFolder: String
    var autoDeleteAudio: Bool
    var defaultType: MeetingType
    var audioSource: String
    // Diarization: speaker clustering threshold (0.5…0.9, lower = more speakers)
    var clusteringThreshold: Double
    // Language ("" = follow system)
    var language: String

    // Read-only state
    var serverStatus: ModelServer.Status = ModelServer.shared.status
    var isCheckingConnection = false

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    var hotkeyDisplayName: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig).displayName
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
        let server = cfg.serverConfig
        let meeting = cfg.meetingConfig
        let summ = cfg.meetingSummarizationConfig
        let diar = parseDiarizationSettings(cfg.meetingDiarizationConfig)

        endpoint = server["endpoint"] as? String ?? "http://localhost:11434"
        model = server["model"] as? String ?? "qwen3.5:4b-mlx"
        api = server["api"] as? String ?? "ollama"
        summarizationModel = server["summarization_model"] as? String ?? ""

        summarizationEnabled = summ["enabled"] as? Bool ?? true
        numCtx = summ["num_ctx"] as? Int ?? 32768

        saveFolder = meeting["save_folder"] as? String ?? BetterVoiceDataDir.meetings.path
        autoDeleteAudio = meeting["auto_delete_audio"] as? Bool ?? false
        defaultType = MeetingType.from(configKey: meeting["default_type"] as? String ?? "general") ?? .general
        audioSource = meeting["audio_source"] as? String ?? "both"
        clusteringThreshold = Double(diar.clusteringThreshold)

        language = cfg.language ?? ""
    }

    /// Reads-modifies-writes each config section, preserving unmanaged keys.
    func persist() {
        let cfg = RuntimeConfig.shared

        var server = cfg.serverConfig
        server["endpoint"] = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        server["model"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        server["api"] = api
        server["summarization_model"] = summarizationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.updateSection("server", server)

        var meeting = cfg.meetingConfig
        meeting["save_folder"] = saveFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting["auto_delete_audio"] = autoDeleteAudio
        meeting["default_type"] = defaultType.configKey
        meeting["audio_source"] = audioSource
        var summ = meeting["summarization"] as? [String: Any] ?? [:]
        summ["enabled"] = summarizationEnabled
        summ["num_ctx"] = max(1024, numCtx)
        meeting["summarization"] = summ
        var diar = meeting["diarization"] as? [String: Any] ?? [:]
        // Clamp to the same 0.5…0.9 range the Core parser enforces.
        diar["clustering_threshold"] = min(max(clusteringThreshold, 0.5), 0.9)
        meeting["diarization"] = diar
        cfg.updateSection("meeting", meeting)

        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.updateTopLevel("language", lang.isEmpty ? nil : lang)
    }

    func checkConnection() {
        isCheckingConnection = true
        Task {
            await ModelServer.shared.checkHealth()
            self.serverStatus = ModelServer.shared.status
            self.isCheckingConnection = false
        }
    }

    func changeHotkey() { HotKeySettingsWindow.shared.show() }

    func openDataFolder() { NSWorkspace.shared.open(BetterVoiceDataDir.url) }

    /// Opens the personal context file; creates it from a template first if it doesn't exist, to help users get started.
    func editPersonalContext() { PersonalContext.openOrCreate() }

    func editConfigFile() {
        let url = BetterVoiceDataDir.configURL
        if !FileManager.default.fileExists(atPath: url.path) { _ = RuntimeConfig.shared }
        NSWorkspace.shared.open(url)
    }

    func viewLogs() {
        let url = BetterVoiceDataDir.logURL
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = t("Choose")
        if !saveFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url.path
        }
    }
}

// MARK: - SwiftUI View

struct SettingsContentView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(t("Model server")) {
                    TextField(t("Endpoint"), text: $viewModel.endpoint)
                    TextField(t("Model"), text: $viewModel.model)
                    Picker(selection: $viewModel.api) {
                        Text("Ollama").tag("ollama")
                        Text("OpenAI-compatible").tag("openai")
                    } label: {
                        Text(t("API type"))
                    }
                    HStack {
                        Text(t("Status"))
                        Spacer()
                        Text(viewModel.serverStatusText)
                            .foregroundStyle(viewModel.serverStatus == .connected ? .green : .secondary)
                        Button(t("Check")) { viewModel.checkConnection() }
                            .disabled(viewModel.isCheckingConnection)
                    }
                }

                Section(t("Summarization")) {
                    Toggle(t("Summarize meetings"), isOn: $viewModel.summarizationEnabled)
                    TextField(t("Summarization model (blank = use model above)"), text: $viewModel.summarizationModel)
                    HStack {
                        Text(t("Context window (num_ctx)"))
                        Spacer()
                        TextField("", value: $viewModel.numCtx, format: .number)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(t("Long meetings need a large-context model. A tiny default model may truncate."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(t("Meetings")) {
                    HStack {
                        TextField(t("Save folder"), text: $viewModel.saveFolder)
                        Button(t("Choose...")) { viewModel.chooseSaveFolder() }
                    }
                    Picker(selection: $viewModel.audioSource) {
                        Text(t("Microphone + system audio")).tag("both")
                        Text(t("Microphone only")).tag("mic")
                        Text(t("System audio only")).tag("system")
                    } label: {
                        Text(t("Meeting audio"))
                    }
                    Text(t("System audio captures the other participants (e.g. video calls) and needs the System Audio Recording permission."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if viewModel.audioSource == "both" {
                        Text(t("Tip: use headphones. With open speakers the other participants' voices leak back into your microphone and can be counted twice."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(t("Delete audio after transcription"), isOn: $viewModel.autoDeleteAudio)
                    Picker(selection: $viewModel.defaultType) {
                        ForEach(MeetingType.allCases) { type in
                            Text(type.defaultDisplayName).tag(type)
                        }
                    } label: {
                        Text(t("Default meeting type"))
                    }
                    HStack {
                        Text(t("Speaker clustering threshold"))
                        Spacer()
                        Stepper(
                            value: $viewModel.clusteringThreshold,
                            in: 0.5...0.9,
                            step: 0.05
                        ) {
                            Text(String(format: "%.2f", viewModel.clusteringThreshold))
                                .monospacedDigit()
                        }
                    }
                    Text(t("Lower = more speakers. Default 0.55. Raise if distinct people are split; lower if speakers are merged."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Button(t("Change...")) { viewModel.changeHotkey() }
                    }
                }

                Section(t("Data")) {
                    Button(t("Edit Personal Context...")) { viewModel.editPersonalContext() }
                    Button(t("Open Data Folder...")) { viewModel.openDataFolder() }
                    Button(t("Edit Config File...")) { viewModel.editConfigFile() }
                    Button(t("View Logs...")) { viewModel.viewLogs() }
                }
            }
            .formStyle(.grouped)

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
    }
}
