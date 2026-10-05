import SwiftUI
import UserNotifications

/// Owns the one import the app runs at a time, independent of any window.
///
/// The session used to live as the main window's `@State`, so closing the window threw away
/// whatever the wizard held — which is why closing had to be guarded with "discard this?" alerts.
/// Held here instead, an import simply carries on in the background when the window closes, and
/// reopening the window shows it exactly where it was. When a backgrounded import finishes or
/// needs the user (naming speakers, a failed Notes save), `ImportHost` posts a notification; the
/// menu bar shows its progress meanwhile.
///
/// When the wizard finishes (`ImportSession.finish()` — Done / Close on any terminal step), the host
/// replaces the session with a fresh one at Step 1.
@MainActor
@Observable
final class ImportHost {
    static let shared = ImportHost()

    private(set) var session: ImportSession

    /// Whether the main window is on screen. Notifications are for a user who isn't looking.
    var isWindowVisible = false

    private init() {
        session = ImportSession()
        session.onFinish = { [weak self] in self?.onImportFinished() }
        session.onStepChange = { [weak self] session, step in self?.stepChanged(session, step) }
    }

    /// True while it's safe to throw away the current session's state: nothing has been
    /// processed yet, or the wizard already reached a terminal screen. Mid-flight steps
    /// (transcribing/naming/summarizing) and `.saveFailed` (finished work not yet in Notes)
    /// must never be silently replaced.
    var canReplaceSession: Bool {
        switch session.step {
        case .setup, .review, .failed, .blocked:
            return true
        case .processing, .naming, .summarizing, .saveFailed:
            return false
        }
    }

    /// Short status for the menu bar while an import is running or waiting on the user; nil when
    /// there's nothing to say.
    var menuStatus: String? {
        switch session.step {
        case .processing:
            return t("Importing meeting… \(Int(session.progress * 100))%")
        case .summarizing:
            return t("Summarizing meeting…")
        case .naming:
            return t("Meeting ready — name the speakers")
        case .saveFailed:
            return t("Meeting not saved to Notes")
        case .setup, .review, .failed, .blocked:
            return nil
        }
    }

    /// Enters a fresh import (drag-and-drop), single-flight via `canReplaceSession`.
    func startImport(_ fileURL: URL?) {
        guard canReplaceSession else { return }
        resetSession(fileURL: fileURL)
    }

    /// Take-and-act on whatever `ImportLauncher` has pending. Guarded by `canReplaceSession`
    /// BEFORE consuming, so a request arriving mid-import (unsafe to replace) is left pending —
    /// picked up when the current import finishes rather than silently dropped.
    func drainPendingRequest() {
        guard canReplaceSession, let request = ImportLauncher.shared.consume() else { return }
        switch request {
        case .importFile(let fileURL):
            resetSession(fileURL: fileURL)
        case .liveMeeting(let micFileURL, let systemFileURL):
            let fresh = makeFreshSession()
            session = fresh
            fresh.beginLiveMeeting(micFileURL: micFileURL, systemFileURL: systemFileURL)
        case .meetingBlocked:
            // Drive a fresh session's begin() so the real gate re-fails and renders `.blocked`
            // with its "Open Notes setup" / "Open Automation Settings" guidance.
            let fresh = makeFreshSession()
            session = fresh
            fresh.begin()
        }
    }

    // MARK: - Private

    /// When any import finishes, reset to a fresh session AND re-drain: a request that arrived
    /// while this import was mid-flight is now safe to act on.
    private func onImportFinished() {
        resetSession(fileURL: nil)
        drainPendingRequest()
    }

    private func resetSession(fileURL: URL?) {
        let fresh = makeFreshSession()
        fresh.fileURL = fileURL
        session = fresh
    }

    private func makeFreshSession() -> ImportSession {
        let fresh = ImportSession()
        fresh.onFinish = { [weak self] in self?.onImportFinished() }
        fresh.onStepChange = { [weak self] session, step in self?.stepChanged(session, step) }
        return fresh
    }

    /// Tell a user who isn't looking that their import is done or waiting on them.
    private func stepChanged(_ changed: ImportSession, _ step: ImportStep) {
        guard !(isWindowVisible && NSApp.isActive) else { return }
        switch step {
        case .review:
            ImportNotifications.post(t("Meeting saved to Notes"), changed.noteTitle ?? t("Your transcript and summary are ready."))
        case .naming:
            ImportNotifications.post(t("Name the speakers"), t("Transcription finished. Confirm who's who to write the summary."))
        case .saveFailed:
            ImportNotifications.post(t("Meeting not saved to Notes"), t("The transcript and summary are kept — open Better Voice to retry or copy them."))
        case .failed(let message):
            ImportNotifications.post(t("Import failed"), message)
        case .setup, .processing, .summarizing, .blocked:
            break
        }
    }
}

/// Local notifications for backgrounded imports. Clicking one opens the main window. Permission is
/// requested the first time one is needed; if it's declined the menu bar status is still there.
@MainActor
enum ImportNotifications {
    private static let delegate = Delegate()

    static func post(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                Logger.log("Import", "Notification not shown (not authorized): \(title)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "import", content: content, trigger: nil))
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            await MainActor.run { WindowRouter.shared.open(id: WindowID.main) }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }
}

/// Main-window root: hosts the import wizard for `ImportHost`'s session. There is no in-app
/// library/editor — Apple Notes is the only meeting store, so the window's only job is the import.
struct MeetingsRootView: View {
    private let host = ImportHost.shared

    var body: some View {
        ImportWizardView(session: host.session)
            .frame(minWidth: 720, minHeight: 480)
            // File-menu commands (⌘N / ⌘O) request an import via ImportLauncher; drag-in drops a
            // file straight onto the window. Both replace the current session — guarded so an
            // in-flight or not-yet-saved import is never silently discarded.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, host.canReplaceSession else { return false }
                host.startImport(url)
                return true
            }
            // Drain any pending ImportLauncher request from BOTH change and appear: `openWindow`
            // doesn't synchronously mount this view, so a request enqueued while the window was
            // closed bumps the token before this `.onChange` subscriber exists — `.onAppear` on
            // the freshly-mounted view is what catches it. `consume()` is read-and-clear, so both
            // firing for one request can't double-import (see ImportLauncher).
            .onChange(of: ImportLauncher.shared.requestToken) { host.drainPendingRequest() }
            .onAppear {
                host.isWindowVisible = true
                host.drainPendingRequest()
            }
            .onDisappear { host.isWindowVisible = false }
    }
}
