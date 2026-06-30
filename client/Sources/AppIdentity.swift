import AppKit

/// Focused application identity information, used for text injection and per-app routing
struct AppIdentity {
    let bundleID: String
    let appName: String
    let processID: pid_t

    /// Get the currently focused application
    @MainActor
    static func current() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(
            bundleID: app.bundleIdentifier ?? "unknown",
            appName: app.localizedName ?? "unknown",
            processID: app.processIdentifier
        )
    }
}
