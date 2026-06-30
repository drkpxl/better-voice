import AppKit
import SwiftUI
import WECore

/// 设置窗口（Feature 0）。
///
/// 用 NSWindow + NSHostingView 嵌入 SwiftUI（与 HotKeySettingsWindow 同栈）。
/// 暴露新功能相关配置 + 关键既有项；"Edit Config File..." 仍保留给高级用户。
/// 保存时按段读-改-写，避免覆盖本窗口不管理的键（如 meeting.l2_*、server.timeout）。
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
    // Waveform
    var noiseFloor: Double
    var sensitivity: Double
    // Language ("" = follow system)
    var language: String

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let cfg = RuntimeConfig.shared
        let server = cfg.serverConfig
        let meeting = cfg.meetingConfig
        let summ = cfg.meetingSummarizationConfig
        let wave = cfg.waveformConfig

        endpoint = server["endpoint"] as? String ?? "http://localhost:11434"
        model = server["model"] as? String ?? "qwen3.5:4b-mlx"
        api = server["api"] as? String ?? "ollama"
        summarizationModel = server["summarization_model"] as? String ?? ""

        summarizationEnabled = summ["enabled"] as? Bool ?? true
        numCtx = summ["num_ctx"] as? Int ?? 32768

        saveFolder = meeting["save_folder"] as? String ?? WEDataDir.meetings.path
        autoDeleteAudio = meeting["auto_delete_audio"] as? Bool ?? false
        defaultType = MeetingType.from(configKey: meeting["default_type"] as? String ?? "general") ?? .general

        noiseFloor = wave["noise_floor"] as? Double ?? 0.02
        sensitivity = wave["sensitivity"] as? Double ?? 1.0

        language = cfg.language ?? ""
    }

    /// 读-改-写各配置段，保留未管理的键。
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
        var summ = meeting["summarization"] as? [String: Any] ?? [:]
        summ["enabled"] = summarizationEnabled
        summ["num_ctx"] = max(1024, numCtx)
        meeting["summarization"] = summ
        cfg.updateSection("meeting", meeting)

        var wave = cfg.waveformConfig
        wave["noise_floor"] = noiseFloor
        wave["sensitivity"] = sensitivity
        cfg.updateSection("waveform", wave)

        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.updateTopLevel("language", lang.isEmpty ? nil : lang)
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

// MARK: - SwiftUI 视图

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
                    Toggle(t("Delete audio after transcription"), isOn: $viewModel.autoDeleteAudio)
                    Picker(selection: $viewModel.defaultType) {
                        ForEach(MeetingType.allCases) { type in
                            Text(type.defaultDisplayName).tag(type)
                        }
                    } label: {
                        Text(t("Default meeting type"))
                    }
                }

                Section(t("Waveform indicator")) {
                    VStack(alignment: .leading) {
                        Text(t("Noise floor: \(String(format: "%.3f", viewModel.noiseFloor))"))
                            .font(.caption)
                        Slider(value: $viewModel.noiseFloor, in: 0...0.2)
                    }
                    VStack(alignment: .leading) {
                        Text(t("Sensitivity: \(String(format: "%.1f", viewModel.sensitivity))"))
                            .font(.caption)
                        Slider(value: $viewModel.sensitivity, in: 0.2...5)
                    }
                }

                Section(t("Language")) {
                    Picker(selection: $viewModel.language) {
                        Text(t("Follow system")).tag("")
                        Text("English").tag("en")
                        Text("简体中文").tag("zh-Hans")
                    } label: {
                        Text(t("Language"))
                    }
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
