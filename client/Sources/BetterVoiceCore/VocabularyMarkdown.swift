import Foundation

/// Parse/render for `<workspace>/vocabulary.md`'s hand-editable format:
///
///   ## Terms
///   - FluidAudio
///   - GitHub
///
///   ## Replacements
///   - fluid audio -> FluidAudio
///
/// Same spirit as `personal-context.md`: no JSON, free to hand-edit. Unlike personal context
/// this file has structure the app must read (terms vs. replacements), so it's heading +
/// bullet based rather than pure free text.

/// Parse the Terms/Replacements sections. Section matching is case-insensitive on the
/// heading text; bullets are `- ` lines; a replacement bullet needs `->` or `→` with a
/// non-empty side on each side, otherwise it's skipped. Prose/blank lines and unrecognized
/// headings are ignored. Empty input returns empty lists.
public func parseVocabularyMarkdown(_ text: String) -> (terms: [String], replacements: [VocabularyReplacement]) {
    enum Section { case none, terms, replacements }
    var section = Section.none
    var terms: [String] = []
    var replacements: [VocabularyReplacement] = []

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
            switch heading {
            case "terms": section = .terms
            case "replacements": section = .replacements
            default: section = .none
            }
            continue
        }
        guard line.hasPrefix("- ") else { continue }
        let content = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { continue }

        switch section {
        case .terms:
            terms.append(content)
        case .replacements:
            guard let range = content.range(of: "->") ?? content.range(of: "\u{2192}") else { continue }
            let from = content[content.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = content[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { continue }
            replacements.append(VocabularyReplacement(from: from, to: to))
        case .none:
            continue
        }
    }
    return (terms, replacements)
}

/// Render the canonical file: fixed instructional prose plus the current terms/replacements
/// as bullet lists. Both headings are always present (even empty) so a user editing a fresh
/// file sees exactly where to add entries.
public func renderVocabularyMarkdown(terms: [String], replacements: [VocabularyReplacement]) -> String {
    var md = """
    # Vocabulary

    Exact spellings and text replacements for dictation and meeting transcripts. Complements
    personal-context.md: that file carries meaning, this one carries spellings. Edit freely —
    changes apply as soon as you save.

    ## Terms
    Correct spellings (names, products, acronyms) the AI should prefer, one per line. Matched
    case-insensitively at word boundaries; near-matches are normalized to the exact casing here.

    """
    for term in terms {
        md += "- \(term)\n"
    }
    md += """

    ## Replacements
    Deterministic fixes for misheard text: "as heard -> correct text", one per line. Applied
    even when dictation polish is off; never shown to the model (so it can't learn the
    misspelling).

    """
    for replacement in replacements {
        md += "- \(replacement.from) -> \(replacement.to)\n"
    }
    return md
}
