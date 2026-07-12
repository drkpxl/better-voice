import Foundation
import FoundationModels
import BetterVoiceCore

/// Apple's on-device model (macOS 26 FoundationModels framework), behind the same `LLMBackend`
/// seam as the HTTP backends — a zero-setup, fully-private option for users with Apple
/// Intelligence enabled (see roadmap §5). `LLMRequest`'s `endpoint`/`apiKey`/`timeout`/
/// `numCtxFloor` are all ignored: there's no server to dial, no auth, no caller-controlled
/// network timeout, and a fixed context window that isn't tunable per-request like Ollama's
/// `num_ctx`.
///
/// A fresh `LanguageModelSession` is created per request (Apple's documented pattern for
/// stateless single-turn calls — a session's `transcript` counts against its context, so reusing
/// one across calls would eventually overflow the 4096-token window). See
/// `docs/plans/2026-07-05-foundation-models-backend.md`'s Appendix for the verified API
/// signatures this file relies on.
@MainActor
final class FoundationModelsBackend: LLMBackend {
    let apiType = "apple"
    static let modelName = "apple-on-device"

    /// Fixed instructions/framing overhead subtracted from the context budget on top of the
    /// caller's own `numPredict` — covers per-turn overhead `estimatedTokenCount` can't see
    /// (Apple doesn't expose an exact pre-flight token count on the 26.0 runtime; see `tokenCount(for:)`
    /// note in the plan's Appendix §7).
    private static let framingMargin = 256
    /// Map-reduce's reduce pass re-chunks and retries at most this many times before giving up
    /// and returning the stitched partials instead of nil (a degraded summary beats no summary).
    private static let maxReduceRounds = 3

    // MARK: - LLMBackend

    func checkHealth(endpoint: String, apiKey: String) async -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    func listModels(endpoint: String, apiKey: String) async -> [String] {
        SystemLanguageModel.default.isAvailable ? [Self.modelName] : []
    }

    func generate(_ request: LLMRequest) async throws -> String? {
        let budget = capacityBudget(numPredict: request.numPredict)
        let inputTokens = estimatedTokenCount(for: request.systemPrompt + request.prompt)

        guard inputTokens <= budget else {
            return try await overflow(request: request, budget: budget)
        }

        do {
            return try await singleShot(
                instructions: request.systemPrompt,
                prompt: request.prompt,
                numPredict: request.numPredict,
                onToken: request.onToken
            )
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
            // The estimate said it would fit but Apple's own accounting disagreed (our chars/3
            // estimate is conservative but not exact) — fall back to the same overflow handling
            // an over-estimate would have taken.
            Logger.log("Server", "Apple backend: exceeded context window despite fitting the estimate, falling back")
            return try await overflow(request: request, budget: budget)
        } catch let error as LanguageModelSession.GenerationError {
            return try handle(error)
        }
    }

    // MARK: - Capacity math

    /// Budget for `systemPrompt + prompt`, in estimated tokens: the session's total context minus
    /// the caller's requested output budget minus a fixed framing margin.
    private func capacityBudget(numPredict: Int) -> Int {
        max(0, SystemLanguageModel.default.contextSize - numPredict - Self.framingMargin)
    }

    // MARK: - Single-shot generation

    private func makeOptions(numPredict: Int) -> GenerationOptions {
        // Property mutation, NOT `GenerationOptions(samplingMode:...)`/`init(sampling:...)` —
        // both are SDK traps on the 26.0 SDK this app ships against (Appendix §4).
        var options = GenerationOptions()
        options.temperature = 0
        options.maximumResponseTokens = numPredict
        return options
    }

    private func respondBuffered(instructions: String, prompt: String, numPredict: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, options: makeOptions(numPredict: numPredict))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams a fresh session's response, converting Apple's cumulative snapshots (Appendix §5 —
    /// each `.content` is the FULL text so far, not a delta) into the incremental deltas
    /// `LLMRequest.onToken` expects. Returns the final snapshot's full content, trimmed.
    private func respondStreaming(
        instructions: String,
        prompt: String,
        numPredict: Int,
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: prompt, options: makeOptions(numPredict: numPredict))
        var previous = ""
        for try await snapshot in stream {
            let full = snapshot.content
            if full.count > previous.count {
                onToken(String(full.dropFirst(previous.count)))
            }
            previous = full
        }
        return previous.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func singleShot(
        instructions: String,
        prompt: String,
        numPredict: Int,
        onToken: ((String) -> Void)?
    ) async throws -> String? {
        if let onToken {
            return try await respondStreaming(instructions: instructions, prompt: prompt, numPredict: numPredict, onToken: onToken)
        }
        return try await respondBuffered(instructions: instructions, prompt: prompt, numPredict: numPredict)
    }

    // MARK: - Overflow: classification truncation or map-reduce

    /// Estimate exceeded the budget (or the single-shot attempt threw `exceededContextWindowSize`).
    /// A tiny requested output (`numPredict <= 64`, e.g. `SummarizationClient`'s 16-token
    /// classify) is classification-shaped: map-reducing a classifier makes no sense, so we
    /// truncate the middle of the prompt instead — the meeting type is inferable from either
    /// edge. Anything else is summarization-shaped and goes through map-reduce.
    private func overflow(request: LLMRequest, budget: Int) async throws -> String? {
        if request.numPredict <= 64 {
            let truncated = truncateMiddle(request.prompt, budgetTokens: budget)
            do {
                return try await singleShot(
                    instructions: request.systemPrompt,
                    prompt: truncated,
                    numPredict: request.numPredict,
                    onToken: request.onToken
                )
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
                // Pathologically tiny budget — truncation still didn't fit. Nothing more to try.
                return nil
            } catch let error as LanguageModelSession.GenerationError {
                return try handle(error)
            }
        }
        return try await mapReduce(request: request, budget: budget, round: 1)
    }

    /// Keeps the head and tail halves of `text` and drops the middle, joined by `"\n…\n"`, so a
    /// classification-shaped prompt still fits in one shot.
    private func truncateMiddle(_ text: String, budgetTokens: Int) -> String {
        let maxChars = max(1, budgetTokens * 3)
        guard text.count > maxChars else { return text }
        let half = maxChars / 2
        let headEnd = text.index(text.startIndex, offsetBy: half)
        let tailStart = text.index(text.endIndex, offsetBy: -half)
        return String(text[text.startIndex..<headEnd]) + "\n…\n" + String(text[tailStart...])
    }

    /// Splits `request.prompt` into line-boundary chunks that individually fit the budget
    /// (`chunkTextByLines`, Core), summarizes each with a fresh session sharing the same
    /// instructions (silent — no `onToken`), then reduces the partials with one more fresh
    /// session. If the reduce input itself would overflow, re-chunks the joined partials and
    /// reduces again, capped at `maxReduceRounds`; past the cap, returns the joined partials
    /// rather than nil. `onToken` streams only the final reduce pass.
    private func mapReduce(request: LLMRequest, budget: Int, round: Int) async throws -> String? {
        let maxChars = max(1, budget * 3)
        let chunks = chunkTextByLines(request.prompt, maxChars: maxChars)
        Logger.log("Server", "Apple backend: map-reduce round \(round), \(chunks.count) chunk(s)")

        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let partPrompt = "Part \(index + 1) of \(chunks.count) of a longer document:\n\n\(chunk)"
            do {
                let text = try await respondBuffered(instructions: request.systemPrompt, prompt: partPrompt, numPredict: request.numPredict)
                partials.append(text)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
                // A single chunk still overflowed (pathological given the sizing above) — hard
                // middle-truncate just that chunk rather than losing the whole part.
                let truncated = truncateMiddle(chunk, budgetTokens: budget)
                let retryPrompt = "Part \(index + 1) of \(chunks.count) of a longer document:\n\n\(truncated)"
                if let text = try? await respondBuffered(instructions: request.systemPrompt, prompt: retryPrompt, numPredict: request.numPredict) {
                    partials.append(text)
                }
            } catch let error as LanguageModelSession.GenerationError {
                if let text = try handle(error) {
                    partials.append(text)
                }
            }
        }

        guard !partials.isEmpty else { return nil }
        let combined = partials.joined(separator: "\n\n---\n\n")
        let combinedTokens = estimatedTokenCount(for: request.systemPrompt + combined)

        if combinedTokens <= budget || round >= Self.maxReduceRounds {
            do {
                return try await singleShot(
                    instructions: request.systemPrompt,
                    prompt: combined,
                    numPredict: request.numPredict,
                    onToken: request.onToken
                )
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
                // At (or past) the round cap with no room left — a stitched summary beats nil
                // (the plan's explicit carve-out; this is the only case that substitutes for the
                // usual nil-on-content-error/rethrow-on-transport-error split below).
                return combined
            } catch let error as LanguageModelSession.GenerationError {
                return try handle(error)
            }
        }

        // The reduce pass itself would overflow and we haven't hit the cap — re-chunk the
        // combined partials and reduce again.
        let reReduceRequest = LLMRequest(
            endpoint: request.endpoint,
            apiKey: request.apiKey,
            model: request.model,
            systemPrompt: request.systemPrompt,
            prompt: combined,
            numCtxFloor: request.numCtxFloor,
            numPredict: request.numPredict,
            timeout: request.timeout,
            onToken: request.onToken
        )
        return try await mapReduce(request: reReduceRequest, budget: budget, round: round + 1)
    }

    // MARK: - Errors

    /// Splits `GenerationError` (Appendix §6 — the 26 SDK type; NOT `LanguageModelError`, which
    /// is 27-only) into content problems — return nil, since the model/session is fine and it's
    /// only this particular content that failed, so `ModelServer` must NOT flip status to
    /// disconnected — vs. everything else, which is rethrown so `ModelServer.generate` logs it
    /// and marks disconnected the same way it does for an HTTP transport failure.
    /// `concurrentRequests` can't happen here (fresh session per call, `@MainActor` serialized)
    /// but harmlessly falls in the rethrow bucket if it ever did.
    private func handle(_ error: LanguageModelSession.GenerationError) throws -> String? {
        switch error {
        case .guardrailViolation(_), .decodingFailure(_), .unsupportedLanguageOrLocale(_):
            Logger.log("Server", "Apple backend content error: \(error)")
            return nil
        case .refusal(_, _):
            Logger.log("Server", "Apple backend content error: \(error)")
            return nil
        default:
            throw error
        }
    }
}
