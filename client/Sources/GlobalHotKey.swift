import Cocoa
import CoreGraphics

/// Global hotkey
///
/// Uses CGEventTap instead of NSEvent monitor to avoid the Swift actor runtime
/// crash (Bus error) in AppKit's GlobalObserverHandler on macOS 26.
///
/// Supports two modes:
/// 1. modifier-only (e.g. Right Option pressed alone) -- listens for flagsChanged, matches modifier keyCode
/// 2. key combination (e.g. Cmd+Shift+R) -- listens for keyDown, matches keyCode + modifiers
final class GlobalHotKey: @unchecked Sendable {
    @MainActor static let shared = GlobalHotKey()

    nonisolated(unsafe) var onPress: (() -> Void)?
    nonisolated(unsafe) var onRelease: (() -> Void)?
    /// Fired on Right Option+M (meeting start/stop). Tracked independently of the dictation
    /// config so the combo keeps working if dictation is rebound.
    nonisolated(unsafe) var onMeetingToggle: (() -> Void)?

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var isPressed = false
    /// Right Option is held (keyCode 61). Part of the meeting combo.
    private nonisolated(unsafe) var rightOptionDown = false
    /// A regular key was pressed while the modifier-only dictation key was held, so the
    /// hold was a combo (e.g. Right Option+M) — don't toggle dictation on release.
    private nonisolated(unsafe) var dictationSuppressed = false

    /// Meeting combo: Right Option + M. ponytail: hardcoded; add a hotkey.meeting config key if rebinding is ever requested.
    private static let meetingKeyCode: Int64 = 46  // M

    /// Periodically checks whether the CGEventTap is still enabled, and re-enables it automatically if disabled.
    /// On macOS 26, a CGEventTap running for a long time (hours to days) can be silently disabled,
    /// and the .tapDisabledByTimeout/.tapDisabledByUserInput callback sometimes doesn't fire (because the
    /// callback itself has been disabled), so an external active ping is needed.
    private var healthTimer: Timer?

    /// The currently active config (nonisolated because the callback reads it from a non-actor context)
    fileprivate nonisolated(unsafe) var currentConfig: HotKeyConfig = .default

    @MainActor
    func start() {
        // Read from config at startup
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

    /// Checks every 30 seconds whether the tap is still enabled; if disabled, proactively re-enables it and logs.
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

    /// Lets the status bar menu query in real time whether the CGEventTap is healthy (enabled + process can receive events).
    @MainActor
    var isHealthy: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Hot-reload config (called after saving settings)
    @MainActor
    func reload(config: HotKeyConfig) {
        currentConfig = config
        isPressed = false  // Prevent residual pressed state from leaking across config switches
        dictationSuppressed = false
        Logger.log("HotKey", "Hotkey reloaded: \(config.displayName) (keyCode=\(config.keyCode), modifierOnly=\(config.isModifierOnly))")
    }

    fileprivate func handleKeyDown(keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool) {
        // Any regular key during a modifier-only hold makes it a combo: suppress the
        // dictation toggle that would otherwise fire when the modifier is released.
        if isPressed { dictationSuppressed = true }

        // Meeting combo: Right Option + M
        if rightOptionDown && keyCode == Self.meetingKeyCode {
            if !isAutorepeat {
                Logger.log("HotKey", "Right Option+M DOWN (meeting toggle)")
                if let onMeetingToggle {
                    DispatchQueue.main.async { onMeetingToggle() }
                }
            }
            return
        }

        // Only handle keyDown in key-combination mode
        let cfg = currentConfig
        guard !cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        // Compare modifier bits (device-independent part)
        let cfgMods = cfg.deviceIndependentModifiers
        let evtMods = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        guard cfgMods == evtMods else { return }

        Logger.log("HotKey", "\(cfg.displayName) DOWN")
        if let onPress {
            DispatchQueue.main.async { onPress() }
        }
        // In key-combination mode, release usually doesn't matter (toggle semantics only look at down), so onRelease is not triggered separately
    }

    fileprivate func handleFlags(_ flags: CGEventFlags, keyCode: Int64) {
        // Track the Right Option hold for the meeting combo regardless of dictation config.
        if keyCode == 61 {
            rightOptionDown = flags.contains(.maskAlternate)
        }

        let cfg = currentConfig
        guard cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        let modDown = isModifierDown(for: cfg.keyCode, in: flags)

        if modDown && !isPressed {
            isPressed = true
            dictationSuppressed = false
            // Fire on RELEASE, not press: a combo key pressed during the hold
            // (e.g. Right Option+M -> meeting) must not also toggle dictation.
        } else if !modDown && isPressed {
            isPressed = false
            if dictationSuppressed { return }
            Logger.log("HotKey", "\(cfg.displayName) DOWN")
            if let onPress {
                DispatchQueue.main.async { onPress() }
            }
            Logger.log("HotKey", "\(cfg.displayName) UP")
            if let onRelease {
                DispatchQueue.main.async { onRelease() }
            }
        }
    }

    /// Given a modifier keyCode, returns whether it is pressed in CGEventFlags
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

/// Pure C callback, does not go through any Swift concurrency path
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
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        hotkey.handleKeyDown(keyCode: keyCode, flags: event.flags, isAutorepeat: isAutorepeat)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
