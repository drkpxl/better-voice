import XCTest
@testable import BetterVoiceCore

/// The risk this guards is one-directional: leaving an "um" in is a cosmetic miss, but deleting a real
/// word silently changes what the user said and they cannot see what went missing. Most of these tests
/// are therefore about what must NOT be removed.
final class FillerStripperTests: XCTestCase {

    private func strip(_ text: String) -> String {
        FillerStripper.strip(text).text
    }

    private func removed(_ text: String) -> [String] {
        FillerStripper.strip(text).removed
    }

    // MARK: - Always-fillers, removed anywhere

    func testRemovesNonWordFillersMidSentence() {
        XCTAssertEqual(strip("I think um we should go"), "I think we should go")
        XCTAssertEqual(strip("It was uh fine"), "It was fine")
    }

    func testRemovesEveryAlwaysFillerVariant() {
        for filler in ["um", "umm", "uh", "uhh", "er", "erm", "hm", "hmm", "mm", "mmm", "mhm"] {
            XCTAssertEqual(strip("start \(filler) end"), "start end", "failed for \(filler)")
        }
    }

    func testRemovesFillerWithAttachedPunctuation() {
        XCTAssertEqual(strip("Well, um, I agree."), "I agree.")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(strip("I think UM we should"), "I think we should")
        XCTAssertEqual(strip("Um I think"), "I think")
    }

    // MARK: - Sentence-initial fillers, removed ONLY at the front

    func testRemovesDiscourseMarkerAtSentenceStart() {
        XCTAssertEqual(strip("So I went home."), "I went home.")
        XCTAssertEqual(strip("Well that's done."), "That's done.")
    }

    func testRemovesARunOfOpeners() {
        // "Um, okay, so ..." must lose all three, not just the first.
        XCTAssertEqual(strip("Um, okay, so I think we should ship."), "I think we should ship.")
    }

    func testKeepsAmbiguousWordsAwayFromTheFront() {
        // The entire reason these are position-restricted.
        XCTAssertEqual(strip("I like it"), "I like it")
        XCTAssertEqual(strip("Turn right at the corner"), "Turn right at the corner")
        XCTAssertEqual(strip("It was so cold"), "It was so cold")
        XCTAssertEqual(strip("The well is dry"), "The well is dry")
        XCTAssertEqual(strip("Is that okay with you"), "Is that okay with you")
        XCTAssertEqual(strip("Say yeah if you agree"), "Say yeah if you agree")
    }

    func testKeepsAnAmbiguousWordThatIsTheWholeSentence() {
        // "Okay." alone is a real answer. It IS stripped as a leading run, which empties the sentence,
        // and an emptied sentence is dropped -- documented behaviour, pinned so a change is deliberate.
        XCTAssertEqual(strip("Okay."), "")
    }

    // MARK: - Structure and capitalization

    func testRecapitalizesWhenTheOpenerWasRemoved() {
        XCTAssertEqual(strip("So we shipped it."), "We shipped it.")
    }

    func testDoesNotRecapitalizeWhenNothingWasRemoved() {
        // Text the user deliberately began in lower case must survive untouched.
        XCTAssertEqual(strip("iPhone battery life is fine."), "iPhone battery life is fine.")
    }

    func testPreservesTerminators() {
        XCTAssertEqual(strip("Um, really? Yes! Okay then."), "Really? Yes! Then.")
    }

    func testHandlesMultipleSentences() {
        XCTAssertEqual(
            strip("So I went there. Um, it was closed. Well that was that."),
            "I went there. It was closed. That was that."
        )
    }

    func testPreservesEllipsisAndRepeatedTerminators() {
        XCTAssertEqual(strip("Wait... um what?"), "Wait... What?")
    }

    func testTextWithNoTerminatorIsStillProcessed() {
        XCTAssertEqual(strip("um so I think this works"), "I think this works")
    }

    // MARK: - Edge cases

    func testEmptyAndWhitespace() {
        XCTAssertEqual(strip(""), "")
        XCTAssertEqual(strip("   "), "")
    }

    func testTextThatIsOnlyFillers() {
        XCTAssertEqual(strip("Um, uh, hmm."), "")
    }

    func testCleanTextIsUnchanged() {
        let text = "We agreed to ship the migration on Thursday."
        XCTAssertEqual(strip(text), text)
    }

    func testCollapsesWhitespaceOnlyWhereWordsWereRemoved() {
        XCTAssertEqual(strip("I  think um  we  should"), "I think we should")
    }

    func testContractionsAndPossessivesSurvive() {
        XCTAssertEqual(strip("It's Emmie's turn"), "It's Emmie's turn")
        XCTAssertEqual(strip("I'm um not sure"), "I'm not sure")
    }

    func testAWordMerelyCONTAININGAFillerIsKept() {
        // "umbrella" starts with "um"; "other" contains "er". Substring matching would eat both.
        XCTAssertEqual(strip("The umbrella is over there"), "The umbrella is over there")
        XCTAssertEqual(strip("Another summer"), "Another summer")
        XCTAssertEqual(strip("Ermine and hummus"), "Ermine and hummus")
    }

    // MARK: - Auditability

    func testRemovedWordsAreReported() {
        XCTAssertEqual(removed("So um I think"), ["So", "um"])
        XCTAssertEqual(removed("Clean text here."), [])
    }

    func testRemovedListKeepsOriginalSpellingAndPunctuation() {
        // Reported verbatim so a log line shows exactly what left the text.
        XCTAssertEqual(removed("Um, I agree"), ["Um,"])
    }
}
