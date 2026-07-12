import SwiftUI

/// Main-window root: hosts the import wizard. Phase 5 removed the in-app file-based
/// library/editor entirely — Apple Notes is the only meeting store now, so there is nothing
/// left to browse in-app. The window's only job is running one import at a time.
///
/// The `ImportSession` lives as view `@State`: it survives while the window is open. When the
/// wizard finishes (`ImportSession.finish()` — Done / Close on any terminal step), the host
/// replaces it with a brand-new session sitting at a fresh Step 1 (setup), rather than closing
/// the window — keeping the window open for the next import mirrors the old "back to the
/// library, ready for another" flow without a library to land on.
struct MeetingsRootView: View {
    @State private var session = ImportSession()

    var body: some View {
        ImportWizardView(session: session)
            .frame(minWidth: 720, minHeight: 480)
            // File-menu commands (⌘N / ⌘O) request an import via ImportLauncher; drag-in drops a
            // file straight onto the window. Both replace the current session — guarded so an
            // in-flight or not-yet-saved import is never silently discarded.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, canReplaceSession else { return false }
                startImport(url)
                return true
            }
            // Drain any pending ImportLauncher request from BOTH change and appear: `openWindow`
            // doesn't synchronously mount this view, so a request enqueued while the window was
            // closed bumps the token before this `.onChange` subscriber exists — `.onAppear` on
            // the freshly-mounted view is what catches it. `consume()` is read-and-clear, so both
            // firing for one request can't double-import (see ImportLauncher).
            .onChange(of: ImportLauncher.shared.requestToken) { drainPendingRequest() }
            .onAppear {
                configureIfNeeded()
                drainPendingRequest()
            }
    }

    /// Wires the initial session's `onFinish` exactly once (idempotent: a fresh `ImportSession`
    /// always starts with `onFinish == nil`, so this only fires the first time the window
    /// appears for a given session).
    private func configureIfNeeded() {
        guard session.onFinish == nil else { return }
        session.onFinish = { onImportFinished() }
    }

    /// When any import finishes, reset to a fresh session AND re-drain: a live-meeting/import
    /// request that arrived while this import was mid-flight (kept pending, not dropped, by the
    /// `canReplaceSession` guard) is now safe to act on — pick it up instead of stranding it
    /// until the next window re-appear.
    private func onImportFinished() {
        resetSession(fileURL: nil)
        drainPendingRequest()
    }

    /// True while it's safe to throw away the current session's state: nothing has been
    /// processed yet, or the wizard already reached a terminal screen. Mid-flight steps
    /// (transcribing/naming/summarizing) and `.saveFailed` (finished work not yet in Notes)
    /// must never be silently replaced.
    private var canReplaceSession: Bool {
        switch session.step {
        case .setup, .review, .failed, .blocked:
            return true
        case .processing, .naming, .summarizing, .saveFailed:
            return false
        }
    }

    /// Enters a fresh import, single-flight via `canReplaceSession`. `fileURL` pre-fills the
    /// setup step for the drag-and-drop entry point; nil starts empty.
    private func startImport(_ fileURL: URL?) {
        guard canReplaceSession else { return }
        resetSession(fileURL: fileURL)
    }

    /// Take-and-act on whatever `ImportLauncher` has pending. Guarded by `canReplaceSession`
    /// BEFORE consuming, so a request arriving mid-import (unsafe to replace) is left pending —
    /// a later `.onAppear`/drain picks it up rather than silently dropping it. Called from both
    /// `.onChange(of: requestToken)` and `.onAppear` (see the body above).
    private func drainPendingRequest() {
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

    /// Swaps in a brand-new `ImportSession` at Step 1, wired to reset itself again on finish.
    private func resetSession(fileURL: URL?) {
        let fresh = makeFreshSession()
        fresh.fileURL = fileURL
        session = fresh
    }

    /// A brand-new `ImportSession` wired to reset itself again on finish — shared by
    /// `resetSession(fileURL:)` (Step 1 pre-fill) and the live-meeting / blocked drains (which
    /// skip straight past Step 1).
    private func makeFreshSession() -> ImportSession {
        let fresh = ImportSession()
        fresh.onFinish = { onImportFinished() }
        return fresh
    }
}
