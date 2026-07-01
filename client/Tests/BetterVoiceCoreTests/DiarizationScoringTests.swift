import XCTest
@testable import BetterVoiceCore

final class DiarizationScoringTests: XCTestCase {
    func test_perfectMatch_scoresZeroError() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let hyp = ref
        let s = scoreDiarization(reference: ref, hypothesis: hyp)
        XCTAssertEqual(s.speakerCountError, 0)
        XCTAssertEqual(s.frameErrorRate, 0, accuracy: 0.001)
    }

    func test_swappedSecondHalf_countsAsError() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let hyp: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "A", start: 2, end: 4)]
        let s = scoreDiarization(reference: ref, hypothesis: hyp, frameSec: 0.5)
        XCTAssertEqual(s.speakerCountError, 1)   // hyp found 1 speaker, ref has 2
        XCTAssertGreaterThan(s.frameErrorRate, 0.4)
    }
}
