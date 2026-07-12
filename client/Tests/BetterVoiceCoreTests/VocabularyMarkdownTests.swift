import XCTest
@testable import BetterVoiceCore

final class VocabularyMarkdownTests: XCTestCase {

    func testEmptyInputReturnsEmptyLists() {
        let (terms, replacements) = parseVocabularyMarkdown("")
        XCTAssertEqual(terms, [])
        XCTAssertEqual(replacements, [])
    }

    func testParsesTermsAndReplacements() {
        let md = """
        ## Terms
        - FluidAudio
        - GitHub

        ## Replacements
        - fluid audio -> FluidAudio
        - dr k p x l -> drkpxl
        """
        let (terms, replacements) = parseVocabularyMarkdown(md)
        XCTAssertEqual(terms, ["FluidAudio", "GitHub"])
        XCTAssertEqual(replacements, [
            .init(from: "fluid audio", to: "FluidAudio"),
            .init(from: "dr k p x l", to: "drkpxl"),
        ])
    }

    func testAcceptsUnicodeArrow() {
        let (_, replacements) = parseVocabularyMarkdown("## Replacements\n- fluid audio \u{2192} FluidAudio")
        XCTAssertEqual(replacements, [.init(from: "fluid audio", to: "FluidAudio")])
    }

    func testSkipsMalformedReplacementBullets() {
        let md = """
        ## Replacements
        - no arrow here
        - -> missing from side
        - missing to side ->
        - a -> b
        """
        let (_, replacements) = parseVocabularyMarkdown(md)
        XCTAssertEqual(replacements, [.init(from: "a", to: "b")])
    }

    func testProseAndBlankLinesIgnored() {
        let md = """
        # Vocabulary

        Some free-text instructions the app never parses.

        ## Terms
        Helper prose right after the heading, also ignored.

        - API

        ## Replacements

        - a -> b
        """
        let (terms, replacements) = parseVocabularyMarkdown(md)
        XCTAssertEqual(terms, ["API"])
        XCTAssertEqual(replacements, [.init(from: "a", to: "b")])
    }

    func testTermsOnlyFileParsesEmptyReplacements() {
        let (terms, replacements) = parseVocabularyMarkdown("## Terms\n- API\n")
        XCTAssertEqual(terms, ["API"])
        XCTAssertEqual(replacements, [])
    }

    func testUnknownHeadingIgnored() {
        let (terms, _) = parseVocabularyMarkdown("## Notes\n- not a term\n## Terms\n- API")
        XCTAssertEqual(terms, ["API"])
    }

    func testRenderIncludesBothHeadingsEvenWhenEmpty() {
        let md = renderVocabularyMarkdown(terms: [], replacements: [])
        XCTAssertTrue(md.contains("## Terms"))
        XCTAssertTrue(md.contains("## Replacements"))
    }

    func testRoundTripRecoversSameLists() {
        let terms = ["FluidAudio", "GitHub", "drkpxl"]
        let replacements = [
            VocabularyReplacement(from: "fluid audio", to: "FluidAudio"),
            VocabularyReplacement(from: "dr k p x l", to: "drkpxl"),
        ]
        let rendered = renderVocabularyMarkdown(terms: terms, replacements: replacements)
        let (parsedTerms, parsedReplacements) = parseVocabularyMarkdown(rendered)
        XCTAssertEqual(parsedTerms, terms)
        XCTAssertEqual(parsedReplacements, replacements)
    }
}
