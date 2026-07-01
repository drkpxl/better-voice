import AppKit
import BetterVoiceCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let voiceModule: VoiceModule
    private let config = RuntimeConfig.shared

    private var isRecording = false
    private var isProcessing = false   // dictation is transcribing/polishing (VoiceModule .processing)

    // meeting mode
    private var meetingSession: MeetingSession?
    private var isMeetingActive: Bool { meetingSession?.isRunning ?? false }
    /// True from when the meeting stops until the wrap-up flow (classification/naming panel/export/summary) finishes; starting a new meeting is blocked during that window.
    private var isFinishingMeeting = false

    init(voiceModule: VoiceModule) {
        self.voiceModule = voiceModule
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

    /// Public entry to rebuild the menu (e.g. when the updater finds a new version).
    func refreshMenu() { setupMenu() }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        updateIcon()
    }

    /// Dictation is transcribing/polishing. Drives the menu-bar "processing" glyph so the
    /// user sees the app is busy (and knows why the hotkey is inert).
    func setProcessing(_ processing: Bool) {
        isProcessing = processing
        updateIcon()
    }

    /// True while a meeting's wrap-up (classification/naming/summary) is running. The hotkey
    /// path checks this to avoid starting a dictation on top of an in-progress transcription.
    var isBusy: Bool { isFinishingMeeting || isProcessing }

    /// Status-bar glyph: the brand's 5-bar waveform as a template icon (auto-tints for
    /// light/dark menu bars) plus a trailing state badge.
    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let icon = NSImage.menuBarWaveform()
        icon.accessibilityDescription = t("Better Voice")
        button.image = icon
        button.imagePosition = .imageLeading

        // Priority: meeting recording > dictation recording > busy (processing/wrap-up) > connection.
        if isMeetingActive {
            button.title = "◉"
            button.contentTintColor = .systemOrange
            return
        }
        if isRecording {
            button.title = "●"
            button.contentTintColor = .systemRed
            return
        }
        if isBusy {
            button.title = "⋯"
            button.contentTintColor = .systemGray
            return
        }

        button.contentTintColor = nil
        switch ModelServer.shared.status {
        case .connected:
            button.title = ""
        case .disconnected:
            button.title = "·"
        case .unknown:
            button.title = "?"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: t("Better Voice"), action: nil, keyEquivalent: ""))
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
            label: t("System audio recording (meetings)"),
            granted: PermissionManager.isSystemAudioGranted(),
            selector: #selector(openSystemAudioSettings)
        )

        menu.addItem(NSMenuItem.separator())

        // meeting mode
        if isMeetingActive {
            let stopMeeting = NSMenuItem(
                title: t("Stop Meeting"),
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            // Display hint for the Right Option+M global hotkey (menus can't show left/right).
            stopMeeting.keyEquivalentModifierMask = [.option]
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
            // Display hint for the Right Option+M global hotkey (menus can't show left/right).
            startMeeting.keyEquivalentModifierMask = [.option]
            startMeeting.target = self
            menu.addItem(startMeeting)
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

        let welcomeItem = NSMenuItem(
            title: t("Welcome / Setup Guide"),
            action: #selector(openWelcome),
            keyEquivalent: ""
        )
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        // updates: a highlighted "Update to X…" row appears when Sparkle has found a new version;
        // a manual "Check for Updates…" is always available.
        if let version = UpdaterController.shared.availableUpdateVersion {
            let updateItem = NSMenuItem(
                title: t("Update to \(version) — Restart to update"),
                action: #selector(showUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            let attr = NSMutableAttributedString(string: updateItem.title)
            attr.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: 0, length: attr.length))
            updateItem.attributedTitle = attr
            menu.addItem(updateItem)
        }
        let checkUpdatesItem = NSMenuItem(
            title: t("Check for Updates..."),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: t("Quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc func toggleMeeting() {
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
        // ...nor while a dictation is still recording or transcribing (don't record on top of it).
        if voiceModule.state != .idle {
            Logger.log("StatusBar", "Ignored start: dictation in progress")
            return
        }
        let session = MeetingSession()
        self.meetingSession = session

        // Same floating waveform HUD as dictation, driven by the mic level (see RecordingIndicator.shared).
        session.onAudioLevel = { level in
            RecordingIndicator.shared.update(level: level)
        }

        Task {
            do {
                try await session.start()
                Logger.log("StatusBar", "Meeting started")
                RecordingIndicator.shared.show()
                self.setupMenu()
                self.updateIcon()
            } catch {
                Logger.log("StatusBar", "Meeting start failed: \(error)")
                RecordingIndicator.shared.hide()
                self.meetingSession = nil
            }
        }
    }

    private func stopMeeting() {
        guard let session = meetingSession else { return }
        RecordingIndicator.shared.hide()

        Task {
            let result = await session.stop()
            self.meetingSession = nil

            if !result.segments.isEmpty {
                // Durability: write the transcript to disk the instant recording stops, before the
                // (blocking) wrap-up naming panel. finishMeeting re-exports over the same file with
                // names applied. If the app dies while the panel is open, the transcript survives.
                _ = MeetingExporter.exportMarkdown(
                    segments: result.segments,
                    duration: result.duration,
                    date: result.date,
                    saveFolder: MeetingExporter.configuredFolder()
                )
            }

            // entering wrap-up: starting a new meeting is blocked until the summary flow finishes.
            self.isFinishingMeeting = true
            self.setupMenu()
            self.updateIcon()
            Logger.log("StatusBar", "Meeting stopped, \(result.segments.count) segments, \(String(format: "%.0f", result.duration))s")

            // wrap-up: classify -> naming/type panel -> export transcript -> summarize -> optionally delete audio.
            await self.finishMeeting(result: result)

            self.isFinishingMeeting = false
            self.setupMenu()
            self.updateIcon()
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
        let rawTranscript = buildSummarizationTranscript(segments: result.segments, speakerPrefix: prefix, localLabel: t("You"))
        let inferred: MeetingType
        if client.classifyEnabled, !rawTranscript.isEmpty {
            inferred = await client.classifyType(transcript: rawTranscript)
        } else {
            inferred = client.defaultType
        }

        // 2. wrap-up panel (waits for the user: naming + type selection; Skip still triggers summarization).
        // Exclude the local user ("You") from the naming list: their segments already
        // render as "You" via resolveSpeakerLabel, so prompting to name themselves is redundant.
        let speakerIds = orderedUniqueSpeakerIds(result.segments).filter { $0 != SpeakerIds.local }
        let quotes = sampleQuotes(result.segments)
        let speakers = speakerIds.map { (id: $0, quotes: quotes[$0] ?? []) }
        let outcome = await MeetingWrapUpWindow.shared.present(speakers: speakers, inferredType: inferred)

        // 3. apply names, export transcript.
        let named = applySpeakerNames(outcome.names, to: result.segments)
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
        // Track success so we never delete the audio (step 5) when a summary was expected but failed.
        var summaryProduced = false
        if client.summarizationEnabled {
            let namedTranscript = buildSummarizationTranscript(segments: named, speakerPrefix: prefix, localLabel: t("You"))
            let summary = await client.summarize(transcript: namedTranscript, type: outcome.type)
            // An empty/whitespace result is a failure, not a summary: local models sometimes return ""
            // (reasoning ate the num_predict budget, or the transcript was garbled). Never write a blank
            // file or mark it produced — that would also green-light auto-deleting the audio (step 5).
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summaryProduced = true
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
                // Surface the failure: the transcript is saved, but the user must know the summary
                // didn't run (server down/timeout) — and step 5 must not delete the audio.
                Notify.warn(
                    t("Summary failed"),
                    t("The meeting transcript was saved, but the summary couldn't be generated (model server unreachable?). Your audio is kept so you can retry.")
                )
            }
        }

        // 5. optional: delete audio after the transcript+summary have been written (including the
        // .mic.wav / .system.wav sibling files). Only delete when a summary wasn't expected, or one
        // was actually produced — otherwise we'd destroy the only chance to re-summarize.
        let autoDelete = config.meetingConfig["auto_delete_audio"] as? Bool ?? false
        let summaryOK = !client.summarizationEnabled || summaryProduced
        if autoDelete, summaryOK, let audioPath = result.audioPath {
            deleteAudioFiles(mainPath: audioPath)
        } else if autoDelete, !summaryOK {
            Logger.log("StatusBar", "Keeping audio: summary expected but not produced")
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

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func openWelcome() {
        WelcomeWindow.shared.show()
    }

    @objc private func showUpdate() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
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
        PermissionManager.openSettings(for: .inputMonitoring)
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.openSettings(for: .accessibility)
    }

    @objc private func openMicrophoneSettings() {
        PermissionManager.openSettings(for: .microphone)
    }

    @objc private func openSystemAudioSettings() {
        PermissionManager.openSettings(for: .systemAudio)
    }
}
