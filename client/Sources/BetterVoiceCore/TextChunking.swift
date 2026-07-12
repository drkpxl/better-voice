import Foundation

/// Pure chunking + token-estimation logic for `FoundationModelsBackend`'s capacity math
/// (fitting a prompt into Apple's fixed 4096-token session context, and splitting an oversized
/// one for the map-reduce fallback). Foundation-only so it's unit-testable without the
/// FoundationModels/macOS 26 surface.

/// Conservative token estimate for prompt-budget math: Apple's guidance (TN3193) is 3–4
/// chars/token for Latin-alphabet text; we divide by 3 (not 4) so we overestimate and chunk
/// early rather than overflow the session's context window. 0 for empty text, else at least 1
/// (a non-empty prompt always costs at least one token).
public func estimatedTokenCount(for text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, text.count / 3)
}

/// Splits `text` on line boundaries into chunks of at most `maxChars` each, for
/// `FoundationModelsBackend`'s map-reduce fallback over a transcript too long for one session.
/// Transcripts are line-oriented (`Speaker: text` lines from `buildSummarizationTranscript`,
/// `### `/backtick lines in exports), so line-boundary chunking never splits mid-utterance.
///
/// Each line keeps its own trailing "\n" (if it had one) as part of the piece that carries it,
/// so concatenating the returned chunks with NO separator reproduces `text` exactly:
/// `chunkTextByLines(text, maxChars: n).joined() == text` always holds, including across a
/// hard split.
///
/// - A single line longer than `maxChars` on its own is hard-split into fixed-size pieces (no
///   line boundary to split on, and map-reduce still needs every chunk to fit the budget).
/// - `maxChars <= 0` is treated as "no limit" and returns `[text]` unchanged (there's no sane
///   chunk size to hard-split to).
/// - Never returns `[]` for non-empty input (empty `text` returns `[]`; there is nothing to
///   summarize).
public func chunkTextByLines(_ text: String, maxChars: Int) -> [String] {
    guard !text.isEmpty else { return [] }
    guard maxChars > 0 else { return [text] }

    var chunks: [String] = []
    var current = ""

    for line in linesKeepingTerminators(text) {
        if line.count > maxChars {
            // This single line alone exceeds the budget — flush whatever was accumulating
            // (so chunk order matches document order), then hard-split the line itself into
            // maxChars-sized pieces. Pieces are plain substrings of `line` with no separator
            // inserted between them, so re-concatenating them reproduces `line` exactly.
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            var remainder = Substring(line)
            while remainder.count > maxChars {
                let cut = remainder.index(remainder.startIndex, offsetBy: maxChars)
                chunks.append(String(remainder[remainder.startIndex..<cut]))
                remainder = remainder[cut...]
            }
            current = String(remainder)
            continue
        }

        if current.count + line.count > maxChars {
            chunks.append(current)
            current = line
        } else {
            current += line
        }
    }
    if !current.isEmpty {
        chunks.append(current)
    }

    // Defensive only: with the guards above (non-empty text, maxChars > 0), `chunks` is always
    // non-empty by construction — but never returning [] for non-empty input is a hard contract
    // for callers (map-reduce needs at least one chunk to reduce), so fall back explicitly.
    return chunks.isEmpty ? [text] : chunks
}

/// Splits `text` into lines, each retaining its own trailing "\n" (the final line keeps none if
/// `text` doesn't end in one). Unlike `String.components(separatedBy:)`, this makes
/// `lines.joined() == text` hold exactly, which is what gives `chunkTextByLines` its
/// content-preservation guarantee.
private func linesKeepingTerminators(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if ch == "\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}
