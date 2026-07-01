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
        "think": false,
        "options": [
            "temperature": temperature,
            "num_predict": numPredict,
            "num_ctx": numCtx,
        ],
    ]
}
