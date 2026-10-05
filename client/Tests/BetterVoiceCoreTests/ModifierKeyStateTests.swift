import XCTest
@testable import BetterVoiceCore

final class ModifierKeyStateTests: XCTestCase {
    private let rightOption: UInt16 = 61
    private let leftOption: UInt16 = 58

    func testRightOptionAlone() {
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: rightOption, flags: ModifierKeyState.option | 0x40))
        XCTAssertFalse(ModifierKeyState.isDown(keyCode: rightOption, flags: 0))
    }

    func testReleasingRightOptionWhileLeftHeldReadsAsUp() {
        // Left ⌥ still down: family bit set, only the left device bit.
        XCTAssertFalse(ModifierKeyState.isDown(keyCode: rightOption, flags: ModifierKeyState.option | 0x20))
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: leftOption, flags: ModifierKeyState.option | 0x20))
    }

    func testBothOptionsDown() {
        let flags = ModifierKeyState.option | 0x20 | 0x40
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: rightOption, flags: flags))
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: leftOption, flags: flags))
    }

    func testNoDeviceBitsFallsBackToFamily() {
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: rightOption, flags: ModifierKeyState.option))
    }

    func testRightControlUsesItsHighDeviceBit() {
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: 62, flags: ModifierKeyState.control | 0x2000))
        XCTAssertFalse(ModifierKeyState.isDown(keyCode: 62, flags: ModifierKeyState.control | 0x0001))
    }

    func testRightCommandWithLeftHeld() {
        XCTAssertFalse(ModifierKeyState.isDown(keyCode: 54, flags: ModifierKeyState.command | 0x08))
    }

    func testCapsLockAndFn() {
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: 57, flags: ModifierKeyState.capsLock))
        XCTAssertTrue(ModifierKeyState.isDown(keyCode: 63, flags: ModifierKeyState.fn))
        XCTAssertFalse(ModifierKeyState.isDown(keyCode: 63, flags: 0))
    }

    func testUnknownKey() {
        XCTAssertFalse(ModifierKeyState.isDown(keyCode: 0, flags: .max))
    }
}
