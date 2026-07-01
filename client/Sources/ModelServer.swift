import Foundation
import BetterVoiceCore

/// Model inference server connection management
/// Supports direct LAN connection / Tailscale / localhost, with automatic health checks + disconnect fallback
@MainActor
final class ModelServer {
    static let shared = ModelServer()

    enum Status: String {
        case unknown
        case connected
        case disconnected
    }

    /// Parameter overrides for a single inference call (different model for summarization / larger context / longer timeout).
    /// When any field is nil, it falls back to the default value from config.server.
    struct GenerateOptions {
        var model: String?
        var numCtx: Int?
        var numPredict: Int?
        var timeout: TimeInterval?

        init(model: String? = nil, numCtx: Int? = nil, numPredict: Int? = nil, timeout: TimeInterval? = nil) {
            self.model = model
            self.numCtx = numCtx
            self.numPredict = numPredict
            self.timeout = timeout
        }
    }

    private(set) var status: Status = .unknown
    private var healthTask: Task<Void, Never>?

    /// Status change notification (used by the menu bar)
    var onStatusChange: ((Status) -> Void)?

    // MARK: - Config reading

    private var serverConfig: [String: Any] {
        RuntimeConfig.shared.serverConfig
    }

    private var endpoint: String {
        serverConfig["endpoint"] as? String ?? "http://localhost:11434"
    }

    private var model: String {
        serverConfig["model"] as? String ?? "qwen3:0.6b"
    }

    private var apiType: String {
        serverConfig["api"] as? String ?? "ollama"
    }

    private var timeout: TimeInterval {
        serverConfig["timeout"] as? TimeInterval ?? 10
    }

    // MARK: - Health checks

    func startHealthCheck() {
        stopHealthCheck()

        let interval = serverConfig["health_interval"] as? TimeInterval ?? 30

        healthTask = Task { [weak self] in
            // Check immediately on first run
            await self?.checkHealth()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.checkHealth()
            }
        }
    }

    func stopHealthCheck() {
        healthTask?.cancel()
        healthTask = nil
    }

    @discardableResult
    func checkHealth() async -> Bool {
        let healthURL: String
        if apiType == "openai" {
            // OpenAI-compatible: strip path, check /v1/models
            let base = endpoint
                .replacingOccurrences(of: "/v1/chat/completions", with: "")
                .replacingOccurrences(of: "/v1/completions", with: "")
            healthURL = base + "/v1/models"
        } else {
            // Ollama: check /api/tags
            let base = endpoint.replacingOccurrences(of: "/api/generate", with: "")
            healthURL = base + "/api/tags"
        }

        guard let url = URL(string: healthURL) else {
            updateStatus(.disconnected)
            return false
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "GET"
            // OpenAI requires auth
            if apiType == "openai", let key = serverConfig["api_key"] as? String, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            updateStatus(ok ? .connected : .disconnected)
            return ok
        } catch {
            Logger.log("Server", "Health check error: \(error)")
            updateStatus(.disconnected)
            return false
        }
    }

    // MARK: - Inference

    func generate(
        prompt: String,
        systemPrompt: String = Prompts.defaultPolish,
        options: GenerateOptions = .init()
    ) async -> String? {
        // If status isn't connected, try a quick health check first
        if status != .connected {
            Logger.log("Server", "Status=\(status.rawValue), trying health check...")
            await checkHealth()
        }
        guard status == .connected else {
            Logger.log("Server", "Not connected after check, skipping generation")
            return nil
        }

        let result: String?
        switch apiType {
        case "openai":
            result = await generateOpenAI(prompt: prompt, systemPrompt: systemPrompt, options: options)
        default:
            result = await generateOllama(prompt: prompt, systemPrompt: systemPrompt, options: options)
        }
        return result
    }

    // MARK: - Ollama API

    private func generateOllama(prompt: String, systemPrompt: String, options: GenerateOptions) async -> String? {
        let urlStr = endpoint.hasSuffix("/api/generate") ? endpoint : endpoint + "/api/generate"
        guard let url = URL(string: urlStr) else { return nil }

        // num_predict must fit a whole speaker turn or long turns get truncated. Resolved from
        // options → config → default. num_ctx is fitted to the prompt (see fittedNumCtx) so long
        // meetings aren't silently dropped from the front of a fixed window.
        let numPredict = options.numPredict ?? (serverConfig["num_predict"] as? Int) ?? 2048
        let modelName = options.model ?? model
        let numCtx = await fittedNumCtx(prompt: prompt, system: systemPrompt, numPredict: numPredict, options: options, model: modelName)
        let body = makeOllamaRequestBody(
            model: modelName,
            system: systemPrompt,
            prompt: prompt,
            numCtx: numCtx,
            numPredict: numPredict,
            temperature: 0
        )

        var request = URLRequest(url: url, timeoutInterval: options.timeout ?? timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            Logger.log("Server", "Ollama error: \(error.localizedDescription)")
            updateStatus(.disconnected)
        }
        return nil
    }

    // MARK: - Context sizing (Ollama)

    /// 256K — the recommended model's max context; we never request more than this.
    private static let maxNumCtx = 262_144
    /// Below 128K a model can't hold a long meeting's transcript. When content overflows a model
    /// this small, we warn the user (once per model) rather than silently truncate.
    private static let minRecommendedCtx = 131_072

    /// Cached max context length per Ollama model (from /api/show). Warned-about small models so
    /// we don't repeat the alert every call.
    private var modelContextCache: [String: Int] = [:]
    private var warnedSmallModels: Set<String> = []

    /// Fit `num_ctx` to the actual prompt so a long meeting isn't dropped from the front of a fixed
    /// window. Clamped to [configured floor … model max … 256K]. Warns once when the content
    /// overflows a model with a sub-128K window (a long meeting on a too-small model).
    private func fittedNumCtx(prompt: String, system: String, numPredict: Int, options: GenerateOptions, model: String) async -> Int {
        let floor = options.numCtx ?? (serverConfig["num_ctx"] as? Int) ?? 32768
        // chars/4 ≈ tokens; add the output budget and a margin for prompt/template overhead.
        let needed = (prompt.count + system.count) / 4 + numPredict + 1024
        var ctx = min(max(floor, needed), Self.maxNumCtx)
        if let maxCtx = await ollamaModelContextLength(model) {
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

    /// Look up an Ollama model's max context length via `/api/show` (cached per model). Returns nil
    /// on any network/parse failure, so the caller simply skips the capacity clamp/warning.
    private func ollamaModelContextLength(_ model: String) async -> Int? {
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

    // MARK: - OpenAI-compatible API

    private func generateOpenAI(prompt: String, systemPrompt: String, options: GenerateOptions) async -> String? {
        let urlStr = endpoint.contains("/v1/") ? endpoint : endpoint + "/v1/chat/completions"
        guard let url = URL(string: urlStr) else { return nil }

        let apiKey = serverConfig["api_key"] as? String ?? ""

        let body: [String: Any] = [
            "model": options.model ?? model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0,
            "max_tokens": options.numPredict ?? (serverConfig["num_predict"] as? Int) ?? 256
        ]

        var request = URLRequest(url: url, timeoutInterval: options.timeout ?? timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            Logger.log("Server", "OpenAI error: \(error.localizedDescription)")
            updateStatus(.disconnected)
        }
        return nil
    }

    // MARK: - Status management

    private func updateStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        Logger.log("Server", "Status -> \(newStatus.rawValue) (\(endpoint))")
        onStatusChange?(newStatus)
    }
}
