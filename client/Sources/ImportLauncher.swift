import Foundation

/// Cross-scene bridge so app-level menu commands (File ▸ New Import… / Open Audio File…) — and
/// `MeetingCoordinator`'s Stop Meeting hand-off / gate-blocked path — can drive the main window's
/// import wizard.
///
/// SwiftUI `.commands` (and `MeetingCoordinator`, an `AppDelegate`-owned singleton independent of
/// any window) live outside `MeetingsRootView`, so they can't call the view's `startImport(_:)`
/// directly. Instead they store a pending request and bump `requestToken`; `MeetingsRootView`
/// DRAINS the request via `consume()`.
///
/// Draining happens from BOTH `.onChange(of: requestToken)` AND `.onAppear`, because
/// `WindowRouter.open` / `openWindow` does NOT synchronously mount `MeetingsRootView`: if the
/// main window was never opened this session, the token is bumped before any `.onChange`
/// subscriber exists, so the request would be lost. `.onAppear` on the freshly-mounted view
/// catches exactly that case. `consume()` is read-and-clear, so the two call sites both firing
/// for a single request can't double-import — whichever runs first takes it, the other sees nil.
///
/// Callers MUST still open the main window (`WindowRouter.shared.open(id: WindowID.main)`) BEFORE
/// enqueuing, so a fresh window's `.onAppear` runs after the request is already pending.
@MainActor
@Observable
final class ImportLauncher {
    static let shared = ImportLauncher()

    /// What the main window should do next. Read-and-cleared by `consume()`.
    enum PendingRequest {
        /// File ▸ New Import… / Open Audio File… / drag-in: pre-fill Step 1 with this file (nil =
        /// empty New Import).
        case importFile(URL?)
        /// `MeetingCoordinator`'s Stop Meeting hand-off: the two finished live-capture WAVs
        /// (system required, mic best-effort — nil when the mic was denied/failed/silent) — skip
        /// Step 1 and go straight to
        /// `ImportSession.beginLiveMeeting(micFileURL:systemFileURL:)`.
        case liveMeeting(micFileURL: URL?, systemFileURL: URL)
        /// `MeetingCoordinator`'s pre-record gate failed (Notes not set up / Automation not
        /// granted): open a fresh session and run `begin()` so the wizard's `.blocked` step
        /// renders its "why + how to fix" guidance instead of a blank Step 1.
        case meetingBlocked
    }

    /// Bumped on each request; `MeetingsRootView` watches this to drain (in addition to draining
    /// on appear).
    private(set) var requestToken = 0
    private var pending: PendingRequest?

    private init() {}

    /// File-menu / drag-in import (nil = empty New Import).
    func requestNew(file: URL?) {
        pending = .importFile(file)
        requestToken += 1
    }

    /// `MeetingCoordinator`'s Stop Meeting hand-off — see the type doc for the required
    /// open-window-first ordering.
    func requestLiveMeeting(micFileURL: URL?, systemFileURL: URL) {
        pending = .liveMeeting(micFileURL: micFileURL, systemFileURL: systemFileURL)
        requestToken += 1
    }

    /// `MeetingCoordinator`'s pre-record gate-failed path — surface the `.blocked` wizard step.
    func requestMeetingBlocked() {
        pending = .meetingBlocked
        requestToken += 1
    }

    /// Atomically take-and-clear the pending request. Returns nil if there's nothing pending (or
    /// it was already drained by the other call site). Idempotent by construction — the clear is
    /// what makes drain-on-appear + drain-on-change safe to both fire for one request.
    func consume() -> PendingRequest? {
        defer { pending = nil }
        return pending
    }
}
