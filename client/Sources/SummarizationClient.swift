import Foundation
import WECore

/// 会议摘要客户端：通过 ModelServer 路由到 Ollama/OpenAI。
/// - classifyType: 用一次快速调用预选会议类型（收尾面板用）。
/// - summarize: 用选定类型的提示词生成 Markdown 摘要。
/// 系统提示词都会经过 `PersonalContext.appended(to:)`，让模型用个人上下文
/// 消歧人名/术语（与 PolishClient 一致）。
@MainActor
final class SummarizationClient {
    static let shared = SummarizationClient()

    // MARK: - 配置读取

    private var summarizationConfig: [String: Any] {
        RuntimeConfig.shared.meetingSummarizationConfig
    }

    /// 摘要模型：server.summarization_model 非空则用之，否则 nil（ModelServer 回退到 server.model）。
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

    /// 收尾面板下拉的默认会议类型。
    var defaultType: MeetingType {
        let raw = RuntimeConfig.shared.meetingConfig["default_type"] as? String ?? "general"
        return MeetingType.from(configKey: raw) ?? .general
    }

    /// 是否启用类型分类预选。
    var classifyEnabled: Bool {
        summarizationConfig["classify_enabled"] as? Bool ?? true
    }

    /// 是否启用摘要。
    var summarizationEnabled: Bool {
        summarizationConfig["enabled"] as? Bool ?? true
    }

    // MARK: - 推理

    /// 用一次快速调用把转录分类为会议类型，失败回退到默认类型。
    func classifyType(transcript: String) async -> MeetingType {
        let fallback = defaultType
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }

        let system = Prompts.meetingTypeClassificationPrompt(language: language)
        // 分类只需极短输出；上下文沿用摘要的 num_ctx 以容纳长转录。
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

    /// 生成 Markdown 摘要。返回 nil 表示失败或服务器未连接。
    func summarize(transcript: String, type: MeetingType) async -> String? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let base = Prompts.summarizationPrompt(for: type, overrides: promptOverrides, language: language)
        let system = PersonalContext.appended(to: base)
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
