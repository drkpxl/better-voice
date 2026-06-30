import Foundation

/// 运行时配置，从 ~/.we/config.json 加载
/// 支持热更新（文件变更时自动重载）
@MainActor
final class RuntimeConfig {
    static let shared = RuntimeConfig()

    private let configURL: URL
    private var values: [String: Any] = [:]
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// G1 ambient 模式开关，默认关闭
    var ambientEnabled: Bool {
        values["ambient_enabled"] as? Bool ?? false
    }

    /// 模型服务器配置
    var serverConfig: [String: Any] {
        values["server"] as? [String: Any] ?? [:]
    }

    /// 润色配置
    var polishConfig: [String: Any] {
        values["polish"] as? [String: Any] ?? [:]
    }

    /// 模型下载配置
    var downloadsConfig: [String: Any] {
        values["downloads"] as? [String: Any] ?? [:]
    }

    /// 远程语音接收配置
    var remoteConfig: [String: Any] {
        values["remote"] as? [String: Any] ?? [:]
    }

    /// 会议模式配置
    var meetingConfig: [String: Any] {
        values["meeting"] as? [String: Any] ?? [:]
    }

    /// 摘要配置（meeting.summarization 子段）
    var meetingSummarizationConfig: [String: Any] {
        meetingConfig["summarization"] as? [String: Any] ?? [:]
    }

    /// 波形指示器配置
    var waveformConfig: [String: Any] {
        values["waveform"] as? [String: Any] ?? [:]
    }

    /// 转写与界面语言（BCP-47 或语言代码，如 "en"、"zh-Hans"）。
    /// nil 时跟随系统语言。
    /// Transcription & UI language (BCP-47 or language code, e.g. "en", "zh-Hans").
    /// When nil, follows the system language.
    var language: String? {
        (values["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 全局热键配置
    var hotKeyConfig: [String: Any] {
        values["hotkey"] as? [String: Any] ?? [:]
    }

    /// 持久化新的 hotkey 配置（设置窗口保存时调用）
    func updateHotKeyConfig(_ dict: [String: Any]) {
        values["hotkey"] = dict
        save()
    }

    /// 写入/覆盖一个顶层配置段（如 "server"、"meeting"、"waveform"），并持久化。
    /// 设置窗口保存时调用。Merges into `values` then saves (avoids clobbering on hot-reload).
    func updateSection(_ key: String, _ dict: [String: Any]) {
        values[key] = dict
        save()
    }

    /// 写入/覆盖一个顶层标量配置（如 "language"）。传 nil 删除该键。
    func updateTopLevel(_ key: String, _ value: Any?) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        save()
    }

    private init() {
        self.configURL = WEDataDir.configURL
        load()
        watchFile()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // 首次运行，创建默认配置
            let defaults: [String: Any] = [
                "language": "en",
                "server": [
                    "endpoint": "http://localhost:11434",
                    "api": "ollama",
                    "model": "qwen3.5:4b-mlx",
                    "timeout": 10,
                    "health_interval": 30,
                    // 摘要可指定不同（更大上下文）的模型；留空则回退到上面的 model。
                    "summarization_model": ""
                ],
                "polish": [
                    "enabled": true,
                    "system_prompt": Prompts.defaultPolish,
                    "personal_context_enabled": true,
                    "context_dictionary_enabled": false,
                    "context_dictionary_path": WEDataDir.correctionDictURL.path
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
                    // 会议转录 + 摘要的保存目录（支持 ~ 展开）。
                    "save_folder": WEDataDir.meetings.path,
                    // 转录完成后是否自动删除音频 wav（默认关闭）。
                    "auto_delete_audio": false,
                    // 收尾面板里会议类型下拉的默认值（general / one_on_one / standup）。
                    "default_type": "general",
                    // 摘要子段。
                    "summarization": [
                        "enabled": true,
                        "num_ctx": 32768,
                        "num_predict": 2048,
                        "timeout": 300,
                        // 是否用一次快速分类预选会议类型。
                        "classify_enabled": true,
                        // 各会议类型的自定义提示词覆盖（留空用内置模板）。
                        "prompts": [String: String]()
                    ]
                ],
                "waveform": [
                    // 噪声地板：RMS 低于此值时波形保持平直（0...1）。
                    "noise_floor": 0.02,
                    // 灵敏度：放大归一化后的电平。
                    "sensitivity": 1.0
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
