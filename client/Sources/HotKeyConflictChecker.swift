import AppKit
import Carbon

/// System-level symbolic hot key conflict detection
///
/// Uses Carbon `CopySymbolicHotKeys()` to query all system shortcuts currently
/// enabled in macOS (Spotlight, Mission Control, app switching, etc.). This is
/// the standard approach used by libraries like MASShortcut / Karabiner-Elements —
/// dynamically query current system state instead of hardcoding.
///
/// Note: modifier-only hotkeys (e.g. Right Option) are outside the scope of
/// symbolic hot keys and are not checked.
enum HotKeyConflictChecker {

    /// Checks whether the given HotKeyConfig conflicts with any currently enabled system shortcut
    static func isConflicting(_ config: HotKeyConfig) -> Bool {
        if config.isModifierOnly { return false }

        var unmanaged: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanaged)
        guard status == noErr,
              let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        let userMods = config.deviceIndependentModifiers
        let userKeyCode = Int(config.keyCode)

        // Field names follow the plist convention; Carbon's public constants are no longer exposed in newer SDKs
        for entry in array {
            guard let enabled = entry["enabled"] as? Bool, enabled,
                  let value = entry["value"] as? [String: Any],
                  let sysKeyCode = value["v_kCode"] as? Int,
                  let carbonMods = value["v_modifiers"] as? Int else {
                continue
            }

            let sysMods = nsModifierFlags(fromCarbon: carbonMods)
            if sysKeyCode == userKeyCode && sysMods == userMods {
                return true
            }
        }
        return false
    }

    /// Carbon modifier bits → NSEvent.ModifierFlags (device-independent portion)
    /// Carbon: cmdKey=1<<8, shiftKey=1<<9, alphaLock=1<<10, optionKey=1<<11, controlKey=1<<12
    private static func nsModifierFlags(fromCarbon carbon: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if (carbon & cmdKey) != 0     { flags.insert(.command) }
        if (carbon & shiftKey) != 0   { flags.insert(.shift) }
        if (carbon & optionKey) != 0  { flags.insert(.option) }
        if (carbon & controlKey) != 0 { flags.insert(.control) }
        if (carbon & alphaLock) != 0  { flags.insert(.capsLock) }
        return flags.intersection(.deviceIndependentFlagsMask)
    }
}
