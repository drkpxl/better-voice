import Foundation

/// L2 semantic polishing client
/// Routes uniformly through ModelServer to remote/local model services
@MainActor
final class PolishClient {
    static let shared = PolishClient()

    /// Polishes text, returns nil to indicate skipped or failed
    func polish(
        text: String,
        words: [WordInfo],
        app: AppIdentity?
    ) async -> String? {
        let config = RuntimeConfig.shared.polishConfig
        guard config["enabled"] as? Bool == true else { return nil }

        // Personal context is intentionally NOT injected into dictation polish. The block is large
        // relative to a short dictation, and local models regurgitate it into the output despite the
        // "never output this" instruction — leaking the user's context as dictated text. It remains a
        // summarization-only signal (see SummarizationClient), where the input is long enough that the
        // model uses it for disambiguation rather than echoing it.
        let systemPrompt = config["system_prompt"] as? String ?? Prompts.defaultPolish

        Logger.log("Polish", "server=\(ModelServer.shared.status.rawValue), app=\(app?.bundleID ?? "none")")

        // Cleanup returns roughly input-length text, so size the output budget to the input.
        // Without this, the OpenAI-compatible path defaults to max_tokens=256 (ModelServer) and
        // truncates any dictation longer than ~200 words. chars/4 ≈ tokens; ×2 headroom, floor 512.
        let estTokens = text.count / 4
        let numPredict = min(max(estTokens * 2, 512), 8192)

        // Polish can use a smaller/faster model than summarization (blank = fall back to server.model).
        let polishModel = (config["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await ModelServer.shared.generate(
            prompt: text,
            systemPrompt: systemPrompt,
            options: .init(model: (polishModel?.isEmpty == false) ? polishModel : nil, numPredict: numPredict)
        )
    }
}
