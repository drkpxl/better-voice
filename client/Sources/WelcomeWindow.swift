import AppKit
import Combine
import SwiftUI
import BetterVoiceCore

/// First-launch onboarding root, shown by the `Window(id: WindowID.welcome)` scene.
///
/// A paged wizard (`WizardStep`) — one idea per screen, Back/Continue navigation, a progress
/// indicator — that introduces the app, requests the privacy permissions, and surfaces the
/// model server, dictation hotkey, and Apple Notes destination. Shown automatically on first
/// launch (see AppDelegate / `RuntimeConfig.onboardingVersion`, routed via `WindowRouter`) and
/// reachable anytime from the menu's "Welcome / Setup Guide". A fresh view model is built per
/// appearance, matching the old per-`show()` singleton behavior.
struct WelcomeRootView: View {
    @State private var viewModel: WelcomeViewModel?
    @Environment(\.dismiss) private var dismiss

    static let windowSize = CGSize(width: 600, height: 620)

    var body: some View {
        Group {
            if let viewModel {
                WelcomeContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .onAppear {
            let vm = WelcomeViewModel()
            vm.onComplete = { dismiss() }
            viewModel = vm
        }
        .onDisappear { viewModel = nil }
    }
}

// MARK: - ViewModel

// Commit-semantics rule: windows WITHOUT a Save button — Welcome (here) and the meeting wrap-up
// panel — persist each field immediately (on submit / on choose); windows WITH a Save button —
// Settings — batch edits and persist only on Save.
@Observable
@MainActor
final class WelcomeViewModel {
    /// Bump this when onboarding changes enough to re-show it to existing users.
    /// Compared against `RuntimeConfig.onboardingVersion` in AppDelegate.
    /// v2: added the Apple Notes destination section (Phase 4).
    /// v3: redesigned into a paged, one-idea-per-screen wizard + system-audio recording note.
    /// v4: real backend picker (Apple/Ollama/OpenAI-compatible) replaces the Apple-locked model
    /// step, dropped the redundant system-audio notice, added Your Name + Personal Context +
    /// Vocabulary steps.
    static let currentOnboardingVersion = 4

    var inputMonitoringGranted = false
    var accessibilityGranted = false
    var microphoneGranted = false
    var automationGranted = false

    // Model server — provider is mutable so onboarding can offer the same three backends as
    // Settings' `providerPicker` ("apple" / "ollama" / "openai"), not just whichever the seeded
    // default happened to be.
    var provider: String
    var endpoint: String
    var model: String
    var apiKey: String
    var serverStatus: ModelServer.Status = ModelServer.shared.status
    var isCheckingConnection = false

    /// The user's display name — prefilled from the Mac account name when the config has none —
    /// used to label the user's own voice in transcripts/summaries instead of "You"
    /// (`RuntimeConfig.userName`).
    var userName: String

    /// Free text for the Personal Context step, prefilled with any existing
    /// `personal-context.md` content. Optional/skippable — see `persistPersonalContext()`.
    var personalContextText: String

    /// One term per line for the Vocabulary step, prefilled from the existing `vocabulary.md`
    /// terms. Optional/skippable — see `persistVocabulary()`.
    var vocabularyText: String

    var onComplete: (() -> Void)?

    /// Ollama's own install page — the old GitHub-Pages help page never shipped, and the repo's
    /// Pages site is retired (marketing site now lives at voice.baselinemakes.com).
    static let ollamaHelpURL = URL(string: "https://ollama.com/download/mac")!

    var hotkeyDisplayName: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig).displayName
    }

    /// The meeting hotkey's live display string, for the `doneStep` recap's "Record a meeting"
    /// column. Falls back to `.meetingDefault` the same way `HotKeyRootView`/`SettingsViewModel`
    /// do, so a pre-second-hotkey install still shows a real value instead of "Unknown".
    var meetingHotkeyDisplayName: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.meetingHotKeyConfig, fallback: .meetingDefault).displayName
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
        let server = cfg.polishServerConfig
        provider = server.api
        // Only Ollama gets the localhost default when blank; OpenAI-compatible and Apple leave it
        // empty (mirrors the provider picker's `defaultEndpoint(for:)`), so reopening onboarding on
        // a saved OpenAI config doesn't wrongly prefill Ollama's endpoint.
        endpoint = server.endpoint.isEmpty ? (server.api == "ollama" ? "http://localhost:11434" : "") : server.endpoint
        model = server.model.isEmpty ? "qwen3.5:4b-mlx" : server.model
        apiKey = server.apiKey
        userName = cfg.userName ?? NSFullUserName()
        personalContextText = PersonalContext.load() ?? ""
        vocabularyText = Vocabulary.shared.terms.joined(separator: "\n")
        refreshStatuses()
    }

    /// Re-reads live permission state (granted toggles out-of-process when the user acts in
    /// System Settings, so the view polls this on a timer while open).
    func refreshStatuses() {
        // These four kinds always resolve (never `nil`) — see `PermissionKind.isGranted`.
        // `.systemAudio` is deliberately excluded: it has no live status to poll (see there).
        let inputMonitoringWasGranted = inputMonitoringGranted
        inputMonitoringGranted = PermissionKind.inputMonitoring.isGranted ?? false
        accessibilityGranted = PermissionKind.accessibility.isGranted ?? false
        microphoneGranted = PermissionKind.microphone.isGranted ?? false
        automationGranted = PermissionKind.automation.isGranted ?? false

        // The CGEventTap is created at launch; if Input Monitoring wasn't granted then, creation
        // failed and the hotkey is dead. The instant the user grants it here, re-create the tap so
        // dictation works immediately — no app restart needed.
        if !inputMonitoringWasGranted, inputMonitoringGranted {
            Logger.log("Permission", "Input Monitoring granted during onboarding — restarting hotkey tap")
            GlobalHotKey.shared.restart()
        }
    }

    func grantInputMonitoring() {
        // If the system won't show its dialog (already decided once), send the user straight to
        // the Settings pane so "Grant" never appears to do nothing.
        if PermissionManager.requestInputMonitoring() == .mustOpenSettings {
            PermissionManager.openSettings(for: .inputMonitoring)
        }
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

    func grantAutomation() {
        _ = PermissionManager.requestAutomation()
        refreshStatuses()
    }

    func openSettings(for kind: PermissionKind) { PermissionManager.openSettings(for: kind) }

    /// Writes the chosen provider/endpoint/model/API key into Dictation Polish's connection
    /// config (preserving its other keys).
    ///
    /// Also mirrors the same values into Summarization's connection config, but ONLY on
    /// someone's first-ever onboarding completion (`onboardingVersion == 0`): a fresh install
    /// seeds both sections identically, so this lets a first-run user correct the shared
    /// provider/endpoint/model/key once for both. Reopening onboarding later (from the menu's
    /// "Setup Guide", potentially after Settings has deliberately split the two providers) must
    /// never silently clobber a Summarization-specific choice, so after the first completion
    /// this only ever touches Polish.
    func persistServer() {
        let cfg = RuntimeConfig.shared
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var polish = cfg.polishConfig
        var polishServer = polish["server"] as? [String: Any] ?? [:]
        polishServer["api"] = provider
        polishServer["endpoint"] = trimmedEndpoint
        polishServer["model"] = trimmedModel
        polishServer["api_key"] = trimmedApiKey
        polish["server"] = polishServer
        cfg.updateSection("polish", polish)

        guard cfg.onboardingVersion == 0 else { return }
        var meeting = cfg.meetingConfig
        var summ = meeting["summarization"] as? [String: Any] ?? [:]
        var summServer = summ["server"] as? [String: Any] ?? [:]
        summServer["api"] = provider
        summServer["endpoint"] = trimmedEndpoint
        summServer["model"] = trimmedModel
        summServer["api_key"] = trimmedApiKey
        summ["server"] = summServer
        meeting["summarization"] = summ
        cfg.updateSection("meeting", meeting)
    }

    /// Persists the name field (trimmed; empty clears back to the "You" fallback). Called on
    /// `Return` in the field and again as a safety net in `complete()`.
    func persistUserName() {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        RuntimeConfig.shared.updateTopLevel("user_name", trimmed.isEmpty ? nil : trimmed)
    }

    /// Writes the Personal Context step's text as-is (no template/headers — onboarding is a
    /// quick free-text add, not the full structured editor reachable from Settings). Never
    /// clobbers an existing file when left blank, so re-running onboarding (Setup Guide) can't
    /// silently wipe out content added later.
    func persistPersonalContext() {
        let trimmed = personalContextText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SupportDir.ensureExists()
        try? trimmed.write(to: PersonalContext.fileURL, atomically: true, encoding: .utf8)
    }

    /// Splits the Vocabulary step's free text into one term per line — stripping a leading
    /// "- " in case the user pasted a bulleted list — and merges them additively into
    /// `vocabulary.md` via `Vocabulary.addTerms`, matching the file's one-term-per-line
    /// convention (see `renderVocabularyMarkdown`).
    func persistVocabulary() {
        let lines = vocabularyText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("- ") { s.removeFirst(2) }
                return s
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        Vocabulary.shared.ensureCreated()
        Vocabulary.shared.addTerms(lines)
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

    func complete() {
        persistUserName()
        persistServer()
        persistPersonalContext()
        persistVocabulary()
        RuntimeConfig.shared.updateTopLevel("onboarding_version", Self.currentOnboardingVersion)
        WindowRouter.shared.open(id: WindowID.main)
        onComplete?()
    }
}

// MARK: - Wizard steps

/// One screen per step, driving `WelcomeContentView`'s paged layout — order is the onboarding
/// flow order, and `CaseIterable` powers the progress dots. Personal Context, Vocabulary, and
/// Notes are all optional (see `WelcomeContentView.footer` / `WelcomeViewModel.complete()`):
/// Continue always advances past them, and `complete()` persists whatever was entered as a
/// safety net regardless of which step last called its own persist method.
private enum WizardStep: Int, CaseIterable {
    case welcome
    case dictation
    case model
    case personalContext
    case vocabulary
    case notes
    case done
}

// MARK: - SwiftUI View

struct WelcomeContentView: View {
    @Bindable var viewModel: WelcomeViewModel
    @State private var showNotesPicker = false
    @State private var step: WizardStep = .welcome

    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// Return-chaining for the model server fields: Return in Endpoint moves focus to Model;
    /// Return in Model persists and drops focus so the default Continue button can take Return.
    private enum ServerField: Hashable { case endpoint, model }
    @FocusState private var focusedServerField: ServerField?

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 22)
                .padding(.bottom, 4)

            Group {
                switch step {
                case .welcome: welcomeStep
                case .dictation: dictationStep
                case .model: modelStep
                case .personalContext: personalContextStep
                case .vocabulary: vocabularyStep
                case .notes: notesStep
                case .done: doneStep
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Divider()

            footer
        }
        .tint(Color.brandAccent)
        .frame(width: WelcomeRootView.windowSize.width, height: WelcomeRootView.windowSize.height)
        .onAppear { viewModel.refreshStatuses() }
        .onReceive(pollTimer) { _ in viewModel.refreshStatuses() }
        .sheet(isPresented: $showNotesPicker) {
            NotesDestinationPickerView(onSaved: { viewModel.refreshStatuses() })
        }
    }

    // MARK: Navigation chrome

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(WizardStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Color.brandAccent : Color.secondary.opacity(0.25))
                    .frame(width: s == step ? 22 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button(t("Back")) { goBack() }
            }
            Spacer()
            Button(step == .done ? t("Get Started") : t("Continue")) { advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    /// Persists whatever the step being left owns, so it lands even for someone who never
    /// reaches the final "Get Started" (`complete()` persists everything again anyway as a
    /// safety net, but this makes leaving a step feel committed immediately, matching the
    /// commit-semantics rule at the top of this file).
    private func persistLeaving(_ leavingStep: WizardStep) {
        switch leavingStep {
        case .welcome: viewModel.persistUserName()
        case .model: viewModel.persistServer()
        case .personalContext: viewModel.persistPersonalContext()
        case .vocabulary: viewModel.persistVocabulary()
        case .dictation, .notes, .done: break
        }
    }

    private func advance() {
        persistLeaving(step)
        guard let next = WizardStep(rawValue: step.rawValue + 1) else {
            viewModel.complete()
            return
        }
        withAnimation { step = next }
    }

    private func goBack() {
        guard let previous = WizardStep(rawValue: step.rawValue - 1) else { return }
        withAnimation { step = previous }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        stepScaffold(
            title: t("Welcome to Better Voice"),
            subtitle: t("Dictate into any app with a hotkey, and turn meeting recordings into titled summaries saved to Apple Notes — everything runs locally on your Mac.")
        ) {
            BrandWaveform(height: 56)
        } content: {
            nameField
                .frame(maxWidth: 320)
        }
    }

    /// Labels the user's own voice in transcripts/summaries — falls back to "You" if left
    /// blank. Prefilled from the Mac account name (`NSFullUserName()`) so most people never
    /// have to type anything here.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Your name")).font(.caption).foregroundStyle(.secondary)
            TextField(t("Your name"), text: $viewModel.userName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.persistUserName() }
        }
    }

    private var dictationStep: some View {
        stepScaffold(
            title: t("Dictate Anywhere"),
            subtitle: t("Hold your hotkey, speak, and release — Better Voice cleans up the text and types it at your cursor in any app.")
        ) {
            stepIcon("keyboard")
        } content: {
            VStack(spacing: 14) {
                hotkeyChip
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
                }
                .padding(.horizontal, 12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: 460)
        }
    }

    private var hotkeyChip: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .foregroundStyle(.secondary)
            Text(viewModel.hotkeyDisplayName)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Button(t("Change...")) { WindowRouter.shared.open(id: WindowID.hotkey) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var modelStep: some View {
        stepScaffold(
            title: t("Local model server"),
            subtitle: t("Better Voice polishes dictation and summarizes meetings using a local AI model. Ollama by default, or any OpenAI-compatible server (LM Studio, llama.cpp, mlx). The defaults work with a standard Ollama install on this Mac.")
        ) {
            stepIcon("cpu")
        } content: {
            modelServerContent
                .frame(maxWidth: 460)
        }
    }

    /// Mirrors Settings' `providerPicker` tags exactly ("apple" / "ollama" / "openai") so a
    /// choice made here reads back identically in Settings.
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

    @ViewBuilder
    private var modelServerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerPicker($viewModel.provider)
                .onChange(of: viewModel.provider) { _, newValue in
                    if newValue == "apple" {
                        viewModel.model = FoundationModelsBackend.modelName
                        viewModel.endpoint = ""
                        viewModel.apiKey = ""
                    } else {
                        // Leaving Apple (or switching between Ollama/OpenAI-compatible): the old
                        // model name belongs to a different provider, so it's never valid here —
                        // clear it rather than leave a stale value.
                        viewModel.model = ""
                        if viewModel.endpoint.isEmpty {
                            viewModel.endpoint = defaultEndpoint(for: newValue)
                        }
                    }
                }

            if viewModel.provider == "apple" {
                // On-device is always available with nothing to configure, so there's no
                // connection to test — unlike Ollama/OpenAI-compatible, a "Test connection"
                // button here would have nothing meaningful to check.
                Text(t("Runs on-device — always available, nothing to set up."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Endpoint")).font(.caption).foregroundStyle(.secondary)
                    TextField("http://localhost:11434", text: $viewModel.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedServerField, equals: .endpoint)
                        .onSubmit { focusedServerField = .model }
                }
                if viewModel.provider == "openai" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("API key")).font(.caption).foregroundStyle(.secondary)
                        SecureField(t("API key (optional)"), text: $viewModel.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Model")).font(.caption).foregroundStyle(.secondary)
                    TextField("qwen3.5:4b-mlx", text: $viewModel.model)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedServerField, equals: .model)
                        .onSubmit {
                            viewModel.persistServer()
                            focusedServerField = nil
                        }
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
                        Text(t("New to local models? Setup guide"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, 2)
    }

    /// Optional at onboarding — skippable, so `complete()` / "Get Started" is never gated on it.
    private var personalContextStep: some View {
        stepScaffold(
            title: t("Personal Context"),
            subtitle: t("Tell Better Voice what you do — your role, the kinds of meetings you record, your industry. It uses this to write summaries that fit your world.")
        ) {
            stepIcon("person.text.rectangle")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                freeformEditor(
                    text: $viewModel.personalContextText,
                    placeholder: t("e.g. \"I'm a product manager on the Payments team at Acme, working mostly with engineering and design.\"")
                )
                Text(t("Optional — skip and add this anytime in Settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 460)
        }
    }

    /// Optional at onboarding — skippable, so `complete()` / "Get Started" is never gated on it.
    private var vocabularyStep: some View {
        stepScaffold(
            title: t("Vocabulary"),
            subtitle: t("Add words Better Voice should get right — industry terms, product and brand names, acronyms, names it might mis-hear.")
        ) {
            stepIcon("textformat.abc")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                freeformEditor(
                    text: $viewModel.vocabularyText,
                    placeholder: t("One term per line, e.g.\nFluidAudio\nAcme Corp\nKubernetes")
                )
                Text(t("Optional — skip and add this anytime in Settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 460)
        }
    }

    /// Shared multi-line text editor for the Personal Context / Vocabulary steps — a plain
    /// `TextEditor` with a lightweight placeholder overlay, since SwiftUI has no built-in one.
    private func freeformEditor(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
        }
        .frame(height: 160)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    /// Optional at onboarding — dictation-only users can skip this entirely, so `complete()` /
    /// "Get Started" is never gated on it (Continue advances past this step regardless of
    /// Automation/destination state). The import wizard's own `.blocked` step catches an
    /// unconfigured destination the first time someone tries to import a meeting.
    private var notesStep: some View {
        stepScaffold(
            title: t("Apple Notes"),
            subtitle: t("Meeting transcripts and summaries are saved to Apple Notes.")
        ) {
            stepIcon("note.text")
        } content: {
            VStack(spacing: 14) {
                Text(t("Optional — dictation works without this. Set it up now if you plan to import meetings, or skip and configure it later in Settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    permissionRow(
                        kind: .automation,
                        granted: viewModel.automationGranted,
                        title: t("Automation access"),
                        detail: t("Lets Better Voice create notes in Apple Notes."),
                        grant: { viewModel.grantAutomation() }
                    )
                    Divider()
                    HStack {
                        Text(notesDestinationSummary())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Choose...")) { showNotesPicker = true }
                    }
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                // System Audio Recording is deliberately not mentioned here — macOS prompts for
                // it automatically the first time a real meeting starts recording, and the
                // Settings deep link (see `SettingsWindow`'s "Apple Notes" section) only makes
                // sense once it's actually been asked for. See `PermissionKind.systemAudio`.
            }
            .frame(maxWidth: 460)
        }
    }

    private var doneStep: some View {
        stepScaffold(
            title: t("You're all set"),
            subtitle: t("Here's what you can do next. Revisit permissions and setup anytime from Settings.")
        ) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.green)
                .frame(height: 52)
        } content: {
            doneRecap
                .frame(maxWidth: 520)
        }
    }

    /// Three equal (33/33/33) columns — icon + title + one line — recapping the app's three
    /// entry points, using the ACTUAL configured hotkeys (not hardcoded defaults) so a user who
    /// changed either binding earlier in the wizard sees what they'll really need to press.
    /// `ViewThatFits` falls back to a stacked column layout if the window is ever narrower than
    /// three columns comfortably fit (the window itself is fixed-size today, but this keeps the
    /// recap correct if that ever changes).
    private var doneRecap: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                recapColumn(icon: "keyboard", title: t("Dictate"), detail: dictateRecapDetail)
                recapColumn(icon: "square.and.arrow.down", title: t("Import a meeting"), detail: importRecapDetail)
                recapColumn(icon: "record.circle", title: t("Record a meeting"), detail: recordRecapDetail)
            }
            VStack(alignment: .leading, spacing: 20) {
                recapColumn(icon: "keyboard", title: t("Dictate"), detail: dictateRecapDetail)
                recapColumn(icon: "square.and.arrow.down", title: t("Import a meeting"), detail: importRecapDetail)
                recapColumn(icon: "record.circle", title: t("Record a meeting"), detail: recordRecapDetail)
            }
        }
    }

    private var dictateRecapDetail: String {
        t("Tap \(viewModel.hotkeyDisplayName) to type text wherever your cursor is.")
    }

    private var importRecapDetail: String {
        t("Drop in a recording, or paste a transcript.")
    }

    private var recordRecapDetail: String {
        t("Tap \(viewModel.meetingHotkeyDisplayName) — or Start Meeting in the menu bar — to capture a call.")
    }

    private func recapColumn(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.brandAccent)
                .frame(height: 30)
            Text(title)
                .font(.subheadline).bold()
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Helpers

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

    /// Shared layout for every step: a large SF Symbol (or brand mark) visual, a title, a short
    /// "why this matters" subtitle, then the step's own controls.
    @ViewBuilder
    private func stepScaffold<Icon: View, Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            icon()
            VStack(spacing: 8) {
                Text(title)
                    .font(.title).bold()
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepIcon(_ symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(Color.brandAccent)
            .frame(height: 52)
    }
}
