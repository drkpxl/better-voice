import XCTest
@testable import BetterVoiceCore

final class DictationGestureTests: XCTestCase {

    // MARK: Combo binding (⌥.)

    func testComboTapTogglesOn() {
        var g = DictationGesture()
        XCTAssertEqual(g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: false), .start)
        XCTAssertEqual(g.up(at: 0.1), .none, "a tap leaves the recording running")
    }

    func testComboHoldIsPushToTalk() {
        var g = DictationGesture()
        XCTAssertEqual(g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: false), .start)
        XCTAssertEqual(g.up(at: 2.5), .stop)
    }

    func testHoldThresholdIsInclusive() {
        var g = DictationGesture()
        _ = g.down(at: 10, isRecording: false, isBusy: false, modifierOnly: false)
        XCTAssertEqual(g.up(at: 10 + DictationGesture.holdThreshold), .stop)
    }

    func testPressWhileRecordingStopsOnRelease() {
        var g = DictationGesture()
        XCTAssertEqual(g.down(at: 0, isRecording: true, isBusy: false, modifierOnly: false), .none)
        XCTAssertEqual(g.up(at: 0.05), .stop)
    }

    func testBusyPressIsIgnored() {
        var g = DictationGesture()
        XCTAssertEqual(g.down(at: 0, isRecording: false, isBusy: true, modifierOnly: false), .none)
        XCTAssertEqual(g.up(at: 1), .none)
    }

    // MARK: Modifier-only binding (Right Option)

    func testModifierTapTogglesOnAtRelease() {
        var g = DictationGesture()
        XCTAssertEqual(g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: true), .scheduleHoldTimer)
        XCTAssertEqual(g.up(at: 0.1), .start)
    }

    func testModifierHoldStartsAtThresholdAndStopsOnRelease() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: true)
        XCTAssertEqual(g.holdTimerFired(at: 0.3), .start)
        XCTAssertEqual(g.up(at: 0.35), .stop, "a hold stops on release even if the remaining hold is short")
    }

    func testModifierUsedInShortcutDoesNothing() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: true)
        XCTAssertEqual(g.otherKeyPressed(at: 0.1), .none)
        XCTAssertEqual(g.holdTimerFired(at: 0.3), .none, "a late timer must not start a consumed press")
        XCTAssertEqual(g.up(at: 0.5), .none)
    }

    func testStrayKeyDuringDeliberateHoldKeepsRecording() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: true)
        _ = g.holdTimerFired(at: 0.3)
        XCTAssertEqual(g.otherKeyPressed(at: 2.0), .none)
        XCTAssertEqual(g.up(at: 4), .stop)
    }

    func testShortcutWhileRecordingDoesNotStop() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: true, isBusy: false, modifierOnly: true)
        _ = g.otherKeyPressed(at: 0.1)
        XCTAssertEqual(g.up(at: 0.2), .none)
    }

    func testTimerAfterReleaseIsIgnored() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: true)
        XCTAssertEqual(g.up(at: 0.1), .start)
        XCTAssertEqual(g.holdTimerFired(at: 0.3), .none)
    }

    func testResetDropsPress() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: false)
        g.reset()
        XCTAssertEqual(g.up(at: 5), .none)
    }

    func testSlowShortcutRightAfterHoldStartCancels() {
        var g = DictationGesture()
        _ = g.down(at: 0, isRecording: false, isBusy: false, modifierOnly: true)
        XCTAssertEqual(g.holdTimerFired(at: 0.3), .start)
        XCTAssertEqual(g.otherKeyPressed(at: 0.5), .cancel)
        XCTAssertEqual(g.up(at: 0.7), .none)
    }
}
