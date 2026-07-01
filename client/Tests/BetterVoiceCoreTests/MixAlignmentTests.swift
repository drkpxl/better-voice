import XCTest
@testable import BetterVoiceCore

final class MixAlignmentTests: XCTestCase {

    func testEqualLengthsAveragesElementwiseWithNoRemainderOrDrop() {
        let r = alignAndMix(mic: [1, 1], sys: [3, 3], maxCarry: 10)
        XCTAssertEqual(r.mixed, [2, 2])
        XCTAssertTrue(r.micRemainder.isEmpty)
        XCTAssertTrue(r.sysRemainder.isEmpty)
        XCTAssertEqual(r.droppedForDrift, 0)
    }

    func testMicLongerCarriesTrailingMicSamples() {
        // mic has 5, sys has 3; k = 2 excess mic samples, well under maxCarry.
        let r = alignAndMix(mic: [1, 1, 1, 7, 9], sys: [3, 3, 3], maxCarry: 10)
        XCTAssertEqual(r.mixed, [2, 2, 2])
        XCTAssertEqual(r.micRemainder, [7, 9])
        XCTAssertTrue(r.sysRemainder.isEmpty)
        XCTAssertEqual(r.droppedForDrift, 0)
    }

    func testSysLongerCarriesTrailingSysSamples() {
        let r = alignAndMix(mic: [3, 3, 3], sys: [1, 1, 1, 7, 9], maxCarry: 10)
        XCTAssertEqual(r.mixed, [2, 2, 2])
        XCTAssertTrue(r.micRemainder.isEmpty)
        XCTAssertEqual(r.sysRemainder, [7, 9])
        XCTAssertEqual(r.droppedForDrift, 0)
    }

    func testRemainderExceedingMaxCarryDropsOldestKeepsNewest() {
        // mic longer by 5 (sys empty aligns 0), remainder = all mic; maxCarry 3.
        let mic: [Float] = [10, 20, 30, 40, 50]
        let r = alignAndMix(mic: mic, sys: [], maxCarry: 3)
        XCTAssertTrue(r.mixed.isEmpty)          // n = min(5, 0) = 0
        XCTAssertEqual(r.droppedForDrift, 2)    // 5 - 3
        XCTAssertEqual(r.micRemainder.count, 3)
        XCTAssertEqual(r.micRemainder, [30, 40, 50]) // newest kept
        XCTAssertTrue(r.sysRemainder.isEmpty)
    }

    func testSysRemainderExceedingMaxCarryDropsOldest() {
        let sys: [Float] = [1, 2, 3, 4, 5, 6]
        let r = alignAndMix(mic: [], sys: sys, maxCarry: 4)
        XCTAssertTrue(r.mixed.isEmpty)
        XCTAssertEqual(r.droppedForDrift, 2)    // 6 - 4
        XCTAssertEqual(r.sysRemainder, [3, 4, 5, 6])
        XCTAssertTrue(r.micRemainder.isEmpty)
    }

    func testBothEmptyProducesEmptyResult() {
        let r = alignAndMix(mic: [], sys: [], maxCarry: 10)
        XCTAssertTrue(r.mixed.isEmpty)
        XCTAssertTrue(r.micRemainder.isEmpty)
        XCTAssertTrue(r.sysRemainder.isEmpty)
        XCTAssertEqual(r.droppedForDrift, 0)
    }

    func testEmptyMicWithSysCarriesSys() {
        let r = alignAndMix(mic: [], sys: [4, 6], maxCarry: 10)
        XCTAssertTrue(r.mixed.isEmpty)
        XCTAssertTrue(r.micRemainder.isEmpty)
        XCTAssertEqual(r.sysRemainder, [4, 6])
        XCTAssertEqual(r.droppedForDrift, 0)
    }

    func testEmptySysWithMicCarriesMic() {
        let r = alignAndMix(mic: [4, 6], sys: [], maxCarry: 10)
        XCTAssertTrue(r.mixed.isEmpty)
        XCTAssertEqual(r.micRemainder, [4, 6])
        XCTAssertTrue(r.sysRemainder.isEmpty)
        XCTAssertEqual(r.droppedForDrift, 0)
    }
}
