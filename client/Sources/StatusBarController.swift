import AppKit
import WECore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let moduleManager: ModuleManager
    private let config = RuntimeConfig.shared

    private var isRecording = false
    private var remoteStatus: RemoteInbox.Status = .idle

    // meeting mode
    private var meetingSession: MeetingSession?
    private let transcriptPanel = TranscriptPanelController()
    private var isMeetingActive: Bool { meetingSession?.isRunning ?? false }
    /// True from when the meeting stops until the wrap-up flow (classification/naming panel/export/summary) finishes; starting a new meeting is blocked during that window.
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

    /// Refresh permission status live when the user opens the menu (since after granting access in System Settings and returning, we want to show a checkmark)
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

        // permission status rows: shows the 4 items directly from the user's perspective, plus a click to jump to System Settings
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

        // meeting mode
        if isMeetingActive {
            let stopMeeting = NSMenuItem(
                title: t("Stop Meeting"),
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            stopMeeting.target = self
            menu.addItem(stopMeeting)
        } else if isFinishingMeeting {
            // wrapping up: placeholder item, starting a new meeting is blocked until the summary flow finishes.
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

        // remote voice
        if remoteStatus != .idle {
            menu.addItem(NSMenuItem.separator())
            let port = RuntimeConfig.shared.remoteConfig["port"] as? Int ?? 9800
            let remoteItem = NSMenuItem(title: t("Remote voice: \(remoteStatus.displayName) (:\(String(port)))"), action: nil, keyEquivalent: "")
            menu.addItem(remoteItem)
        }

        menu.addItem(NSMenuItem.separator())

        // settings (server/summarization/meeting/hotkeys/data are all collected in the settings window)
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
        // starting a new meeting is not allowed while the previous meeting's wrap-up flow (naming/summary) hasn't finished.
        guard !isFinishingMeeting else {
            Logger.log("StatusBar", "Ignored start: previous meeting still finishing")
            return
        }
        let session = MeetingSession()
        self.meetingSession = session

        // live transcription callback -> update panel
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

        // show the transcript panel
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

            // update the panel to show the final result (with speaker labels)
            if !result.segments.isEmpty {
                self.transcriptPanel.updateTranscript(segments: result.segments)
            }

            // entering wrap-up: starting a new meeting is blocked until the summary flow finishes.
            self.isFinishingMeeting = true
            self.setupMenu()
            self.updateMeetingIcon()
            Logger.log("StatusBar", "Meeting stopped, \(result.segments.count) segments, \(String(format: "%.0f", result.duration))s")

            // wrap-up: classify -> naming/type panel -> export transcript -> summarize -> optionally delete audio.
            await self.finishMeeting(result: result)

            self.isFinishingMeeting = false
            self.setupMenu()
            self.updateMeetingIcon()
        }
    }

    /// Meeting wrap-up flow (after diagnostics): pre-select meeting type via classification, speaker naming panel, export transcript and summary, delete audio as needed.
    private func finishMeeting(result: MeetingResult) async {
        guard !result.segments.isEmpty else {
            Logger.log("StatusBar", "Empty meeting, skipping wrap-up/summary")
            return
        }

        let prefix = t("Speaker")
        let client = SummarizationClient.shared

        // 1. use a quick classification pass to pre-select the meeting type.
        let rawTranscript = buildSummarizationTranscript(segments: result.segments, speakerPrefix: prefix)
        let inferred: MeetingType
        if client.classifyEnabled, !rawTranscript.isEmpty {
            inferred = await client.classifyType(transcript: rawTranscript)
        } else {
            inferred = client.defaultType
        }

        // 2. wrap-up panel (waits for the user: naming + type selection; Skip still triggers summarization).
        let speakerIds = orderedUniqueSpeakerIds(result.segments)
        let snippets = sampleSnippets(result.segments, maxLen: 100)
        let speakers = speakerIds.map { (id: $0, snippet: snippets[$0] ?? "") }
        let outcome = await MeetingWrapUpWindow.shared.present(speakers: speakers, inferredType: inferred)

        // 3. apply names, export transcript.
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

        // 4. summarize (selected type, large num_ctx) + write the summary file.
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

        // 5. optional: delete audio after the transcript+summary have been written (including the .mic.wav / .system.wav sibling files).
        let autoDelete = config.meetingConfig["auto_delete_audio"] as? Bool ?? false
        if autoDelete, let audioPath = result.audioPath {
            deleteAudioFiles(mainPath: audioPath)
        }
    }

    /// Delete the main meeting audio file along with its .mic.wav / .system.wav sibling files.
    private func deleteAudioFiles(mainPath: String) {
        let fm = FileManager.default
        let mainURL = URL(fileURLWithPath: mainPath)
        let base = mainURL.deletingPathExtension()   // strip the .wav
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

    // MARK: - Permission status rows

    /// Add a permission status row to the menu. When granted=true it's not clickable (info row);
    /// when granted=false it turns red, and clicking jumps to the corresponding System Settings page.
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
            // red highlight hint
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
