import AppKit
import AVFoundation
import CoreServices

/// Permission checks and prompting
/// - **Accessibility**: gates BOTH the global hotkey and typing at the cursor. The hotkey is an
///   ACTIVE `CGEventTap` (`.defaultTap` — it swallows matched combo key-downs), and macOS gates
///   active taps on Accessibility; `TextInjector`'s AX API needs the same grant. (Older comments
///   here claimed CGEventTap needed Input Monitoring — that was true of the LISTEN-ONLY tap the app
///   used before combo hotkeys forced `.defaultTap`. The app no longer uses Input Monitoring at
///   all, which is why its Settings pane read "No Items".)
/// - Microphone: used for voice recording
/// - **Automation**: needed to send Apple events to Apple Notes (`NotesScript`) to save meetings.
///   Requested just-in-time at the meeting/import gates, not during onboarding.
/// - **System Audio Recording** (`kTCCServiceAudioCapture`): needed by `SystemAudioCapturer`'s Core
///   Audio process tap to record a meeting's system audio. Deliberately has NO check/request
///   functions here — see `PermissionKind.systemAudio`'s doc comment for why.
enum PermissionManager {
    static func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            Logger.log("Permission", "Accessibility not granted, prompting...")
            let prompt = "AXTrustedCheckOptionPrompt" as CFString
            let options = [prompt: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return trusted
    }

    // MARK: - For status bar polling — pure query, no dialog prompt

    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func checkMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            // Once denied, requestAccess is a silent no-op — the pane is the only way back, so
            // open it, otherwise the caller's "Grant" button looks dead.
            Logger.log("Permission", "Microphone denied — opening System Settings")
            openSettings(for: .microphone)
            return false
        }
    }

    /// Pure query: can we send Apple events to Apple Notes without prompting the user?
    /// Maps `noErr` → granted; `errAEEventNotPermitted` (-1743) and anything else → not granted.
    static func isAutomationGranted() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false
        )
        return status == noErr
    }

    /// Triggers the Automation TCC prompt (if not already determined) and returns the result.
    @discardableResult
    static func requestAutomation() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, true
        )
        if status != noErr {
            Logger.log("Permission", "Automation (Apple Notes) not granted, status \(status)")
        }
        return status == noErr
    }

    // MARK: - System Settings deep links

    /// Opens the relevant Privacy & Security pane in System Settings for the given permission.
    /// Single source of the `x-apple.systempreferences:` URLs, shared by the menu and onboarding.
    static func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

/// The privacy permissions Better Voice needs for dictation and meeting recording. Provides a
/// single place for the pure-query status and the System Settings deep link of each.
enum PermissionKind: CaseIterable {
    case accessibility
    case microphone
    case automation
    /// "System Audio Recording" (`kTCCServiceAudioCapture`) — consumed by `SystemAudioCapturer`'s
    /// Core Audio process tap when a meeting recording starts. Unlike the other cases, this
    /// one is fundamentally unqueryable/unrequestable — see `isGranted` below.
    case systemAudio

    /// Live granted state (pure query, no prompt) — `nil` where that's not knowable.
    ///
    /// `.systemAudio` always returns `nil`: macOS has **no public API** to query or request the
    /// "System Audio Recording" consent (the private `TCCAccessPreflight`/`TCCAccessRequest` SPI
    /// v1 used is deliberately not reintroduced — notarization/future-OS risk). Worse, a denial
    /// doesn't surface as a query failure or a thrown error: `SystemAudioCapturer.start()` still
    /// returns `noErr` and the tap simply delivers silence (see its doc comment). Returning
    /// `false` here would falsely claim "not granted" for a permission that may well be granted;
    /// returning `true` would hide a real denial behind a fake checkmark. `nil` forces every
    /// caller to render this as "ask again automatically, deep-link to Settings if it's wrong" —
    /// never as a live ✓/⚠ status — which is why `.systemAudio` deliberately does NOT participate
    /// in the `permissionRow(kind:granted:...)` UI the other cases use.
    var isGranted: Bool? {
        switch self {
        case .accessibility: return PermissionManager.isAccessibilityGranted()
        case .microphone: return PermissionManager.isMicrophoneGranted()
        case .automation: return PermissionManager.isAutomationGranted()
        case .systemAudio: return nil
        }
    }

    /// Deep link to the matching Privacy pane in System Settings.
    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .automation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        case .systemAudio:
            // No documented dedicated anchor for kTCCServiceAudioCapture. On current macOS
            // (Sequoia+) Apple merged audio-only capture consent into the same pane as Screen
            // Recording — Apple's own support article is titled "Control access to screen and
            // system audio recording on Mac" and describes one combined "Screen & System Audio
            // Recording" list where apps can be granted "just your audio" — so Privacy_ScreenCapture
            // (the long-documented anchor for that pane) is the closest working deep link, not a
            // generic Privacy & Security root. If a future macOS splits them again, this anchor
            // may need to change; fall back to opening the Privacy & Security root by hand if it
            // ever stops resolving.
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
