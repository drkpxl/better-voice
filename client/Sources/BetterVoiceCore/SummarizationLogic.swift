import Foundation

/// Pure summarization logic (prompt selection, type parsing, transcript building,
/// Ollama request-body building) — kept free of networking/GUI for unit tests.

/// Pick the summarization system prompt: a non-empty config override wins, else builtin.
public func resolveSummarizationPrompt(
    type: MeetingType,
    overrides: [String: String],
    builtin: (MeetingType) -> String
) -> String {
    if let override = overrides[type.configKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
        return override
    }
    return builtin(type)
}

/// Parse a MeetingType out of a classifier's free-text response. Falls back to `default`.
public func parseMeetingType(from response: String, default fallback: MeetingType) -> MeetingType {
    let s = response.lowercased()
    // Order matters: match more specific type keywords first.
    if s.contains("one on one") || s.contains("one-on-one") || s.contains("1:1")
        || s.contains("1 on 1") || s.contains("oneonone") {
        return .oneOnOne
    }
    if s.contains("standup") || s.contains("stand-up") || s.contains("stand up")
        || s.contains("status") || s.contains("scrum") {
        return .standup
    }
    if s.contains("general") {
        return .general
    }
    return fallback
}

/// Extracts the optional `TITLE: ...` leading line the summarization prompt asks the model to
/// emit before the Markdown summary body (see `Prompts.summaryTitleInstructionEN`), and returns
/// the remainder as the summary markdown. Parses defensively: any response that doesn't start
/// with a well-formed title line is returned completely unchanged as `markdown` with a nil
/// `title` — a missing/malformed title must never turn a successful summarization into a
/// failure. Models that wrap the requested plain title line in markdown anyway (`**TITLE:** X`,
/// `**TITLE: X**`, `# TITLE: X`) are tolerated: heading markers and bold asterisks around the
/// marker/title are stripped. We control neither the model nor user-custom prompts, so this
/// cheap robustness beats leaking a `**TITLE:**` line into the summary body.
///
/// At most one blank line immediately after the title line is consumed as the title/body
/// separator; further blank lines are part of the body and preserved.
public func parseSummaryTitle(from response: String) -> (title: String?, markdown: String) {
    let lines = response.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let titleIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
        return (nil, response)
    }

    // Normalize a COPY for matching only — if it doesn't turn out to be a title line, the
    // original response is returned byte-identical.
    var candidate = lines[titleIndex].trimmingCharacters(in: .whitespaces)
    while candidate.hasPrefix("#") || candidate.hasPrefix("*") {
        candidate.removeFirst()
    }
    candidate = candidate.trimmingCharacters(in: .whitespaces)

    let prefix = "title:"
    guard candidate.lowercased().hasPrefix(prefix) else {
        return (nil, response)
    }

    let boldOrSpace = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*"))
    let titleText = candidate.dropFirst(prefix.count).trimmingCharacters(in: boldOrSpace)
    guard !titleText.isEmpty else {
        return (nil, response)
    }

    var remaining = Array(lines[(titleIndex + 1)...])
    if let first = remaining.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        remaining.removeFirst()
    }
    return (titleText, remaining.joined(separator: "\n"))
}

/// Drop leading markdown markers (`#`, `*`, `-`) and surrounding whitespace, lowercased — used to
/// recognize a line regardless of how the model dressed it up.
private func normalizedLine(_ line: String) -> String {
    var t = line.trimmingCharacters(in: .whitespaces)
    while let f = t.first, "#*->".contains(f) || f == " " { t.removeFirst() }
    return t.trimmingCharacters(in: .whitespaces).lowercased()
}

/// Removes an echoed "Personal context" block that a model leaked into its summary despite the
/// system prompt's "never output this section" instruction. Small on-device models routinely echo
/// system-prompt content verbatim, so defensive post-processing — not prompt wording — is the only
/// reliable guard. Strips a "Personal context" heading (however marked) and any line that verbatim
/// reproduces a line of the injected `personalContext`. Leaves everything else byte-identical, then
/// collapses leading blank lines. `personalContext == nil`/empty → only the heading is removed.
public func stripEchoedContext(_ raw: String, personalContext: String?) -> String {
    let contextLines: Set<String> = Set(
        (personalContext ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { normalizedLine(String($0)) }
            .filter { !$0.isEmpty }
    )
    var kept: [String] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let norm = normalizedLine(line)
        if norm == "personal context" || norm == "personal context:" { continue }
        if !contextLines.isEmpty, contextLines.contains(norm) { continue }
        kept.append(line)
    }
    while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        kept.removeFirst()
    }
    return kept.joined(separator: "\n")
}

/// Removes any stray `TITLE: …` line left in a summary body (the summarization prompt asks for one
/// leading title line, but a model — especially the on-device map-reduce path — can scatter extra
/// ones through the body). `parseSummaryTitle` consumes the leading one for the note title; this
/// clears the rest so they don't render as summary content. Then collapses leading blank lines.
public func stripStrayTitleLines(_ markdown: String) -> String {
    var kept: [String] = []
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if normalizedLine(line).hasPrefix("title:") { continue }
        kept.append(line)
    }
    while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        kept.removeFirst()
    }
    return kept.joined(separator: "\n")
}

/// Cleans up a dedicated follow-up "give me a title" LLM response (see
/// `SummarizationClient.generateFallbackTitle`, used when the inline `TITLE:` line the main
/// summarization call asks for wasn't produced — notably the Apple on-device backend's
/// map-reduce path, which applies that instruction per-chunk and can leave zero or several
/// `TITLE:` lines scattered through the reduced output instead of one clean leading line).
///
/// A dedicated title-only call has far less structure to go wrong, but models still routinely
/// wrap the answer in quotes, restate the "Title:" label, add a trailing period, or reply with
/// several lines. This strips all of that defensively:
/// - keeps only the first non-empty line (defends against multi-line chatter),
/// - strips leading markdown heading/bullet/bold markers and a leading "Title:" label,
/// - strips wrapping straight/curly quotes,
/// - strips trailing sentence punctuation,
/// - caps length at `maxLength` characters, preferring a word boundary.
///
/// Returns nil if nothing usable remains — callers must treat that exactly like "no title",
/// never as an empty-string title.
public func sanitizeGeneratedTitle(_ raw: String, maxLength: Int = 80) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }

    // Keep only the first non-empty line.
    if let firstLine = s.split(separator: "\n", omittingEmptySubsequences: true).first {
        s = String(firstLine)
    }
    s = s.trimmingCharacters(in: .whitespaces)

    // Strip leading markdown markers (heading/bullet/bold/italic).
    while let first = s.first, "#*-".contains(first) {
        s.removeFirst()
    }
    s = s.trimmingCharacters(in: .whitespaces)

    // Strip a leading "Title:" label the model echoed back despite being asked not to.
    if s.lowercased().hasPrefix("title:") {
        s = String(s.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
    }

    // Strip wrapping bold/italic markers and quotes (straight + curly), which may be nested
    // (e.g. `**"Title"**`), so trim repeatedly until a pass changes nothing.
    let wrapChars = CharacterSet(charactersIn: "*_\"'“”‘’")
    var previous = ""
    while previous != s {
        previous = s
        s = s.trimmingCharacters(in: wrapChars)
        s = s.trimmingCharacters(in: .whitespaces)
    }

    // Strip trailing sentence punctuation.
    while let last = s.last, ".!?,;:".contains(last) {
        s.removeLast()
    }
    s = s.trimmingCharacters(in: .whitespaces)

    guard !s.isEmpty else { return nil }

    guard s.count > maxLength else { return s }

    // Cap length at a word boundary where possible.
    let words = s.split(separator: " ")
    var capped = ""
    for word in words {
        let candidate = capped.isEmpty ? String(word) : capped + " " + word
        guard candidate.count <= maxLength else { break }
        capped = candidate
    }
    if capped.isEmpty {
        capped = String(s.prefix(maxLength))
    }
    return capped.isEmpty ? nil : capped
}

/// Build a "Label: text" transcript from (named) segments for the summarizer.
public func buildSummarizationTranscript(
    segments: [MeetingSegment],
    speakerPrefix: String,
    localLabel: String = "You"
) -> String {
    var lines: [String] = []
    for seg in segments {
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if let label = seg.speakerLabel(prefix: speakerPrefix, localLabel: localLabel) {
            lines.append("\(label): \(text)")
        } else {
            lines.append(text)
        }
    }
    return lines.joined(separator: "\n")
}

/// Build the Ollama /api/generate request body as a plain dictionary.
public func makeOllamaRequestBody(
    model: String,
    system: String,
    prompt: String,
    numCtx: Int,
    numPredict: Int,
    temperature: Double
) -> [String: Any] {
    [
        "model": model,
        "prompt": prompt,
        "system": system,
        "stream": false,
        // Thinking stays off: benchmarks showed reasoning eats the num_predict budget and returns an
        // empty summary on local models, with no quality gain. See SummarizationClient.
        "think": false,
        "options": [
            "temperature": temperature,
            "num_predict": numPredict,
            "num_ctx": numCtx,
        ],
    ]
}
