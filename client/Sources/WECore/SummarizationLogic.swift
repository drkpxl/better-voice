import Foundation

/// 摘要相关的纯逻辑：提示词选择、类型解析、转录文本拼接、Ollama 请求体构造。
/// Pure summarization logic (prompt selection, type parsing, transcript building,
/// Ollama request-body building) — kept free of networking/GUI for unit tests.

/// 选择摘要系统提示词：config 覆盖优先，否则用内置模板。
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

/// 从分类模型的自由文本回复里解析出 MeetingType（大小写不敏感、子串匹配）。
/// Parse a MeetingType out of a classifier's free-text response. Falls back to `default`.
public func parseMeetingType(from response: String, default fallback: MeetingType) -> MeetingType {
    let s = response.lowercased()
    // 顺序很重要：先匹配更具体的类型关键词。
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

/// 把（已命名的）片段拼成 "Label: text" 多行转录，喂给摘要模型。
/// Build a "Label: text" transcript from (named) segments for the summarizer.
public func buildSummarizationTranscript(segments: [MeetingSegment], speakerPrefix: String) -> String {
    var lines: [String] = []
    for seg in segments {
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if let label = seg.speakerLabel(prefix: speakerPrefix) {
            lines.append("\(label): \(text)")
        } else {
            lines.append(text)
        }
    }
    return lines.joined(separator: "\n")
}

/// 构造 Ollama /api/generate 请求体（纯字典，便于单测断言）。
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
