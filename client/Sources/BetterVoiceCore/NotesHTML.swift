import Foundation

/// Converts the small Markdown subset our generated transcripts (`MeetingMarkdown`) and
/// summaries (LLM output rendered through `SummarizationLogic`) actually use into HTML that
/// Apple Notes can import via AppleScript's `body` property (see `NotesScript.createNote`).
///
/// This is deliberately not a general CommonMark parser — no nesting, no tables, no reference
/// links, no indented code blocks. Supported constructs:
///   - `#` / `##` / `###` → `<h1>` / `<h2>` / `<h3>`
///   - `-` / `*` bullet lists → `<ul>` of `<li>`; `1.` ordered lists ALSO → `<ul>` of `<li>`, with
///     an explicit "N. " text prefix (numbering restarts per list, increments per item) — a live
///     spike against real Apple Notes found `<ol>` merges into an adjacent `<ul>` and loses its
///     numbering, so plain `<ul>` + a text prefix is the only reliable way to show numbers.
///     (contiguous list lines — no blank line between them — group into one list)
///   - `` `code` `` inline code (used for `MM:SS` timestamps) → `<code>`
///   - `**bold**` → `<strong>`, `*italic*` → `<em>`
///   - `[text](url)` → escaped `text (url)` — Apple Notes strips `<a href>` down to underlined
///     plain text (confirmed by the same spike), so there is no benefit to emitting an anchor.
///     When `text` and `url` are identical, the url is rendered once (no `foo (foo)`).
///   - `---` on its own line → `<hr>`
///   - blank-line-separated paragraphs → `<p>`; contiguous plain lines within one paragraph
///     join with `<br>`
///   - task list items `- [ ]` / `- [x]` → a plain `<li>` prefixed with a `☐` / `☑` glyph.
///     Apple Notes does not reliably import checkbox HTML via AppleScript, so this degrades
///     deliberately rather than emitting Notes' native (unreliable) checklist markup — swap
///     `taskListPrefix(checked:)` below if a later spike proves native checklists work.
/// All text content is HTML-escaped (`&`, `<`, `>`, `"`), including inside code spans and link
/// text/URLs.
public func markdownToNotesHTML(_ markdown: String) -> String {
    var blocks: [String] = []

    var paragraphLines: [String] = []
    var listItems: [String] = []
    var listIsOrdered = false
    var listOpen = false
    var orderedIndex = 0

    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        blocks.append("<p>\(paragraphLines.joined(separator: "<br>"))</p>")
        paragraphLines.removeAll()
    }

    func flushList() {
        guard listOpen else { return }
        blocks.append("<ul>\n\(listItems.joined(separator: "\n"))\n</ul>")
        listItems.removeAll()
        listOpen = false
        orderedIndex = 0
    }

    /// `item` is already-rendered inline content (no `<li>` wrapper). Ordered items get an
    /// explicit "N. " prefix, numbered from 1 within each contiguous list — see the type doc
    /// comment for why this replaces `<ol>`.
    /// Known limitation: a task/bullet item interleaved into an ordered run flushes the list and
    /// restarts numbering at 1 — nothing we render currently produces that mix.
    func startOrContinueList(ordered: Bool, item: String) {
        if listOpen && listIsOrdered != ordered {
            flushList()
        }
        listOpen = true
        listIsOrdered = ordered
        if ordered {
            orderedIndex += 1
            listItems.append("<li>\(orderedIndex). \(item)</li>")
        } else {
            listItems.append("<li>\(item)</li>")
        }
    }

    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            flushParagraph()
            flushList()
            continue
        }

        if let (level, content) = matchHeading(trimmed) {
            flushParagraph()
            flushList()
            blocks.append("<h\(level)>\(renderInline(content))</h\(level)>")
            continue
        }

        if isHorizontalRule(trimmed) {
            flushParagraph()
            flushList()
            blocks.append("<hr>")
            continue
        }

        if let (checked, content) = matchTaskItem(trimmed) {
            flushParagraph()
            startOrContinueList(ordered: false, item: "\(taskListPrefix(checked: checked)) \(renderInline(content))")
            continue
        }

        if let content = matchBullet(trimmed) {
            flushParagraph()
            startOrContinueList(ordered: false, item: renderInline(content))
            continue
        }

        if let content = matchOrdered(trimmed) {
            flushParagraph()
            startOrContinueList(ordered: true, item: renderInline(content))
            continue
        }

        flushList()
        paragraphLines.append(renderInline(trimmed))
    }

    flushParagraph()
    flushList()

    return blocks.joined(separator: "\n")
}

// MARK: - Block matchers

/// `#`/`##`/`###` heading. Requires whitespace after the hashes and 1-3 of them (`####+` is
/// deliberately not a heading — out of the supported subset — and falls through to paragraph).
private func matchHeading(_ trimmed: String) -> (level: Int, content: String)? {
    guard let match = firstMatch(of: "^(#{1,3})\\s+(.+)$", in: trimmed) else { return nil }
    return (level: match.string(1).count, content: match.string(2))
}

private func isHorizontalRule(_ trimmed: String) -> Bool {
    trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
}

private func matchTaskItem(_ trimmed: String) -> (checked: Bool, content: String)? {
    guard let match = firstMatch(of: "^[-*]\\s+\\[([ xX])\\]\\s+(.+)$", in: trimmed) else { return nil }
    let mark = match.string(1)
    return (checked: mark == "x" || mark == "X", content: match.string(2))
}

/// The single place task-list rendering is decided: a `☐`/`☑` glyph prefixing a plain `<li>`.
/// Apple Notes does not reliably import checkbox HTML via AppleScript, so we degrade
/// deliberately — swap this helper's body if a later spike proves native checklists work.
private func taskListPrefix(checked: Bool) -> String {
    checked ? "☑" : "☐"
}

private func matchBullet(_ trimmed: String) -> String? {
    firstMatch(of: "^[-*]\\s+(.+)$", in: trimmed)?.string(1)
}

private func matchOrdered(_ trimmed: String) -> String? {
    firstMatch(of: "^\\d+\\.\\s+(.+)$", in: trimmed)?.string(1)
}

// MARK: - Inline formatting

/// Renders `` `code` ``, `[text](url)`, `**bold**`, `*italic*` (in that precedence, so a code
/// span's contents are never re-interpreted as bold/italic) and HTML-escapes every literal text
/// run in between, including inside those spans.
private func renderInline(_ text: String) -> String {
    let pattern = "`([^`]+)`|\\[([^\\]]*)\\]\\(([^)]*)\\)|\\*\\*([^*]+)\\*\\*|\\*([^*]+)\\*"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return escapeHTML(text) }

    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

    var result = ""
    var cursor = 0
    for match in matches {
        if match.range.location > cursor {
            result += escapeHTML(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
        }
        result += renderInlineMatch(match, in: ns)
        cursor = match.range.location + match.range.length
    }
    if cursor < ns.length {
        result += escapeHTML(ns.substring(from: cursor))
    }
    return result
}

private func renderInlineMatch(_ match: NSTextCheckingResult, in ns: NSString) -> String {
    func group(_ i: Int) -> String? {
        let range = match.range(at: i)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    if let code = group(1) {
        return "<code>\(escapeHTML(code))</code>"
    }
    if let linkText = group(2), let url = group(3) {
        // Apple Notes strips <a href> to underlined plain text, so render "text (url)" instead —
        // or just the url once when the link text already IS the url (no "foo (foo)").
        if linkText == url {
            return escapeHTML(url)
        }
        return "\(escapeHTML(linkText)) (\(escapeHTML(url)))"
    }
    if let bold = group(4) {
        return "<strong>\(escapeHTML(bold))</strong>"
    }
    if let italic = group(5) {
        return "<em>\(escapeHTML(italic))</em>"
    }
    return escapeHTML(ns.substring(with: match.range))
}

// MARK: - Escaping

private func escapeHTML(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out
}

// MARK: - Regex helpers

private struct RegexMatch {
    let ns: NSString
    let result: NSTextCheckingResult

    func string(_ group: Int) -> String {
        let r = result.range(at: group)
        guard r.location != NSNotFound else { return "" }
        return ns.substring(with: r)
    }
}

private func firstMatch(of pattern: String, in text: String) -> RegexMatch? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
        return nil
    }
    return RegexMatch(ns: ns, result: result)
}
