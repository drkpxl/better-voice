import Cocoa
import CoreGraphics

/// 全局热键
///
/// 使用 CGEventTap 替代 NSEvent monitor，避免 macOS 26 下
/// AppKit GlobalObserverHandler 的 Swift actor runtime crash (Bus error)。
///
/// 支持两种模式：
/// 1. modifier-only（如 Right Option 单独按下）—— 监听 flagsChanged，匹配 modifier keyCode
/// 2. 组合键（如 Cmd+Shift+R）—— 监听 keyDown，匹配 keyCode + modifiers
final class GlobalHotKey: @unchecked Sendable {
    @MainActor static let shared = GlobalHotKey()

    nonisolated(unsafe) var onPress: (() -> Void)?
    nonisolated(unsafe) var onRelease: (() -> Void)?

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var isPressed = false

    /// 定期检查 CGEventTap 是否仍 enable，失活自动 re-enable。
    /// macOS 26 上 CGEventTap 长时间运行（数小时到数天）会被静默 disable，
    /// 而 .tapDisabledByTimeout/.tapDisabledByUserInput 回调有时不触发（因为 callback
    /// 本身就被 disable 了），所以需要外部主动 ping。
    private var healthTimer: Timer?

    /// 当前生效的配置（nonisolated 是因为 callback 在非 actor 上下文读它）
    fileprivate nonisolated(unsafe) var currentConfig: HotKeyConfig = .default

    @MainActor
    func start() {
        // 启动时从 config 读
        let dict = RuntimeConfig.shared.hotKeyConfig
        currentConfig = HotKeyConfig.load(from: dict)
        Logger.log("HotKey", "Loaded hotkey: \(currentConfig.displayName) (keyCode=\(currentConfig.keyCode), modifierOnly=\(currentConfig.isModifierOnly))")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: globalHotKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.log("HotKey", "Failed to create CGEventTap (check Input Monitoring permission: System Settings → Privacy → Input Monitoring)")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Logger.log("HotKey", "Global hotkey started (CGEventTap)")

        startHealthMonitor()
    }

    /// 每 30 秒检查一次 tap 是否还 enable；失活则主动 re-enable + 打日志。
    @MainActor
    private func startHealthMonitor() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.log("HotKey", "Re-enabled CGEventTap (was disabled by system)")
            }
        }
    }

    @MainActor
    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// 让状态栏菜单查询 CGEventTap 实时是否健康（启用 + 进程能收到事件）。
    @MainActor
    var isHealthy: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// 热更新配置（保存设置后调用）
    @MainActor
    func reload(config: HotKeyConfig) {
        currentConfig = config
        isPressed = false  // 防止跨配置切换时残留按下状态
        Logger.log("HotKey", "Hotkey reloaded: \(config.displayName) (keyCode=\(config.keyCode), modifierOnly=\(config.isModifierOnly))")
    }

    fileprivate func handleKeyDown(keyCode: Int64, flags: CGEventFlags) {
        // 仅在组合键模式下处理 keyDown
        let cfg = currentConfig
        guard !cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        // 比较 modifier 位（device-independent 部分）
        let cfgMods = cfg.deviceIndependentModifiers
        let evtMods = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        guard cfgMods == evtMods else { return }

        Logger.log("HotKey", "\(cfg.displayName) DOWN")
        if let onPress {
            DispatchQueue.main.async { onPress() }
        }
        // 组合键模式下，松开通常不重要（toggle 语义只看 down），不再额外触发 onRelease
    }

    fileprivate func handleFlags(_ flags: CGEventFlags, keyCode: Int64) {
        let cfg = currentConfig
        guard cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        let modDown = isModifierDown(for: cfg.keyCode, in: flags)

        if modDown && !isPressed {
            isPressed = true
            Logger.log("HotKey", "\(cfg.displayName) DOWN")
            if let onPress {
                DispatchQueue.main.async { onPress() }
            }
        } else if !modDown && isPressed {
            isPressed = false
            Logger.log("HotKey", "\(cfg.displayName) UP")
            if let onRelease {
                DispatchQueue.main.async { onRelease() }
            }
        }
    }

    /// 给定一个 modifier 键码，返回它在 CGEventFlags 里是否被按下
    private func isModifierDown(for keyCode: UInt16, in flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)    // Right/Left Cmd
        case 56, 60: return flags.contains(.maskShift)      // Left/Right Shift
        case 57:     return flags.contains(.maskAlphaShift) // Caps Lock
        case 58, 61: return flags.contains(.maskAlternate)  // Left/Right Option
        case 59, 62: return flags.contains(.maskControl)    // Left/Right Control
        case 63:     return flags.contains(.maskSecondaryFn) // fn
        default:     return false
        }
    }
}

/// 纯 C 回调，不经过任何 Swift concurrency 路径
private func globalHotKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hotkey = Unmanaged<GlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
        hotkey.handleFlags(event.flags, keyCode: keyCode)
    } else if type == .keyDown {
        hotkey.handleKeyDown(keyCode: keyCode, flags: event.flags)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
