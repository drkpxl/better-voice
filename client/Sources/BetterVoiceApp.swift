import AppKit
import SwiftUI
import BetterVoiceCore

@main
struct BetterVoiceApp {
    static func main() {
        // contextualStrings capacity test
        if CommandLine.arguments.contains("--test-context-capacity") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await ContextCapacityTest.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // alternatives test: BetterVoice --test-alternatives <wav-file>
        if CommandLine.arguments.contains("--test-alternatives") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await AlternativesTest.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // truncation test: BetterVoice --test-truncation <wav-file> [--locale zh-CN]
        if CommandLine.arguments.contains("--test-truncation") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await TruncationTest.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // evaluation mode: BetterVoice --bench-meeting <wav-file> [--locale zh-CN] [--output result.json]
        if CommandLine.arguments.contains("--bench-meeting") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await MeetingBenchmark.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // live recording evaluation: BetterVoice --bench-voice <wav> [--locale zh-CN] [--output result.json]
        // Runs the full ContextEnhancer + SA + L2 polish pipeline (from the user's perspective), but does not inject at the cursor or write history
        if CommandLine.arguments.contains("--bench-voice") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await VoiceBenchmark.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar app, no Dock icon
        app.run()
    }
}

/// Meeting mode evaluation entry point
/// Usage: BetterVoice --bench-meeting <wav> [--locale zh-CN] [--output result.json]
///   or: BetterVoice --bench-meeting --batch <manifest.jsonl> [--output-dir results/]
enum MeetingBenchmark {
    @MainActor
    static func run() async {
        BetterVoiceDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let benchIdx = args.firstIndex(of: "--bench-meeting"), benchIdx + 1 < args.count else {
            print("Usage: BetterVoice --bench-meeting <wav-file> [--locale zh-CN] [--output result.json]")
            print("       BetterVoice --bench-meeting --batch <manifest.jsonl> [--output-dir results/]")
            return
        }

        let locale = parseArg(args, key: "--locale") ?? "zh-CN"

        if args.contains("--batch") {
            guard let manifest = parseArg(args, key: "--batch") else {
                print("Error: --batch requires manifest file path")
                return
            }
            let outputDir = parseArg(args, key: "--output-dir") ?? "bench-results"
            await runBatch(manifest: manifest, outputDir: outputDir, locale: locale)
        } else {
            let wavPath = args[benchIdx + 1]
            let output = parseArg(args, key: "--output")
            await runSingle(wavPath: wavPath, locale: locale, outputPath: output)
        }
    }

    @MainActor
    static func runSingle(wavPath: String, locale: String, outputPath: String?) async {
        let fileURL = URL(fileURLWithPath: wavPath)
        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            return
        }

        print("Audio: \(wavPath)")
        print("Locale: \(locale)")

        let session = MeetingSession()
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = await session.runFromFile(fileURL, locale: locale)
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime

        // export Markdown (via our MeetingExporter)
        let mdURL = MeetingExporter.exportMarkdown(
            segments: result.segments,
            duration: result.duration
        )

        // build evaluation JSON
        let json = formatResult(result, totalTime: totalTime, mdPath: mdURL?.path)

        if let outputPath {
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: outputPath))
            print("Result: \(outputPath)")
        } else {
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        }

        if let md = mdURL {
            print("Markdown: \(md.path)")
        }
    }

    @MainActor
    static func runBatch(manifest: String, outputDir: String, locale: String) async {
        guard let content = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            print("Error: cannot read \(manifest)")
            return
        }

        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        print("Manifest: \(manifest) (\(lines.count) files)")
        print("Output: \(outputDir)/\n")

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioPath = entry["audio"] as? String else {
                print("[\(i+1)/\(lines.count)] SKIP: invalid line")
                continue
            }

            let id = entry["id"] as? String ?? URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
            let entryLocale = entry["locale"] as? String ?? locale

            print("[\(i+1)/\(lines.count)] \(id) ...", terminator: " ")
            fflush(stdout)

            let fileURL = URL(fileURLWithPath: audioPath)
            let session = MeetingSession()
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = await session.runFromFile(fileURL, locale: entryLocale)
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime

            // export Markdown
            let mdURL = MeetingExporter.exportMarkdown(
                segments: result.segments,
                duration: result.duration
            )

            // save JSON
            let json = formatResult(result, totalTime: totalTime, mdPath: mdURL?.path)
            let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let outPath = "\(outputDir)/\(id).json"
            try? jsonData?.write(to: URL(fileURLWithPath: outPath))

            let rtfx = result.duration / totalTime
            print("OK \(String(format: "%.1f", result.duration))s RTFx=\(String(format: "%.1f", rtfx)) segs=\(result.segments.count)")
        }
    }

    static func formatResult(_ result: MeetingResult, totalTime: Double, mdPath: String?) -> [String: Any] {
        var json: [String: Any] = [
            "audio": result.audioPath ?? "",
            "duration_s": round(result.duration * 100) / 100,
            "total_processing_s": round(totalTime * 100) / 100,
            "rtfx": round(result.duration / max(totalTime, 0.01) * 10) / 10,
            "n_segments": result.segments.count,
            "n_speakers": Set(result.segments.compactMap { $0.speakerId }).count,
            "markdown_path": mdPath ?? "",
            // full transcript text (for WER/CER comparison)
            "hypothesis": result.segments.map { $0.text }.joined(),
            "segments": result.segments.map { seg in
                [
                    "text": seg.text,
                    "start": round(seg.startTime * 100) / 100,
                    "end": round(seg.endTime * 100) / 100,
                    "speaker": seg.speakerId ?? ""
                ] as [String: Any]
            }
        ]
        // DER-proxy scores against the optional <wav>.speakers.json ground-truth sidecar.
        if let score = benchDiarizationScore(segments: result.segments, audioPath: result.audioPath) {
            json["der_proxy_fer"] = round(score.frameErrorRate * 1000) / 1000
            json["der_proxy_sc_err"] = score.speakerCountError
        }
        return json
    }

    /// Loads the optional `<wav>.speakers.json` diarization ground-truth sidecar next to `audioPath`
    /// (a JSON array of `{"speaker","start","end"}`) and scores the produced segments against it with
    /// the lightweight DER proxy. Returns nil when no valid sidecar exists so scoring is skipped silently.
    static func benchDiarizationScore(segments: [MeetingSegment], audioPath: String?) -> DiarizationScore? {
        guard let audioPath else { return nil }
        let sidecar = audioPath + ".speakers.json"
        guard let data = FileManager.default.contents(atPath: sidecar) else { return nil }
        let hypothesis = segments.map {
            LabeledInterval(speaker: $0.speakerId ?? "?", start: $0.startTime, end: $0.endTime)
        }
        return scoreDiarizationAgainstSidecar(hypothesis: hypothesis, sidecarJSONData: data)
    }

    static func parseArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private let moduleManager = ModuleManager()
    private let config = RuntimeConfig.shared
    private let recordingIndicator = RecordingIndicator.shared
    private let remoteInbox = RemoteInbox()
    private var updater: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // initialize data directory
        BetterVoiceDataDir.ensureExists()

        // First-launch onboarding: when the user hasn't completed onboarding, the welcome
        // window requests permissions inline, so skip the eager prompts here to avoid stacking
        // system dialogs behind it. Otherwise prompt as usual.
        let needsOnboarding = config.onboardingVersion < WelcomeWindow.currentOnboardingVersion
        if needsOnboarding {
            Logger.log("App", "First launch — showing onboarding (permissions requested there)")
        } else {
            // check permissions (system-audio is requested on demand when a meeting starts, not eagerly)
            let axOK = PermissionManager.checkAccessibility()
            // Input Monitoring is the permission actually needed for CGEventTap to listen for the global hotkey (not Accessibility)
            let inputOK = PermissionManager.checkInputMonitoring()
            Logger.log("App", "Accessibility: \(axOK), Input Monitoring: \(inputOK)")
        }

        // initialize the menu bar
        statusBar = StatusBarController(moduleManager: moduleManager)

        // start the Sparkle updater; refresh the menu when an update is found/cleared
        let updater = UpdaterController.shared
        updater.onUpdateStateChange = { [weak self] in self?.statusBar?.refreshMenu() }
        self.updater = updater

        // register the voice module
        let voiceModule = VoiceModule()
        voiceModule.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusBar?.setRecording(state == .recording)
            self.statusBar?.setProcessing(state == .processing)
            switch state {
            case .recording:
                self.recordingIndicator.show()
                DictationSound.playStart()
            case .processing:
                // First non-recording state after a real recording — play the
                // stop cue here (not on .idle) so it fires exactly once.
                self.recordingIndicator.hide()
                DictationSound.playStop()
            case .idle:
                self.recordingIndicator.hide()
            }
        }
        voiceModule.onAudioLevel = { [weak self] level in
            self?.recordingIndicator.update(level: level)
        }
        moduleManager.register(voiceModule)

        // register the global hotkey
        GlobalHotKey.shared.onPress = { [weak self] in
            guard let self else { return }
            // Don't let the hotkey start a dictation on top of a meeting wrap-up that's
            // still summarizing (a long transcription in progress). Dictation-vs-dictation
            // is already gated inside VoiceModule by its .processing state.
            if self.statusBar?.isBusy == true {
                Logger.log("Hotkey", "Ignored: processing in progress")
                return
            }
            self.moduleManager.activeModule?.onHotKeyDown()
        }
        GlobalHotKey.shared.onRelease = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyUp()
        }
        GlobalHotKey.shared.start()

        // start model server health checks
        ModelServer.shared.startHealthCheck()

        // start the remote voice inbox
        let remoteConfig = config.remoteConfig
        if remoteConfig["enabled"] as? Bool == true {
            let port = remoteConfig["port"] as? Int ?? 9800
            let token = remoteConfig["auth_token"] as? String ?? ""
            remoteInbox.onStatusChange = { [weak self] status in
                self?.statusBar?.setRemoteStatus(status)
            }
            remoteInbox.start(port: UInt16(port), authToken: token)
            Logger.log("App", "Remote inbox: ON (:\(port))")
        }

        // G1 ambient mode (toggled via config)
        if config.ambientEnabled {
            let ambient = AmbientController.shared
            ambient.onSpeechStart = { [weak self] in
                guard let self,
                      self.statusBar?.isBusy != true,
                      let vm = self.moduleManager.activeModule as? VoiceModule,
                      vm.state == .idle else { return }
                vm.onHotKeyDown()  // reuse the hotkey flow: start recording
            }
            ambient.onSpeechEnd = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .recording else { return }
                vm.onHotKeyDown()  // reuse the hotkey flow: stop and process
            }
            ambient.start()
            Logger.log("App", "Ambient mode: ON")
        }

        Logger.log("App", "App launched, modules: \(moduleManager.moduleNames)")
        Logger.log("App", "Server endpoint: \(config.serverConfig["endpoint"] as? String ?? "not set")")

        // first-launch welcome screen (after the rest of the app is initialized)
        if needsOnboarding {
            WelcomeWindow.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.stop()
        AmbientController.shared.stop()
        ModelServer.shared.stopHealthCheck()
        remoteInbox.stop()
        Logger.log("App", "App terminated")
    }
}
