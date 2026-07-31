import XCTest
@testable import BetterVoiceCore

final class PhraseSegmentationTests: XCTestCase {

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    private func phrases(_ words: [TimedWord], maxGapSec: TimeInterval? = nil) -> [Phrase] {
        if let maxGapSec {
            return PhraseSegmentation.phrases(from: words, maxGapSec: maxGapSec)
        }
        return PhraseSegmentation.phrases(from: words)
    }

    // MARK: - phrases: base cases

    func testEmptyWordsYieldsNoPhrases() {
        XCTAssertTrue(phrases([]).isEmpty)
    }

    func testSingleWordWithoutPunctuationIsOnePhrase() {
        let result = phrases([word("hello", 0.25, 0.75)])
        XCTAssertEqual(result, [Phrase(text: "hello", start: 0.25, end: 0.75)])
    }

    func testSingleWordWithTrailingPunctuationIsOnePhrase() {
        // The punctuation rule fires on the last word, then the final flush finds nothing left --
        // there must be exactly one phrase, not one plus an empty tail.
        XCTAssertEqual(phrases([word("hello.", 0, 1)]), [Phrase(text: "hello.", start: 0, end: 1)])
    }

    func testPhraseSpansFirstWordStartToLastWordEnd() {
        let result = phrases([word("a", 1.5, 1.8), word("b", 1.9, 2.2), word("c", 2.3, 3.0)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "a b c")
        XCTAssertEqual(result[0].start, 1.5, accuracy: 0.0001)
        XCTAssertEqual(result[0].end, 3.0, accuracy: 0.0001)
    }

    // MARK: - phrases: punctuation splits

    func testSplitsAfterSentenceFinalPeriod() {
        let result = phrases([word("Hello", 0, 0.4), word("there.", 0.5, 1.0),
                             word("Second", 1.1, 1.5), word("one.", 1.6, 2.0)])
        XCTAssertEqual(result, [Phrase(text: "Hello there.", start: 0, end: 1.0),
                                Phrase(text: "Second one.", start: 1.1, end: 2.0)])
    }

    func testSplitsAfterQuestionAndExclamationMarks() {
        let result = phrases([word("Really?", 0, 0.4), word("Yes!", 0.5, 0.9), word("Ok", 1.0, 1.3)])
        XCTAssertEqual(result.map(\.text), ["Really?", "Yes!", "Ok"])
    }

    func testSplitsWhenPeriodIsFollowedByClosingQuote() {
        let result = phrases([word("He", 0, 0.2), word("said", 0.3, 0.5), word("\"stop.\"", 0.6, 1.0),
                             word("Then", 1.1, 1.4), word("left.", 1.5, 1.9)])
        XCTAssertEqual(result.map(\.text), ["He said \"stop.\"", "Then left."])
    }

    func testSplitsWhenPeriodIsFollowedByClosingParen() {
        let result = phrases([word("(yes.)", 0, 0.5), word("Next", 0.6, 1.0)])
        XCTAssertEqual(result.map(\.text), ["(yes.)", "Next"])
    }

    func testMultipleTrailingMarksStillSplit() {
        let result = phrases([word("What?!", 0, 0.5), word("Fine", 0.6, 1.0)])
        XCTAssertEqual(result.map(\.text), ["What?!", "Fine"])
    }

    func testEllipsisSplits() {
        // Stem ".." has empty dot-separated parts, so it is not mistaken for an initialism.
        let result = phrases([word("well...", 0, 0.5), word("anyway", 0.6, 1.0)])
        XCTAssertEqual(result.map(\.text), ["well...", "anyway"])
    }

    func testLonePeriodTokenSplitsAndKeepsItsSpace() {
        // A standalone punctuation token is joined with a space in front of it. `joinWords` is not
        // punctuation-aware on purpose (Parakeet attaches punctuation to the preceding word); this
        // pins the current behaviour so a change to it is a deliberate one.
        let result = phrases([word("hmm", 0, 0.3), word(".", 0.4, 0.5), word("next", 0.6, 1.0)])
        XCTAssertEqual(result.map(\.text), ["hmm .", "next"])
    }

    // MARK: - phrases: punctuation that must NOT split

    func testDecimalNumberDoesNotSplit() {
        let result = phrases([word("It", 0, 0.2), word("is", 0.3, 0.4),
                             word("3.5", 0.5, 0.9), word("meters", 1.0, 1.4)])
        XCTAssertEqual(result.map(\.text), ["It is 3.5 meters"])
    }

    func testMidWordPeriodDoesNotSplit() {
        let result = phrases([word("Visit", 0, 0.3), word("example.com", 0.4, 1.0), word("today", 1.1, 1.5)])
        XCTAssertEqual(result.map(\.text), ["Visit example.com today"])
    }

    func testTitleAbbreviationDoesNotSplit() {
        let result = phrases([word("Dr.", 0, 0.3), word("Smith", 0.4, 0.8), word("arrived.", 0.9, 1.4)])
        XCTAssertEqual(result.map(\.text), ["Dr. Smith arrived."])
    }

    func testEtceteraAbbreviationDoesNotSplit() {
        let result = phrases([word("Logs,", 0, 0.3), word("metrics,", 0.4, 0.8),
                             word("etc.", 0.9, 1.2), word("are", 1.3, 1.5), word("here.", 1.6, 2.0)])
        XCTAssertEqual(result.map(\.text), ["Logs, metrics, etc. are here."])
    }

    func testSingleLetterInitialsDoNotSplit() {
        let result = phrases([word("J.", 0, 0.2), word("R.", 0.3, 0.5), word("Tolkien", 0.6, 1.0),
                             word("wrote", 1.1, 1.3), word("it.", 1.4, 1.8)])
        XCTAssertEqual(result.map(\.text), ["J. R. Tolkien wrote it."])
    }

    func testDottedInitialismDoesNotSplit() {
        let us = phrases([word("The", 0, 0.2), word("U.S.", 0.3, 0.7),
                          word("economy", 0.8, 1.2), word("grew.", 1.3, 1.7)])
        XCTAssertEqual(us.map(\.text), ["The U.S. economy grew."])

        let eg = phrases([word("Use", 0, 0.2), word("e.g.", 0.3, 0.6), word("this", 0.7, 1.0)])
        XCTAssertEqual(eg.map(\.text), ["Use e.g. this"])

        let phd = phrases([word("Ask", 0, 0.2), word("Ph.D.", 0.3, 0.7), word("students", 0.8, 1.2)])
        XCTAssertEqual(phd.map(\.text), ["Ask Ph.D. students"])
    }

    // MARK: - phrases: gap splits

    func testGapAboveThresholdSplits() {
        let result = phrases([word("before", 0, 1.0), word("after", 3.0, 3.5)], maxGapSec: 0.6)
        XCTAssertEqual(result, [Phrase(text: "before", start: 0, end: 1.0),
                                Phrase(text: "after", start: 3.0, end: 3.5)])
    }

    func testGapExactlyAtThresholdDoesNotSplit() {
        // Strictly greater-than: a gap of exactly maxGapSec stays inside one phrase. 1.0, 1.5 and 0.5
        // are all exactly representable, so 1.5 - 1.0 == 0.5 holds bit-for-bit and this test is about
        // the comparison's inclusivity, not about float noise.
        let result = phrases([word("a", 0.5, 1.0), word("b", 1.5, 2.0)], maxGapSec: 0.5)
        XCTAssertEqual(result, [Phrase(text: "a b", start: 0.5, end: 2.0)])
    }

    func testGapJustOverThresholdSplits() {
        let result = phrases([word("a", 0.5, 1.0), word("b", 1.5001, 2.0)], maxGapSec: 0.5)
        XCTAssertEqual(result.map(\.text), ["a", "b"])
    }

    func testDefaultGapThresholdIsSixTenths() {
        XCTAssertEqual(PhraseSegmentation.defaultMaxGapSec, 0.6, accuracy: 0.0001)
        // 0.5s gap -> below the default, one phrase.
        XCTAssertEqual(phrases([word("a", 0, 1.0), word("b", 1.5, 2.0)]).count, 1)
        // 0.7s gap -> above the default, two phrases.
        XCTAssertEqual(phrases([word("a", 0, 1.0), word("b", 1.7, 2.0)]).count, 2)
    }

    func testZeroGapThresholdSplitsOnEveryRealGap() {
        // Guard that the threshold is honoured at its degenerate end: with maxGapSec 0 only
        // back-to-back words stay together.
        let result = phrases([word("a", 0, 1.0), word("b", 1.0, 2.0), word("c", 2.1, 3.0)], maxGapSec: 0)
        XCTAssertEqual(result.map(\.text), ["a b", "c"])
    }

    // MARK: - phrases: both rules at one boundary

    func testPunctuationAndGapAtSameBoundaryProduceNoEmptyPhrase() {
        // "One." ends a sentence AND is followed by a 4s silence. Both rules want to break at the
        // same place; the result must be two phrases, not two plus an empty one between them.
        let result = phrases([word("One.", 0, 1.0), word("Two", 5.0, 6.0)], maxGapSec: 0.6)
        XCTAssertEqual(result, [Phrase(text: "One.", start: 0, end: 1.0),
                                Phrase(text: "Two", start: 5.0, end: 6.0)])
        XCTAssertFalse(result.contains { $0.text.isEmpty })
    }

    func testNoPhraseIsEverEmptyAcrossAMixedRun() {
        let result = phrases([word("A.", 0, 0.5), word("B.", 4.0, 4.5), word("", 4.6, 4.7),
                             word("C.", 9.0, 9.5), word("   ", 9.6, 9.7)], maxGapSec: 0.6)
        XCTAssertEqual(result.map(\.text), ["A.", "B.", "C."])
    }

    // MARK: - phrases: empty and whitespace-only word text

    func testDropsEmptyAndWhitespaceOnlyWords() {
        let result = phrases([word("", 0, 1), word("   ", 1, 2), word("hi", 2, 3), word("\n", 3, 4)])
        XCTAssertEqual(result, [Phrase(text: "hi", start: 2, end: 3)])
    }

    func testAllBlankWordsYieldNoPhrases() {
        XCTAssertTrue(phrases([word("", 0, 1), word(" ", 1, 2), word("\t", 2, 3)]).isEmpty)
    }

    func testBlankWordDoesNotMaskARealGap() {
        // A padding token covering the silence would otherwise read as two zero-length gaps and hold
        // both sides in a single phrase. Blank words are dropped before the gap math for this reason.
        let result = phrases([word("A", 0, 1.0), word("   ", 1.0, 4.0), word("B", 4.0, 5.0)], maxGapSec: 0.6)
        XCTAssertEqual(result, [Phrase(text: "A", start: 0, end: 1.0),
                                Phrase(text: "B", start: 4.0, end: 5.0)])
    }

    func testBlankWordDoesNotDefineAPhraseSpan() {
        let result = phrases([word("  ", 0, 0.1), word("word", 2.0, 2.5), word("", 9.0, 9.5)], maxGapSec: 0.6)
        XCTAssertEqual(result, [Phrase(text: "word", start: 2.0, end: 2.5)])
    }

    // MARK: - phrases: non-monotonic timings

    func testOverlappingWordsStayInOnePhrase() {
        // A negative gap is never above the threshold, so overlap never splits. The span still runs
        // first-word start to last-word end.
        let result = phrases([word("A", 0, 5.0), word("B", 1.0, 6.0)], maxGapSec: 0.6)
        XCTAssertEqual(result, [Phrase(text: "A B", start: 0, end: 6.0)])
    }

    func testOutOfOrderWordsKeepEmissionOrderAndNeverInvertTheSpan() {
        // Documented behaviour: words are never sorted (the engine's word order is authoritative for
        // the text), and `end` is clamped to `start` so the span degenerates to zero duration instead
        // of coming out inverted.
        let result = phrases([word("A", 5.0, 6.0), word("B", 0, 1.0)], maxGapSec: 0.6)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "A B")
        XCTAssertEqual(result[0].start, 5.0, accuracy: 0.0001)
        XCTAssertEqual(result[0].end, 5.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(result[0].end, result[0].start)
    }

    func testEveryPhraseSpanIsNonInvertedForScrambledInput() {
        let scrambled = [word("one.", 9.0, 9.5), word("two", 0.1, 0.2), word("three.", 0.05, 0.06),
                         word("four", 20.0, 19.0)]
        for phrase in phrases(scrambled, maxGapSec: 0.6) {
            XCTAssertGreaterThanOrEqual(phrase.end, phrase.start)
            XCTAssertFalse(phrase.text.isEmpty)
        }
    }

    func testZeroDurationWordsDoNotCrash() {
        let result = phrases([word("a", 1.0, 1.0), word("b", 1.0, 1.0)], maxGapSec: 0.6)
        XCTAssertEqual(result, [Phrase(text: "a b", start: 1.0, end: 1.0)])
    }

    // MARK: - joinWords: the spacing hazard

    func testJoinWordsEmptyIsEmptyString() {
        XCTAssertEqual(PhraseSegmentation.joinWords([]), "")
    }

    func testJoinWordsSingleWordHasNoPadding() {
        XCTAssertEqual(PhraseSegmentation.joinWords([word(" hello", 0, 1)]), "hello")
        XCTAssertEqual(PhraseSegmentation.joinWords([word("hello", 0, 1)]), "hello")
    }

    func testJoinWordsHandlesLeadingSpaceConvention() {
        // SentencePiece-style: every word-initial token carries the space marker.
        let words = [word(" the", 0, 1), word(" quick", 1, 2), word(" fox", 2, 3)]
        XCTAssertEqual(PhraseSegmentation.joinWords(words), "the quick fox")
    }

    func testJoinWordsHandlesNoSpaceConvention() {
        let words = [word("the", 0, 1), word("quick", 1, 2), word("fox", 2, 3)]
        XCTAssertEqual(PhraseSegmentation.joinWords(words), "the quick fox")
    }

    func testJoinWordsHandlesMixedConventionsInOneArray() {
        // The realistic shape: the utterance's first token has no marker, later ones do.
        let words = [word("the", 0, 1), word(" quick", 1, 2), word("brown", 2, 3), word(" fox.", 3, 4)]
        XCTAssertEqual(PhraseSegmentation.joinWords(words), "the quick brown fox.")
    }

    func testJoinWordsDropsBlankWordsRatherThanDoubleSpacing() {
        let words = [word("a", 0, 1), word("", 1, 2), word("   ", 2, 3), word(" b", 3, 4)]
        XCTAssertEqual(PhraseSegmentation.joinWords(words), "a b")
    }

    func testJoinWordsPreservesInteriorWhitespaceOfAWord() {
        // A multi-token unit emitted as one TimedWord keeps its insides; only the edges are touched.
        let words = [word(" New York", 0, 1), word(" City", 1, 2)]
        XCTAssertEqual(PhraseSegmentation.joinWords(words), "New York City")
    }

    func testPhraseTextHasNoLeadingOrTrailingSpace() {
        let result = phrases([word(" Hello", 0, 0.4), word(" world.", 0.5, 1.0)])
        XCTAssertEqual(result.map(\.text), ["Hello world."])
        XCTAssertEqual(result[0].text, result[0].text.trimmingCharacters(in: .whitespaces))
    }

    func testMixedConventionSurvivesSegmentation() {
        let result = phrases([word("One", 0, 0.3), word(" two.", 0.4, 0.8),
                             word("Three", 0.9, 1.2), word(" four.", 1.3, 1.7)])
        XCTAssertEqual(result.map(\.text), ["One two.", "Three four."])
    }

    // MARK: - round trip into the real consumer (groupIntoTurns)

    func testPhrasesAttributeToTheRightSpeakersThroughGroupIntoTurns() {
        // Speaker 1 talks 0-2s, speaker 2 from 2.5s. The synthesized spans must land each phrase on
        // the right diarization interval -- this is the whole reason phrase synthesis has to be right.
        let words = [word("Hello", 0, 0.4), word(" there.", 0.5, 1.0),
                     word("Hi", 3.0, 3.3), word(" back.", 3.4, 4.0)]
        let result = phrases(words)
        XCTAssertEqual(result.map(\.text), ["Hello there.", "Hi back."])

        let intervals = [SpeakerInterval(speakerId: "1", start: 0, end: 2.0),
                         SpeakerInterval(speakerId: "2", start: 2.5, end: 5.0)]
        let turns = groupIntoTurns(phrases: result.map { (span: $0.span, text: $0.text) },
                                   intervals: intervals)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speakerId, "1")
        XCTAssertEqual(turns[0].text, "Hello there.")
        XCTAssertEqual(turns[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(turns[0].end, 1.0, accuracy: 0.0001)
        XCTAssertEqual(turns[0].minConfidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(turns[1].speakerId, "2")
        XCTAssertEqual(turns[1].text, "Hi back.")
        XCTAssertEqual(turns[1].start, 3.0, accuracy: 0.0001)
        XCTAssertEqual(turns[1].end, 4.0, accuracy: 0.0001)
    }

    func testGapSplitLetsASpeakerChangeMidSentenceBeAttributedSeparately() {
        // One continuous word run whose speaker changes in the middle, with a pause at the change.
        // Without the gap split the whole run would be one phrase and one speaker would be lost.
        let words = [word("I", 0, 0.2), word(" think", 0.3, 0.6), word(" so", 0.7, 1.0),
                     word("me", 3.0, 3.2), word(" too", 3.3, 3.6)]
        let result = phrases(words)
        XCTAssertEqual(result.map(\.text), ["I think so", "me too"])

        let intervals = [SpeakerInterval(speakerId: "1", start: 0, end: 1.5),
                         SpeakerInterval(speakerId: "2", start: 2.5, end: 4.0)]
        let turns = groupIntoTurns(phrases: result.map { (span: $0.span, text: $0.text) },
                                   intervals: intervals)
        XCTAssertEqual(turns.map(\.speakerId), ["1", "2"])
    }

    func testGroupIntoTurnsSpacesSynthesizedPhrasesCorrectly() {
        // This test previously pinned a BUG: `groupIntoTurns` folded a turn with a bare `.joined()`,
        // and synthesized phrase text is trimmed, so a multi-phrase turn came out as "One.Two.".
        // `joinPhraseTexts` fixed it, and this now asserts the fix.
        let words = [word("One.", 0, 0.5), word("Two.", 0.7, 1.2)]
        let result = phrases(words)
        XCTAssertEqual(result.map(\.text), ["One.", "Two."])

        let intervals = [SpeakerInterval(speakerId: "1", start: 0, end: 2.0)]
        let turns = groupIntoTurns(phrases: result.map { (span: $0.span, text: $0.text) },
                                   intervals: intervals)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "One. Two.")
    }

    func testGroupIntoTurnsLeavesAppleStyleSpacingByteIdentical()  {
        // The other engine's convention: Apple's segments carry their own trailing space. The join must
        // not double it, or every turn boundary in the existing app would gain a space.
        let intervals = [SpeakerInterval(speakerId: "1", start: 0, end: 2.0)]
        let turns = groupIntoTurns(
            phrases: [(span: PhraseSpan(start: 0, end: 1), text: "Hello "),
                      (span: PhraseSpan(start: 1, end: 2), text: "world.")],
            intervals: intervals
        )
        XCTAssertEqual(turns[0].text, "Hello world.")
    }

    // MARK: - joinPhraseTexts

    private func joined(_ texts: [String]) -> String {
        PhraseSegmentation.joinPhraseTexts(texts)
    }

    func testJoinPhraseTextsInsertsOneSpaceBetweenTrimmedPieces() {
        XCTAssertEqual(joined(["One.", "Two."]), "One. Two.")
    }

    func testJoinPhraseTextsDoesNotDoubleAnExistingSpace() {
        XCTAssertEqual(joined(["Hello ", "world."]), "Hello world.")
        XCTAssertEqual(joined(["Hello", " world."]), "Hello world.")
        XCTAssertEqual(joined(["Hello ", " world."]), "Hello  world.")   // both sides spaced: content preserved
    }

    func testJoinPhraseTextsNeverSpacesBeforeHuggingPunctuation() {
        // The reason a plain joined(separator: " ") was not good enough -- an engine that splits a
        // phrase before a comma would otherwise produce "Hello , world".
        XCTAssertEqual(joined(["Hello", ", world"]), "Hello, world")
        XCTAssertEqual(joined(["done", "."]), "done.")
        XCTAssertEqual(joined(["really", "?"]), "really?")
        XCTAssertEqual(joined(["quote", "\u{201D} then"]), "quote\u{201D} then")
        XCTAssertEqual(joined(["fifty", "%"]), "fifty%")
    }

    func testJoinPhraseTextsEdgeCases() {
        XCTAssertEqual(joined([]), "")
        XCTAssertEqual(joined(["only"]), "only")
        XCTAssertEqual(joined(["", "a", "", "b"]), "a b")   // empty pieces cannot leave a double space
        XCTAssertEqual(joined(["a"]), "a")
    }

    func testJoinPhraseTextsPreservesContentExactly() {
        // Only spaces are ever ADDED; nothing is trimmed or rewritten.
        XCTAssertEqual(joined(["  leading", "trailing  "]), "  leading trailing  ")
    }

    func testUnattributedPhrasesStillRoundTripWithoutIntervals() {
        let result = phrases([word("no", 0, 0.3), word(" diarization.", 0.4, 1.0)])
        let turns = groupIntoTurns(phrases: result.map { (span: $0.span, text: $0.text) }, intervals: [])
        XCTAssertEqual(turns.count, 1)
        XCTAssertNil(turns[0].speakerId)
        XCTAssertEqual(turns[0].text, "no diarization.")
    }
}
