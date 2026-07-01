import XCTest
@testable import BetterVoiceCore

final class SpeakerAlignmentTests: XCTestCase {

    // MARK: - assignSpeaker

    func testAssignsMaxOverlapSpeaker() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 3),
                   SpeakerInterval(speakerId: "2", start: 3, end: 6)]
        let a = assignSpeaker(to: PhraseSpan(start: 2.5, end: 3.2), among: ivs)
        XCTAssertEqual(a.speakerId, "1")            // 0.5 vs 0.2 overlap
        XCTAssertGreaterThan(a.confidence, 0.6)
    }

    func testNoOverlapIsLowConfidenceNotSnap() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 1)]
        let a = assignSpeaker(to: PhraseSpan(start: 5, end: 6), among: ivs)
        XCTAssertNil(a.speakerId)
        XCTAssertEqual(a.confidence, 0, accuracy: 0.001)
    }

    func testFlagsOverlapWhenTwoSpeakersInPhrase() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 2),
                   SpeakerInterval(speakerId: "2", start: 1.5, end: 3)]
        let a = assignSpeaker(to: PhraseSpan(start: 0, end: 3), among: ivs)
        XCTAssertTrue(a.overlapped)
    }

    func testEmptyIntervalsYieldsNilLowConfidence() {
        let a = assignSpeaker(to: PhraseSpan(start: 0, end: 2), among: [])
        XCTAssertNil(a.speakerId)
        XCTAssertNil(a.embedding)
        XCTAssertEqual(a.confidence, 0, accuracy: 0.001)
        XCTAssertFalse(a.overlapped)
    }

    func testConfidenceIsFullWhenPhraseWithinSingleSpeaker() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 10)]
        let a = assignSpeaker(to: PhraseSpan(start: 2, end: 4), among: ivs)
        XCTAssertEqual(a.speakerId, "1")
        XCTAssertEqual(a.confidence, 1.0, accuracy: 0.001)
        XCTAssertFalse(a.overlapped)
    }

    func testSumsOverlapAcrossMultipleIntervalsOfSameSpeaker() {
        // Speaker "1" has two short intervals summing to 1.0s; "2" has one 0.6s interval.
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 0.5),
                   SpeakerInterval(speakerId: "2", start: 0.5, end: 1.1),
                   SpeakerInterval(speakerId: "1", start: 1.1, end: 1.6)]
        let a = assignSpeaker(to: PhraseSpan(start: 0, end: 2), among: ivs)
        XCTAssertEqual(a.speakerId, "1")            // 1.0s total vs 0.6s
    }

    func testCarriesEmbeddingFromLongestOverlappingIntervalOfBestSpeaker() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 0.3, embedding: [1, 0, 0]),
                   SpeakerInterval(speakerId: "1", start: 0.3, end: 1.3, embedding: [0, 1, 0])]
        let a = assignSpeaker(to: PhraseSpan(start: 0, end: 2), among: ivs)
        XCTAssertEqual(a.speakerId, "1")
        XCTAssertEqual(a.embedding, [0, 1, 0])      // second interval overlaps 1.0s > 0.3s
    }

    func testZeroDurationPhraseIsZeroConfidence() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 10)]
        let a = assignSpeaker(to: PhraseSpan(start: 5, end: 5), among: ivs)
        XCTAssertEqual(a.confidence, 0, accuracy: 0.001)
    }

    func testNotOverlappedWhenSecondSpeakerBelowThreshold() {
        // Speaker "2" overlaps only 0.05s out of a 3s phrase (< 0.15 * 3 = 0.45).
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 2.95),
                   SpeakerInterval(speakerId: "2", start: 2.95, end: 3.0)]
        let a = assignSpeaker(to: PhraseSpan(start: 0, end: 3), among: ivs)
        XCTAssertEqual(a.speakerId, "1")
        XCTAssertFalse(a.overlapped)
    }

    // MARK: - groupIntoTurns

    func testGroupsConsecutiveSameSpeakerPhrasesIntoOneTurn() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 10)]
        let phrases = [(span: PhraseSpan(start: 0, end: 1), text: "Hello "),
                       (span: PhraseSpan(start: 1, end: 2), text: "world.")]
        let turns = groupIntoTurns(phrases: phrases, intervals: ivs)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speakerId, "1")
        XCTAssertEqual(turns[0].text, "Hello world.")
        XCTAssertEqual(turns[0].start, 0)
        XCTAssertEqual(turns[0].end, 2)
    }

    func testSpeakerChangeStartsNewTurn() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 2),
                   SpeakerInterval(speakerId: "2", start: 2, end: 4)]
        let phrases = [(span: PhraseSpan(start: 0, end: 1), text: "A "),
                       (span: PhraseSpan(start: 1, end: 2), text: "B "),
                       (span: PhraseSpan(start: 2, end: 3), text: "C "),
                       (span: PhraseSpan(start: 3, end: 4), text: "D")]
        let turns = groupIntoTurns(phrases: phrases, intervals: ivs)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speakerId, "1")
        XCTAssertEqual(turns[0].text, "A B ")
        XCTAssertEqual(turns[1].speakerId, "2")
        XCTAssertEqual(turns[1].text, "C D")
    }

    func testTurnSpanCoversAllPhrases() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 10)]
        let phrases = [(span: PhraseSpan(start: 0.5, end: 1.5), text: "a "),
                       (span: PhraseSpan(start: 1.5, end: 3.75), text: "b")]
        let turns = groupIntoTurns(phrases: phrases, intervals: ivs)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].start, 0.5, accuracy: 0.001)
        XCTAssertEqual(turns[0].end, 3.75, accuracy: 0.001)
    }

    func testContainedOverlapPropagatesToTurn() {
        // Two speakers both overlap the single phrase -> overlapped -> containedOverlap.
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 2),
                   SpeakerInterval(speakerId: "2", start: 1, end: 3)]
        let phrases = [(span: PhraseSpan(start: 0, end: 3), text: "crosstalk")]
        let turns = groupIntoTurns(phrases: phrases, intervals: ivs)
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns[0].containedOverlap)
    }

    func testTurnEmbeddingIsFirstNonNilAndMinConfidenceIsMinimum() {
        let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 10, embedding: [9, 9])]
        // Second phrase sits fully in speaker 1 (confidence 1); first phrase juts past the
        // interval so its confidence is lower.
        let phrases = [(span: PhraseSpan(start: 8, end: 12), text: "a "),
                       (span: PhraseSpan(start: 5, end: 6), text: "b")]
        // Reorder so consecutive same-speaker; both map to "1".
        let turns = groupIntoTurns(phrases: phrases, intervals: ivs)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].embedding, [9, 9])
        XCTAssertEqual(turns[0].minConfidence, 0.5, accuracy: 0.001) // first phrase: 2s overlap / 4s
    }

    func testEmptyPhrasesYieldsNoTurns() {
        let turns = groupIntoTurns(phrases: [], intervals: [])
        XCTAssertTrue(turns.isEmpty)
    }
}
