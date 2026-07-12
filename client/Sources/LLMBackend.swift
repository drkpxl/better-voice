import Foundation
import BetterVoiceCore

/// One fully-resolved inference request: `ModelServer` merges `GenerateOptions` with config
/// defaults into this before dispatching to whichever backend is configured.
struct LLMRequest {
    let endpoint: String
    let apiKey: String
    let model: String
    let systemPrompt: String
    let prompt: String
    /// Context floor for fitting (Ollama-only concern; `OpenAICompatibleBackend` ignores it —
    /// OpenAI-compatible servers don't expose a way to ask for/clamp a model's context window).
    let numCtxFloor: Int
    let numPredict: Int
    let timeout: TimeInterval
    /// Non-nil requests a streamed response, invoked once per token as it arrives. nil = the
    /// current buffered single-shot behavior (the only mode used today; no caller passes a token
    /// callback yet — see Task 2.2 in the fingerprinting/LLM-backend plan).
    let onToken: ((String) -> Void)?
}

/// A local/self-hosted LLM inference server API, OR Apple's on-device model. `ModelServer` is a
/// thin facade over one of these at a time (whichever `config.server.api` selects) — this is
/// behavior-level so a non-HTTP backend (`FoundationModelsBackend`) fits alongside the two HTTP
/// ones without any URL-shaped assumptions leaking into `ModelServer`.
@MainActor
protocol LLMBackend: AnyObject {
    /// "ollama" / "openai" / "apple" — matches `config.server.api` and settings UI values.
    var apiType: String { get }
    /// True when the backend can serve requests. HTTP backends: the models-list endpoint answers
    /// 200. Apple: `SystemLanguageModel` availability. `endpoint`/`apiKey` are ignored by backends
    /// that don't use them (Apple).
    func checkHealth(endpoint: String, apiKey: String) async -> Bool
    /// Models to offer in the Settings dropdowns. [] on failure/unavailable — never a failure
    /// state `ModelServer` needs to react to, just an empty dropdown.
    func listModels(endpoint: String, apiKey: String) async -> [String]
    /// Run one inference call. Returns nil when the response body couldn't be parsed into text
    /// (not a failure state ModelServer needs to react to); throws on a network/transport error
    /// so the caller can log it and flip status to `.disconnected`.
    func generate(_ request: LLMRequest) async throws -> String?
}

/// Shared GET with a 5s timeout, used by both `checkHealth` (only needs the status code) and
/// `listModels` (needs the parsed JSON body) so the two HTTP backends' endpoint-reachability
/// logic lives in one place instead of duplicated per backend. Returns nil on a malformed URL or
/// any transport error (logged the same way `ModelServer`'s pre-reshape `checkHealth` did) or a
/// non-200 status. `apiKey`: sent as `Authorization: Bearer <key>` only when non-empty — Ollama
/// callers always pass "" (its API doesn't take one), matching today's "only openai attaches a
/// key" behavior without the caller needing to know its own apiType.
private func fetchOK(urlString: String, apiKey: String) async -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "GET"
    if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    } catch {
        Logger.log("Server", "Health check error: \(error)")
        return nil
    }
}

/// `fetchOK` + JSON-object parse, for `listModels`. nil on a non-200/transport failure (see
/// `fetchOK`) or an unparseable body.
private func fetchJSON(urlString: String, apiKey: String) async -> [String: Any]? {
    guard let data = await fetchOK(urlString: urlString, apiKey: apiKey) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Ollama

/// Ollama's `/api/generate` + `/api/tags` + `/api/show` API.
@MainActor
final class OllamaBackend: LLMBackend {
    let apiType = "ollama"

    /// 256K — the recommended model's max context; we never request more than this.
    private static let maxNumCtx = 262_144
    /// Below 128K a model can't hold a long meeting's transcript. When content overflows a model
    /// this small, we warn the user (once per model) rather than silently truncate.
    private static let minRecommendedCtx = 131_072

    /// Cached max context length per Ollama model (from /api/show). Warned-about small models so
    /// we don't repeat the alert every call. Instance state, so it lives as long as `ModelServer`
    /// holds this backend (i.e. the app's lifetime).
    private var modelContextCache: [String: Int] = [:]
    private var warnedSmallModels: Set<String> = []

    /// Ollama never takes the config's api_key (its own API doesn't use one) — checkHealth/
    /// listModels below always pass "" to `fetchOK`/`fetchJSON` regardless of what's configured,
    /// same as the pre-reshape `ModelServer` only attaching `Authorization` for `apiType == "openai"`.
    func checkHealth(endpoint: String, apiKey: String) async -> Bool {
        await fetchOK(urlString: modelsListURL(endpoint: endpoint), apiKey: "") != nil
    }

    func listModels(endpoint: String, apiKey: String) async -> [String] {
        guard let json = await fetchJSON(urlString: modelsListURL(endpoint: endpoint), apiKey: "") else { return [] }
        return parseModelList(json)
    }

    /// Build the model-list URL for a server (used by both the health check and model
    /// discovery). Tolerates endpoints written with a trailing path or slash.
    private func modelsListURL(endpoint: String) -> String {
        var base = endpoint.replacingOccurrences(of: "/api/generate", with: "")
        if base.hasSuffix("/") { base.removeLast() }
        return base + "/api/tags"
    }

    /// Parse a model-list response body into model names/ids.
    private func parseModelList(_ json: [String: Any]) -> [String] {
        (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    func generate(_ request: LLMRequest) async throws -> String? {
        let urlStr = request.endpoint.hasSuffix("/api/generate") ? request.endpoint : request.endpoint + "/api/generate"
        guard let url = URL(string: urlStr) else { return nil }

        // num_ctx is fitted to the prompt so long meetings aren't silently dropped from the
        // front of a fixed window.
        let numCtx = await fittedNumCtx(
            prompt: request.prompt,
            system: request.systemPrompt,
            numPredict: request.numPredict,
            floor: request.numCtxFloor,
            model: request.model,
            endpoint: request.endpoint
        )
        var body = makeOllamaRequestBody(
            model: request.model,
            system: request.systemPrompt,
            prompt: request.prompt,
            numCtx: numCtx,
            numPredict: request.numPredict,
            temperature: 0
        )
        if request.onToken != nil { body["stream"] = true }

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let onToken = request.onToken {
            return try await streamNDJSON(urlRequest, onToken: onToken)
        }

        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let response = json["response"] as? String {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Streams Ollama's NDJSON response (one JSON object per line, `"done": true` on the last
    /// one), calling `onToken` with each line's `response` field as it arrives. Returns the
    /// accumulated full string — same content the buffered path would have returned.
    private func streamNDJSON(_ urlRequest: URLRequest, onToken: @escaping (String) -> Void) async throws -> String {
        let (bytes, _) = try await URLSession.shared.bytes(for: urlRequest)
        var full = ""
        for try await line in bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let token = json["response"] as? String, !token.isEmpty {
                full += token
                onToken(token)
            }
            if json["done"] as? Bool == true { break }
        }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Context sizing

    /// Fit `num_ctx` to the actual prompt so a long meeting isn't dropped from the front of a
    /// fixed window. Clamped to [floor … model max … 256K]. Warns once when the content overflows
    /// a model with a sub-128K window (a long meeting on a too-small model).
    private func fittedNumCtx(prompt: String, system: String, numPredict: Int, floor: Int, model: String, endpoint: String) async -> Int {
        // chars/4 ≈ tokens; add the output budget and a margin for prompt/template overhead.
        let needed = (prompt.count + system.count) / 4 + numPredict + 1024
        var ctx = min(max(floor, needed), Self.maxNumCtx)
        if let maxCtx = await ollamaModelContextLength(model, endpoint: endpoint) {
            if needed > maxCtx, maxCtx < Self.minRecommendedCtx, !warnedSmallModels.contains(model) {
                warnedSmallModels.insert(model)
                Notify.warn(
                    t("Model too small for this meeting"),
                    t("“\(model)” has a \(maxCtx / 1024)K context window, smaller than this transcript needs — the summary may miss the beginning. Use a model with at least a 128K context for long meetings.")
                )
            }
            ctx = min(ctx, maxCtx)   // never request more than the model supports
        }
        return ctx
    }

    /// Look up an Ollama model's max context length via `/api/show` (cached per model). Returns
    /// nil on any network/parse failure, so the caller simply skips the capacity clamp/warning.
    private func ollamaModelContextLength(_ model: String, endpoint: String) async -> Int? {
        if let cached = modelContextCache[model] { return cached }
        let base = endpoint.replacingOccurrences(of: "/api/generate", with: "")
        guard let url = URL(string: base + "/api/show") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["model_info"] as? [String: Any] else { return nil }
        // The key is architecture-specific, e.g. "qwen3.context_length", "llama.context_length".
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let n = (value as? NSNumber)?.intValue, n > 0 {
                modelContextCache[model] = n
                Logger.log("Server", "Model \(model) context_length=\(n)")
                return n
            }
        }
        return nil
    }
}

// MARK: - OpenAI-compatible

/// Any server speaking the OpenAI `/v1/chat/completions` + `/v1/models` API (LM Studio,
/// llama.cpp's `llama-server`, mlx-lm's `mlx_lm.server`, Jan, OpenAI itself, etc.).
@MainActor
final class OpenAICompatibleBackend: LLMBackend {
    let apiType = "openai"

    /// The only backend that attaches the config's api_key (matches the pre-reshape
    /// `ModelServer`'s `apiType == "openai"` gate) — `fetchOK`/`fetchJSON` themselves only send
    /// `Authorization` when the key is non-empty, so an unset key behaves exactly as before.
    func checkHealth(endpoint: String, apiKey: String) async -> Bool {
        await fetchOK(urlString: modelsListURL(endpoint: endpoint), apiKey: apiKey) != nil
    }

    func listModels(endpoint: String, apiKey: String) async -> [String] {
        guard let json = await fetchJSON(urlString: modelsListURL(endpoint: endpoint), apiKey: apiKey) else { return [] }
        return parseModelList(json)
    }

    /// Tolerates endpoints written with a trailing path or slash (`…/v1`,
    /// `…/v1/chat/completions`, `…/`) so we never produce a doubled `/v1/v1/models`.
    private func modelsListURL(endpoint: String) -> String {
        var base = endpoint
            .replacingOccurrences(of: "/v1/chat/completions", with: "")
            .replacingOccurrences(of: "/v1/completions", with: "")
        if base.hasSuffix("/v1") { base.removeLast(3) }
        if base.hasSuffix("/") { base.removeLast() }
        return base + "/v1/models"
    }

    private func parseModelList(_ json: [String: Any]) -> [String] {
        (json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    func generate(_ request: LLMRequest) async throws -> String? {
        let urlStr = request.endpoint.contains("/v1/") ? request.endpoint : request.endpoint + "/v1/chat/completions"
        guard let url = URL(string: urlStr) else { return nil }

        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.prompt]
            ],
            "temperature": 0,
            "max_tokens": request.numPredict
        ]
        if request.onToken != nil { body["stream"] = true }

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !request.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let onToken = request.onToken {
            return try await streamSSE(urlRequest, onToken: onToken)
        }

        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Streams the OpenAI-compatible SSE response (`data: {json}` lines, terminated by
    /// `data: [DONE]`), calling `onToken` with each chunk's `choices[0].delta.content` as it
    /// arrives. Returns the accumulated full string — same content the buffered path would have
    /// returned.
    private func streamSSE(_ urlRequest: URLRequest, onToken: @escaping (String) -> Void) async throws -> String {
        let (bytes, _) = try await URLSession.shared.bytes(for: urlRequest)
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let token = delta["content"] as? String,
                  !token.isEmpty else { continue }
            full += token
            onToken(token)
        }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
