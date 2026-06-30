import Foundation
import WECore

/// 模型推理服务器连接管理
/// 支持局域网直连 / Tailscale / localhost，自动健康检测 + 断线降级
@MainActor
final class ModelServer {
    static let shared = ModelServer()

    enum Status: String {
        case unknown
        case connected
        case disconnected
    }

    /// 单次推理的参数覆盖（摘要用不同模型 / 更大上下文 / 更长超时）。
    /// 任一字段为 nil 时回退到 config.server 的默认值。
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

    /// 状态变更通知（菜单栏用）
    var onStatusChange: ((Status) -> Void)?

    // MARK: - 配置读取

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

    // MARK: - 健康检测

    func startHealthCheck() {
        stopHealthCheck()

        let interval = serverConfig["health_interval"] as? TimeInterval ?? 30

        healthTask = Task { [weak self] in
            // 首次立即检查
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
            // OpenAI 需要 auth
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

    // MARK: - 推理

    func generate(
        prompt: String,
        systemPrompt: String = Prompts.defaultPolish,
        options: GenerateOptions = .init()
    ) async -> String? {
        // 如果状态不是 connected，先尝试一次快速健康检查
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

        // 长会议需要更大的 KV 上下文；num_predict 需足够容纳整段说话人回合，
        // 否则长段落会被截断。可在 config 的 server 段覆盖，或由调用方 options 覆盖。
        // Long meetings need a bigger KV context; num_predict must fit a whole
        // speaker turn or long turns get truncated. Resolved from options → config → default.
        let numCtx = options.numCtx ?? (serverConfig["num_ctx"] as? Int) ?? 32768
        let numPredict = options.numPredict ?? (serverConfig["num_predict"] as? Int) ?? 2048
        let body = makeOllamaRequestBody(
            model: options.model ?? model,
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

    // MARK: - 状态管理

    private func updateStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        Logger.log("Server", "Status -> \(newStatus.rawValue) (\(endpoint))")
        onStatusChange?(newStatus)
    }
}
