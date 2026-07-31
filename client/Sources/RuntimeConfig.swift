import Foundation
import FoundationModels

/// App preferences facade. v1 stored these in `~/.better-voice/config.json` with a file-watcher;
/// v2 backs the SAME public API onto `UserDefaults` (one dictionary under `runtimeConfigKey`), so
/// preferences are app-level and independent of the chosen workspace folder. The nested
/// `[String: Any]` shape is preserved verbatim so every consumer (`summarizationServerConfig`, …)
/// ports unchanged.
///
/// Retired vs. v1 (live-capture only): `meeting.audio_source`, `meeting.auto_delete_audio`,
/// `meeting.save_folder` — dropped from the seeded defaults and no longer read. (v1's
/// `hotkey.meeting` — a nested key under `hotkey` — was ALSO dropped at the same time, but a
/// meeting hotkey is back as of the second global hotkey: see the top-level `meeting_hotkey`
/// section below, a sibling of `hotkey` rather than nested inside it.)
///
/// Retired since: the whole `polish` section, with the LLM dictation-cleanup stage. Unlike the v1
/// keys above it is actively DELETED rather than just unread -- see `migratePolishSectionIfNeeded`.
@MainActor
final class RuntimeConfig {
    static let shared = RuntimeConfig()

    private static let defaultsKey = "runtimeConfig"
    private var values: [String: Any] = [:]

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

    /// Meeting-summarization provider connection -- the app's only LLM provider since dictation
    /// cleanup was retired. See `ServerConnectionConfig`.
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

    /// Whether dictation strips discourse fillers ("um", "uh", sentence-opening "so"/"well").
    /// Defaults to TRUE: it is what replaced the removed LLM cleanup stage for that job. See
    /// `FillerStripper`, which is deliberately conservative about ambiguous words.
    var stripFillers: Bool {
        values["strip_fillers"] as? Bool ?? true
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

    /// Whether `personal-context.md` is appended to system prompts (see `PersonalContext`).
    ///
    /// Top-level, not nested under `meeting.summarization`, even though summarization is its only
    /// consumer today: it gates one app-wide user-data file, and burying it inside the summarization
    /// section would make `PersonalContext` -- a general helper -- read the meeting config to answer
    /// a question that has nothing to do with meetings. Lived at `polish.personal_context_enabled`
    /// until the cleanup stage was deleted; `migratePolishSectionIfNeeded` carries the old value
    /// over, because dropping it would silently re-enable context injection for anyone who had
    /// turned it off.
    var personalContextEnabled: Bool {
        values["personal_context_enabled"] as? Bool ?? true
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
            // Chronological order: the single-server split shipped first, the cleanup-stage deletion
            // second, so an install that skipped both versions must be walked through in that order.
            migrateServerSectionIfNeeded()
            migratePolishSectionIfNeeded()
            migrateSegmentKeysIfNeeded()
            Logger.log("Config", "Loaded preferences from UserDefaults")
            return
        }
        // First run — seed a zero-setup default. A fresh install with Apple Intelligence enabled
        // gets meeting summaries with nothing to install.
        //
        // The Ollama fallback seeds `ornith:9b` (decision 12). Not the `qwen3.5:4b-mlx` it seeded
        // originally, which measured worst of the four models tried and drops most of what a meeting
        // was about -- that reads as "summaries are useless" rather than "the default model is
        // small". And not `qwen3.5:9b-mlx`, which this briefly named on the strength of a bake-off
        // run that turned out to be measuring a pipeline we do not ship: it fed the models anonymous
        // `S1`-`S4` speaker labels and suppressed the vocabulary block, so they produced "iSummit"
        // where the app produces "Summit Pass". Re-run in the shipping configuration, thread recall is
        // a three-way tie -- ornith:9b, gemma4:12b and qwen3.5:9b-mlx all at 72.7% -- so the metric
        // does not choose between them and the owner chose by reading the summaries.
        //
        // ornith:9b is also the smallest of the three at 5.6 GB against qwen's 8.9 GB and gemma's
        // 6.8 GB, which matters because it is a fresh install's download on top of Parakeet's
        // 470 MB. It is thinking-capable; `makeOllamaRequestBody` sends `think: false`, so it
        // answers directly rather than spending num_predict on reasoning.
        let connection: [String: Any] = SystemLanguageModel.default.isAvailable
            ? ["api": "apple", "endpoint": "", "model": FoundationModelsBackend.modelName, "api_key": ""]
            : ["api": "ollama", "endpoint": "http://localhost:11434", "model": OllamaBackend.defaultModel, "api_key": ""]
        let defaults: [String: Any] = [
            "language": "en",
            "personal_context_enabled": true,
            "meeting": [
                // Segment grouping thresholds. Named `l2_*` until the LLM cleanup stage they bounded
                // was deleted; `migrateSegmentKeysIfNeeded` carries old values across.
                "segment_pause_sec": 1.5,
                "segment_max_chars": 200,
                "segment_min_chars": 30,
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

    /// One-time migration for installs that predate per-section providers: the old single top-level
    /// `server` section (api/endpoint/model/api_key/timeout, one connection shared by dictation
    /// cleanup and meeting summarization) gets copied into `meeting.summarization.server` so an
    /// existing setup carries over instead of resetting to Apple. `server.summarization_model` (the
    /// old per-call model override) becomes the section's own `model` if it was set, else the old
    /// shared `server.model`.
    ///
    /// Deletes `server` once it has been read. It used to be left behind as a harmless orphan,
    /// using the presence of `polish.server` as the "already migrated" sentinel -- but the polish
    /// section is now stripped on load, so that sentinel would read as absent on the next launch and
    /// this migration would run a second time, overwriting a summarization provider the user had
    /// since changed in Settings. Removing the input makes it unrepeatable by construction.
    private func migrateServerSectionIfNeeded() {
        guard let oldServer = values["server"] as? [String: Any] else { return }

        var meeting = values["meeting"] as? [String: Any] ?? [:]
        var summ = meeting["summarization"] as? [String: Any] ?? [:]
        if summ["server"] == nil {
            let sharedModel = oldServer["model"] as? String ?? ""
            let modelOverride = (oldServer["summarization_model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            summ["server"] = [
                "api": oldServer["api"] as? String ?? "ollama",
                "endpoint": oldServer["endpoint"] as? String ?? "",
                "model": (modelOverride?.isEmpty == false) ? modelOverride! : sharedModel,
                "api_key": oldServer["api_key"] as? String ?? ""
            ]
            meeting["summarization"] = summ
            values["meeting"] = meeting
            Logger.log("Config", "Migrated single server config into the summarization provider")
        }

        values.removeValue(forKey: "server")
        save()
    }

    /// One-time migration for installs that predate the removal of the LLM dictation-cleanup stage.
    /// Lifts `polish.personal_context_enabled` to the top level (see `personalContextEnabled`), then
    /// deletes the whole `polish` section.
    ///
    /// Stripped rather than left inert for three reasons. `save()` rewrites the entire dictionary,
    /// so an inert section is not merely unread, it is actively re-persisted on every settings
    /// change and would outlive the feature indefinitely. `polish.server.api_key` is a credential
    /// the user can no longer see or clear from any UI, so keeping it is a liability with no
    /// remaining purpose. And `polish.system_prompt` is a multi-KB prompt blob whose only effect now
    /// would be to make a future reader think the stage still exists.
    private func migratePolishSectionIfNeeded() {
        guard let polish = values["polish"] as? [String: Any] else { return }

        // Deleting `polish` below makes this unrepeatable, so the guard is only for the config that
        // carries both keys at once -- a downgrade-then-upgrade, where the top-level value is the
        // newer of the two and must win.
        if values["personal_context_enabled"] == nil {
            values["personal_context_enabled"] = polish["personal_context_enabled"] as? Bool ?? true
        }
        values.removeValue(forKey: "polish")
        Logger.log("Config", "Removed retired polish config section (personal_context_enabled preserved)")
        save()
    }

    /// Rename `meeting.l2_*` to `meeting.segment_*`. These are `SegmentBuffer`'s grouping thresholds;
    /// they were named for the LLM cleanup stage whose input they used to bound, and kept that name
    /// after the stage was deleted, which left the config describing a pipeline the app no longer has.
    ///
    /// Values are carried over rather than reset because they are user-tunable and a silent revert to
    /// defaults would change how transcripts are chunked with no visible cause. Deleting the old keys
    /// makes this unrepeatable, so a later hand-edit of a `segment_*` value cannot be overwritten by a
    /// stale `l2_*` sibling on the next launch.
    private func migrateSegmentKeysIfNeeded() {
        guard var meeting = values["meeting"] as? [String: Any] else { return }
        let renames = [
            ("l2_flush_on_pause_sec", "segment_pause_sec"),
            ("l2_flush_on_chars", "segment_max_chars"),
            ("l2_min_chars", "segment_min_chars"),
        ]
        guard renames.contains(where: { meeting[$0.0] != nil }) else { return }

        for (old, new) in renames {
            guard let value = meeting[old] else { continue }
            // An existing `segment_*` value is the newer of the two and wins, for the same
            // downgrade-then-upgrade reason as `personal_context_enabled`.
            if meeting[new] == nil { meeting[new] = value }
            meeting.removeValue(forKey: old)
        }
        values["meeting"] = meeting
        Logger.log("Config", "Migrated meeting.l2_* segmentation keys to meeting.segment_*")
        save()
    }

    private func save() {
        UserDefaults.standard.set(values, forKey: Self.defaultsKey)
    }
}
