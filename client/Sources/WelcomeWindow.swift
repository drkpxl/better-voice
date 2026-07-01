import AppKit
import Combine
import SwiftUI
import BetterVoiceCore

/// First-launch onboarding window.
///
/// A single scrolling welcome screen (not a wizard) that introduces the app, requests
/// the four privacy permissions inline, and surfaces the hotkey, meeting save folder, and
/// personal context. Uses the same NSWindow + NSHostingView + @Observable ViewModel pattern
/// as `SettingsWindow`. Shown automatically on first launch (see AppDelegate / RuntimeConfig
/// `onboarding_version`) and reachable anytime from the menu's "Welcome / Setup Guide".
@MainActor
final class WelcomeWindow {
    static let shared = WelcomeWindow()

    /// Bump this when onboarding changes enough to re-show it to existing users.
    /// Compared against `RuntimeConfig.onboardingVersion` in AppDelegate.
    static let currentOnboardingVersion = 1

    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = WelcomeViewModel()
        viewModel.onComplete = { [weak self] in self?.close() }

        let host = NSHostingView(rootView: WelcomeContentView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = t("Welcome to Better Voice")
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
final class WelcomeViewModel {
    var inputMonitoringGranted = false
    var accessibilityGranted = false
    var microphoneGranted = false
    var systemAudioGranted = false

    // Model server (Ollama)
    var endpoint: String
    var model: String
    var serverStatus: ModelServer.Status = ModelServer.shared.status
    var isCheckingConnection = false

    var saveFolder: String

    var onComplete: (() -> Void)?

    /// Doc page explaining Ollama (hosted on the GitHub Pages site).
    static let ollamaHelpURL = URL(string: "https://drkpxl.github.io/better-voice/ollama.html")!

    var hotkeyDisplayName: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig).displayName
    }

    var serverStatusText: String {
        switch serverStatus {
        case .connected: return t("Connected")
        case .disconnected: return t("Not reachable")
        case .unknown: return t("Unknown")
        }
    }

    init() {
        let cfg = RuntimeConfig.shared
        let server = cfg.serverConfig
        let meeting = cfg.meetingConfig
        endpoint = server["endpoint"] as? String ?? "http://localhost:11434"
        model = server["model"] as? String ?? "qwen3.5:4b-mlx"
        saveFolder = meeting["save_folder"] as? String ?? BetterVoiceDataDir.meetings.path
        refreshStatuses()
    }

    /// Re-reads live permission state (granted toggles out-of-process when the user acts in
    /// System Settings, so the view polls this on a timer while open).
    func refreshStatuses() {
        inputMonitoringGranted = PermissionKind.inputMonitoring.isGranted
        accessibilityGranted = PermissionKind.accessibility.isGranted
        microphoneGranted = PermissionKind.microphone.isGranted
        systemAudioGranted = PermissionKind.systemAudio.isGranted
    }

    func grantInputMonitoring() {
        _ = PermissionManager.checkInputMonitoring()
        refreshStatuses()
    }

    func grantAccessibility() {
        _ = PermissionManager.checkAccessibility()
        refreshStatuses()
    }

    func grantMicrophone() {
        Task {
            _ = await PermissionManager.checkMicrophone()
            refreshStatuses()
        }
    }

    func grantSystemAudio() {
        PermissionManager.requestSystemAudio { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
    }

    func openSettings(for kind: PermissionKind) { PermissionManager.openSettings(for: kind) }

    /// Writes the entered endpoint/model into the server config (preserving other keys).
    func persistServer() {
        var server = RuntimeConfig.shared.serverConfig
        server["endpoint"] = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        server["model"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        RuntimeConfig.shared.updateSection("server", server)
    }

    /// Persists the entered values, then health-checks the endpoint so the status reflects them.
    func testConnection() {
        persistServer()
        isCheckingConnection = true
        Task {
            await ModelServer.shared.checkHealth()
            self.serverStatus = ModelServer.shared.status
            self.isCheckingConnection = false
        }
    }

    func openOllamaHelp() { NSWorkspace.shared.open(Self.ollamaHelpURL) }

    func changeHotkey() { HotKeySettingsWindow.shared.show() }

    /// Picks a meeting save folder and persists it immediately (onboarding has no global Save).
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
            var meeting = RuntimeConfig.shared.meetingConfig
            meeting["save_folder"] = url.path
            RuntimeConfig.shared.updateSection("meeting", meeting)
        }
    }

    func editPersonalContext() { PersonalContext.openOrCreate() }

    func openSettingsWindow() { SettingsWindow.shared.show() }

    func complete() {
        persistServer()
        RuntimeConfig.shared.updateTopLevel("onboarding_version", WelcomeWindow.currentOnboardingVersion)
        onComplete?()
    }
}

// MARK: - SwiftUI View

struct WelcomeContentView: View {
    @Bindable var viewModel: WelcomeViewModel

    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    permissionsSection
                    modelServerSection
                    hotkeySection
                    saveFolderSection
                    personalContextSection
                }
                .padding(24)
            }

            Divider()

            footer
        }
        .tint(Color.brandAccent)
        .frame(width: 560, height: 680)
        .onAppear { viewModel.refreshStatuses() }
        .onReceive(pollTimer) { _ in viewModel.refreshStatuses() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                BrandWaveform(height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Welcome to Better Voice"))
                        .font(.title).bold()
                    Text(t("On-device dictation and meeting notes that stay private."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(t("Press your hotkey to dictate into any app. Start a meeting to capture a transcript and summary — everything is processed locally on your Mac."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionsSection: some View {
        sectionCard(
            title: t("Permissions"),
            subtitle: t("Better Voice needs these to work. Grant them now, or anytime in System Settings.")
        ) {
            VStack(spacing: 0) {
                permissionRow(
                    kind: .inputMonitoring,
                    granted: viewModel.inputMonitoringGranted,
                    title: t("Global hotkey monitoring"),
                    detail: t("Lets your dictation hotkey work in every app."),
                    grant: { viewModel.grantInputMonitoring() }
                )
                Divider()
                permissionRow(
                    kind: .accessibility,
                    granted: viewModel.accessibilityGranted,
                    title: t("Text injection"),
                    detail: t("Types transcribed text at your cursor."),
                    grant: { viewModel.grantAccessibility() }
                )
                Divider()
                permissionRow(
                    kind: .microphone,
                    granted: viewModel.microphoneGranted,
                    title: t("Microphone"),
                    detail: t("Records your voice for transcription."),
                    grant: { viewModel.grantMicrophone() }
                )
                Divider()
                permissionRow(
                    kind: .systemAudio,
                    granted: viewModel.systemAudioGranted,
                    title: t("System audio recording"),
                    detail: t("Captures the other side's audio for meeting notes (e.g. video calls). Only needed for meetings."),
                    grant: { viewModel.grantSystemAudio() }
                )
            }
        }
    }

    private func permissionRow(
        kind: PermissionKind,
        granted: Bool,
        title: String,
        detail: String,
        grant: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Text(t("Granted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Button(t("Grant")) { grant() }
                    Button {
                        viewModel.openSettings(for: kind)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help(t("Open System Settings"))
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var modelServerSection: some View {
        sectionCard(
            title: t("Model server (Ollama)"),
            subtitle: t("Better Voice polishes dictation and summarizes meetings using a local AI model served by Ollama. The defaults work with a standard Ollama install on this Mac.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Endpoint")).font(.caption).foregroundStyle(.secondary)
                    TextField("http://localhost:11434", text: $viewModel.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.persistServer() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Model")).font(.caption).foregroundStyle(.secondary)
                    TextField("qwen3.5:4b-mlx", text: $viewModel.model)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.persistServer() }
                }
                HStack {
                    Button(t("Test connection")) { viewModel.testConnection() }
                        .disabled(viewModel.isCheckingConnection)
                    Text(viewModel.serverStatusText)
                        .font(.caption)
                        .foregroundStyle(viewModel.serverStatus == .connected ? .green : .secondary)
                    Spacer()
                }
                Button {
                    viewModel.openOllamaHelp()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                        Text(t("New to Ollama? What it is & why it's needed"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
            }
            .padding(.vertical, 2)
        }
    }

    private var hotkeySection: some View {
        sectionCard(
            title: t("Dictation hotkey"),
            subtitle: t("Hold this key to dictate; release to insert the text.")
        ) {
            HStack {
                Text(viewModel.hotkeyDisplayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("Change...")) { viewModel.changeHotkey() }
            }
            .padding(.vertical, 2)
        }
    }

    private var saveFolderSection: some View {
        sectionCard(
            title: t("Meeting save folder"),
            subtitle: t("Where meeting transcripts and summaries are saved.")
        ) {
            HStack {
                Text(viewModel.saveFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(t("Choose...")) { viewModel.chooseSaveFolder() }
            }
            .padding(.vertical, 2)
        }
    }

    private var personalContextSection: some View {
        sectionCard(
            title: t("Personal context (recommended)"),
            subtitle: t("Tell the local AI a little about you — your name, team, projects, and the people and jargon you mention. It uses this only to spell names and terms correctly when polishing dictation and summarizing meetings; it's never added to your text.")
        ) {
            Button(t("Edit Personal Context...")) { viewModel.editPersonalContext() }
                .padding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack {
            Button(t("Open full Settings...")) { viewModel.openSettingsWindow() }
            Spacer()
            Button(t("Get Started")) { viewModel.complete() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
