import XCTest
@testable import BetterVoiceCore

final class KnownSpeakersTests: XCTestCase {
    func test_learnThenMatch_returnsName() {
        var book = KnownSpeakers()
        book.learn(name: "Sam", embedding: [1, 0, 0, 0])
        let m = book.bestMatch(for: [0.99, 0.01, 0, 0])
        XCTAssertEqual(m?.name, "Sam")
    }

    func test_learnSameNameCaseInsensitive_mergesToRunningCentroid() {
        var book = KnownSpeakers()
        book.learn(name: "Sam", embedding: [1, 0, 0, 0])
        book.learn(name: " sam ", embedding: [0, 1, 0, 0])
        XCTAssertEqual(book.profiles.count, 1)
        XCTAssertEqual(book.profiles[0].sampleCount, 2)
        XCTAssertEqual(book.bestMatch(for: [0.5, 0.5, 0, 0])?.name, "Sam")  // first-seen casing kept
    }

    func test_orthogonalVoice_noMatch() {
        var book = KnownSpeakers()
        book.learn(name: "Sam", embedding: [1, 0, 0, 0])
        XCTAssertNil(book.bestMatch(for: [0, 1, 0, 0]))
    }

    func test_suggestNames_dedupesProfileAcrossSpeakers_byBestDistance() {
        var book = KnownSpeakers()
        book.learn(name: "Sam", embedding: [1, 0, 0, 0])
        // Two meeting speakers both near Sam; only the closer one ("2") may be suggested "Sam".
        let suggestions = book.suggestNames(for: [
            "1": [0.90, 0.10, 0, 0],
            "2": [0.99, 0.01, 0, 0],
        ])
        XCTAssertEqual(suggestions, ["2": "Sam"])
    }

    func test_codableRoundTrip() throws {
        var book = KnownSpeakers()
        book.learn(name: "Sam", embedding: [1, 0, 0, 0])
        let data = try JSONEncoder().encode(book)
        let back = try JSONDecoder().decode(KnownSpeakers.self, from: data)
        XCTAssertEqual(back, book)
    }

    func test_conformsToSpeakerRegistrySeam() {
        var reg: any SpeakerRegistry = KnownSpeakers()
        reg.upsert(id: "Sam", embedding: [1, 0, 0, 0])
        XCTAssertEqual(reg.match([0.99, 0.01, 0, 0])?.id, "Sam")
    }

    // MARK: - Task 1.2: speakerEmbeddings(from:)

    func test_speakerEmbeddings_twoSpeakers_returnsMeanPerSpeaker() {
        let segments = [
            MeetingSegment(text: "a", rawText: "a", startTime: 0, endTime: 1, speakerId: "1",
                           l2Kind: .changed, isFinal: true, speakerEmbedding: [1, 0]),
            MeetingSegment(text: "b", rawText: "b", startTime: 1, endTime: 2, speakerId: "1",
                           l2Kind: .changed, isFinal: true, speakerEmbedding: [0, 1]),
            MeetingSegment(text: "c", rawText: "c", startTime: 2, endTime: 3, speakerId: "2",
                           l2Kind: .changed, isFinal: true, speakerEmbedding: [0, 2]),
        ]
        let means = speakerEmbeddings(from: segments)
        XCTAssertEqual(means["1"] ?? [], [0.5, 0.5])
        XCTAssertEqual(means["2"] ?? [], [0, 2])
    }

    func test_speakerEmbeddings_nilEmbeddingSegmentsSkipped_speakerAbsentWhenAllNil() {
        let segments = [
            MeetingSegment(text: "a", rawText: "a", startTime: 0, endTime: 1, speakerId: "1",
                           l2Kind: .changed, isFinal: true, speakerEmbedding: nil),
            MeetingSegment(text: "b", rawText: "b", startTime: 1, endTime: 2, speakerId: "2",
                           l2Kind: .changed, isFinal: true, speakerEmbedding: [1, 1]),
        ]
        let means = speakerEmbeddings(from: segments)
        XCTAssertNil(means["1"])
        XCTAssertEqual(means["2"] ?? [], [1, 1])
    }

    func test_speakerEmbeddings_includesLocalSpeaker_callerFiltersIfNeeded() {
        let segments = [
            MeetingSegment(text: "a", rawText: "a", startTime: 0, endTime: 1, speakerId: SpeakerIds.local,
                           l2Kind: .changed, isFinal: true, speakerEmbedding: [3, 3]),
        ]
        let means = speakerEmbeddings(from: segments)
        XCTAssertEqual(means[SpeakerIds.local] ?? [], [3, 3])
    }
}
