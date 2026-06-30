import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let moduleManager: ModuleManager
    private let config = RuntimeConfig.shared

    private var isRecording = false
    private var remoteStatus: RemoteInbox.Status = .idle

    // 会议模式
    private var meetingSession: MeetingSession?
    private let transcriptPanel = TranscriptPanelController()
    private var isMeetingActive: Bool { meetingSession?.isRunning ?? false }

    init(moduleManager: ModuleManager) {
        self.moduleManager = moduleManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        ModelServer.shared.onStatusChange = { [weak self] _ in
            self?.updateIcon()
            self?.setupMenu()
        }

        updateIcon()
        setupMenu()
    }

    /// 用户点开菜单时实时刷新权限状态（因为去系统设置授权后回来，希望看到 ✓）
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in self.setupMenu() }
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        updateIcon()
    }

    func setRemoteStatus(_ status: RemoteInbox.Status) {
        remoteStatus = status
        setupMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        if isRecording {
            button.title = "WE●"
            button.contentTintColor = .systemRed
            return
        }

        button.contentTintColor = nil
        switch ModelServer.shared.status {
        case .connected:
            button.title = "WE"
        case .disconnected:
            button.title = "WE·"
        case .unknown:
            button.title = "WE?"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: L10n.t("WE Voice Input", "WE 语音输入"), action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // 服务器状态
        let serverItem = NSMenuItem(title: serverMenuTitle, action: nil, keyEquivalent: "")
        menu.addItem(serverItem)

        let modelItem = NSMenuItem(title: modelMenuTitle, action: nil, keyEquivalent: "")
        menu.addItem(modelItem)

        let reconnectItem = NSMenuItem(
            title: L10n.t("Check server connection", "检查服务器连接"),
            action: #selector(checkServer),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        // 权限状态行：用户视角直接看 4 项 + 点击跳系统设置
        addPermissionRow(
            to: menu,
            label: L10n.t("Global hotkey monitoring", "全局热键监听"),
            granted: PermissionManager.isInputMonitoringGranted(),
            selector: #selector(openInputMonitoringSettings)
        )
        addPermissionRow(
            to: menu,
            label: L10n.t("Text injection (cursor)", "文字注入光标"),
            granted: PermissionManager.isAccessibilityGranted(),
            selector: #selector(openAccessibilitySettings)
        )
        addPermissionRow(
            to: menu,
            label: L10n.t("Microphone", "麦克风录音"),
            granted: PermissionManager.isMicrophoneGranted(),
            selector: #selector(openMicrophoneSettings)
        )
        addPermissionRow(
            to: menu,
            label: L10n.t("Screen Recording (meeting system audio)", "屏幕录制（会议系统音频）"),
            granted: PermissionManager.isScreenCaptureGranted(),
            selector: #selector(openScreenRecordingSettings)
        )

        menu.addItem(NSMenuItem.separator())

        // 会议模式
        if isMeetingActive {
            let stopMeeting = NSMenuItem(
                title: L10n.t("Stop Meeting", "结束会议"),
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            stopMeeting.target = self
            menu.addItem(stopMeeting)
        } else {
            let startMeeting = NSMenuItem(
                title: L10n.t("Start Meeting Recording", "开始会议录音"),
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            startMeeting.target = self
            menu.addItem(startMeeting)
        }

        // 远程语音
        if remoteStatus != .idle {
            menu.addItem(NSMenuItem.separator())
            let port = RuntimeConfig.shared.remoteConfig["port"] as? Int ?? 9800
            let remoteItem = NSMenuItem(title: "\(L10n.t("Remote voice", "远程语音"))\(L10n.t(": ", "："))\(remoteStatus.rawValue) (:\(port))", action: nil, keyEquivalent: "")
            menu.addItem(remoteItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 配置与数据
        let hotkeyTitle: String = {
            let cfg = HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig)
            return L10n.t("Set Hotkey... (\(cfg.displayName))", "设置热键... (\(cfg.displayName))")
        }()
        let hotkeyItem = NSMenuItem(
            title: hotkeyTitle,
            action: #selector(openHotKeySettings),
            keyEquivalent: ""
        )
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        let configItem = NSMenuItem(
            title: L10n.t("Edit Config File...", "编辑配置文件..."),
            action: #selector(openConfig),
            keyEquivalent: ","
        )
        configItem.target = self
        menu.addItem(configItem)

        let dataItem = NSMenuItem(
            title: L10n.t("Open Data Folder...", "打开数据目录..."),
            action: #selector(openDataDir),
            keyEquivalent: ""
        )
        dataItem.target = self
        menu.addItem(dataItem)

        let logItem = NSMenuItem(
            title: L10n.t("View Logs...", "查看日志..."),
            action: #selector(openLog),
            keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.t("Quit", "退出"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private var serverMenuTitle: String {
        let status = ModelServer.shared.status
        let endpoint = RuntimeConfig.shared.serverConfig["endpoint"] as? String ?? L10n.t("not configured", "未配置")
        switch status {
        case .connected:
            return L10n.t("Server: connected (\(endpoint))", "服务器：已连接 (\(endpoint))")
        case .disconnected:
            return L10n.t("Server: disconnected (\(endpoint))", "服务器：未连接 (\(endpoint))")
        case .unknown:
            return L10n.t("Server: checking...", "服务器：检测中...")
        }
    }

    private var modelMenuTitle: String {
        let model = RuntimeConfig.shared.serverConfig["model"] as? String ?? L10n.t("not configured", "未配置")
        return L10n.t("Model: \(model)", "模型：\(model)")
    }


    @objc private func checkServer() {
        Task {
            await ModelServer.shared.checkHealth()
            setupMenu()
            updateIcon()
        }
    }

    @objc private func toggleMeeting() {
        if isMeetingActive {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    private func startMeeting() {
        let session = MeetingSession()
        self.meetingSession = session

        // 实时转写回调 → 更新面板
        var wordCount = 0
        session.onTranscriptUpdate = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                wordCount += text.count
                let segment = MeetingSegment(
                    text: text,
                    rawText: text,
                    startTime: self.meetingSession?.duration ?? 0,
                    endTime: self.meetingSession?.duration ?? 0,
                    speakerId: nil,
                    l2Kind: .skipped,
                    isFinal: true
                )
                self.transcriptPanel.appendSegment(segment)
                self.transcriptPanel.updateStatus(
                    duration: self.meetingSession?.duration ?? 0,
                    wordCount: wordCount
                )
            }
        }

        session.onDurationUpdate = { [weak self] duration in
            guard let self else { return }
            self.transcriptPanel.updateStatus(
                duration: duration,
                wordCount: wordCount
            )
        }

        // 显示转录面板
        transcriptPanel.clear()
        transcriptPanel.setRecording(true)
        transcriptPanel.show()

        Task {
            do {
                try await session.start()
                Logger.log("StatusBar", "Meeting started")
                self.setupMenu()
                self.updateMeetingIcon()
            } catch {
                Logger.log("StatusBar", "Meeting start failed: \(error)")
                self.meetingSession = nil
                self.transcriptPanel.hide()
            }
        }
    }

    private func stopMeeting() {
        guard let session = meetingSession else { return }
        transcriptPanel.setRecording(false)

        Task {
            let result = await session.stop()
            self.meetingSession = nil

            // 更新面板显示最终结果（带说话人标签）
            if !result.segments.isEmpty {
                self.transcriptPanel.updateTranscript(segments: result.segments)
            }

            // 导出 Markdown
            if let url = MeetingExporter.exportMarkdown(
                segments: result.segments,
                duration: result.duration
            ) {
                Logger.log("StatusBar", "Meeting exported: \(url.lastPathComponent)")
            }

            self.setupMenu()
            self.updateMeetingIcon()
            Logger.log("StatusBar", "Meeting stopped, \(result.segments.count) segments, \(String(format: "%.0f", result.duration))s")
        }
    }

    private func updateMeetingIcon() {
        guard let button = statusItem.button else { return }
        if isMeetingActive {
            button.title = "WE◉"
            button.contentTintColor = .systemOrange
        } else if !isRecording {
            updateIcon()
        }
    }

    @objc private func openHotKeySettings() {
        HotKeySettingsWindow.shared.show()
    }

    @objc private func openConfig() {
        let configURL = WEDataDir.configURL
        // 确保配置文件存在
        if !FileManager.default.fileExists(atPath: configURL.path) {
            _ = RuntimeConfig.shared  // 触发默认配置创建
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc private func openDataDir() {
        NSWorkspace.shared.open(WEDataDir.url)
    }

    @objc private func openLog() {
        let logURL = WEDataDir.logURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 权限状态行

    /// 给菜单加一行权限状态。granted=true 时不可点击（信息行）；
    /// granted=false 时变红，点击跳系统设置对应页面。
    private func addPermissionRow(to menu: NSMenu, label: String, granted: Bool, selector: Selector) {
        let icon = granted ? "✓" : "⚠"
        let separator = L10n.t(": ", "：")
        let statusText = granted
            ? L10n.t("Authorized", "已授权")
            : L10n.t("Not authorized — click to open Settings", "未授权 — 点击设置")
        let item = NSMenuItem(
            title: "\(icon) \(label)\(separator)\(statusText)",
            action: granted ? nil : selector,
            keyEquivalent: ""
        )
        if !granted {
            item.target = self
            // 红色高亮提示
            let attr = NSMutableAttributedString(string: item.title)
            attr.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: attr.length))
            item.attributedTitle = attr
        }
        menu.addItem(item)
    }

    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
