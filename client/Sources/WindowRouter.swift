import AppKit
import SwiftUI

/// Bridges AppKit call sites to SwiftUI's window actions. `openWindow` is an environment
/// value, unreachable from `AppDelegate` — the `MenuBarExtra` label view (materialized at app
/// launch, unlike menu content) captures it here via `.onAppear`.
///
/// A request that arrives before capture (a startup race against scene setup) is queued and
/// flushed on capture — a menu-bar app must never lose a requested window to a startup race,
/// and must never crash over a missing window action.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindowAction: OpenWindowAction?
    private var pendingWindowIDs: [String] = []

    func capture(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
        let pending = pendingWindowIDs
        pendingWindowIDs = []
        for id in pending {
            open(id: id)
        }
    }

    /// Opens a `Window(id:)` scene, activating the app first (accessory apps lose the
    /// activation race — same reason the old window singletons called `NSApp.activate`).
    func open(id: String) {
        guard let openWindowAction else {
            Logger.log("WindowRouter", "Queued open of '\(id)' (window action not captured yet)")
            pendingWindowIDs.append(id)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction(id: id)
    }

    /// Convenience for the first-launch onboarding scene.
    func openWelcome() { open(id: WindowID.welcome) }
}
