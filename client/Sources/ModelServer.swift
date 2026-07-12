import Foundation
import BetterVoiceCore

/// One resolved provider connection — which backend, where, which model, credentials. Built by
/// `RuntimeConfig`'s per-section accessors (`polishServerConfig`, `summarizationServerConfig`) so
/// Polish and Summarization can each point at an independent provider instead of sharing one
/// ambient config.
struct ServerConnectionConfig {
    var api: String
    var endpoint: String
    var model: String
    var apiKey: String
}

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

    /// Parameter overrides for a single inference call (larger context / longer timeout).
    /// When any field is nil, it falls back to a fixed default (see `generate(server:...)`).
    struct GenerateOptions {
        var numCtx: Int?
        var numPredict: Int?
        var timeout: TimeInterval?

        init(numCtx: Int? = nil, numPredict: Int? = nil, timeout: TimeInterval? = nil) {
            self.numCtx = numCtx
            self.numPredict = numPredict
            self.timeout = timeout
        }
    }

    private(set) var status: Status = .unknown
    private var healthTask: Task<Void, Never>?

    /// Status change notification (used by the menu bar)
    var onStatusChange: ((Status) -> Void)?

    // MARK: - Backends

    /// One instance per API family, held for the app's lifetime (`OllamaBackend` caches model
    /// context lengths + which small models it has already warned about).
    private let ollamaBackend = OllamaBackend()
    private let openAIBackend = OpenAICompatibleBackend()
    private let foundationModelsBackend = FoundationModelsBackend()

    private func backend(for apiType: String) -> any LLMBackend {
        switch apiType {
        case "openai": return openAIBackend
        case "apple": return foundationModelsBackend
        default: return ollamaBackend
        }
    }

    // MARK: - Health checks

    /// Health-check polling cadence. Was `server.health_interval` when there was one global
    /// server config; never exposed in Settings UI, so fixing it as a constant loses no
    /// user-facing capability now that there's no single "server" section to hang it off.
    private static let healthCheckInterval: TimeInterval = 30

    func startHealthCheck() {
        stopHealthCheck()

        healthTask = Task { [weak self] in
            // Check immediately on first run
            await self?.checkHealth()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckInterval))
                guard !Task.isCancelled else { break }
                await self?.checkHealth()
            }
        }
    }

    func stopHealthCheck() {
        healthTask?.cancel()
        healthTask = nil
    }

    /// Combined status across both sections: checks whichever of Polish/Summarization is
    /// currently enabled and reduces to worst-case — `.disconnected` if any enabled section's
    /// provider is unreachable, `.connected` if every enabled section is reachable, `.unknown` if
    /// both are disabled (nothing to check).
    @discardableResult
    func checkHealth() async -> Bool {
        let cfg = RuntimeConfig.shared
        var checked = false
        var allOK = true

        if cfg.polishConfig["enabled"] as? Bool == true {
            checked = true
            let server = cfg.polishServerConfig
            let ok = await backend(for: server.api).checkHealth(endpoint: server.endpoint, apiKey: server.apiKey)
            allOK = allOK && ok
        }
        if cfg.meetingSummarizationConfig["enabled"] as? Bool ?? true {
            checked = true
            let server = cfg.summarizationServerConfig
            let ok = await backend(for: server.api).checkHealth(endpoint: server.endpoint, apiKey: server.apiKey)
            allOK = allOK && ok
        }

        guard checked else {
            updateStatus(.unknown)
            return false
        }
        updateStatus(allOK ? .connected : .disconnected)
        return allOK
    }

    // MARK: - Model discovery

    /// Models a given section's configured provider reports, for that section's Settings
    /// dropdown. [] on failure/unavailable — never a failure state the caller needs to react to,
    /// just an empty dropdown.
    func availableModels(server: ServerConnectionConfig) async -> [String] {
        let models = await backend(for: server.api).listModels(endpoint: server.endpoint, apiKey: server.apiKey)
        return models.sorted()
    }

    // MARK: - Inference

    /// Runs one inference call against `server`'s own provider — independent of whatever the
    /// other section (Polish vs. Summarization) is configured to use. Returns nil on any
    /// content/parse failure; on a transport error, logs it and nudges the combined `status` to
    /// `.disconnected` (corrected by the next periodic `checkHealth()` tick if only this one
    /// section was actually affected).
    func generate(
        server: ServerConnectionConfig,
        prompt: String,
        systemPrompt: String = Prompts.defaultPolish,
        options: GenerateOptions = .init(),
        onToken: ((String) -> Void)? = nil
    ) async -> String? {
        let backend = backend(for: server.api)

        // Apple has no network endpoint to probe. HTTP backends get a quick fail-fast health
        // check first so a black-holed endpoint (not just "connection refused") fails in ~5s
        // instead of waiting out the full request timeout (up to 300s for Summarization).
        // Purely local to this call — does not touch `status`, which is owned exclusively by
        // the periodic combined checkHealth() loop.
        if server.api != "apple" {
            guard await backend.checkHealth(endpoint: server.endpoint, apiKey: server.apiKey) else {
                Logger.log("Server", "\(backend.apiType) unreachable at \(server.endpoint), skipping generation")
                return nil
            }
        }

        let request = LLMRequest(
            endpoint: server.endpoint,
            apiKey: server.apiKey,
            model: server.model,
            systemPrompt: systemPrompt,
            prompt: prompt,
            numCtxFloor: options.numCtx ?? 32768,
            numPredict: options.numPredict ?? 2048,
            timeout: options.timeout ?? 10,
            onToken: onToken
        )
        do {
            return try await backend.generate(request)
        } catch {
            Logger.log("Server", "\(backend.apiType) error: \(error.localizedDescription)")
            updateStatus(.disconnected)
            return nil
        }
    }

    // MARK: - Status management

    private func updateStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        Logger.log("Server", "Status -> \(newStatus.rawValue)")
        onStatusChange?(newStatus)
    }
}
