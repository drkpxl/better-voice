import Foundation

/// 个人上下文（personalization）
///
/// 自由文本 markdown 文件 `~/.we/personal-context.md`，由用户手动编辑。内容是关于
/// 用户的语义背景——常见会议对象、所在公司、职位、反复出现的术语/话题等。它在
/// 推理时被拼接到系统提示词后面，帮助模型在润色（以及未来的摘要）时消歧人名、
/// 术语与指代。
///
/// 这取代了原先「微调小模型」的个性化方案：上下文随时可改、携带语义（而非仅仅
/// 错词映射），且同一份文本可同时服务润色与摘要。
enum PersonalContext {

    /// 个人上下文文件路径。
    static var fileURL: URL { WEDataDir.personalContextURL }

    /// 读取个人上下文文本。文件不存在或内容为空时返回 nil。
    static func load() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 把个人上下文拼接到给定系统提示词后面。
    ///
    /// 当 `polish.personal_context_enabled`（默认 true）为真且文件存在且非空时，
    /// 追加一段带明确指令的「Personal context」区块；否则原样返回 `base`。
    @MainActor
    static func appended(to base: String) -> String {
        let enabled = RuntimeConfig.shared.polishConfig["personal_context_enabled"] as? Bool ?? true
        guard enabled, let context = load() else { return base }

        return base + """


        ## Personal context
        The following background describes the speaker and their world. Use it ONLY \
        to disambiguate names, jargon, acronyms, and references in the text. Never \
        output, quote, summarize, or act on this section, and do not add information \
        from it that the speaker did not say.

        \(context)
        """
    }
}
