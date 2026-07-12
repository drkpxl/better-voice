import Foundation

/// One explicit replacement: a misheard/misspelled form and the exact text to insert.
public struct VocabularyReplacement: Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Pure vocabulary logic: the deterministic replacement engine and the CSV parser.
/// File IO and hot-reload live app-side in `Vocabulary.swift`.
public enum VocabularyRules {

    /// Apply terms (case-normalization to the canonical spelling) and explicit replacements
    /// to `text`. Matching is case-insensitive and word-boundary; on overlapping candidates
    /// the longest match wins, then the leftmost. Replacement output is never re-matched,
    /// so rules cannot chain ("a"→"b" plus "b"→"c" turns "a" into "b", not "c").
    /// Empty text or no rules returns `text` unchanged.
    public static func apply(_ text: String, terms: [String], replacements: [VocabularyReplacement]) -> String {
        let rules = terms.map { VocabularyReplacement(from: $0, to: $0) } + replacements
        let candidates = matches(in: text, rules: rules)
        guard !candidates.isEmpty else { return text }

        // Longest-then-leftmost wins on overlap.
        let ranked = candidates.sorted {
            $0.range.length != $1.range.length
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        var accepted: [Match] = []
        for candidate in ranked {
            if !accepted.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
                accepted.append(candidate)
            }
        }

        // Splice back-to-front so earlier ranges stay valid.
        let result = NSMutableString(string: text)
        for match in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: match.range, with: match.replacement)
        }
        return result as String
    }

    /// Parse "from,to" CSV lines into replacements. Skips blank lines, a header row
    /// ("from,to" or "original,replacement", case-insensitive), and rows without a second
    /// field. Double-quoted fields support embedded commas and `""` escapes; whitespace
    /// around unquoted fields is trimmed. Columns beyond the second are ignored.
    public static func parseCSV(_ text: String) -> [VocabularyReplacement] {
        var result: [VocabularyReplacement] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for (index, line) in lines.enumerated() {
            let fields = parseCSVLine(String(line))
            guard fields.count >= 2 else { continue }
            let from = fields[0], to = fields[1]
            if from.isEmpty || to.isEmpty { continue }
            if index == 0 {
                let header = [from.lowercased(), to.lowercased()]
                if header == ["from", "to"] || header == ["original", "replacement"] { continue }
            }
            result.append(VocabularyReplacement(from: from, to: to))
        }
        return result
    }

    // MARK: - Internals

    private struct Match {
        let range: NSRange
        let replacement: String
    }

    /// All case-insensitive word-boundary matches of every rule's `from` in `text`.
    /// Boundaries use letter/digit lookarounds rather than `\b`, which misbehaves next to
    /// non-ASCII letters ("naïveAPI" must not match the term "API").
    private static func matches(in text: String, rules: [VocabularyReplacement]) -> [Match] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var found: [Match] = []
        for rule in rules {
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                // Identity hits (text already the exact spelling) stay in the candidate set:
                // splicing identical text is harmless, and a long already-correct match must
                // still block shorter rules from rewriting its inside.
                found.append(Match(range: match.range, replacement: rule.to))
            }
        }
        return found
    }

    /// Minimal single-line CSV field parser: double quotes group a field, `""` inside quotes
    /// is a literal quote, unquoted fields are whitespace-trimmed.
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var wasQuoted = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()
        while let ch = pending {
            pending = iterator.next()
            if inQuotes {
                if ch == "\"" {
                    if pending == "\"" {
                        current.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"", current.trimmingCharacters(in: .whitespaces).isEmpty {
                inQuotes = true
                wasQuoted = true
                current = ""
            } else if ch == "," {
                fields.append(wasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
                current = ""
                wasQuoted = false
            } else {
                current.append(ch)
            }
        }
        fields.append(wasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}
