import XCTest
@testable import BetterVoiceCore

final class DiarizationScoringTests: XCTestCase {
    func testPerfectMatchScoresZeroError() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let hyp = ref
        let s = scoreDiarization(reference: ref, hypothesis: hyp)
        XCTAssertEqual(s.speakerCountError, 0)
        XCTAssertEqual(s.frameErrorRate, 0, accuracy: 0.001)
    }

    func testSwappedSecondHalfCountsAsError() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let hyp: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "A", start: 2, end: 4)]
        let s = scoreDiarization(reference: ref, hypothesis: hyp, frameSec: 0.5)
        XCTAssertEqual(s.speakerCountError, 1)   // hyp found 1 speaker, ref has 2
        XCTAssertGreaterThan(s.frameErrorRate, 0.4)
    }

    // MARK: - Edge cases

    func testEmptyHypothesisAgainstReferenceIsAllWrong() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let s = scoreDiarization(reference: ref, hypothesis: [])
        XCTAssertEqual(s.frameErrorRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.speakerCountError, 2) // hyp has 0 speakers, ref has 2
    }

    func testEmptyReferenceAndHypothesisScoresZero() {
        let s = scoreDiarization(reference: [], hypothesis: [])
        XCTAssertEqual(s.frameErrorRate, 0, accuracy: 0.001)
        XCTAssertEqual(s.speakerCountError, 0)
    }

    // MARK: - Sidecar decode + score

    private func sidecarData(_ json: String) -> Data { Data(json.utf8) }

    func testSidecarValidJSONScores() {
        let hyp: [LabeledInterval] = [.init(speaker: "1", start: 0, end: 2),
                                      .init(speaker: "2", start: 2, end: 4)]
        // Integer and float numbers both must decode via NSNumber casting.
        let data = sidecarData("""
        [{"speaker":"A","start":0,"end":2},{"speaker":"B","start":2.0,"end":4.0}]
        """)
        let s = scoreDiarizationAgainstSidecar(hypothesis: hyp, sidecarJSONData: data)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.frameErrorRate ?? 1, 0, accuracy: 0.001) // "1"->A, "2"->B maps perfectly
        XCTAssertEqual(s?.speakerCountError, 0)
    }

    func testSidecarEmptyArrayReturnsNil() {
        let hyp: [LabeledInterval] = [.init(speaker: "1", start: 0, end: 2)]
        XCTAssertNil(scoreDiarizationAgainstSidecar(hypothesis: hyp, sidecarJSONData: sidecarData("[]")))
    }

    func testSidecarMalformedJSONReturnsNil() {
        let hyp: [LabeledInterval] = [.init(speaker: "1", start: 0, end: 2)]
        XCTAssertNil(scoreDiarizationAgainstSidecar(hypothesis: hyp, sidecarJSONData: sidecarData("{ not json")))
    }

    func testSidecarWrongShapeJSONReturnsNil() {
        let hyp: [LabeledInterval] = [.init(speaker: "1", start: 0, end: 2)]
        // A JSON object (not an array of objects) is the wrong shape.
        XCTAssertNil(scoreDiarizationAgainstSidecar(hypothesis: hyp, sidecarJSONData: sidecarData(#"{"speaker":"A"}"#)))
        // An array whose entries lack required keys decodes to an empty reference -> nil.
        XCTAssertNil(scoreDiarizationAgainstSidecar(hypothesis: hyp, sidecarJSONData: sidecarData(#"[{"foo":1}]"#)))
    }
}
