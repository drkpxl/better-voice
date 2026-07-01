import XCTest
@testable import BetterVoiceCore

final class SpeakerRegistryTests: XCTestCase {

    func testMatchesNearIdenticalVector() {
        var reg = InMemorySpeakerRegistry()
        reg.upsert(id: "A", embedding: [1, 0, 0, 0])
        let m = reg.match([0.99, 0.01, 0, 0])
        XCTAssertEqual(m?.id, "A")
        XCTAssertLessThan(m!.distance, 0.35)
    }

    func testOrthogonalVectorDoesNotMatch() {
        var reg = InMemorySpeakerRegistry()
        reg.upsert(id: "A", embedding: [1, 0, 0, 0])
        XCTAssertNil(reg.match([0, 1, 0, 0]))   // cosine distance = 1 > threshold
    }

    func testEmptyRegistryReturnsNil() {
        let reg = InMemorySpeakerRegistry()
        XCTAssertNil(reg.match([1, 0, 0, 0]))
    }

    func testUpsertSameIdAveragesToRunningMean() {
        var reg = InMemorySpeakerRegistry()
        reg.upsert(id: "A", embedding: [1, 0, 0, 0])
        reg.upsert(id: "A", embedding: [0, 1, 0, 0])
        XCTAssertEqual(reg.count, 1)                 // still one speaker
        // Mean of the two upserts is [0.5, 0.5, 0, 0]; a query along it is ~0 distance.
        let m = reg.match([0.5, 0.5, 0, 0])
        XCTAssertEqual(m?.id, "A")
        XCTAssertEqual(m!.distance, 0, accuracy: 1e-5)
    }

    func testTwoSpeakersReturnsNearerOne() {
        var reg = InMemorySpeakerRegistry()
        reg.upsert(id: "A", embedding: [1, 0, 0, 0])
        reg.upsert(id: "B", embedding: [0, 0, 1, 0])
        let m = reg.match([0, 0, 0.9, 0.1])
        XCTAssertEqual(m?.id, "B")
    }

    func testZeroVectorQueryReturnsNil() {
        var reg = InMemorySpeakerRegistry()
        reg.upsert(id: "A", embedding: [1, 0, 0, 0])
        XCTAssertNil(reg.match([0, 0, 0, 0]))       // zero-norm query: no crash, no match
    }

    func testMismatchedLengthReferenceIsSkipped() {
        var reg = InMemorySpeakerRegistry()
        reg.upsert(id: "A", embedding: [1, 0, 0, 0])      // len 4
        reg.upsert(id: "B", embedding: [1, 0, 0, 0, 0])   // len 5
        // Query length 5 matches B; A (len 4) must be skipped without crashing.
        let m = reg.match([0.99, 0, 0, 0, 0.01])
        XCTAssertEqual(m?.id, "B")
    }

    func testCountReflectsEnrolledSpeakers() {
        var reg = InMemorySpeakerRegistry()
        XCTAssertEqual(reg.count, 0)
        reg.upsert(id: "A", embedding: [1, 0])
        reg.upsert(id: "B", embedding: [0, 1])
        XCTAssertEqual(reg.count, 2)
    }
}
