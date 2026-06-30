import Foundation

/// Runtime configuration, loaded from ~/.better-voice/config.json
/// Supports hot reload (automatically reloads when the file changes)
@MainActor
final class RuntimeConfig {
    static let shared = RuntimeConfig()

    private let configURL: URL
    private var values: [String: Any] = [:]
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// G1 ambient mode toggle, off by default
    var ambientEnabled: Bool {
        values["ambient_enabled"] as? Bool ?? false
    }

    /// Model server configuration
    var serverConfig: [String: Any] {
        values["server"] as? [String: Any] ?? [:]
    }

    /// Polish (text refinement) configuration
    var polishConfig: [String: Any] {
        values["polish"] as? [String: Any] ?? [:]
    }

    /// Model download configuration
    var downloadsConfig: [String: Any] {
        values["downloads"] as? [String: Any] ?? [:]
    }

    /// Remote voice inbox configuration
    var remoteConfig: [String: Any] {
        values["remote"] as? [String: Any] ?? [:]
    }

    /// Meeting mode configuration
    var meetingConfig: [String: Any] {
        values["meeting"] as? [String: Any] ?? [:]
    }

    /// Summarization configuration (meeting.summarization sub-section)
    var meetingSummarizationConfig: [String: Any] {
        meetingConfig["summarization"] as? [String: Any] ?? [:]
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

    /// Persist a new hotkey configuration (called when the settings window saves)
    func updateHotKeyConfig(_ dict: [String: Any]) {
        values["hotkey"] = dict
        save()
    }

    /// Write/overwrite a top-level config section (e.g. "server", "meeting", "waveform"), and persist it.
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
                    "system_prompt": Prompts.defaultPolish,
                    "personal_context_enabled": true,
                    "context_dictionary_enabled": false,
                    "context_dictionary_path": BetterVoiceDataDir.correctionDictURL.path
                ],
                "downloads": [:],
                "remote": [
                    "enabled": true,
                    "port": 9800,
                    "auth_token": ""
                ],
                "meeting": [
                    "l2_flush_on_pause_sec": 1.5,
                    "l2_flush_on_chars": 200,
                    "l2_min_chars": 30,
                    "audio_source": "mic",
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
                    ]
                ],
                "hotkey": [
                    "keyCode": 61,
                    "modifierFlags": 0,
                    "isModifierOnly": true,
                    "displayName": "Right Option"
                ]
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
