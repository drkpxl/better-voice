import AppKit

/// Minimal user-facing notice for infrequent, important failures (summary failed, model too small,
/// dictation paste dropped). The app is a menu-bar (LSUIElement) utility with no notification
/// framework wired up, so we use a lightweight informational `NSAlert` — reliable on a self-signed
/// build, no entitlements or permission prompt. Reserve for events the user must know about;
/// everything routine still goes to `Logger`.
enum Notify {
    @MainActor
    static func warn(_ title: String, _ message: String) {
        Logger.log("Notify", "\(title) — \(message)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("OK"))
        alert.runModal()
    }
}
