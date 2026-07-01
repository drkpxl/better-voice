import Speech

/// Shared SpeechAnalyzer utilities
/// Locale lookup and model management shared by VoiceSession and MeetingSession
enum SpeechUtils {

    /// Picks the best SpeechTranscriber locale based on configuration/system language.
    /// Priority: config.json's "language" -> system language -> English -> Chinese fallback.
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

    /// Ordered priority list of language prefixes (BCP-47 prefixes).
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

    /// Backward-compatible alias for the old call name (now follows the configured language, no longer forced to Chinese).
    /// Back-compat alias — now follows the configured language, no longer Chinese-only.
    static func findChineseLocale() async -> Locale? {
        await bestLocale()
    }

    /// Ensures the speech model is installed
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
