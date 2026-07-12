import XCTest
@testable import BetterVoiceCore

final class VocabularyRulesTests: XCTestCase {

    private func apply(_ text: String, terms: [String] = [], replacements: [VocabularyReplacement] = []) -> String {
        VocabularyRules.apply(text, terms: terms, replacements: replacements)
    }

    // MARK: - apply: base cases

    func testEmptyTextAndEmptyRulesAreIdentity() {
        XCTAssertEqual(apply("", terms: ["API"]), "")
        XCTAssertEqual(apply("hello world"), "hello world")
    }

    func testAlreadyCorrectTextComesBackByteIdentical() {
        let text = "We pushed to GitHub and FluidAudio picked it up."
        XCTAssertEqual(apply(text, terms: ["GitHub", "FluidAudio"]), text)
    }

    // MARK: - apply: terms (case normalization)

    func testTermNormalizesCaseVariants() {
        XCTAssertEqual(apply("we use github and GITHUB", terms: ["GitHub"]),
                       "we use GitHub and GitHub")
    }

    func testTermDoesNotMatchInsideWords() {
        XCTAssertEqual(apply("capitalize the apiary", terms: ["API"]),
                       "capitalize the apiary")
        XCTAssertEqual(apply("the api is down", terms: ["API"]),
                       "the API is down")
    }

    func testTermRespectsNonASCIILetterBoundaries() {
        // \b would treat the ï→A transition as a word boundary; our lookarounds must not.
        XCTAssertEqual(apply("naïveapi", terms: ["API"]), "naïveapi")
    }

    func testTermMatchesAtStringStartAndEnd() {
        XCTAssertEqual(apply("github", terms: ["GitHub"]), "GitHub")
        XCTAssertEqual(apply("try github.", terms: ["GitHub"]), "try GitHub.")
        XCTAssertEqual(apply("(github)", terms: ["GitHub"]), "(GitHub)")
    }

    // MARK: - apply: explicit replacements

    func testReplacementIsCaseInsensitiveAndMultiWord() {
        XCTAssertEqual(apply("Fluid Audio ships models",
                             replacements: [.init(from: "fluid audio", to: "FluidAudio")]),
                       "FluidAudio ships models")
    }

    func testReplacementInsertsTextVerbatim() {
        XCTAssertEqual(apply("open dr k p x l please",
                             replacements: [.init(from: "dr k p x l", to: "drkpxl")]),
                       "open drkpxl please")
    }

    // MARK: - apply: overlap and chaining

    func testLongestMatchWinsOnOverlap() {
        let result = apply("i said Better Voice today",
                           terms: ["voice"],
                           replacements: [.init(from: "better voice", to: "BetterVoice")])
        XCTAssertEqual(result, "i said BetterVoice today")
    }

    func testAlreadyCorrectLongMatchBlocksShorterRuleInside() {
        // "Better Voice" is the canonical spelling; the shorter "voice" term must not rewrite its inside.
        let result = apply("Better Voice is live", terms: ["Better Voice", "VOICE"])
        XCTAssertEqual(result, "Better Voice is live")
    }

    func testReplacementOutputIsNeverReMatched() {
        let result = apply("a", replacements: [.init(from: "a", to: "b"), .init(from: "b", to: "c")])
        XCTAssertEqual(result, "b")
    }

    func testMultipleOccurrencesAllReplaced() {
        XCTAssertEqual(apply("api api api", terms: ["API"]), "API API API")
    }

    func testEmptyAndWhitespaceFromRulesAreIgnored() {
        XCTAssertEqual(apply("hello", replacements: [.init(from: "", to: "x"), .init(from: "  ", to: "y")]),
                       "hello")
    }

    // MARK: - parseCSV

    func testParseCSVBasicRows() {
        let rows = VocabularyRules.parseCSV("fluid audio,FluidAudio\ngit hub,GitHub")
        XCTAssertEqual(rows, [.init(from: "fluid audio", to: "FluidAudio"),
                              .init(from: "git hub", to: "GitHub")])
    }

    func testParseCSVSkipsHeaderRow() {
        XCTAssertEqual(VocabularyRules.parseCSV("From,To\na,b"), [.init(from: "a", to: "b")])
        XCTAssertEqual(VocabularyRules.parseCSV("Original,Replacement\na,b"), [.init(from: "a", to: "b")])
    }

    func testParseCSVKeepsNonHeaderFirstRow() {
        XCTAssertEqual(VocabularyRules.parseCSV("a,b\nc,d"),
                       [.init(from: "a", to: "b"), .init(from: "c", to: "d")])
    }

    func testParseCSVSkipsBlankAndMalformedLines() {
        XCTAssertEqual(VocabularyRules.parseCSV("\nonly-one-field\na,b\n\n"),
                       [.init(from: "a", to: "b")])
    }

    func testParseCSVQuotedFieldsWithCommasAndEscapes() {
        let rows = VocabularyRules.parseCSV(#""hello, world",greeting"# + "\n" + #""say ""hi""",greet"#)
        XCTAssertEqual(rows, [.init(from: "hello, world", to: "greeting"),
                              .init(from: #"say "hi""#, to: "greet")])
    }

    func testParseCSVTrimsUnquotedFieldsAndHandlesCRLF() {
        XCTAssertEqual(VocabularyRules.parseCSV(" a , b \r\nc,d"),
                       [.init(from: "a", to: "b"), .init(from: "c", to: "d")])
    }

    func testParseCSVIgnoresExtraColumns() {
        XCTAssertEqual(VocabularyRules.parseCSV("a,b,c,d"), [.init(from: "a", to: "b")])
    }
}
