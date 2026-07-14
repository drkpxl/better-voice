import AppKit
import SwiftUI
import BetterVoiceCore

/// SwiftUI replacement for the old `StatusBarController`'s NSStatusItem + NSMenu. State lives
/// in `MenuBarModel`; the AppDelegate wires VoiceModule/ModelServer callbacks into it.
///
/// Phase 2 (dictation-only) scope: no meeting/live-capture, no Settings/Welcome scenes, no
/// Sparkle update surface. Those land in later phases.

/// Scene identifiers for `Window(id:)` / `openWindow(id:)`.
enum WindowID {
    static let main = "main"
    static let hotkey = "hotkey"
    static let welcome = "welcome"
    static let personalContext = "personalContext"
    static let vocabulary = "vocabulary"
}

/// Observable state behind the menu-bar label and menu. Written by AppDelegate's wiring
/// (VoiceModule / ModelServer callbacks).
@MainActor
@Observable
final class MenuBarModel {
    var isRecording = false
    /// Dictation is transcribing/polishing (VoiceModule .processing) — drives the "busy"
    /// glyph and the hotkey guard.
    var isProcessing = false
    var serverStatus: ModelServer.Status = ModelServer.shared.status
    /// Display version of an available Sparkle update (set by UpdaterController), or nil. Drives
    /// the "Update to X…" menu item.
    var availableUpdateVersion: String?
}

// MARK: - Label (the status-bar glyph)

/// The status-bar label: brand waveform + a trailing state badge, composited into ONE
/// `NSImage` because `MenuBarExtra` labels are template-rendered — per-view colors are
/// stripped, so the badge color must be baked into the image (`isTemplate = false` while a
/// colored badge is active).
struct MenuBarLabel: View {
    let model: MenuBarModel
    let meetingCoordinator: MeetingCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: statusIcon)
            .accessibilityLabel(t("Better Voice"))
            .onAppear {
                // The label is materialized at app launch (unlike the menu content), which
                // makes it the one reliable place to hand SwiftUI's window actions to AppKit
                // call sites (WindowRouter).
                WindowRouter.shared.capture(openWindow: openWindow)
            }
    }

    /// Priority: meeting recording > dictation recording > busy (processing) > connection status
    /// (matching v1's ordering — a meeting recording is the longer-running, higher-stakes state).
    private var statusIcon: NSImage {
        if meetingCoordinator.isRecording {
            return .menuBarStatusIcon(badge: "●", badgeColor: .systemRed)
        }
        if model.isRecording {
            return .menuBarStatusIcon(badge: "●", badgeColor: .systemRed)
        }
        if model.isProcessing {
            return .menuBarStatusIcon(badge: "⋯", badgeColor: .systemGray)
        }
        switch model.serverStatus {
        case .connected: return .menuBarStatusIcon()
        case .disconnected: return .menuBarStatusIcon(badge: "·")
        case .unknown: return .menuBarStatusIcon(badge: "?")
        }
    }
}

// MARK: - Menu content

/// The menu. Menu-style `MenuBarExtra` re-evaluates this body when the menu opens, which
/// gives a live permission refresh (grant a permission in System Settings, reopen, expect ✓).
struct MenuBarMenu: View {
    let model: MenuBarModel
    let meetingCoordinator: MeetingCoordinator
    /// Single source of truth for permission status (see `PermissionStore`). Reading its
    /// `@Observable` state here is what makes the rows re-render when a permission changes —
    /// the old code read `PermissionKind.isGranted` imperatively, which SwiftUI couldn't track,
    /// so the menu stayed frozen at its launch-time (all "Not authorized") snapshot.
    let permissions: PermissionStore

    /// Live hotkey display strings, shown inline in the menu so the shortcuts are discoverable.
    /// Read as plain text (not `.keyboardShortcut`) so they never register a menu-scoped shortcut
    /// that would double-fire alongside the global CGEventTap when the app is frontmost.
    private var dictationHotkey: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig).displayName
    }
    private var meetingHotkey: String {
        HotKeyConfig.load(from: RuntimeConfig.shared.meetingHotKeyConfig, fallback: .meetingDefault).displayName
    }

    var body: some View {
        Text(t("Better Voice"))
            // Menu-style content is rebuilt each time the menu opens; refresh here so a permission
            // toggled in System Settings while the app was backgrounded is reflected immediately,
            // not only after the next app activation.
            .onAppear { permissions.refresh() }

        Divider()

        // One Accessibility row: it gates BOTH the global hotkey (active CGEventTap) and typing at
        // the cursor. Input Monitoring is intentionally absent — the app never uses that service
        // (its pane read "No Items"); an active keyboard tap is an Accessibility capability.
        permissionRow(t("Global hotkey & text injection"), .accessibility)
        permissionRow(t("Microphone"), .microphone)

        Divider()

        meetingRow

        Divider()

        // Route window opens through WindowRouter so the app activates first — an accessory
        // app's windows otherwise open behind whatever is frontmost.
        Button(t("Open Better Voice")) { WindowRouter.shared.open(id: WindowID.main) }
        Button("\(t("Set Hotkeys…"))   \(dictationHotkey) · \(meetingHotkey)") {
            WindowRouter.shared.open(id: WindowID.hotkey)
        }

        Divider()

        Button(t("Welcome / Setup Guide")) { WindowRouter.shared.open(id: WindowID.welcome) }

        Divider()

        // Sparkle updates (release builds only — dev builds strip the feed URL). The "Update to X…"
        // row only appears once a check has found one; the manual "Check for Updates…" is always
        // available. Both open Sparkle's standard update window (release notes + Install & Relaunch).
        if UpdaterController.isEnabled {
            if let version = model.availableUpdateVersion {
                Button(t("Update to \(version) — Restart to update")) {
                    UpdaterController.shared.checkForUpdates()
                }
            }
            Button(t("Check for Updates…")) { UpdaterController.shared.checkForUpdates() }

            Divider()
        }

        // SettingsLink opens the `Settings` scene (no window id → not routed through
        // WindowRouter; the Settings view activates the app itself on appear).
        SettingsLink { Text(t("Settings…")) }
            .keyboardShortcut(",")

        Button(t("Quit")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Start Meeting Recording" / "Stop Meeting Recording" toggle row. The row stays put (not
    /// hidden — the menu item shouldn't jump around) but is disabled during the transitional
    /// `.starting`/`.stopping` states: Stop is only enabled once the tap is fully live (`canStop`
    /// — a Stop during `.starting` would race `start()`), and Start only from a clean idle
    /// (`canStart`), so a stray click can't double-invoke either.
    @ViewBuilder
    private var meetingRow: some View {
        if meetingCoordinator.isRecording {
            Button("\(t("Stop Meeting Recording"))   \(meetingHotkey)") { meetingCoordinator.stopMeeting() }
                .disabled(!meetingCoordinator.canStop)
        } else {
            Button("\(t("Start Meeting Recording"))   \(meetingHotkey)") { meetingCoordinator.startMeeting() }
                .disabled(!meetingCoordinator.canStart)
        }
    }

    /// Permission status row: granted -> inert info row with ✓; not granted -> ⚠ row that
    /// jumps to the matching System Settings pane. (The old red tint isn't representable in
    /// menu-style SwiftUI content; the ⚠ carries the signal.)
    @ViewBuilder
    private func permissionRow(_ label: String, _ kind: PermissionKind) -> some View {
        // Reads the @Observable `PermissionStore` (never the imperative `PermissionKind.isGranted`)
        // so the row re-renders when the permission changes. `.systemAudio` deliberately has no row.
        if permissions.isGranted(kind) {
            Text("✓ \(t("\(label): \(t("Authorized"))"))")
        } else {
            Button("⚠ \(t("\(label): \(t("Not authorized — click to open Settings"))"))") {
                PermissionManager.openSettings(for: kind)
            }
        }
    }
}

// MARK: - Icon compositing

extension NSImage {
    /// The menu-bar waveform plus an optional trailing badge, composited into one image.
    /// No badge -> the plain template waveform (auto-tints). With a badge the image is
    /// non-template and draws itself: the drawing handler runs at draw time, so
    /// `NSColor.labelColor` still resolves against the current menu-bar appearance;
    /// `badgeColor` nil means "label color" (the un-tinted `·`/`?` badges).
    static func menuBarStatusIcon(badge: String? = nil, badgeColor: NSColor? = nil) -> NSImage {
        guard let badge, !badge.isEmpty else { return menuBarWaveform() }

        let heights: [CGFloat] = [6, 13, 9, 16, 7]
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2.5
        let maxHeight = heights.max() ?? 16
        let waveWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap

        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let text = badge as NSString
        let textWidth = ceil(text.size(withAttributes: [.font: font]).width)
        let pad: CGFloat = 3
        let size = NSSize(width: waveWidth + pad + textWidth, height: maxHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setFill()
            for (i, h) in heights.enumerated() {
                let x = CGFloat(i) * (barWidth + gap)
                let bar = NSRect(x: x, y: 0, width: barWidth, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: badgeColor ?? NSColor.labelColor,
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(x: waveWidth + pad, y: (maxHeight - textSize.height) / 2),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }
}
