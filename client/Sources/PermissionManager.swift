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

    /// Probe the Apple-events-to-Notes permission, optionally firing the consent prompt.
    ///
    /// Always logs the raw `OSStatus`. The previous version collapsed every non-`noErr` code to
    /// "not granted" and logged only on the prompting path, which made the states that matter
    /// indistinguishable in a log: a real denial, an undetermined state that a prompt would resolve,
    /// and Notes simply not running all read as the same failure.
    static func automationStatus(promptIfNeeded: Bool) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        let raw = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, promptIfNeeded
        )
        let status = AutomationStatus(raw)
        if status != .granted {
            Logger.log("Permission", "Automation (Apple Notes): \(status.diagnosis) [status \(raw)]")
        }
        return status
    }

    /// Pure query for display: is automation definitely available right now?
    ///
    /// `.granted` only. Used for ✓/⚠ rows and the "denied" banner, where claiming a grant we do not
    /// have would be worse than under-reporting.
    static func isAutomationGranted() -> Bool {
        automationStatus(promptIfNeeded: false) == .granted
    }

    /// Is automation *definitively* denied — i.e. is System Settings genuinely the way back?
    ///
    /// The question to ask before telling a user to go grant a permission. `!isAutomationGranted()`
    /// is the wrong test for that: it is also true when Notes merely is not running, which would send
    /// someone to an Automation pane to fix nothing.
    static func isAutomationDenied() -> Bool {
        automationStatus(promptIfNeeded: false) == .denied
    }

    /// Whether a Notes write should be **attempted**, prompting first if the state is undetermined.
    ///
    /// Deliberately not the same question as `isAutomationGranted()`. Only a definitive denial
    /// returns false. `.targetNotRunning` (-600) is not a permission state at all — it means the
    /// probe could not see Notes — and blocking on it sent the user to an Automation pane to fix
    /// something that was never broken, while the operation itself would have succeeded: sending an
    /// Apple event to a non-running app launches it, which is exactly what `NotesScript` does. An
    /// indeterminate pre-flight must not veto an operation that can still work; if it genuinely
    /// cannot, `NotesScript` surfaces the real `osascript` failure, which is the better error anyway.
    @discardableResult
    static func automationAllowsAttempt() -> Bool {
        let status = automationStatus(promptIfNeeded: true)
        if status == .denied { return false }
        if status != .granted {
            Logger.log("Permission", "Automation indeterminate (\(status.diagnosis)) — attempting anyway")
        }
        return true
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
/// The distinguishable outcomes of `AEDeterminePermissionToAutomateTarget`.
///
/// These four are not interchangeable and the difference decides what the user should be told:
/// `.denied` means System Settings is the only way back, `.undetermined` means a prompt will resolve
/// it, and `.targetNotRunning` means nothing is wrong with the permission at all. Collapsing them to
/// a `Bool` is what made a `-600` read as "grant this permission" in the logs and the UI.
enum AutomationStatus: Equatable {
    /// `noErr` — Apple events to Notes are permitted.
    case granted
    /// `errAEEventNotPermitted` (-1743) — the user said no. Only System Settings can undo it.
    case denied
    /// `errAEEventWouldRequireUserConsent` (-1744) — undecided; prompting resolves it.
    case undetermined
    /// `procNotFound` (-600) — the probe could not see Notes running. Not a permission state.
    case targetNotRunning
    case other(OSStatus)

    init(_ raw: OSStatus) {
        switch raw {
        case noErr:   self = .granted
        case -1743:   self = .denied
        case -1744:   self = .undetermined
        case -600:    self = .targetNotRunning
        default:      self = .other(raw)
        }
    }

    /// One line naming the state and the action that would resolve it — written for a log reader
    /// trying to answer "is this the user's problem, and which one".
    var diagnosis: String {
        switch self {
        case .granted:          return "granted"
        case .denied:           return "denied by the user — only System Settings → Privacy & Security → Automation can restore it"
        case .undetermined:     return "undetermined — a consent prompt would resolve it"
        case .targetNotRunning: return "Notes not running, so permission is undeterminable — not a denial"
        case .other(let raw):   return "unexpected AE status \(raw)"
        }
    }
}

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
