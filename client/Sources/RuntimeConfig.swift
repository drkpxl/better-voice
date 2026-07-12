import Foundation
import FoundationModels

/// App preferences facade. v1 stored these in `~/.better-voice/config.json` with a file-watcher;
/// v2 backs the SAME public API onto `UserDefaults` (one dictionary under `runtimeConfigKey`), so
/// preferences are app-level and independent of the chosen workspace folder. The nested
/// `[String: Any]` shape is preserved verbatim so every consumer (`polishServerConfig`,
/// `summarizationServerConfig`, …) ports unchanged.
///
/// Retired vs. v1 (live-capture only): `meeting.audio_source`, `meeting.auto_delete_audio`,
/// `meeting.save_folder` — dropped from the seeded defaults and no longer read. (v1's
/// `hotkey.meeting` — a nested key under `hotkey` — was ALSO dropped at the same time, but a
/// meeting hotkey is back as of the second global hotkey: see the top-level `meeting_hotkey`
/// section below, a sibling of `hotkey` rather than nested inside it.)
@MainActor
final class RuntimeConfig {
    static let shared = RuntimeConfig()

    private static let defaultsKey = "runtimeConfig"
    private var values: [String: Any] = [:]

    /// Polish (text refinement) configuration
    var polishConfig: [String: Any] {
        values["polish"] as? [String: Any] ?? [:]
    }

    /// Meeting mode configuration
    var meetingConfig: [String: Any] {
        values["meeting"] as? [String: Any] ?? [:]
    }

    /// Apple Notes destination configuration: chosen account name plus the Transcripts/Summaries
    /// folder id+name pairs (`account`, `transcriptsFolderId`, `transcriptsFolderName`,
    /// `summariesFolderId`, `summariesFolderName`). Names are kept alongside ids so
    /// `NotesMeetingWriter` can re-resolve (or recreate) a folder by name if its id goes stale —
    /// e.g. the user deleted or recreated the folder in Notes since it was chosen.
    var notesConfig: [String: Any] {
        values["notes"] as? [String: Any] ?? [:]
    }

    /// True once the user has picked an account and both folders. THE authoritative "is the
    /// Apple Notes destination set up" definition — all five `notesConfig` keys non-empty (ids
    /// AND names, since `NotesMeetingWriter`'s stale-folder recovery needs the names): Phase
    /// 3b's onboarding checks it to know whether setup is still needed, and
    /// `NotesMeetingWriter.currentDestination()` guards on it before every write.
    var notesConfigured: Bool {
        let cfg = notesConfig
        let keys = ["account", "transcriptsFolderId", "transcriptsFolderName", "summariesFolderId", "summariesFolderName"]
        return keys.allSatisfy { key in
            let value = (cfg[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !value.isEmpty
        }
    }

    /// Summarization configuration (meeting.summarization sub-section)
    var meetingSummarizationConfig: [String: Any] {
        meetingConfig["summarization"] as? [String: Any] ?? [:]
    }

    /// Dictation/transcript-polish provider connection — independent of Summarization's, see
    /// `ServerConnectionConfig`.
    var polishServerConfig: ServerConnectionConfig {
        let dict = polishConfig["server"] as? [String: Any] ?? [:]
        return ServerConnectionConfig(
            api: dict["api"] as? String ?? "apple",
            endpoint: dict["endpoint"] as? String ?? "",
            model: dict["model"] as? String ?? FoundationModelsBackend.modelName,
            apiKey: dict["api_key"] as? String ?? ""
        )
    }

    /// Meeting-summarization provider connection — independent of Polish's, see
    /// `ServerConnectionConfig`.
    var summarizationServerConfig: ServerConnectionConfig {
        let dict = meetingSummarizationConfig["server"] as? [String: Any] ?? [:]
        return ServerConnectionConfig(
            api: dict["api"] as? String ?? "apple",
            endpoint: dict["endpoint"] as? String ?? "",
            model: dict["model"] as? String ?? FoundationModelsBackend.modelName,
            apiKey: dict["api_key"] as? String ?? ""
        )
    }

    /// Transcription & UI language (BCP-47 or language code, e.g. "en", "zh-Hans").
    /// When nil, follows the system language.
    var language: String? {
        (values["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Dictation hotkey configuration.
    var hotKeyConfig: [String: Any] {
        values["hotkey"] as? [String: Any] ?? [:]
    }

    /// Meeting hotkey configuration (toggles `MeetingCoordinator.toggleMeeting()`) — a sibling
    /// top-level section, independent of `hotKeyConfig`/`hotkey` above. Empty on installs that
    /// predate the second hotkey; `HotKeyConfig.load(from:fallback:)` handles that by falling
    /// back to `.meetingDefault` rather than treating an empty dict as "unset -> dictation's
    /// default", which would silently collide the two bindings.
    var meetingHotKeyConfig: [String: Any] {
        values["meeting_hotkey"] as? [String: Any] ?? [:]
    }

    /// The user's own name, used to label their own voice in transcripts/summaries instead of
    /// the generic "You" (see `SpeakerLabeling.swift`'s `localLabel` parameter). Empty/unset -> nil.
    var userName: String? {
        (values["user_name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Highest onboarding version the user has completed.
    var onboardingVersion: Int {
        values["onboarding_version"] as? Int ?? 0
    }

    /// Persist a new dictation hotkey configuration (called when the settings window saves).
    /// Merges into the existing section so sibling keys aren't dropped.
    func updateHotKeyConfig(_ dict: [String: Any]) {
        var merged = hotKeyConfig
        for (key, value) in dict { merged[key] = value }
        values["hotkey"] = merged
        save()
    }

    /// Persist a new meeting hotkey configuration (called when the settings window saves).
    /// Companion to `updateHotKeyConfig`, same merge-not-overwrite behavior.
    func updateMeetingHotKeyConfig(_ dict: [String: Any]) {
        var merged = meetingHotKeyConfig
        for (key, value) in dict { merged[key] = value }
        values["meeting_hotkey"] = merged
        save()
    }

    /// Write/overwrite a top-level config section (e.g. "server", "meeting"), and persist it.
    func updateSection(_ key: String, _ dict: [String: Any]) {
        values[key] = dict
        save()
    }

    /// Write/overwrite a top-level scalar config value (e.g. "language"). Pass nil to delete the key.
    func updateTopLevel(_ key: String, _ value: Any?) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        save()
    }

    private init() {
        load()
    }

    private func load() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey), !stored.isEmpty {
            values = stored
            migrateServerSectionIfNeeded()
            Logger.log("Config", "Loaded preferences from UserDefaults")
            return
        }
        // First run — seed a zero-setup default. A fresh install with Apple Intelligence enabled
        // gets dictation polish and meeting summaries with nothing to install.
        let connection: [String: Any] = SystemLanguageModel.default.isAvailable
            ? ["api": "apple", "endpoint": "", "model": FoundationModelsBackend.modelName, "api_key": ""]
            : ["api": "ollama", "endpoint": "http://localhost:11434", "model": "qwen3.5:4b-mlx", "api_key": ""]
        let defaults: [String: Any] = [
            "language": "en",
            "polish": [
                "enabled": true,
                "system_prompt": Prompts.defaultPolish,
                "personal_context_enabled": true,
                "server": connection
            ],
            "meeting": [
                "l2_flush_on_pause_sec": 1.5,
                "l2_flush_on_chars": 200,
                "l2_min_chars": 30,
                // default value for the meeting type dropdown (general / one_on_one / standup).
                "default_type": "general",
                "summarization": [
                    "enabled": true,
                    "num_ctx": 32768,
                    "num_predict": 2048,
                    "timeout": 300,
                    "classify_enabled": true,
                    "prompts": [String: String](),
                    "server": connection
                ]
            ],
            // Sourced from HotKeyConfig's own defaults (not re-literaled here) so the seeded
            // UserDefaults dict can never drift from what `HotKeyConfig.default`/`.meetingDefault`
            // actually describe.
            "hotkey": HotKeyConfig.default.toDictionary(),
            "meeting_hotkey": HotKeyConfig.meetingDefault.toDictionary(),
            "onboarding_version": 0
        ]
        values = defaults
        save()
    }

    /// One-time migration for installs that predate per-section providers: the old single
    /// top-level `server` section (api/endpoint/model/api_key/timeout, one connection shared by
    /// dictation polish and meeting summarization) gets copied into both `polish.server` and
    /// `meeting.summarization.server` so an existing setup carries over instead of resetting to
    /// Apple. `polish.model`/`server.summarization_model` (the old per-call model overrides)
    /// become each new section's own `model` if they were set, else the old shared `server.model`.
    /// Never deletes the old `server` key — a harmless orphaned value once nothing reads it.
    private func migrateServerSectionIfNeeded() {
        guard let oldServer = values["server"] as? [String: Any] else { return }
        var polish = values["polish"] as? [String: Any] ?? [:]
        guard polish["server"] == nil else { return }   // already migrated

        let api = oldServer["api"] as? String ?? "ollama"
        let endpoint = oldServer["endpoint"] as? String ?? ""
        let apiKey = oldServer["api_key"] as? String ?? ""
        let sharedModel = oldServer["model"] as? String ?? ""
        let polishModelOverride = (polish["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarizationModelOverride = (oldServer["summarization_model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        polish["server"] = [
            "api": api, "endpoint": endpoint,
            "model": (polishModelOverride?.isEmpty == false) ? polishModelOverride! : sharedModel,
            "api_key": apiKey
        ]
        values["polish"] = polish

        var meeting = values["meeting"] as? [String: Any] ?? [:]
        var summ = meeting["summarization"] as? [String: Any] ?? [:]
        summ["server"] = [
            "api": api, "endpoint": endpoint,
            "model": (summarizationModelOverride?.isEmpty == false) ? summarizationModelOverride! : sharedModel,
            "api_key": apiKey
        ]
        meeting["summarization"] = summ
        values["meeting"] = meeting

        Logger.log("Config", "Migrated single server config into per-section polish/summarization providers")
        save()
    }

    private func save() {
        UserDefaults.standard.set(values, forKey: Self.defaultsKey)
    }
}
