import XCTest
@testable import BetterVoiceCore

final class TextChunkingTests: XCTestCase {

    // MARK: - estimatedTokenCount

    func testEstimatedTokenCountEmptyIsZero() {
        XCTAssertEqual(estimatedTokenCount(for: ""), 0)
    }

    func testEstimatedTokenCountAtLeastOneForNonEmpty() {
        XCTAssertEqual(estimatedTokenCount(for: "a"), 1)
        XCTAssertEqual(estimatedTokenCount(for: "ab"), 1)
    }

    func testEstimatedTokenCountDividesCharsByThree() {
        XCTAssertEqual(estimatedTokenCount(for: String(repeating: "x", count: 300)), 100)
        XCTAssertEqual(estimatedTokenCount(for: String(repeating: "x", count: 301)), 100) // floor
    }

    // MARK: - chunkTextByLines: base cases

    func testShortTextIsOneChunk() {
        let text = "hello world"
        XCTAssertEqual(chunkTextByLines(text, maxChars: 1000), [text])
    }

    func testEmptyTextReturnsNoChunks() {
        XCTAssertEqual(chunkTextByLines("", maxChars: 100), [])
    }

    func testNonPositiveMaxCharsReturnsWholeTextUnchanged() {
        let text = "line one\nline two\nline three"
        XCTAssertEqual(chunkTextByLines(text, maxChars: 0), [text])
        XCTAssertEqual(chunkTextByLines(text, maxChars: -5), [text])
    }

    func testNeverReturnsEmptyArrayForNonEmptyInput() {
        XCTAssertFalse(chunkTextByLines("x", maxChars: 1).isEmpty)
        XCTAssertFalse(chunkTextByLines("a\nb\nc", maxChars: 2).isEmpty)
    }

    // MARK: - Multi-line splitting near the budget

    func testMultiLineSplitsOnLineBoundaries() {
        // Each line is 5 chars + \n = 6 chars. A budget of 12 fits two lines per chunk.
        let text = "line1\nline2\nline3\nline4"
        let chunks = chunkTextByLines(text, maxChars: 12)
        // No chunk splits a line in half — each chunk is a whole number of lines.
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 12)
        }
        XCTAssertEqual(chunks, ["line1\nline2\n", "line3\nline4"])
    }

    func testEachLineStaysWholeAcrossChunkBoundaries() {
        let text = (1...20).map { "line number \($0)" }.joined(separator: "\n")
        let chunks = chunkTextByLines(text, maxChars: 50)
        // Reassembling every line out of the chunks reproduces the original line list.
        let reassembledLines = chunks.joined().components(separatedBy: "\n").filter { !$0.isEmpty }
        let originalLines = text.components(separatedBy: "\n")
        XCTAssertEqual(reassembledLines, originalLines)
    }

    // MARK: - Oversized single line hard-splits

    func testOversizedSingleLineHardSplits() {
        let longLine = String(repeating: "z", count: 25)
        let chunks = chunkTextByLines(longLine, maxChars: 10)
        XCTAssertEqual(chunks, [
            String(repeating: "z", count: 10),
            String(repeating: "z", count: 10),
            String(repeating: "z", count: 5),
        ])
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 10)
        }
    }

    func testOversizedLineAmongNormalLinesFlushesFirst() {
        let text = "short\n" + String(repeating: "z", count: 25) + "\nshort2"
        let chunks = chunkTextByLines(text, maxChars: 10)
        // "short\n" (6 chars) is flushed on its own before the oversized line is hard-split.
        XCTAssertEqual(chunks.first, "short\n")
        XCTAssertEqual(chunks.last, "short2")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 10)
        }
    }

    // MARK: - Content preservation

    func testContentPreservationAcrossVariousBudgets() {
        let text = """
        Speaker 1: Hello, how are you today?
        Speaker 2: I'm doing well, thanks for asking.
        Speaker 1: Great, let's get started with the agenda.
        Speaker 2: Sounds good to me.
        """
        for maxChars in [1, 5, 10, 20, 50, 1000] {
            let chunks = chunkTextByLines(text, maxChars: maxChars)
            XCTAssertEqual(chunks.joined(), text, "maxChars=\(maxChars) should reproduce the text exactly")
        }
    }

    func testContentPreservationWithHardSplitLines() {
        let text = "prefix\n" + String(repeating: "abc123", count: 40) + "\nsuffix line here"
        for maxChars in [1, 3, 7, 25, 200] {
            let chunks = chunkTextByLines(text, maxChars: maxChars)
            XCTAssertEqual(chunks.joined(), text, "maxChars=\(maxChars) should reproduce the text exactly")
        }
    }

    func testContentPreservationNoTrailingNewline() {
        let text = "no trailing newline here"
        let chunks = chunkTextByLines(text, maxChars: 5)
        XCTAssertEqual(chunks.joined(), text)
    }

    func testContentPreservationWithTrailingNewline() {
        let text = "line1\nline2\n"
        let chunks = chunkTextByLines(text, maxChars: 4)
        XCTAssertEqual(chunks.joined(), text)
    }
}
