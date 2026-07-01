import XCTest
@testable import BetterVoiceCore

final class DiarizationConfigTests: XCTestCase {

    func testEmptyDictYieldsAllDefaults() {
        let s = parseDiarizationSettings([:])
        XCTAssertEqual(s.clusteringThreshold, 0.55, accuracy: 1e-6)
        XCTAssertEqual(s.minSpeechDuration, 1.0, accuracy: 1e-6)
        XCTAssertEqual(s.minSilenceGap, 0.5, accuracy: 1e-6)
    }

    func testValidDictIsParsed() {
        let s = parseDiarizationSettings([
            "clustering_threshold": 0.65,
            "min_speech_duration": 2.0,
            "min_silence_gap": 0.75
        ])
        XCTAssertEqual(s.clusteringThreshold, 0.65, accuracy: 1e-6)
        XCTAssertEqual(s.minSpeechDuration, 2.0, accuracy: 1e-6)
        XCTAssertEqual(s.minSilenceGap, 0.75, accuracy: 1e-6)
    }

    func testThresholdBelowRangeIsClampedToLowerBound() {
        let s = parseDiarizationSettings(["clustering_threshold": 0.3])
        XCTAssertEqual(s.clusteringThreshold, 0.5, accuracy: 1e-6)
    }

    func testThresholdAboveRangeIsClampedToUpperBound() {
        let s = parseDiarizationSettings(["clustering_threshold": 1.0])
        XCTAssertEqual(s.clusteringThreshold, 0.9, accuracy: 1e-6)
    }

    func testWrongTypedValueFallsBackToDefault() {
        let s = parseDiarizationSettings(["clustering_threshold": "high"])
        XCTAssertEqual(s.clusteringThreshold, 0.55, accuracy: 1e-6)
    }

    func testPartialDictMixesParsedAndDefaults() {
        let s = parseDiarizationSettings(["min_silence_gap": 0.9])
        XCTAssertEqual(s.clusteringThreshold, 0.55, accuracy: 1e-6)  // default
        XCTAssertEqual(s.minSpeechDuration, 1.0, accuracy: 1e-6)     // default
        XCTAssertEqual(s.minSilenceGap, 0.9, accuracy: 1e-6)         // parsed
    }

    func testIntAndFloatTypesAreCoerced() {
        let s = parseDiarizationSettings([
            "clustering_threshold": Int(1),   // clamps to 0.9 after coercion
            "min_speech_duration": Float(3.0)
        ])
        XCTAssertEqual(s.clusteringThreshold, 0.9, accuracy: 1e-6)
        XCTAssertEqual(s.minSpeechDuration, 3.0, accuracy: 1e-6)
    }
}
