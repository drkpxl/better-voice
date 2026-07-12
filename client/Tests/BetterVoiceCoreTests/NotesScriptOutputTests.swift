import XCTest
@testable import BetterVoiceCore

/// Contract for `NotesScriptOutput` — the pure parser for the delimited strings the
/// `NotesScript` AppleScripts emit (fields separated by ASCII 30, records by newline).
final class NotesScriptOutputTests: XCTestCase {

    private let d = NotesScriptOutput.fieldDelimiter

    // MARK: - lines(of:)

    func test_linesSplitsOnNewlinesAndDropsBlanks() {
        XCTAssertEqual(NotesScriptOutput.lines(of: "iCloud\nOn My Mac\n\n"), ["iCloud", "On My Mac"])
    }

    func test_linesTrimsSurroundingWhitespace() {
        XCTAssertEqual(NotesScriptOutput.lines(of: "  iCloud  \n\t\n"), ["iCloud"])
    }

    func test_linesEmptyOutputYieldsEmptyArray() {
        XCTAssertEqual(NotesScriptOutput.lines(of: ""), [])
        XCTAssertEqual(NotesScriptOutput.lines(of: "\n\n"), [])
    }

    // MARK: - records(of:)

    func test_recordsEmptyOutputYieldsEmptyArray() throws {
        XCTAssertTrue(try NotesScriptOutput.records(of: "").isEmpty)
        XCTAssertTrue(try NotesScriptOutput.records(of: "\n").isEmpty)
    }

    func test_recordsParsesMultipleRecords() throws {
        let output = "x-coredata://AAA/ICFolder/p1\(d)Meetings\nx-coredata://AAA/ICFolder/p2\(d)Notes\n"
        let records = try NotesScriptOutput.records(of: output)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].id, "x-coredata://AAA/ICFolder/p1")
        XCTAssertEqual(records[0].name, "Meetings")
        XCTAssertEqual(records[1].id, "x-coredata://AAA/ICFolder/p2")
        XCTAssertEqual(records[1].name, "Notes")
    }

    func test_recordsNamesContainingCommasSurviveIntact() throws {
        let output = "id-1\(d)Meetings, 1:1s, and Standups\n"
        let records = try NotesScriptOutput.records(of: output)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "Meetings, 1:1s, and Standups")
    }

    func test_recordsMissingDelimiterThrowsWrongFieldCount() {
        XCTAssertThrowsError(try NotesScriptOutput.records(of: "just-an-id-no-name\n")) { error in
            XCTAssertEqual(
                error as? NotesScriptOutput.ParseError,
                .wrongFieldCount(expected: 2, got: 1, line: "just-an-id-no-name")
            )
        }
    }

    func test_recordsExtraDelimiterInsideNameThrowsWrongFieldCount() {
        // A name that itself contains the delimiter adjacent to content splits into 3 fields —
        // rejected rather than silently mis-parsed.
        let line = "id-1\(d)Mee\(d)tings"
        XCTAssertThrowsError(try NotesScriptOutput.records(of: line + "\n")) { error in
            XCTAssertEqual(
                error as? NotesScriptOutput.ParseError,
                .wrongFieldCount(expected: 2, got: 3, line: line)
            )
        }
    }

    func test_recordsTrailingDelimiterThrowsWrongFieldCount() {
        // Delimiter at the end of the line ("id<RS>name<RS>") yields a trailing empty field.
        let line = "id-1\(d)Meetings\(d)"
        XCTAssertThrowsError(try NotesScriptOutput.records(of: line + "\n")) { error in
            XCTAssertEqual(
                error as? NotesScriptOutput.ParseError,
                .wrongFieldCount(expected: 2, got: 3, line: line)
            )
        }
    }
}
