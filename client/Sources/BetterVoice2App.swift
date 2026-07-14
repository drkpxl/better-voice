import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BetterVoiceCore

/// Entry point. Not the SwiftUI `App` itself, so the BENCH-mode CLI dispatch below can run
/// before any scene machinery spins up; the GUI path hands off to `BetterVoice2App.main()`
/// (SwiftUI's synthesized entry).
@main
enum BetterVoice2Main {
    static func main() {
        #if BENCH
        // Offline import-pipeline evaluation:
        //   BetterVoice2 --bench-meeting <audio> [--locale zh-CN] [--single] [--output result.json]
        if CommandLine.arguments.contains("--bench-meeting") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await ImportBenchmark.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // Dictation-polish sanity check (verifies the model cleans, not answers):
        //   BetterVoice2 --bench-polish "some dictated text"
        if let idx = CommandLine.arguments.firstIndex(of: "--bench-polish"), idx + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[idx + 1]
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                // PolishClient touches Vocabulary.shared, which resolves SupportDir paths — configure a scratch root.
                SupportDir.configure(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bettervoice2-bench"))
                await ModelServer.shared.checkHealth()
                let out = await PolishClient.shared.polish(text: text, words: [], app: nil)
                print("INPUT:  \(text)")
                print("OUTPUT: \(out ?? "<nil>")")
                app.terminate(nil)
            }
            app.run()
            return
        }
        // Editor edit/dirty/save chain sanity check (no GUI interaction needed):
        //   BetterVoice2 --bench-editor
        if CommandLine.arguments.contains("--bench-editor") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let harness = EditorBenchHarness()
            harness.run { app.terminate(nil) }
            app.run()
            return
        }
        #endif

        BetterVoice2App.main()
    }
}

/// SwiftUI app: `MenuBarExtra` replaces the old NSStatusItem, and windows are `Window` scenes.
/// Phase 2 is dictation-only: a `.regular` Dock app with a menu-bar item, a placeholder main
/// window, and the hotkey recorder. Onboarding, the import wizard, Settings, and meetings land
/// in later phases.
struct BetterVoice2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(
                model: appDelegate.menuModel,
                meetingCoordinator: appDelegate.meetingCoordinator,
                permissions: appDelegate.permissionStore
            )
        } label: {
            MenuBarLabel(model: appDelegate.menuModel, meetingCoordinator: appDelegate.meetingCoordinator)
        }

        // The main Dock window: hosts the import wizard (Apple Notes is the only meeting store —
        // there's no in-app library to browse). Launch is controlled explicitly by AppDelegate
        // (gated on onboarding), so suppress the default auto-open + restoration like the other
        // windows.
        Window(t("Better Voice"), id: WindowID.main) {
            MeetingsRootView()
        }
        .defaultSize(width: 960, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // File-menu commands drive the main window's import wizard via ImportLauncher: open (or
        // focus) the main window, then bump the launcher token that MeetingsRootView observes.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(t("New Import…")) {
                    WindowRouter.shared.open(id: WindowID.main)
                    ImportLauncher.shared.requestNew(file: nil)
                }
                .keyboardShortcut("n")

                Button(t("Open Audio File…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        WindowRouter.shared.open(id: WindowID.main)
                        ImportLauncher.shared.requestNew(file: url)
                    }
                }
                .keyboardShortcut("o")
            }
        }

        // First-launch onboarding. Opened explicitly by AppDelegate when onboarding_version is
        // stale, and from the menu anytime.
        Window(t("Welcome to Better Voice"), id: WindowID.welcome) {
            WelcomeRootView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Window scenes auto-open at launch by default — wrong for a menu-bar-driven app, hence
        // suppressed launch + disabled restoration.
        Window(t("Better Voice Set Hotkey"), id: WindowID.hotkey) {
            HotKeyRootView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Freeform-text editors for the two markdown files in the support dir. Opened on demand
        // from Settings / onboarding via WindowRouter; suppressed + non-restoring like the rest.
        Window(t("Personal Context"), id: WindowID.personalContext) {
            PersonalContextRootView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(t("Vocabulary"), id: WindowID.vocabulary) {
            VocabularyRootView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Standard macOS Settings scene (⌘, via the menu's SettingsLink).
        Settings {
            SettingsRootView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Constructed at delegate init (before the scene body evaluates) so the App struct can
    // hand them to the MenuBarExtra views.
    let voiceModule = VoiceModule()
    let menuModel = MenuBarModel()
    let meetingCoordinator = MeetingCoordinator()
    /// Single source of truth for live permission state — drives both the menu bar and onboarding.
    let permissionStore = PermissionStore.shared

    private let config = RuntimeConfig.shared
    private let recordingIndicator = RecordingIndicator.shared
    private var updater: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular Dock app with a menu-bar item.
        NSApp.setActivationPolicy(.regular)

        // The support directory is fixed (no user choice, no onboarding step) — just make sure
        // it exists before anything (SpeakerStore, Vocabulary, PersonalContext, MeetingHistory)
        // does its first file I/O.
        SupportDir.ensureExists()

        // Whether first-launch onboarding runs this session (gates the window opened at the end).
        let needsOnboarding = config.onboardingVersion < WelcomeViewModel.currentOnboardingVersion

        // Launch (almost) never prompts for permissions — the shared PermissionStore QUERIED fresh
        // at its init. The old code fired the Accessibility + Input Monitoring + Microphone system
        // dialogs back-to-back for a returning user (three prompts + Settings panes stacked on
        // launch), and pre-consumed Input Monitoring's one-shot dialog so onboarding's "Grant" fell
        // through to an empty ("No Items") pane. Now permissions are granted either in onboarding
        // (sequentially, one prompt at a time) or just-in-time at the point of use — dictation
        // requests the mic (VoiceModule), meetings request Automation / System Audio — while the
        // menu bar shows a live ⚠ for anything missing.
        Logger.log("App", "Permissions at launch — accessibility: \(permissionStore.accessibility), microphone: \(permissionStore.microphone), automation: \(permissionStore.automation)")

        // The ONE launch prompt kept, for returning users only: Accessibility. It's the sole
        // permission with no just-in-time path — without it the hotkey tap can't even be created,
        // so nothing at the point of use is alive to ask, and a since-revoked grant (TCC reset,
        // macOS upgrade, re-signed build) would otherwise dead-end silently until the user happens
        // to open the menu and notice the ⚠ row. A single dialog; none of the old triple-stack.
        if !needsOnboarding, !permissionStore.accessibility {
            _ = PermissionManager.checkAccessibility()
        }

        // menu-bar icon tracks the server connection
        ModelServer.shared.onStatusChange = { [weak self] status in
            self?.menuModel.serverStatus = status
        }
        ModelServer.shared.startHealthCheck()

        // wire up the voice module
        voiceModule.onStateChange = { [weak self] state in
            guard let self else { return }
            self.menuModel.isRecording = (state == .recording)
            self.menuModel.isProcessing = (state == .processing)
            switch state {
            case .recording:
                self.recordingIndicator.show(owner: .dictation)
                DictationSound.playStart()
            case .processing:
                // First non-recording state after a real recording — play the
                // stop cue here (not on .idle) so it fires exactly once.
                self.recordingIndicator.hide(owner: .dictation)
                DictationSound.playStop()
            case .idle:
                self.recordingIndicator.hide(owner: .dictation)
            }
        }
        voiceModule.onAudioLevel = { [weak self] level in
            self?.recordingIndicator.update(level: level)
        }

        // register the global hotkey
        GlobalHotKey.shared.onPress = { [weak self] in
            guard let self else { return }
            // Dictation-vs-dictation is gated inside VoiceModule by its .processing state; guard
            // here as well so a stray press can't stack on an in-flight transcription/polish.
            if self.menuModel.isProcessing {
                Logger.log("Hotkey", "Ignored: processing in progress")
                return
            }
            self.voiceModule.onHotKeyDown()
        }
        GlobalHotKey.shared.onRelease = { [weak self] in
            self?.voiceModule.onHotKeyUp()
        }
        // Meeting hotkey: a fire-once toggle (no processing gate needed — toggleMeeting() is
        // already start/stop-gated by MeetingCoordinator's own state machine, same guard the menu
        // bar's Start/Stop row relies on).
        GlobalHotKey.shared.onMeetingFire = { [weak self] in
            self?.meetingCoordinator.toggleMeeting()
        }
        GlobalHotKey.shared.start()

        // Keep the shared permission store live and self-heal the hotkey tap: when the app
        // reactivates (e.g. the user just granted Accessibility in System Settings), re-query
        // and, if Accessibility is now granted but the tap isn't live, recreate it — no relaunch
        // needed. This activation refresh also keeps the menu bar's permission rows current, though
        // the menu's own `.onAppear` refresh is the primary path there (a status-item click does
        // not activate the app, so this observer alone would miss it).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPermissions() }
        }

        // Start the Sparkle updater (scheduled checks per Info.plist SUEnableAutomaticChecks); the
        // menu re-renders to show "Update to X…" when one is found. Without this the bundled
        // framework + feed URL do nothing — no checks, no menu item (the gap that made 1.0/1.0.1
        // never actually self-update). Skipped on dev builds, which strip the feed URL.
        if UpdaterController.isEnabled {
            let updater = UpdaterController.shared
            updater.onUpdateStateChange = { [weak self] in
                self?.menuModel.availableUpdateVersion = UpdaterController.shared.availableUpdateVersion
            }
            self.updater = updater
        }

        Logger.log("App", "App launched")
        Logger.log("App", "Polish provider: \(config.polishServerConfig.api), Summarization provider: \(config.summarizationServerConfig.api)")

        // Gate the main window on onboarding: show Welcome (and NOT the main window) when
        // onboarding_version is stale relative to the current onboarding. Otherwise open the
        // main window directly. (The support dir is always ready, so there's no "not configured
        // yet" case to check anymore.)
        if needsOnboarding {
            Logger.log("App", "Onboarding required — opening Welcome")
            WindowRouter.shared.openWelcome()
        } else {
            WindowRouter.shared.open(id: WindowID.main)
        }
    }

    /// Re-query permissions into the shared store and heal the hotkey tap when Accessibility is
    /// granted but the tap isn't live (it was granted in System Settings after launch, so the
    /// launch-time `GlobalHotKey.start()` couldn't create it). Called on every app reactivation.
    private func syncPermissions() {
        permissionStore.refresh()
        GlobalHotKey.shared.restartIfNeeded(accessibilityGranted: permissionStore.accessibility)
    }

    /// Reopen (Dock click / relaunch) with no visible windows: open the main window — the
    /// support dir is always ready, so there's no onboarding gate to resume here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WindowRouter.shared.open(id: WindowID.main)
        return true
    }

    /// Guards ⌘Q / the menu-bar Quit against silently destroying in-flight work. Two cases, each
    /// seen through its own self-clearing weak static (see the pointed-to doc comments):
    /// - A finished-but-unsaved import (`ImportSession.activeSession`): `WizardCloseGuard`
    ///   (ImportWizardView.swift) already confirms on window close, but quitting terminates the
    ///   app directly without going through a window close first — same alert, same choice.
    /// - The Notes destination picker mid-`save()` (`NotesDestinationPickerViewModel.
    ///   activePicker`): a `createFolder` may have reached Notes with the config write still
    ///   pending; quitting then orphans the new folder, so confirm first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Fall through rather than early-return so that (in the unlikely both-at-once case) each
        // pending piece of work gets its own confirmation before the app is allowed to quit.
        if NotesDestinationPickerViewModel.activePicker?.isSaving == true,
           !confirmQuitDuringNotesSetupSave() {
            return .terminateCancel
        }
        // A meeting recording in progress happens BEFORE any ImportSession step change (there's
        // no session yet — the WAV isn't handed off until Stop), so `ImportSession.
        // activeSession`/`hasUnsavedFinishedWork` below never sees it; this is its own guard.
        if meetingCoordinator.isActive, !confirmQuitDuringMeetingRecording() {
            return .terminateCancel
        }
        guard ImportSession.activeSession?.hasUnsavedFinishedWork == true else { return .terminateNow }
        return confirmDiscardUnsavedImport() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting mid-recording is already confirmed by this point (applicationShouldTerminate)
        // — tear down any live Core Audio tap/aggregate device so it doesn't leak past exit.
        meetingCoordinator.forceStopForQuit()
        GlobalHotKey.shared.stop()
        ModelServer.shared.stopHealthCheck()
        Logger.log("App", "App terminated")
    }
}
