import Foundation

/// Runtime configuration, loaded from ~/.better-voice/config.json
/// Supports hot reload (automatically reloads when the file changes)
@MainActor
final class RuntimeConfig {
    static let shared = RuntimeConfig()

    private let configURL: URL
    private var values: [String: Any] = [:]
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// Model server configuration
    var serverConfig: [String: Any] {
        values["server"] as? [String: Any] ?? [:]
    }

    /// Polish (text refinement) configuration
    var polishConfig: [String: Any] {
        values["polish"] as? [String: Any] ?? [:]
    }

    /// Meeting mode configuration
    var meetingConfig: [String: Any] {
        values["meeting"] as? [String: Any] ?? [:]
    }

    /// Summarization configuration (meeting.summarization sub-section)
    var meetingSummarizationConfig: [String: Any] {
        meetingConfig["summarization"] as? [String: Any] ?? [:]
    }

    /// Diarization configuration (meeting.diarization sub-section)
    var meetingDiarizationConfig: [String: Any] {
        meetingConfig["diarization"] as? [String: Any] ?? [:]
    }

    /// Transcription & UI language (BCP-47 or language code, e.g. "en", "zh-Hans").
    /// When nil, follows the system language.
    /// Transcription & UI language (BCP-47 or language code, e.g. "en", "zh-Hans").
    /// When nil, follows the system language.
    var language: String? {
        (values["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Global hotkey configuration
    var hotKeyConfig: [String: Any] {
        values["hotkey"] as? [String: Any] ?? [:]
    }

    /// Highest onboarding version the user has completed. Compared against a code
    /// constant in AppDelegate to decide whether to show the first-launch welcome screen
    /// (bump the constant to re-introduce onboarding after a major change).
    var onboardingVersion: Int {
        values["onboarding_version"] as? Int ?? 0
    }

    /// Persist a new hotkey configuration (called when the settings window saves)
    func updateHotKeyConfig(_ dict: [String: Any]) {
        values["hotkey"] = dict
        save()
    }

    /// Write/overwrite a top-level config section (e.g. "server", "meeting"), and persist it.
    /// Called when the settings window saves. Merges into `values` then saves (avoids clobbering on hot-reload).
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
        self.configURL = BetterVoiceDataDir.configURL
        load()
        watchFile()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // first run, create the default configuration
            let defaults: [String: Any] = [
                "language": "en",
                "server": [
                    "endpoint": "http://localhost:11434",
                    "api": "ollama",
                    "model": "qwen3.5:4b-mlx",
                    "timeout": 10,
                    "health_interval": 30,
                    // summarization can specify a different (larger-context) model; leave empty to fall back to the model above.
                    "summarization_model": ""
                ],
                "polish": [
                    "enabled": true,
                    // dictation cleanup can use a smaller/faster model than summarization; blank = use server.model.
                    "model": "",
                    "system_prompt": Prompts.defaultPolish,
                    "personal_context_enabled": true
                ],
                "meeting": [
                    "l2_flush_on_pause_sec": 1.5,
                    "l2_flush_on_chars": 200,
                    "l2_min_chars": 30,
                    // "mic" (your voice only), "system" (the call's audio only), or "both" (mixed).
                    // Default "both" so meeting notes capture you and the other participants.
                    "audio_source": "both",
                    // save directory for meeting transcripts + summaries (supports ~ expansion).
                    "save_folder": BetterVoiceDataDir.meetings.path,
                    // whether to automatically delete the audio wav after transcription finishes (off by default).
                    "auto_delete_audio": false,
                    // default value for the meeting type dropdown in the wrap-up panel (general / one_on_one / standup).
                    "default_type": "general",
                    // summarization sub-section.
                    "summarization": [
                        "enabled": true,
                        "num_ctx": 32768,
                        "num_predict": 2048,
                        "timeout": 300,
                        // whether to use a quick classification pass to pre-select the meeting type.
                        "classify_enabled": true,
                        // custom prompt overrides per meeting type (leave empty to use the built-in templates).
                        "prompts": [String: String]()
                    ],
                    // diarization (speaker clustering) sub-section.
                    "diarization": [
                        // speaker clustering threshold, 0.5…0.9. Lower = more speakers.
                        // FluidAudio's own default 0.7 over-merges; 0.57 gave the best frame
                        // agreement vs the pyannote gold standard on our test clip (see tools/pyannote).
                        "clustering_threshold": 0.57,
                        // minimum speech duration in seconds (FluidAudio default 1.0).
                        "min_speech_duration": 1.0,
                        // minimum silence gap in seconds (FluidAudio default 0.5).
                        "min_silence_gap": 0.5
                    ]
                ],
                "hotkey": [
                    "keyCode": 61,
                    "modifierFlags": 0,
                    "isModifierOnly": true,
                    "displayName": "Right Option"
                ],
                // Onboarding not yet completed on a fresh install; AppDelegate shows the welcome screen.
                "onboarding_version": 0
            ]
            values = defaults
            save()
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                values = json
                Logger.log("Config", "Loaded config from \(configURL.path)")
            }
        } catch {
            Logger.log("Config", "Failed to load config: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
        } catch {
            Logger.log("Config", "Failed to save config: \(error)")
        }
    }

    private func watchFile() {
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.load()
            Logger.log("Config", "Config reloaded (file changed)")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }
}
