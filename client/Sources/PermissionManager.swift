import AppKit
import AVFoundation
import IOKit.hid

/// 权限检查与引导
/// - Accessibility：用于 TextInjector (AX API) 和 ScreenContextProvider (焦点位置)
/// - **Input Monitoring**：CGEventTap 监听全局键盘事件的真实权限（macOS 10.15+ 必须）
///   ⚠️ 不是 Accessibility。CGEventTap 能"创建成功"但不收事件 = Input Monitoring 缺失。
/// - Microphone：用于语音录制
/// - Screen Capture：用于 G3 屏幕上下文感知
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

    /// 检查 Input Monitoring（全局键盘监听）权限。
    /// 这是 CGEventTap 真正需要的权限——Accessibility 给了也没用，不收事件。
    /// 首次未授权时会弹系统对话框（IOHIDRequestAccess 异步）。
    @discardableResult
    static func checkInputMonitoring() -> Bool {
        let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !granted {
            Logger.log("Permission", "Input Monitoring not granted — CGEventTap will not receive key events. Requesting...")
            // 异步弹系统对话框
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            Logger.log("Permission", "Input Monitoring: OK")
        }
        return granted
    }

    // MARK: - 状态栏轮询用 — 纯查询，不弹对话框

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

    /// 请求屏幕录制权限（G3 需要）
    /// CGRequestScreenCaptureAccess() 会把 app 加入系统设置的屏幕录制列表
    /// 用户需要手动开启后重启 app 才生效
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
