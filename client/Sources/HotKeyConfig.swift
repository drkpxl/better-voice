import AppKit
import CoreGraphics

/// Hotkey configuration
///
/// Two modes:
/// 1. modifier-only (e.g. Right Option pressed alone): keyCode is the modifier keyCode (61 = Right Option, etc.), modifiers is empty
/// 2. key combination (e.g. Cmd+Shift+R): keyCode is a letter/number keyCode, modifiers is the set of modifier flag bits
///
/// Storage format (JSON under the `hotkey` key in RuntimeConfig / UserDefaults):
/// ```json
/// "hotkey": {
///   "keyCode": 61,
///   "modifierFlags": 0,         // NSEvent.ModifierFlags.rawValue
///   "isModifierOnly": true,
///   "displayName": "Right Option"
/// }
/// ```
struct HotKeyConfig: Codable, Equatable, Sendable {
    let keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue (do not store CGEventFlags directly, their bits differ)
    let modifierFlags: UInt
    let isModifierOnly: Bool
    let displayName: String

    /// Dictation hotkey default: Option + Period. A key+modifier combo (not modifier-only) — see
    /// `GlobalHotKey.handleKeyDown`, which already matches combos like Cmd+Shift+R the same way.
    /// `displayName` matches `HotKeyFormatter.displayName(keyCode:47, modifiers:[.option],
    /// isModifierOnly:false)` byte-for-byte (⌥ then the key glyph, no separator).
    static let `default` = HotKeyConfig(
        keyCode: 47,                                       // kVK_ANSI_Period
        modifierFlags: NSEvent.ModifierFlags.option.rawValue, // 0x80000 / 524288
        isModifierOnly: false,
        displayName: "⌥."
    )

    /// Meeting hotkey default: Option + M. Fires `GlobalHotKey.onMeetingFire` once per press (a
    /// toggle via `MeetingCoordinator.toggleMeeting()`), independent of the dictation binding
    /// above — see `GlobalHotKey`'s two-binding doc comment.
    static let meetingDefault = HotKeyConfig(
        keyCode: 46,                                       // kVK_ANSI_M
        modifierFlags: NSEvent.ModifierFlags.option.rawValue, // 0x80000 / 524288
        isModifierOnly: false,
        displayName: "⌥M"
    )

    /// Reads from RuntimeConfig, returns `fallback` on failure (`.default` for the dictation
    /// binding; callers reading the meeting binding pass `.meetingDefault` so an install that
    /// predates the second hotkey — no `meeting_hotkey` section yet — gets Option+M rather than
    /// silently colliding with the dictation binding).
    static func load(from dict: [String: Any], fallback: HotKeyConfig = .default) -> HotKeyConfig {
        guard let keyCode = dict["keyCode"] as? Int else {
            return fallback
        }
        let modifierFlags = (dict["modifierFlags"] as? Int).map { UInt($0) } ?? 0
        let isModifierOnly = dict["isModifierOnly"] as? Bool ?? false
        let displayName = dict["displayName"] as? String ?? "Unknown"
        return HotKeyConfig(
            keyCode: UInt16(keyCode),
            modifierFlags: modifierFlags,
            isModifierOnly: isModifierOnly,
            displayName: displayName
        )
    }

    /// Serializes back to [String: Any] for writing to config
    func toDictionary() -> [String: Any] {
        return [
            "keyCode": Int(keyCode),
            "modifierFlags": Int(modifierFlags),
            "isModifierOnly": isModifierOnly,
            "displayName": displayName
        ]
    }

    /// CGEventFlags representation (used for GlobalHotKey matching)
    /// Note: NSEvent.ModifierFlags and CGEventFlags share the same modifier bits (consistent internally in macOS)
    var cgEventFlags: CGEventFlags {
        return CGEventFlags(rawValue: UInt64(modifierFlags))
    }

    /// Takes only the modifier flag bits (command/shift/option/control/capsLock)
    var deviceIndependentModifiers: NSEvent.ModifierFlags {
        return NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }
}

// MARK: - Display name rendering

/// Renders keyCode + modifiers into a human-readable string ("⌘⇧R" / "Right Option" etc.)
enum HotKeyFormatter {

    /// Constructs displayName from an NSEvent recording result
    static func displayName(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isModifierOnly: Bool) -> String {
        let modifierFlags = modifiers.intersection(.deviceIndependentFlagsMask)

        if isModifierOnly {
            return modifierOnlyName(keyCode: keyCode)
        }

        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option)  { parts.append("⌥") }
        if modifierFlags.contains(.shift)   { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        if let key = keyName(keyCode: keyCode) {
            parts.append(key)
        } else {
            parts.append("Key \(keyCode)")
        }
        return parts.joined()
    }

    /// When modifier-only, translates the keyCode into a specific modifier name.
    static func modifierOnlyName(keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right Command"   // ⌘ right
        case 55: return "Left Command"    // ⌘ left
        case 56: return "Left Shift"
        case 57: return "Caps Lock"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "Function (fn)"
        default: return "Modifier \(keyCode)"
        }
    }

    /// Readable names for letter/number/common keys (from macOS standard physical key codes).
    static func keyName(keyCode: UInt16) -> String? {
        // Source: HIToolbox/Events.h kVK_* constants
        switch keyCode {
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 27: return "-"
        case 24: return "="
        case 33: return "["
        case 30: return "]"
        case 41: return ";"
        case 39: return "'"
        case 43: return ","
        case 47: return "."
        case 44: return "/"
        case 50: return "`"
        case 42: return "\\"
        default: return nil
        }
    }
}
