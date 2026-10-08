import XCTest
@testable import BetterVoiceCore

/// Excerpts from a real speakerphone call: the system channel's remote turn, and the mic
/// channel's copy of it as transcribed separately.
final class MeetingEchoFilterTests: XCTestCase {
    private func seg(_ text: String, _ start: TimeInterval, _ end: TimeInterval, speaker: String? = nil) -> MeetingSegment {
        MeetingSegment(text: text, startTime: start, endTime: end, speakerId: speaker, isFinal: true)
    }

    private let melanie = "Yes. So it would be like the working team. So for like premium it would be it was Tom who was our pod leader. I was pulled in for marketing. Um Alex Tarnoff was pulled in from strategy, whatever role he lived in, Michael Gregory was guest experience."

    func testPureEchoTurnIsRemoved() {
        let mic = seg("I was pulled in for marketing. Alex Tarnoff was pulled in from strategy, whatever role he lived in. Michael Gregory was guest experience?", 17, 33)
        let out = MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [seg(melanie, 9, 47, speaker: "2")])
        XCTAssertTrue(out.isEmpty, out.map(\.text).description)
    }

    func testOwnSpeechAfterEchoInSameTurnIsKept() {
        let susanne = "So I don't disagree with most all of what you said, but I do think having that alignment up front is critical."
        let mic = seg("So I don't disagree with most all of what you said, but I do think having that alignment up front is critical. Sure. But now for an RFP. I mean, RFP is gonna be a document we're all gonna comment down.", 422, 435)
        let out = MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [seg(susanne, 391, 437, speaker: "1")])
        XCTAssertEqual(out.map(\.text), ["Sure. But now for an RFP. I mean, RFP is gonna be a document we're all gonna comment down."])
        XCTAssertGreaterThan(out[0].startTime, 422)
        XCTAssertEqual(out[0].endTime, 435)
    }

    func testOwnSpeechOnBothSidesOfEchoIsSplit() {
        let remote = seg("Yeah, I hear that. I think for the RFP, the roles and responsibilities are Steve, you and I have to make the business decisions.", 493, 510, speaker: "2")
        let mic = seg("and that if we get distracted I think that's gonna delay us. Yeah, I hear that. I think for the RFP, the roles and responsibilities are Steve, you and I have to make the business decisions. Okay, that works for me.", 482, 515)
        let out = MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [remote])
        XCTAssertEqual(out.map(\.text), ["and that if we get distracted I think that's gonna delay us.", "Okay, that works for me."])
        XCTAssertLessThan(out[0].endTime, out[1].startTime)
    }

    func testSmallTranscriptionDifferencesStillMatch() {
        let remote = seg("And again, like I'm I want to be an active participant. I'm not saying like you do you and I'll do me.", 125, 140, speaker: "1")
        let mic = seg("And again, like I'm I wanna be an active participant. I'm not saying like you do you and I'll do me.", 164, 174)
        XCTAssertTrue(MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [remote]).isEmpty)
    }

    func testOwnSpeechWithNoMatchIsUntouched() {
        let mic = seg("You know, I the the where I struggle a bit is that this is a a platform that we're purchasing.", 266, 283)
        let out = MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [seg(melanie, 250, 290, speaker: "2")])
        XCTAssertEqual(out.map(\.text), [mic.text])
        XCTAssertEqual(out[0].startTime, 266)
    }

    func testShortCommonPhraseIsNotTreatedAsEcho() {
        let remote = seg("I think that's right, let's move on.", 100, 104, speaker: "1")
        let mic = seg("Honestly I think that's fine for now.", 110, 113)
        XCTAssertEqual(MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [remote]).map(\.text), [mic.text])
    }

    func testSameWordsFarApartInTimeAreKept() {
        let mic = seg("I was pulled in for marketing. Alex Tarnoff was pulled in from strategy.", 900, 910)
        let out = MeetingEchoFilter.apply(localSegments: [mic], remoteSegments: [seg(melanie, 9, 47, speaker: "2")])
        XCTAssertEqual(out.map(\.text), [mic.text])
    }

    func testMergeDropsEchoAndKeepsRemoteTurn() {
        let remote = seg(melanie, 9, 47, speaker: "2")
        let mic = seg("I was pulled in for marketing. Alex Tarnoff was pulled in from strategy, whatever role he lived in.", 17, 33)
        let merged = mergeSpeakerTimelines(localSegments: [mic], remoteSegments: [remote])
        XCTAssertEqual(merged.map(\.speakerId), ["2"])
    }
}
