import Foundation

/// Pure parsing of the delimited strings the `NotesScript` AppleScripts emit: records separated
/// by newlines, fields within a record separated by ASCII 30 ("record separator" — vanishingly
/// unlikely to appear in an account/folder name, unlike a comma). Lives in BetterVoiceCore so
/// the parsing is unit-testable without the app target's OS surface (see Package.swift).
public enum NotesScriptOutput {

    /// Field separator the AppleScript side interpolates between id and name.
    public static let fieldDelimiter = "\u{1E}"

    public enum ParseError: Error, Equatable {
        case wrongFieldCount(expected: Int, got: Int, line: String)
    }

    /// Non-empty, whitespace-trimmed lines of `output` (one record or plain value per line).
    public static func lines(of output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse `id<RS>name` records, one per line. A line with any other field count (a missing
    /// delimiter, or a name that itself contains the delimiter) is rejected rather than
    /// silently mis-parsed.
    public static func records(of output: String) throws -> [(id: String, name: String)] {
        try lines(of: output).map { line in
            let fields = line.components(separatedBy: fieldDelimiter)
            guard fields.count == 2 else {
                throw ParseError.wrongFieldCount(expected: 2, got: fields.count, line: line)
            }
            return (id: fields[0], name: fields[1])
        }
    }
}
