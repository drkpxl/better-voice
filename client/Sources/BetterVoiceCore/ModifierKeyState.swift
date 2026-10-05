import Foundation

/// Whether one physical modifier key is down, from a keyboard event's raw flags.
///
/// The device-independent bit (e.g. "an Option key is down") can't tell Right Option from Left:
/// hold Right Option to talk, touch Left Option, release Right first, and the flags still say
/// Option — the release would be missed. The low bits carry one flag per physical key (IOKit's
/// `NX_DEVICE*KEYMASK`), so those decide. Events with no device bits at all (some synthesized
/// ones) fall back to the device-independent bit.
public enum ModifierKeyState {
    // CGEventFlags device-independent masks.
    static let shift: UInt64 = 0x0002_0000
    static let control: UInt64 = 0x0004_0000
    static let option: UInt64 = 0x0008_0000
    static let command: UInt64 = 0x0010_0000
    static let capsLock: UInt64 = 0x0001_0000
    static let fn: UInt64 = 0x0080_0000

    /// keyCode → (device-independent mask, this key's device bit, both sides' device bits).
    private static let keys: [UInt16: (family: UInt64, device: UInt64, familyDevices: UInt64)] = [
        55: (command, 0x0008, 0x0018),   // Left ⌘
        54: (command, 0x0010, 0x0018),   // Right ⌘
        56: (shift, 0x0002, 0x0006),     // Left ⇧
        60: (shift, 0x0004, 0x0006),     // Right ⇧
        58: (option, 0x0020, 0x0060),    // Left ⌥
        61: (option, 0x0040, 0x0060),    // Right ⌥
        59: (control, 0x0001, 0x2001),   // Left ⌃
        62: (control, 0x2000, 0x2001),   // Right ⌃
    ]

    public static func isDown(keyCode: UInt16, flags: UInt64) -> Bool {
        switch keyCode {
        case 57: return flags & capsLock != 0
        case 63: return flags & fn != 0
        default: break
        }
        guard let key = keys[keyCode], flags & key.family != 0 else { return false }
        if flags & key.familyDevices == 0 { return true }   // no device bits: trust the family bit
        return flags & key.device != 0
    }
}
