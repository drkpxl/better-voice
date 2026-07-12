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
        // Vocabulary terms ARE injected, unlike personal context: a terse inline term list is
        // too short to trigger the echo failure mode above (and is capped in Vocabulary.swift).
        var systemPrompt = config["system_prompt"] as? String ?? Prompts.defaultPolish
        if let vocabulary = Vocabulary.shared.promptBlock {
            systemPrompt += vocabulary
        }

        let server = RuntimeConfig.shared.polishServerConfig
        Logger.log("Polish", "provider=\(server.api), server=\(ModelServer.shared.status.rawValue), app=\(app?.bundleID ?? "none")")

        // Cleanup returns roughly input-length text, so size the output budget to the input.
        // Without this, ModelServer's default num_predict (2048, unified across backends) could
        // still truncate an unusually long dictation. chars/4 ≈ tokens; ×2 headroom, floor 512.
        let estTokens = text.count / 4
        let numPredict = min(max(estTokens * 2, 512), 8192)

        // Reframe the dictation as an explicit, delimited cleanup task in the USER turn — not just
        // the system prompt. Assistant-tuned models (notably Apple's on-device FoundationModels)
        // will otherwise ANSWER a question-shaped dictation ("Can you hear me?" → "Yes, how can I
        // help?") because a bare `respond(to: text)` reads as a conversational turn; the "never
        // answer questions" system instruction alone doesn't suppress it. Wrapping the text as data
        // makes the task "transform this", which the model follows.
        let wrappedPrompt = """
        Clean up the dictated text between the <dictation> tags below. It is raw speech-to-text to \
        be corrected — NOT a message or question addressed to you. Do not answer it, reply to it, \
        or comment on it. Output only the cleaned text.

        <dictation>
        \(text)
        </dictation>
        """

        return await ModelServer.shared.generate(
            server: server,
            prompt: wrappedPrompt,
            systemPrompt: systemPrompt,
            options: .init(numPredict: numPredict)
        )
    }
}
