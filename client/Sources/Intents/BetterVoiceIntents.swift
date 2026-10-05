import AppIntents
import Foundation

// Shortcuts / Spotlight / Siri actions. Each one drives the same objects the menu bar and hotkeys
// do (via `AppDelegate.shared`), so behaviour is identical whichever way it's triggered.

struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription("Starts dictating, or stops and inserts the text at your cursor.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.voiceModule.toggle()
        return .result()
    }
}

struct StartMeetingRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Meeting Recording"
    static let description = IntentDescription("Records your microphone and this Mac's audio until you stop it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let coordinator = AppDelegate.shared?.meetingCoordinator, coordinator.canStart else { return .result() }
        coordinator.startMeeting()
        return .result()
    }
}

struct StopMeetingRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Meeting Recording"
    static let description = IntentDescription("Stops the meeting recording and starts transcribing it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let coordinator = AppDelegate.shared?.meetingCoordinator, coordinator.canStop else { return .result() }
        coordinator.stopMeeting()
        return .result()
    }
}

struct ImportMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Meeting Recording"
    static let description = IntentDescription("Opens a recording in Better Voice to transcribe, name the speakers, summarize, and save to Apple Notes.")
    static let openAppWhenRun = true

    @Parameter(title: "Recording", supportedContentTypes: [.audio])
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = try IntentFiles.materialize(file)
        WindowRouter.shared.open(id: WindowID.main)
        ImportLauncher.shared.requestNew(file: url)
        return .result()
    }
}

struct TranscribeAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio"
    static let description = IntentDescription("Transcribes an audio file on this Mac and returns the text. Nothing is saved.")

    @Parameter(title: "Audio", supportedContentTypes: [.audio])
    var file: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = try IntentFiles.materialize(file)
        defer { try? FileManager.default.removeItem(at: url) }
        let locale = await RuntimeConfig.shared.speechLocale
        let transcript = try await ParakeetTranscriber.shared.transcribe(fileURL: url, locale: locale)
        return .result(value: transcript.text)
    }
}

struct GetLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Dictation"
    static let description = IntentDescription("Returns the text of your most recent dictation.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: VoiceHistory.shared.recent.first?.finalText ?? "")
    }
}

struct BetterVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: ["Dictate with \(.applicationName)", "Toggle \(.applicationName) dictation"],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: StartMeetingRecordingIntent(),
            phrases: ["Start a meeting recording in \(.applicationName)", "Record a meeting with \(.applicationName)"],
            shortTitle: "Record Meeting",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopMeetingRecordingIntent(),
            phrases: ["Stop the meeting recording in \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: GetLastDictationIntent(),
            phrases: ["Get my last \(.applicationName) dictation"],
            shortTitle: "Last Dictation",
            systemImageName: "text.quote"
        )
    }
}

/// Shortcuts hands files over as data; the engine and the import wizard want a file on disk.
enum IntentFiles {
    static func materialize(_ file: IntentFile) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bettervoice-intents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = file.filename.isEmpty ? "audio.m4a" : file.filename
        let url = dir.appendingPathComponent(UUID().uuidString + "-" + name)
        try file.data.write(to: url)
        return url
    }
}
