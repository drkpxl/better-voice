import AppKit
import AVFoundation
import IOKit.hid

/// Permission checks and prompting
/// - Accessibility: used by TextInjector (AX API)
/// - **Input Monitoring**: the real permission CGEventTap needs to listen for global keyboard events (required on macOS 10.15+)
///   ⚠️ Not Accessibility. CGEventTap can "succeed at creation" but still not receive events = Input Monitoring is missing.
/// - Microphone: used for voice recording
/// - Screen Capture: used for meeting system audio capture (SystemAudioCapturer / ScreenCaptureKit)
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

    /// Check the Input Monitoring (global keyboard listening) permission.
    /// This is the permission CGEventTap actually needs — granting Accessibility alone doesn't help, no events are received.
    /// The first time it's unauthorized, a system dialog will pop up (IOHIDRequestAccess is async).
    @discardableResult
    static func checkInputMonitoring() -> Bool {
        let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !granted {
            Logger.log("Permission", "Input Monitoring not granted — CGEventTap will not receive key events. Requesting...")
            // Async system dialog prompt
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            Logger.log("Permission", "Input Monitoring: OK")
        }
        return granted
    }

    // MARK: - For status bar polling — pure query, no dialog prompt

    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// System-audio recording (Core Audio process tap) authorization.
    /// There is no public preflight for this consent, so we use the private TCC SPI (fine for a
    /// non-App-Store app). Returns false when denied or not-yet-determined.
    static func isSystemAudioGranted() -> Bool {
        TCCPrivate.preflight(kTCCServiceAudioCapture) == 0  // 0 = authorized
    }

    static func checkMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            Logger.log("Permission", "Microphone denied, open System Settings")
            return false
        }
    }

    /// Request System-audio recording permission (needed by meeting system-audio capture, see
    /// SystemAudioCapturer). Shows the macOS consent prompt via the private TCC request SPI; the
    /// prompt also appears automatically the first time a tap is started.
    static func requestSystemAudio(_ completion: @escaping @Sendable (Bool) -> Void) {
        if isSystemAudioGranted() { completion(true); return }
        Logger.log("Permission", "System audio not granted, requesting...")
        TCCPrivate.request(kTCCServiceAudioCapture) { granted in
            Logger.log("Permission", "System audio request result: \(granted)")
            completion(granted)
        }
    }

    // MARK: - System Settings deep links

    /// Opens the relevant Privacy & Security pane in System Settings for the given permission.
    /// Single source of the `x-apple.systempreferences:` URLs, shared by the menu and onboarding.
    static func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

/// The four privacy permissions Better Voice needs. Provides a single place for the
/// pure-query status and the System Settings deep link of each.
enum PermissionKind: CaseIterable {
    case inputMonitoring
    case accessibility
    case microphone
    case systemAudio

    /// Live granted state (pure query, no prompt).
    var isGranted: Bool {
        switch self {
        case .inputMonitoring: return PermissionManager.isInputMonitoringGranted()
        case .accessibility: return PermissionManager.isAccessibilityGranted()
        case .microphone: return PermissionManager.isMicrophoneGranted()
        case .systemAudio: return PermissionManager.isSystemAudioGranted()
        }
    }

    /// Deep link to the matching Privacy pane in System Settings.
    var settingsURL: URL {
        switch self {
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .systemAudio:
            // No dedicated URL anchor for the system-audio pane; open Privacy & Security root.
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        }
    }
}

// MARK: - Private TCC SPI bridge (system-audio recording consent)

/// Minimal bridge to the private TCC framework for the system-audio ("Audio Recording") consent,
/// which has no public preflight/request API. Acceptable here because Better Voice is distributed
/// outside the App Store. Symbols are resolved lazily via dlsym; if unavailable, calls degrade to
/// "unknown"/failure and the tap start still surfaces the OS prompt on first use.
private enum TCCPrivate {
    typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func preflight(_ service: CFString) -> Int {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return 2 }  // 2 = unknown
        return unsafeBitCast(sym, to: PreflightFunc.self)(service, nil)
    }

    static func request(_ service: CFString, _ completion: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        unsafeBitCast(sym, to: RequestFunc.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

private nonisolated(unsafe) let kTCCServiceAudioCapture = "kTCCServiceAudioCapture" as CFString
