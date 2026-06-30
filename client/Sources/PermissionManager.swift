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

    static func isScreenCaptureGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
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

    /// Request Screen Recording permission (needed by meeting system audio capture, see SystemAudioCapturer)
    /// CGRequestScreenCaptureAccess() adds the app to the Screen Recording list in System Settings
    /// The user needs to manually enable it and restart the app for it to take effect
    static func checkScreenCapture() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            Logger.log("Permission", "Screen capture not granted, requesting...")
            CGRequestScreenCaptureAccess()
        } else {
            Logger.log("Permission", "Screen capture: OK")
        }
        return granted
    }
}
