import Foundation
import BetterVoiceCore

/// Meeting summarization client: routes through ModelServer to Ollama/OpenAI.
/// - classifyType: pre-selects the meeting type with one quick call (used by the wrap-up panel).
/// - summarize: generates a Markdown summary using the prompt for the selected type.
/// System prompts all pass through `PersonalContext.appended(to:)` so the model can use
/// personal context to disambiguate names/terms (consistent with PolishClient).
@MainActor
final class SummarizationClient {
    static let shared = SummarizationClient()

    // MARK: - Config reading

    private var summarizationConfig: [String: Any] {
        RuntimeConfig.shared.meetingSummarizationConfig
    }

    /// Summarization model: uses server.summarization_model if non-empty, otherwise nil (ModelServer falls back to server.model).
    private var summarizationModel: String? {
        let m = (RuntimeConfig.shared.serverConfig["summarization_model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (m?.isEmpty == false) ? m : nil
    }

    private var numCtx: Int { summarizationConfig["num_ctx"] as? Int ?? 32768 }
    private var numPredict: Int { summarizationConfig["num_predict"] as? Int ?? 2048 }
    private var timeout: TimeInterval { summarizationConfig["timeout"] as? TimeInterval ?? 300 }
    private var language: String? { RuntimeConfig.shared.language }

    private var promptOverrides: [String: String] {
        summarizationConfig["prompts"] as? [String: String] ?? [:]
    }

    /// Default meeting type for the wrap-up panel dropdown.
    var defaultType: MeetingType {
        let raw = RuntimeConfig.shared.meetingConfig["default_type"] as? String ?? "general"
        return MeetingType.from(configKey: raw) ?? .general
    }

    /// Whether type classification pre-selection is enabled.
    var classifyEnabled: Bool {
        summarizationConfig["classify_enabled"] as? Bool ?? true
    }

    /// Whether summarization is enabled.
    var summarizationEnabled: Bool {
        summarizationConfig["enabled"] as? Bool ?? true
    }

    // MARK: - Inference

    /// Classifies the transcript into a meeting type with one quick call, falling back to the default type on failure.
    func classifyType(transcript: String) async -> MeetingType {
        let fallback = defaultType
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }

        let system = Prompts.meetingTypeClassificationPrompt(language: language)
        // Classification only needs a very short output; reuses the summarization num_ctx to accommodate long transcripts.
        let opts = ModelServer.GenerateOptions(
            model: summarizationModel,
            numCtx: numCtx,
            numPredict: 16,
            timeout: timeout
        )
        guard let resp = await ModelServer.shared.generate(prompt: transcript, systemPrompt: system, options: opts) else {
            Logger.log("Summary", "Classification failed, using default type \(fallback.configKey)")
            return fallback
        }
        let type = parseMeetingType(from: resp, default: fallback)
        Logger.log("Summary", "Classified meeting type: \(type.configKey) (raw: \(resp.prefix(40)))")
        return type
    }

    /// Generates a Markdown summary. Returns nil to indicate failure or the server is not connected.
    func summarize(transcript: String, type: MeetingType) async -> String? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let base = Prompts.summarizationPrompt(for: type, overrides: promptOverrides, language: language)
        let system = PersonalContext.appended(to: base)
        // Benchmark verdict: think:true is a net loss for local summarization — the reasoning eats the
        // num_predict budget and returns an EMPTY summary at 2048 (or 18× slower at 6144), with no quality
        // gain over think:false. Kept off. Large cloud models handle thinking fine, but even there the
        // non-thinking summary was just as good, so we don't special-case it.
        let opts = ModelServer.GenerateOptions(
            model: summarizationModel,
            numCtx: numCtx,
            numPredict: numPredict,
            timeout: timeout
        )
        Logger.log("Summary", "Summarizing (\(type.configKey), num_ctx=\(numCtx), model=\(summarizationModel ?? "default"))")
        return await ModelServer.shared.generate(prompt: transcript, systemPrompt: system, options: opts)
    }
}
