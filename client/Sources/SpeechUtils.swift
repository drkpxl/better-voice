import Speech

/// SpeechAnalyzer 共享工具
/// VoiceSession、MeetingSession、RemoteInbox 共用的 locale 查找和模型管理
enum SpeechUtils {

    /// 根据配置/系统语言挑选最佳 SpeechTranscriber locale。
    /// 优先级：config.json 的 "language" → 系统语言 → 英语 → 中文兜底。
    /// Picks the best transcriber locale from config/system language.
    /// Priority: config.json "language" → system language → English → Chinese fallback.
    static func bestLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let prefixes = await MainActor.run { preferredLanguagePrefixes() }
        for prefix in prefixes {
            if let match = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                Logger.log("Speech", "Using locale \(match.identifier(.bcp47)) (matched \"\(prefix)\")")
                return match
            }
        }
        Logger.log("Speech", "No preferred locale matched; falling back to first supported")
        return supported.first
    }

    /// 语言前缀优先级列表（BCP-47 前缀）。
    /// Ordered list of language prefixes to try when selecting a locale.
    @MainActor
    static func preferredLanguagePrefixes() -> [String] {
        var prefixes: [String] = []
        if let configured = RuntimeConfig.shared.language, !configured.isEmpty {
            prefixes.append(configured)
        }
        // Region-qualified current locale first (e.g. "en-US"), then bare language ("en"),
        // so a US machine prefers en-US over the first arbitrary en-* locale.
        let full = Locale.current.identifier(.bcp47)
        if !full.isEmpty { prefixes.append(full) }
        if let system = Locale.current.language.languageCode?.identifier {
            prefixes.append(system)
        }
        // Sensible fallbacks so transcription always has *some* locale.
        prefixes.append(contentsOf: ["en-US", "en", "zh-Hans", "zh-CN", "zh"])
        return prefixes
    }

    /// 向后兼容旧调用名（现在跟随配置语言，不再强制中文）。
    /// Back-compat alias — now follows the configured language, no longer Chinese-only.
    static func findChineseLocale() async -> Locale? {
        await bestLocale()
    }

    /// 确保语音模型已安装
    static func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == localeID }) {
            return
        }
        Logger.log("Speech", "Downloading model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Speech", "Model downloaded")
        }
    }
}
