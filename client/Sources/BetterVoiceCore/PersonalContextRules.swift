import Foundation

/// Pure logic for deciding what part of `personal-context.md` is worth sending to a model.
/// File IO and the starter template live app-side in `PersonalContext.swift`, matching the
/// `Vocabulary` / `VocabularyRules` split.
public enum PersonalContextRules {

    /// The lines the user actually wrote, with the starter template's scaffolding removed.
    ///
    /// Exists because "is this file empty?" is the wrong question. The starter template is ~500
    /// characters of headings and prose addressed to the *user* ("Edit freely. Useful things to
    /// include: - Your name and how it's spelled."), so an untouched file is not empty. Treating it
    /// as real context ships a blank form to the model wrapped in "The following background
    /// describes the speaker and their world", on every dictation polish and every meeting summary,
    /// for anyone who never filled it in.
    ///
    /// That is not just wasted tokens. Measured on a 57-minute meeting fixture, removing it moved
    /// summary thread recall by up to 20 points, and the *sign depended on the model* (one 9B model
    /// +20.5, a 12B +2.3, a 4B −18.2) — an uncontrolled perturbation on every summary rather than a
    /// mild inefficiency. See `bench/results/2026-07-30-summarization-bakeoff.md`.
    ///
    /// Scaffolding is identified by subtracting the template's own lines rather than comparing the
    /// whole file against it, so a user who deletes the preamble but leaves the headings still reads
    /// as empty, and a user who edits one bullet doesn't have the rest of their file discarded.
    ///
    /// - Parameters:
    ///   - text: the file's contents.
    ///   - scaffolding: the starter template; its non-blank lines are treated as not-user-written.
    /// - Returns: the user's own content, or `""` when they have written nothing.
    public static func authoredContent(in text: String, scaffolding: String) -> String {
        let boilerplate = Set(
            normalizingNewlines(scaffolding).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        var kept: [String] = []
        var pendingHeading: String?

        // Normalize line endings before splitting. Swift treats "\r\n" as a SINGLE Character, so
        // `split(separator: "\n")` does not split on it at all -- a CRLF file (pasted from Windows or
        // a web page into this user-editable file) would collapse into one line, get read as a single
        // heading, and silently drop the user's entire context.
        for rawLine in normalizingNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                // A heading is structure, not content: hold it and emit it only once something the
                // user wrote shows up underneath, so an untouched "## People" never reaches a model.
                // Only the nearest heading is held, so runs of empty sections collapse away.
                pendingHeading = line
                continue
            }

            // A template instruction the user left in place is not something they wrote.
            if boilerplate.contains(line) { continue }

            if let heading = pendingHeading {
                kept.append(heading)
                pendingHeading = nil
            }
            kept.append(line)
        }

        return kept.joined(separator: "\n")
    }

    /// Collapses CRLF and lone CR to LF so line-based processing behaves. Needed because Swift's
    /// grapheme clustering makes "\r\n" one Character, which `split(separator: "\n")` will not split.
    private static func normalizingNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
