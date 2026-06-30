import AppKit
import WECore

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
    /// 停止后到收尾流程（分类/命名面板/导出/摘要）结束之间为真，期间禁止开新会议。
    private var isFinishingMeeting = false

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

        menu.addItem(NSMenuItem(title: t("WE Voice Input"), action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // 权限状态行：用户视角直接看 4 项 + 点击跳系统设置
        addPermissionRow(
            to: menu,
            label: t("Global hotkey monitoring"),
            granted: PermissionManager.isInputMonitoringGranted(),
            selector: #selector(openInputMonitoringSettings)
        )
        addPermissionRow(
            to: menu,
            label: t("Text injection (cursor)"),
            granted: PermissionManager.isAccessibilityGranted(),
            selector: #selector(openAccessibilitySettings)
        )
        addPermissionRow(
            to: menu,
            label: t("Microphone"),
            granted: PermissionManager.isMicrophoneGranted(),
            selector: #selector(openMicrophoneSettings)
        )
        addPermissionRow(
            to: menu,
            label: t("Screen Recording (meeting system audio)"),
            granted: PermissionManager.isScreenCaptureGranted(),
            selector: #selector(openScreenRecordingSettings)
        )

        menu.addItem(NSMenuItem.separator())

        // 会议模式
        if isMeetingActive {
            let stopMeeting = NSMenuItem(
                title: t("Stop Meeting"),
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            stopMeeting.target = self
            menu.addItem(stopMeeting)
        } else if isFinishingMeeting {
            // 收尾中：占位项，禁止开新会议直到摘要流程结束。
            let finishing = NSMenuItem(title: t("Finishing meeting..."), action: nil, keyEquivalent: "")
            finishing.isEnabled = false
            menu.addItem(finishing)
        } else {
            let startMeeting = NSMenuItem(
                title: t("Start Meeting Recording"),
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
            let remoteItem = NSMenuItem(title: t("Remote voice: \(remoteStatus.displayName) (:\(String(port)))"), action: nil, keyEquivalent: "")
            menu.addItem(remoteItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 设置（服务器/摘要/会议/快捷键/数据都收进设置窗口）
        let settingsItem = NSMenuItem(
            title: t("Settings..."),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: t("Quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleMeeting() {
        if isMeetingActive {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    private func startMeeting() {
        // 上一场会议的收尾流程（命名/摘要）还没结束时，不允许开新会议。
        guard !isFinishingMeeting else {
            Logger.log("StatusBar", "Ignored start: previous meeting still finishing")
            return
        }
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

            // 进入收尾：禁止开新会议直到摘要流程结束。
            self.isFinishingMeeting = true
            self.setupMenu()
            self.updateMeetingIcon()
            Logger.log("StatusBar", "Meeting stopped, \(result.segments.count) segments, \(String(format: "%.0f", result.duration))s")

            // 收尾：分类 → 命名/类型面板 → 导出转录 → 摘要 → 可选删音频。
            await self.finishMeeting(result: result)

            self.isFinishingMeeting = false
            self.setupMenu()
            self.updateMeetingIcon()
        }
    }

    /// 会议收尾流程（诊断后）：会议类型分类预选、说话人命名面板、导出转录与摘要、按需删除音频。
    private func finishMeeting(result: MeetingResult) async {
        guard !result.segments.isEmpty else {
            Logger.log("StatusBar", "Empty meeting, skipping wrap-up/summary")
            return
        }

        let prefix = t("Speaker")
        let client = SummarizationClient.shared

        // 1. 用一次快速分类预选会议类型。
        let rawTranscript = buildSummarizationTranscript(segments: result.segments, speakerPrefix: prefix)
        let inferred: MeetingType
        if client.classifyEnabled, !rawTranscript.isEmpty {
            inferred = await client.classifyType(transcript: rawTranscript)
        } else {
            inferred = client.defaultType
        }

        // 2. 收尾面板（等待用户：命名 + 选类型；Skip 也会摘要）。
        let speakerIds = orderedUniqueSpeakerIds(result.segments)
        let snippets = sampleSnippets(result.segments, maxLen: 100)
        let speakers = speakerIds.map { (id: $0, snippet: snippets[$0] ?? "") }
        let outcome = await MeetingWrapUpWindow.shared.present(speakers: speakers, inferredType: inferred)

        // 3. 应用名字，导出转录。
        let named = applySpeakerNames(outcome.names, to: result.segments)
        self.transcriptPanel.updateTranscript(segments: named)
        let folder = MeetingExporter.configuredFolder()
        let transcriptURL = MeetingExporter.exportMarkdown(
            segments: named,
            duration: result.duration,
            date: result.date,
            saveFolder: folder
        )
        if let transcriptURL {
            Logger.log("StatusBar", "Meeting transcript exported: \(transcriptURL.lastPathComponent)")
        }

        // 4. 摘要（选定类型，大 num_ctx）+ 写 summary 文件。
        if client.summarizationEnabled {
            let namedTranscript = buildSummarizationTranscript(segments: named, speakerPrefix: prefix)
            if let summary = await client.summarize(transcript: namedTranscript, type: outcome.type) {
                let base = transcriptURL?.deletingPathExtension().lastPathComponent
                    ?? MeetingExporter.baseName(for: result.date)
                if let summaryURL = MeetingExporter.exportSummary(
                    summary,
                    baseName: base,
                    type: outcome.type,
                    duration: result.duration,
                    date: result.date,
                    saveFolder: folder
                ) {
                    Logger.log("StatusBar", "Meeting summary exported: \(summaryURL.lastPathComponent)")
                }
            } else {
                Logger.log("StatusBar", "Summarization skipped/failed (server unreachable?)")
            }
        }

        // 5. 可选：转录+摘要写完后删除音频（含 .mic.wav / .system.wav 兄弟文件）。
        let autoDelete = config.meetingConfig["auto_delete_audio"] as? Bool ?? false
        if autoDelete, let audioPath = result.audioPath {
            deleteAudioFiles(mainPath: audioPath)
        }
    }

    /// 删除会议音频主文件及其 .mic.wav / .system.wav 兄弟文件。
    private func deleteAudioFiles(mainPath: String) {
        let fm = FileManager.default
        let mainURL = URL(fileURLWithPath: mainPath)
        let base = mainURL.deletingPathExtension()   // 去掉 .wav
        let candidates = [
            mainURL,
            base.appendingPathExtension("mic.wav"),
            base.appendingPathExtension("system.wav"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                Logger.log("StatusBar", "Deleted audio \(url.lastPathComponent)")
            } catch {
                Logger.log("StatusBar", "Audio delete failed for \(url.lastPathComponent): \(error)")
            }
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

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 权限状态行

    /// 给菜单加一行权限状态。granted=true 时不可点击（信息行）；
    /// granted=false 时变红，点击跳系统设置对应页面。
    private func addPermissionRow(to menu: NSMenu, label: String, granted: Bool, selector: Selector) {
        let icon = granted ? "✓" : "⚠"
        let statusText = granted
            ? t("Authorized")
            : t("Not authorized — click to open Settings")
        let item = NSMenuItem(
            title: "\(icon) \(t("\(label): \(statusText)"))",
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
