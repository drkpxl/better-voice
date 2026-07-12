import XCTest
@testable import BetterVoiceCore

/// Contract for `MeetingNoteTitle` — the note title Apple Notes derives its display title from
/// (see `NotesScript.createNote`'s doc comment: the first HTML line must be an `<h1>`).
final class MeetingNoteTitleTests: XCTestCase {

    /// Noon in the *current* (device) time zone, so the resulting `Date` maps back to the same
    /// calendar day under `MeetingNoteTitle`'s own (also current-time-zone) formatting no matter
    /// what time zone the test happens to run in — only locale/calendar are fixed, not the zone.
    private func date(year: Int, month: Int, day: Int) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let comps = DateComponents(year: year, month: month, day: day, hour: 12)
        return cal.date(from: comps)!
    }

    // MARK: - LLM title present

    func test_usesLLMTitleWhenPresent() {
        let title = MeetingNoteTitle.title(
            date: date(year: 2026, month: 6, day: 18),
            llmTitle: "Q3 Roadmap Sync",
            typeDisplayName: "1:1"
        )
        XCTAssertEqual(title, "Jun 18th - Q3 Roadmap Sync")
    }

    func test_trimsWhitespaceAroundLLMTitle() {
        let title = MeetingNoteTitle.title(
            date: date(year: 2026, month: 6, day: 18),
            llmTitle: "  Q3 Roadmap Sync  ",
            typeDisplayName: "1:1"
        )
        XCTAssertEqual(title, "Jun 18th - Q3 Roadmap Sync")
    }

    // MARK: - Fallback to type display name

    func test_fallsBackToTypeDisplayNameWhenLLMTitleIsNil() {
        let title = MeetingNoteTitle.title(
            date: date(year: 2026, month: 6, day: 18),
            llmTitle: nil,
            typeDisplayName: "1:1"
        )
        XCTAssertEqual(title, "Jun 18th - 1:1")
    }

    func test_fallsBackToTypeDisplayNameWhenLLMTitleIsBlank() {
        let title = MeetingNoteTitle.title(
            date: date(year: 2026, month: 6, day: 18),
            llmTitle: "   ",
            typeDisplayName: "1:1"
        )
        XCTAssertEqual(title, "Jun 18th - 1:1")
    }

    // MARK: - Transcript variant

    func test_transcriptTitleIsPrefixed() {
        let title = MeetingNoteTitle.transcriptTitle(
            date: date(year: 2026, month: 6, day: 18),
            llmTitle: "Q3 Roadmap Sync",
            typeDisplayName: "1:1"
        )
        XCTAssertEqual(title, "Transcript · Jun 18th - Q3 Roadmap Sync")
    }

    func test_transcriptTitleFallbackIsPrefixed() {
        let title = MeetingNoteTitle.transcriptTitle(
            date: date(year: 2026, month: 6, day: 18),
            llmTitle: nil,
            typeDisplayName: "Status / Standup"
        )
        XCTAssertEqual(title, "Transcript · Jun 18th - Status / Standup")
    }

    // MARK: - Ordinal suffix table

    func test_ordinalSuffixes() {
        let cases: [(Int, String)] = [
            (1, "st"), (2, "nd"), (3, "rd"), (4, "th"),
            (10, "th"), (11, "th"), (12, "th"), (13, "th"),
            (14, "th"), (20, "th"), (21, "st"), (22, "nd"),
            (23, "rd"), (24, "th"), (30, "th"), (31, "st"),
        ]
        for (day, expectedSuffix) in cases {
            let title = MeetingNoteTitle.title(
                date: date(year: 2026, month: 1, day: day),
                llmTitle: nil,
                typeDisplayName: "General"
            )
            XCTAssertEqual(title, "Jan \(day)\(expectedSuffix) - General", "day \(day)")
        }
    }

    // MARK: - Month abbreviations

    func test_monthAbbreviations() {
        let expected = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        for (index, month) in expected.enumerated() {
            let title = MeetingNoteTitle.title(
                date: date(year: 2026, month: index + 1, day: 5),
                llmTitle: nil,
                typeDisplayName: "General"
            )
            XCTAssertEqual(title, "\(month) 5th - General")
        }
    }
}
