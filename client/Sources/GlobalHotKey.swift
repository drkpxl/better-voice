import Cocoa
import CoreGraphics

/// Global hotkey
///
/// Uses CGEventTap instead of NSEvent monitor to avoid the Swift actor runtime
/// crash (Bus error) in AppKit's GlobalObserverHandler on macOS 26.
///
/// Each binding supports two modes:
/// 1. modifier-only (e.g. Right Option pressed alone) -- listens for flagsChanged, matches modifier keyCode
/// 2. key combination (e.g. Cmd+Shift+R) -- listens for keyDown, matches keyCode + modifiers
///
/// ONE CGEventTap, TWO independent bindings, sharing the same callback/mask:
/// - **Dictation** (`currentConfig` / `onPress` / `onRelease`) is a toggle fired from
///   `VoiceModule.onHotKeyDown` (idle -> recording -> stopAndProcess) — `onPress`/`onRelease` are
///   named for the physical key edges, not push-to-talk semantics; `onHotKeyUp` is a no-op today.
///   Modifier-only fires on the RELEASE edge (v1's edge, so one tap = one toggle); key-combo mode
///   fires on keyDown only (no keyUp tracking — release is irrelevant to a toggle). This is the
///   ORIGINAL behavior, unchanged by the second binding below.
/// - **Meeting** (`currentMeetingConfig` / `onMeetingFire`) is also a toggle
///   (`MeetingCoordinator.toggleMeeting()`), fired EXACTLY ONCE per physical press regardless of
///   mode: modifier-only fires on the PRESS edge (not release — release is ignored outright, see
///   `handleMeetingFlags`); key-combo mode fires on the first (non-autorepeat) keyDown and ignores
///   every repeat keyDown the OS sends while the key is held (`isAutorepeat` from
///   `.keyboardEventAutorepeat`), so holding the combo doesn't rapid-fire start/stop.
///
/// The two bindings are matched independently against every flagsChanged/keyDown event (by
/// keyCode + modifier bits), so they can be set to different keys/modifiers freely; setting them
/// to the SAME binding is caught earlier, in Settings (`HotKeySettingsViewModel`), not here.
final class GlobalHotKey: @unchecked Sendable {
    @MainActor static let shared = GlobalHotKey()

    nonisolated(unsafe) var onPress: (() -> Void)?
    nonisolated(unsafe) var onRelease: (() -> Void)?
    /// Meeting binding's callback — see the class doc comment above for its fire-once-per-press,
    /// release-ignored semantics.
    nonisolated(unsafe) var onMeetingFire: (() -> Void)?

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// Modifier-only press-state for the dictation binding.
    private nonisolated(unsafe) var isPressed = false
    /// Modifier-only press-state for the meeting binding (independent of `isPressed` above).
    private nonisolated(unsafe) var isMeetingPressed = false
    /// Set when another key is pressed while a modifier-only DICTATION hotkey is held, marking the
    /// hold as a combo gesture (e.g. Right Option + M for the meeting binding) rather than a clean
    /// modifier tap — so the dictation release-fire is suppressed and the two bindings don't
    /// cross-fire when they share a modifier.
    private nonisolated(unsafe) var dictationModifierConsumed = false
    /// Armed when a *combo* dictation hotkey's key-combination is pressed; the toggle fires on the
    /// following modifier RELEASE (not on key-down), so by the time we toggle → transcribe →
    /// synthesize ⌘V the keyboard is quiescent and a still-held modifier can't corrupt the paste
    /// into ⌘⌥V. Reproduces the modifier-only hotkey's fire-on-release edge for combos.
    private nonisolated(unsafe) var dictationComboArmed = false

    /// Periodically checks whether the CGEventTap is still enabled, and re-enables it automatically if disabled.
    /// On macOS 26, a CGEventTap running for a long time (hours to days) can be silently disabled,
    /// and the .tapDisabledByTimeout/.tapDisabledByUserInput callback sometimes doesn't fire (because the
    /// callback itself has been disabled), so an external active ping is needed.
    private var healthTimer: Timer?

    /// The currently active dictation config (nonisolated because the callback reads it from a non-actor context)
    fileprivate nonisolated(unsafe) var currentConfig: HotKeyConfig = .default
    /// The currently active meeting config (nonisolated for the same reason as `currentConfig`)
    fileprivate nonisolated(unsafe) var currentMeetingConfig: HotKeyConfig = .meetingDefault

    @MainActor
    func start() {
        // Read both bindings from config at startup. The meeting binding falls back to
        // `.meetingDefault` (not `.default`) so an install that predates it — no `meeting_hotkey`
        // section in UserDefaults yet — gets Option+M instead of colliding with dictation.
        let dict = RuntimeConfig.shared.hotKeyConfig
        currentConfig = HotKeyConfig.load(from: dict)
        Logger.log("HotKey", "Loaded dictation hotkey: \(currentConfig.displayName) (keyCode=\(currentConfig.keyCode), modifierOnly=\(currentConfig.isModifierOnly))")

        let meetingDict = RuntimeConfig.shared.meetingHotKeyConfig
        currentMeetingConfig = HotKeyConfig.load(from: meetingDict, fallback: .meetingDefault)
        Logger.log("HotKey", "Loaded meeting hotkey: \(currentMeetingConfig.displayName) (keyCode=\(currentMeetingConfig.keyCode), modifierOnly=\(currentMeetingConfig.isModifierOnly))")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        // Active tap (NOT `.listenOnly`) so the callback can SWALLOW a matched combo key-down by
        // returning nil. A combo like ⌥. or ⌥M emits a printable character (≥ / µ); without
        // consuming the key-down that character would leak into the focused field alongside the
        // dictation. (Modifier-only bindings emit no character, so listen-only sufficed before the
        // default became a printable combo.)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalHotKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.log("HotKey", "Failed to create CGEventTap (active tap needs Accessibility: System Settings → Privacy & Security → Accessibility)")
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

    /// Re-create the tap after Accessibility is granted post-launch (the active `.defaultTap` is
    /// gated on Accessibility — see `PermissionManager`'s header). The tap is created once at
    /// `start()`; if Accessibility wasn't granted then, `CGEvent.tapCreate` returns nil and the
    /// hotkey is dead until this runs. Every permission-refresh path calls `restartIfNeeded` the
    /// instant the grant is visible, so the hotkey works without quitting and relaunching the app.
    @MainActor
    func restart() {
        stop()
        start()
    }

    /// Level-based self-heal, safe to call from every permission-refresh path (app activation,
    /// menu open, onboarding poll): if Accessibility is granted but the tap isn't live (it was
    /// granted in System Settings after `start()` failed at launch), re-create it. Level-based
    /// rather than edge-based on purpose — the shared `PermissionStore` has several refreshers, and
    /// whichever one happens to observe the grant first must not be the only one that can heal.
    @MainActor
    func restartIfNeeded(accessibilityGranted: Bool) {
        guard accessibilityGranted, !isHealthy else { return }
        Logger.log("HotKey", "Accessibility granted but tap not live — restarting tap")
        restart()
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

    /// Hot-reload the dictation config (called after saving settings).
    @MainActor
    func reload(config: HotKeyConfig) {
        currentConfig = config
        isPressed = false  // Prevent residual pressed state from leaking across config switches
        dictationComboArmed = false  // drop any pending combo arm so it can't fire against the new binding
        Logger.log("HotKey", "Dictation hotkey reloaded: \(config.displayName) (keyCode=\(config.keyCode), modifierOnly=\(config.isModifierOnly))")
    }

    /// Hot-reload the meeting config (called after saving settings). Companion to `reload(config:)`.
    @MainActor
    func reloadMeeting(config: HotKeyConfig) {
        currentMeetingConfig = config
        isMeetingPressed = false  // Prevent residual pressed state from leaking across config switches
        Logger.log("HotKey", "Meeting hotkey reloaded: \(config.displayName) (keyCode=\(config.keyCode), modifierOnly=\(config.isModifierOnly))")
    }

    /// True when `flags` carries exactly `cfg`'s device-independent modifier bits — shared by
    /// both bindings' key-combination matching.
    private func modifiersMatch(_ cfg: HotKeyConfig, _ flags: CGEventFlags) -> Bool {
        let cfgMods = cfg.deviceIndependentModifiers
        let evtMods = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        return cfgMods == evtMods
    }

    /// Returns true when this key-down matched a combo binding and the callback should SWALLOW it
    /// (return nil) so its printable character (≥ for ⌥., µ for ⌥M) doesn't leak into the field.
    fileprivate func handleKeyDown(keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool) -> Bool {
        // Any key pressed while a modifier-only dictation hotkey is held makes this a combo
        // gesture, not a clean tap — suppress the eventual release-fire so, e.g., Right Option + M
        // (the meeting binding) doesn't also toggle a Right-Option dictation hotkey on release.
        if currentConfig.isModifierOnly, isPressed {
            dictationModifierConsumed = true
        }
        // Evaluate BOTH (side effects: arm/fire) — `||` would short-circuit the meeting check.
        let consumedDictation = handleDictationKeyDown(keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        let consumedMeeting = handleMeetingKeyDown(keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        return consumedDictation || consumedMeeting
    }

    /// True when `flags`+`keyCode` match `cfg`'s key-combination (only meaningful for combo bindings).
    private func comboMatches(_ cfg: HotKeyConfig, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard !cfg.isModifierOnly else { return false }
        guard Int64(cfg.keyCode) == keyCode else { return false }
        return modifiersMatch(cfg, flags)
    }

    /// Dictation's key-combination path. ARMS the toggle on key-down but does NOT fire here — the
    /// toggle fires on the following modifier release (see `handleDictationComboRelease`). Firing on
    /// release reproduces the modifier-only hotkey's guarantee that the keyboard is quiescent before
    /// we toggle → transcribe → synthesize ⌘V, so a still-held Option can't corrupt the paste into
    /// ⌘⌥V. Autorepeat keyDowns (the OS resends keyDown while a key is held) don't re-arm, but a
    /// matched combo is always CONSUMED (return true) — including autorepeats — so no character (or
    /// a stream of them while held) leaks. Returns true when the key-down matched and was consumed.
    private func handleDictationKeyDown(keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool) -> Bool {
        let cfg = currentConfig
        guard comboMatches(cfg, keyCode: keyCode, flags: flags) else { return false }
        if !isAutorepeat {
            dictationComboArmed = true
            Logger.log("HotKey", "\(cfg.displayName) DOWN (armed — fires on release)")
        }
        return true
    }

    /// Meeting's key-combination path — fires `onMeetingFire` once per physical press. Autorepeat
    /// keyDown events (the OS resends keyDown while a key is held) don't re-fire, but a matched combo
    /// is always CONSUMED (return true) so its character doesn't leak; release is never observed in
    /// key-combination mode (the tap doesn't listen for keyUp), which is fine since the meeting
    /// binding ignores release entirely anyway. Returns true when the key-down matched and was consumed.
    private func handleMeetingKeyDown(keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool) -> Bool {
        let cfg = currentMeetingConfig
        guard comboMatches(cfg, keyCode: keyCode, flags: flags) else { return false }
        if !isAutorepeat {
            Logger.log("HotKey", "\(cfg.displayName) MEETING FIRE")
            if let onMeetingFire {
                DispatchQueue.main.async { onMeetingFire() }
            }
        }
        return true
    }

    fileprivate func handleFlags(_ flags: CGEventFlags, keyCode: Int64) {
        handleDictationFlags(flags, keyCode: keyCode)
        handleDictationComboRelease(flags)
        handleMeetingFlags(flags, keyCode: keyCode)
    }

    /// Dictation's key-combination RELEASE path. A combo hotkey (e.g. ⌥.) arms on key-down
    /// (`handleDictationKeyDown`) and fires the toggle here, once its required modifier is released.
    /// By deferring the fire to the release edge, the toggle → transcription → synthesized ⌘V runs
    /// with the keyboard quiescent, so a still-held Option can't reinterpret the paste as ⌘⌥V (which
    /// terminals in particular do, reading live modifier state). Reproduces the modifier-only
    /// hotkey's fire-on-release reliability for combos.
    private func handleDictationComboRelease(_ flags: CGEventFlags) {
        let cfg = currentConfig
        guard !cfg.isModifierOnly, dictationComboArmed else { return }
        // Fire only once a REQUIRED modifier is no longer held. Superset check (not exact match) so
        // that pressing an *extra* modifier while armed doesn't fire early — only releasing one of
        // the combo's own modifiers does.
        let required = cfg.deviceIndependentModifiers
        let current = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        guard !current.isSuperset(of: required) else { return }

        dictationComboArmed = false
        Logger.log("HotKey", "\(cfg.displayName) UP (combo release — fire)")
        if let onPress {
            DispatchQueue.main.async { onPress() }
        }
    }

    /// Dictation's modifier-only path — UNCHANGED from before the meeting binding existed.
    private func handleDictationFlags(_ flags: CGEventFlags, keyCode: Int64) {
        let cfg = currentConfig
        guard cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        let modDown = isModifierDown(for: cfg.keyCode, in: flags)

        if modDown && !isPressed {
            isPressed = true
            dictationModifierConsumed = false   // fresh hold — clean until another key is pressed
            // Fire on RELEASE, not press — matches v1's edge so a single tap of the
            // modifier maps to exactly one toggle.
        } else if !modDown && isPressed {
            isPressed = false
            // A combo gesture consumed this hold (another key was pressed) — not a clean tap, so
            // don't fire dictation. Prevents cross-fire with a combo binding sharing this modifier.
            if dictationModifierConsumed {
                dictationModifierConsumed = false
                return
            }
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

    /// Meeting's modifier-only path — fires `onMeetingFire` once on the PRESS edge (not release:
    /// unlike dictation above, the meeting binding is a pure fire-once toggle, so there's no
    /// second callback to pair with a release edge — see the class doc comment).
    private func handleMeetingFlags(_ flags: CGEventFlags, keyCode: Int64) {
        let cfg = currentMeetingConfig
        guard cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        let modDown = isModifierDown(for: cfg.keyCode, in: flags)

        if modDown && !isMeetingPressed {
            isMeetingPressed = true
            Logger.log("HotKey", "\(cfg.displayName) MEETING FIRE")
            if let onMeetingFire {
                DispatchQueue.main.async { onMeetingFire() }
            }
        } else if !modDown && isMeetingPressed {
            isMeetingPressed = false
            // Release intentionally ignored — see doc comment above.
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
        // Swallow a matched combo key-down (return nil) so its printable character (≥ for ⌥.,
        // µ for ⌥M) never reaches the focused field.
        if hotkey.handleKeyDown(keyCode: keyCode, flags: event.flags, isAutorepeat: isAutorepeat) {
            return nil
        }
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
