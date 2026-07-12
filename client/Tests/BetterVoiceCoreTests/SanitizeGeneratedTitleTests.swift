import XCTest
@testable import BetterVoiceCore

/// Contract for `sanitizeGeneratedTitle` — cleans up `SummarizationClient`'s dedicated
/// follow-up "give me a title" call (Bug 3: the inline `TITLE:` line the main summarization
/// prompt asks for isn't reliably produced, notably by the Apple on-device backend's map-reduce
/// path — see `SummarizationLogic.swift`'s doc comment on this function).
final class SanitizeGeneratedTitleTests: XCTestCase {

    func test_passesThroughAlreadyCleanTitle() {
        XCTAssertEqual(sanitizeGeneratedTitle("Q3 Roadmap Sync"), "Q3 Roadmap Sync")
    }

    func test_trimsWhitespace() {
        XCTAssertEqual(sanitizeGeneratedTitle("  Q3 Roadmap Sync  \n"), "Q3 Roadmap Sync")
    }

    func test_stripsLeadingTitleLabel() {
        XCTAssertEqual(sanitizeGeneratedTitle("Title: Q3 Roadmap Sync"), "Q3 Roadmap Sync")
        XCTAssertEqual(sanitizeGeneratedTitle("TITLE: Q3 Roadmap Sync"), "Q3 Roadmap Sync")
    }

    func test_stripsWrappingStraightQuotes() {
        XCTAssertEqual(sanitizeGeneratedTitle("\"Q3 Roadmap Sync\""), "Q3 Roadmap Sync")
        XCTAssertEqual(sanitizeGeneratedTitle("'Q3 Roadmap Sync'"), "Q3 Roadmap Sync")
    }

    func test_stripsWrappingCurlyQuotes() {
        XCTAssertEqual(sanitizeGeneratedTitle("\u{201C}Q3 Roadmap Sync\u{201D}"), "Q3 Roadmap Sync")
    }

    func test_stripsMarkdownHeadingMarker() {
        XCTAssertEqual(sanitizeGeneratedTitle("# Q3 Roadmap Sync"), "Q3 Roadmap Sync")
        XCTAssertEqual(sanitizeGeneratedTitle("## Q3 Roadmap Sync"), "Q3 Roadmap Sync")
    }

    func test_stripsBoldMarkers() {
        XCTAssertEqual(sanitizeGeneratedTitle("**Q3 Roadmap Sync**"), "Q3 Roadmap Sync")
    }

    func test_stripsNestedBoldAndQuotes() {
        XCTAssertEqual(sanitizeGeneratedTitle("**\"Q3 Roadmap Sync\"**"), "Q3 Roadmap Sync")
    }

    func test_stripsTrailingPeriod() {
        XCTAssertEqual(sanitizeGeneratedTitle("Q3 Roadmap Sync."), "Q3 Roadmap Sync")
    }

    func test_stripsTrailingPunctuationVariants() {
        XCTAssertEqual(sanitizeGeneratedTitle("Q3 Roadmap Sync!"), "Q3 Roadmap Sync")
        XCTAssertEqual(sanitizeGeneratedTitle("Q3 Roadmap Sync,"), "Q3 Roadmap Sync")
        XCTAssertEqual(sanitizeGeneratedTitle("Q3 Roadmap Sync:"), "Q3 Roadmap Sync")
    }

    func test_keepsOnlyFirstLineOfMultiLineResponse() {
        XCTAssertEqual(sanitizeGeneratedTitle("Q3 Roadmap Sync\nSome extra chatter the model added."), "Q3 Roadmap Sync")
    }

    func test_skipsLeadingBlankLines() {
        XCTAssertEqual(sanitizeGeneratedTitle("\n\nQ3 Roadmap Sync"), "Q3 Roadmap Sync")
    }

    func test_emptyInputReturnsNil() {
        XCTAssertNil(sanitizeGeneratedTitle(""))
    }

    func test_whitespaceOnlyInputReturnsNil() {
        XCTAssertNil(sanitizeGeneratedTitle("   \n  "))
    }

    func test_titleLabelWithNothingAfterReturnsNil() {
        XCTAssertNil(sanitizeGeneratedTitle("Title:"))
    }

    func test_onlyPunctuationReturnsNil() {
        XCTAssertNil(sanitizeGeneratedTitle("\"\"."))
    }

    func test_capsLengthAtWordBoundary() {
        let long = "This is a very long generated title that goes on and on and on and on and well past a reasonable length for a note title"
        let result = sanitizeGeneratedTitle(long, maxLength: 40)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.count, 40)
        XCTAssertFalse(result!.hasSuffix(" "))
        // Confirms word-boundary truncation, not a mid-word chop.
        XCTAssertFalse(long.hasPrefix(result! + "well"))
    }

    func test_shortTitleUnderMaxLengthIsUnaffected() {
        XCTAssertEqual(sanitizeGeneratedTitle("Short Title", maxLength: 80), "Short Title")
    }

    func test_singleOverlongWordFallsBackToHardTruncate() {
        let word = String(repeating: "x", count: 100)
        let result = sanitizeGeneratedTitle(word, maxLength: 20)
        XCTAssertEqual(result?.count, 20)
    }

    // MARK: - stripEchoedContext / stripStrayTitleLines

    func test_stripEchoedContext_removesHeadingAndVerbatimContextLine() {
        let context = "Steven is the Senior Director of Digital Experience at Alterra."
        let raw = """
        Personal context
        \(context)
        TITLE: Meeting with Peter
        Summary
        They talked.
        """
        let out = stripEchoedContext(raw, personalContext: context)
        XCTAssertFalse(out.contains("Personal context"))
        XCTAssertFalse(out.contains(context))
        XCTAssertTrue(out.hasPrefix("TITLE: Meeting with Peter"))
        XCTAssertTrue(out.contains("They talked."))
    }

    func test_stripEchoedContext_removesMarkdownWrappedHeading() {
        let out = stripEchoedContext("## Personal context\nSummary\nx", personalContext: nil)
        XCTAssertEqual(out, "Summary\nx")
    }

    func test_stripEchoedContext_leavesCleanSummaryUntouched() {
        let s = "Summary\nThey discussed the roadmap.\nKey points\n* A"
        XCTAssertEqual(stripEchoedContext(s, personalContext: "Steven is a director."), s)
    }

    func test_stripStrayTitleLines_removesTitleLinesAnywhere() {
        let md = "Summary\nThey met.\nTITLE: A second title\nKey points\n* x"
        let out = stripStrayTitleLines(md)
        XCTAssertFalse(out.contains("TITLE:"))
        XCTAssertTrue(out.contains("They met."))
        XCTAssertTrue(out.contains("Key points"))
    }

    // End-to-end: the exact leak shape reported in UAT (context echo + non-leading TITLE) →
    // parse extracts the model's title, body has neither the context nor the TITLE line.
    func test_deleakThenParse_producesTitleAndCleanBody() {
        let context = "Steven is the Senior Director of Digital Experience at Alterra."
        let raw = """
        Personal context
        \(context)
        TITLE: Meeting with Peter and Guy
        Summary
        A casual introduction.
        """
        let deleaked = stripEchoedContext(raw, personalContext: context)
        let parsed = parseSummaryTitle(from: deleaked)
        let body = stripStrayTitleLines(parsed.markdown)
        XCTAssertEqual(parsed.title, "Meeting with Peter and Guy")
        XCTAssertFalse(body.contains("Personal context"))
        XCTAssertFalse(body.contains(context))
        XCTAssertFalse(body.contains("TITLE:"))
        XCTAssertTrue(body.hasPrefix("Summary"))
    }
}
