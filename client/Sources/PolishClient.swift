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

        let basePrompt = config["system_prompt"] as? String ?? Prompts.defaultPolish
        let systemPrompt = PersonalContext.appended(to: basePrompt)

        Logger.log("Polish", "server=\(ModelServer.shared.status.rawValue), app=\(app?.bundleID ?? "none"), personalContext=\(systemPrompt.count != basePrompt.count)")

        // Cleanup returns roughly input-length text, so size the output budget to the input.
        // Without this, the OpenAI-compatible path defaults to max_tokens=256 (ModelServer) and
        // truncates any dictation longer than ~200 words. chars/4 ≈ tokens; ×2 headroom, floor 512.
        let estTokens = text.count / 4
        let numPredict = min(max(estTokens * 2, 512), 8192)

        return await ModelServer.shared.generate(
            prompt: text,
            systemPrompt: systemPrompt,
            options: .init(numPredict: numPredict)
        )
    }
}
