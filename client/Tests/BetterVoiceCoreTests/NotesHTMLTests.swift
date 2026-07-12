import XCTest
@testable import BetterVoiceCore

/// Contract for `markdownToNotesHTML` — the small Markdown subset our generated transcripts and
/// summaries actually use (see `MeetingMarkdown` / `SummarizationLogic`). Not a general
/// CommonMark parser: no nesting, no tables, no reference links.
final class NotesHTMLTests: XCTestCase {

    // MARK: - Headings

    func test_h1() {
        XCTAssertEqual(markdownToNotesHTML("# Title"), "<h1>Title</h1>")
    }

    func test_h2() {
        XCTAssertEqual(markdownToNotesHTML("## Section"), "<h2>Section</h2>")
    }

    func test_h3() {
        XCTAssertEqual(markdownToNotesHTML("### Speaker"), "<h3>Speaker</h3>")
    }

    func test_h4AndDeeperAreNotHeadings_fallsBackToParagraph() {
        XCTAssertEqual(markdownToNotesHTML("#### Not a heading"), "<p>#### Not a heading</p>")
    }

    func test_hashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(markdownToNotesHTML("#NotAHeading"), "<p>#NotAHeading</p>")
    }

    // MARK: - Paragraphs

    func test_singleParagraph() {
        XCTAssertEqual(markdownToNotesHTML("Just some text."), "<p>Just some text.</p>")
    }

    func test_blankLineSeparatedParagraphs() {
        let md = "First paragraph.\n\nSecond paragraph."
        let html = markdownToNotesHTML(md)
        XCTAssertEqual(html, "<p>First paragraph.</p>\n<p>Second paragraph.</p>")
    }

    func test_contiguousPlainLinesJoinIntoOneParagraphWithLineBreak() {
        let md = "Line one\nLine two"
        XCTAssertEqual(markdownToNotesHTML(md), "<p>Line one<br>Line two</p>")
    }

    // MARK: - Lists

    func test_bulletListWithDash() {
        let md = "- One\n- Two\n- Three"
        XCTAssertEqual(markdownToNotesHTML(md), "<ul>\n<li>One</li>\n<li>Two</li>\n<li>Three</li>\n</ul>")
    }

    func test_bulletListWithAsterisk() {
        let md = "* One\n* Two"
        XCTAssertEqual(markdownToNotesHTML(md), "<ul>\n<li>One</li>\n<li>Two</li>\n</ul>")
    }

    // Apple Notes merges <ol> into an adjacent <ul> and loses numbering (confirmed by a live
    // spike), so ordered lists render as <ul><li> with an explicit "N. " text prefix instead.
    func test_orderedList() {
        let md = "1. First\n2. Second\n3. Third"
        XCTAssertEqual(markdownToNotesHTML(md), "<ul>\n<li>1. First</li>\n<li>2. Second</li>\n<li>3. Third</li>\n</ul>")
    }

    func test_orderedListNumberingRestartsPerList() {
        let md = "1. a\n2. b\n\n1. c\n2. d\n3. e"
        let html = markdownToNotesHTML(md)
        XCTAssertEqual(
            html,
            "<ul>\n<li>1. a</li>\n<li>2. b</li>\n</ul>\n<ul>\n<li>1. c</li>\n<li>2. d</li>\n<li>3. e</li>\n</ul>"
        )
    }

    func test_contiguousListLinesGroupIntoOneList() {
        // No blank lines between items: exactly one <ul>, not three.
        let md = "- a\n- b\n- c"
        let html = markdownToNotesHTML(md)
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "</ul>").count - 1, 1)
    }

    func test_adjacentListsSeparatedByBlankLineAreTwoLists() {
        let md = "- a\n- b\n\n- c\n- d"
        let html = markdownToNotesHTML(md)
        XCTAssertEqual(html, "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ul>\n<li>c</li>\n<li>d</li>\n</ul>")
    }

    func test_listFollowedImmediatelyByParagraphEndsTheList() {
        let md = "- a\n- b\nParagraph text"
        let html = markdownToNotesHTML(md)
        XCTAssertEqual(html, "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<p>Paragraph text</p>")
    }

    func test_paragraphBetweenTwoListsKeepsThemSeparate() {
        let md = "- a\n\nmiddle paragraph\n\n- b"
        let html = markdownToNotesHTML(md)
        XCTAssertEqual(html, "<ul>\n<li>a</li>\n</ul>\n<p>middle paragraph</p>\n<ul>\n<li>b</li>\n</ul>")
    }

    // MARK: - Task lists

    func test_taskListUnchecked() {
        XCTAssertEqual(markdownToNotesHTML("- [ ] Do the thing"), "<ul>\n<li>☐ Do the thing</li>\n</ul>")
    }

    func test_taskListChecked() {
        XCTAssertEqual(markdownToNotesHTML("- [x] Done thing"), "<ul>\n<li>☑ Done thing</li>\n</ul>")
    }

    func test_taskListCheckedUppercaseX() {
        XCTAssertEqual(markdownToNotesHTML("- [X] Done thing"), "<ul>\n<li>☑ Done thing</li>\n</ul>")
    }

    func test_mixedTaskList() {
        let md = "- [ ] Todo one\n- [x] Done one\n- [ ] Todo two"
        XCTAssertEqual(
            markdownToNotesHTML(md),
            "<ul>\n<li>☐ Todo one</li>\n<li>☑ Done one</li>\n<li>☐ Todo two</li>\n</ul>"
        )
    }

    // MARK: - Inline formatting

    func test_inlineCode() {
        XCTAssertEqual(markdownToNotesHTML("Elapsed `00:42` so far"), "<p>Elapsed <code>00:42</code> so far</p>")
    }

    func test_bold() {
        XCTAssertEqual(markdownToNotesHTML("This is **important**."), "<p>This is <strong>important</strong>.</p>")
    }

    func test_italic() {
        XCTAssertEqual(markdownToNotesHTML("This is *emphasized*."), "<p>This is <em>emphasized</em>.</p>")
    }

    // Apple Notes strips <a href> down to underlined plain text (confirmed by a live spike), so
    // links render as escaped "text (url)" instead of an anchor tag.
    func test_link() {
        XCTAssertEqual(
            markdownToNotesHTML("See [the doc](https://example.com/doc?a=1&b=2)."),
            "<p>See the doc (https://example.com/doc?a=1&amp;b=2).</p>"
        )
    }

    func test_linkTextIdenticalToURLRendersOnce() {
        XCTAssertEqual(
            markdownToNotesHTML("Visit [https://example.com](https://example.com) today."),
            "<p>Visit https://example.com today.</p>"
        )
    }

    func test_horizontalRule() {
        XCTAssertEqual(markdownToNotesHTML("---"), "<hr>")
    }

    func test_horizontalRuleSeparatesParagraphs() {
        let md = "Above.\n\n---\n\nBelow."
        XCTAssertEqual(markdownToNotesHTML(md), "<p>Above.</p>\n<hr>\n<p>Below.</p>")
    }

    // MARK: - Escaping

    func test_escapesAmpersandLessThanGreaterThanQuoteInParagraph() {
        XCTAssertEqual(
            markdownToNotesHTML("Ben & Co <script> said \"hi\""),
            "<p>Ben &amp; Co &lt;script&gt; said &quot;hi&quot;</p>"
        )
    }

    func test_escapesInsideCodeSpan() {
        XCTAssertEqual(
            markdownToNotesHTML("`<tag> & \"quote\"`"),
            "<p><code>&lt;tag&gt; &amp; &quot;quote&quot;</code></p>"
        )
    }

    func test_escapesInsideLinkText() {
        XCTAssertEqual(
            markdownToNotesHTML("[A & B](https://example.com)"),
            "<p>A &amp; B (https://example.com)</p>"
        )
    }

    func test_escapesInHeading() {
        XCTAssertEqual(markdownToNotesHTML("# Ben & Co"), "<h1>Ben &amp; Co</h1>")
    }

    func test_escapesInsideBoldSpan() {
        XCTAssertEqual(
            markdownToNotesHTML("**a<b & c>**"),
            "<p><strong>a&lt;b &amp; c&gt;</strong></p>"
        )
    }

    func test_escapesInsideItalicSpan() {
        XCTAssertEqual(
            markdownToNotesHTML("*\"quoted\" & <tagged>*"),
            "<p><em>&quot;quoted&quot; &amp; &lt;tagged&gt;</em></p>"
        )
    }

    func test_escapesInTaskListItem() {
        XCTAssertEqual(
            markdownToNotesHTML("- [ ] Fix <bug> & ship"),
            "<ul>\n<li>☐ Fix &lt;bug&gt; &amp; ship</li>\n</ul>"
        )
    }

    // MARK: - Realistic samples

    /// Shape of `MeetingMarkdown.renderTranscript`: title, metadata bullets, `---`, then
    /// `### Speaker` headings each followed by one or more `` `MM:SS` `` turn paragraphs.
    func test_realisticTranscriptSample() {
        let md = """
        # Meeting Transcript

        - Date: 2026-07-10 09:30
        - Duration: 12m 30s

        ---

        ### Sam

        `00:00` Morning everyone, let's start.

        `00:12` The rollout finished last night.

        ### Speaker 2

        `00:30` Any regressions so far? Let's check the <alerts> dashboard & the on-call channel.
        """
        let html = markdownToNotesHTML(md)

        XCTAssertTrue(html.hasPrefix("<h1>Meeting Transcript</h1>"))
        XCTAssertTrue(html.contains("<ul>\n<li>Date: 2026-07-10 09:30</li>\n<li>Duration: 12m 30s</li>\n</ul>"))
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<h3>Sam</h3>"))
        XCTAssertTrue(html.contains("<p><code>00:00</code> Morning everyone, let's start.</p>"))
        XCTAssertTrue(html.contains("<p><code>00:12</code> The rollout finished last night.</p>"))
        XCTAssertTrue(html.contains("<h3>Speaker 2</h3>"))
        XCTAssertTrue(html.contains("&lt;alerts&gt; dashboard &amp; the on-call channel."))
        // First line of the HTML body must be an <h1> — Apple Notes derives the note's visible
        // title from it (see NotesScript.createNote).
        XCTAssertTrue(html.hasPrefix("<h1>"))
    }

    /// Shape of a typical LLM-produced summary: headings, bullets, and an action-item task list.
    func test_realisticSummarySample() {
        let md = """
        # Summary

        - Date: 2026-07-10
        - Duration: 12m 30s

        ---

        ## Key Points

        - Rollout finished with no regressions
        - Next check-in is Thursday

        ## Action Items

        - [ ] File the follow-up ticket
        - [x] Notify the on-call channel

        Overall a **smooth** rollout, per *everyone* on the call.
        """
        let html = markdownToNotesHTML(md)

        XCTAssertTrue(html.hasPrefix("<h1>Summary</h1>"))
        XCTAssertTrue(html.contains("<h2>Key Points</h2>"))
        XCTAssertTrue(html.contains("<ul>\n<li>Rollout finished with no regressions</li>\n<li>Next check-in is Thursday</li>\n</ul>"))
        XCTAssertTrue(html.contains("<h2>Action Items</h2>"))
        XCTAssertTrue(html.contains("<ul>\n<li>☐ File the follow-up ticket</li>\n<li>☑ Notify the on-call channel</li>\n</ul>"))
        XCTAssertTrue(html.contains("<p>Overall a <strong>smooth</strong> rollout, per <em>everyone</em> on the call.</p>"))
    }
}
