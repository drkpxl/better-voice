import XCTest
@testable import BetterVoiceCore

/// The regression these guard: an untouched `personal-context.md` used to reach the model as if it
/// were real background, because the starter template is not an empty file. It measurably degraded
/// summaries (up to 20 points of thread recall, direction depending on the model).
final class PersonalContextRulesTests: XCTestCase {

    /// Byte-for-byte copy of `PersonalContext.template`. Duplicated deliberately: the template lives
    /// in the app target, which the test target cannot import, and pinning it here also makes the
    /// tests fail loudly if the shipped template is reworded without revisiting this logic.
    private let template = """
    # Personal context

    This file gives the local AI background about you so it spells names, jargon,
    and acronyms correctly when summarizing meetings. It is used only for
    disambiguation — it is never added to your summaries.

    Edit freely. Useful things to include:
    - Your name and how it's spelled.
    - Your company / team and what it does.
    - Your role / title.
    - People you talk to often (names + roles).
    - Recurring projects, products, tools, and acronyms.

    ## About me


    ## People


    ## Projects & terms

    """

    private func authored(_ text: String) -> String {
        PersonalContextRules.authoredContent(in: text, scaffolding: template)
    }

    // MARK: - The bug

    func testUntouchedTemplateYieldsNothing() {
        XCTAssertEqual(authored(template), "")
    }

    func testEmptyFileYieldsNothing() {
        XCTAssertEqual(authored(""), "")
        XCTAssertEqual(authored("\n\n   \n"), "")
    }

    func testTemplateStrippedOfItsPreambleButStillEmptyYieldsNothing() {
        // A user who deletes the explanatory prose but never fills the sections in has still written
        // nothing. Comparing the whole file against the template would miss this.
        let gutted = """
        # Personal context

        ## About me

        ## People

        ## Projects & terms
        """
        XCTAssertEqual(authored(gutted), "")
    }

    func testHeadingsAloneNeverReachTheModel() {
        XCTAssertEqual(authored("## About me\n\n## People\n"), "")
    }

    // MARK: - Real content survives

    func testContentUnderAHeadingKeepsItsHeading() {
        let filled = template.replacingOccurrences(
            of: "## About me\n",
            with: "## About me\nI am a design lead at a ski company.\n"
        )
        XCTAssertEqual(authored(filled), "## About me\nI am a design lead at a ski company.")
    }

    func testOnlyHeadingsWithContentAreKept() {
        let filled = """
        # Personal context

        ## About me

        ## People
        Dana runs platform.

        ## Projects & terms
        """
        // "About me" and "Projects & terms" are empty, so they collapse away entirely.
        XCTAssertEqual(authored(filled), "## People\nDana runs platform.")
    }

    func testFreeTextWithNoHeadingsIsKept() {
        // A user may simply delete the template and type prose.
        XCTAssertEqual(authored("I work at Acme. Dana runs platform."),
                       "I work at Acme. Dana runs platform.")
    }

    func testUserHeadingsAreKeptWhenTheyHaveContent() {
        let custom = "## Acronyms\nRACI is a responsibility matrix.\n"
        XCTAssertEqual(authored(custom), "## Acronyms\nRACI is a responsibility matrix.")
    }

    func testMultipleFilledSectionsPreserveOrder() {
        let filled = """
        ## About me
        Design lead.

        ## People
        Dana runs platform.
        Sam runs engineering.
        """
        XCTAssertEqual(
            authored(filled),
            "## About me\nDesign lead.\n## People\nDana runs platform.\nSam runs engineering."
        )
    }

    // MARK: - Scaffolding subtraction specifics

    func testALeftoverTemplateBulletIsNotTreatedAsContent() {
        // The user filled in one section but left the "Useful things to include" list in place; the
        // list is an instruction to them, not background about them.
        let filled = template.replacingOccurrences(
            of: "## People\n",
            with: "## People\nDana runs platform.\n"
        )
        let result = authored(filled)
        XCTAssertEqual(result, "## People\nDana runs platform.")
        XCTAssertFalse(result.contains("Edit freely"))
        XCTAssertFalse(result.contains("Your name and how it's spelled"))
    }

    func testIndentationAndTrailingWhitespaceDoNotDefeatSubtraction() {
        let padded = "   Edit freely. Useful things to include:   \n  ## People  \n  Dana.  \n"
        XCTAssertEqual(authored(padded), "## People\nDana.")
    }

    func testContentThatMerelyResemblesTemplateProseIsKept() {
        // Only exact line matches count as scaffolding, so a user's own sentence survives.
        let text = "## About me\nEdit freely is a phrase I happen to use.\n"
        XCTAssertEqual(authored(text), "## About me\nEdit freely is a phrase I happen to use.")
    }

    func testEmptyScaffoldingKeepsEverythingExceptBareHeadings() {
        XCTAssertEqual(
            PersonalContextRules.authoredContent(in: "## A\nkeep me\n", scaffolding: ""),
            "## A\nkeep me"
        )
        XCTAssertEqual(PersonalContextRules.authoredContent(in: "## A\n", scaffolding: ""), "")
    }

    func testCRLFLineEndingsAreHandled() {
        // A user editing the file on another platform, or pasting from one, should not defeat this.
        let crlf = "## People\r\nDana runs platform.\r\n"
        XCTAssertEqual(authored(crlf), "## People\nDana runs platform.")
    }
}
