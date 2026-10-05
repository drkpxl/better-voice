// Small, self-applying Settings controls (no Save/Cancel draft).
import ServiceManagement
import SwiftUI

/// "Open at Login" via `SMAppService.mainApp` — the app registers itself as a login item, which
/// shows up (and can be turned off) under System Settings › General › Login Items.
///
/// Applies immediately rather than on Settings' Save: it's a system registration, not a stored
/// preference, and the status is re-read from the service so the toggle can never disagree with
/// what macOS actually has.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorText: String?

    var body: some View {
        Toggle(isOn: Binding(get: { status == .enabled }, set: set)) {
            Text(t("Open at login"))
        }
        if status == .requiresApproval {
            HStack {
                Text(t("macOS needs your approval in Login Items."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("Open Login Items…")) { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            Logger.log("App", "Login item \(enabled ? "register" : "unregister") failed: \(error)")
            errorText = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}

/// A Settings toggle for a top-level Boolean preference that applies the moment it's flipped,
/// independent of the Settings window's Save/Cancel draft.
struct ImmediateToggle: View {
    let title: String
    let key: String
    @State private var isOn: Bool

    init(_ title: String, key: String, default defaultValue: Bool) {
        self.title = title
        self.key = key
        _isOn = State(initialValue: RuntimeConfig.shared.bool(key, default: defaultValue))
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .onChange(of: isOn) { _, newValue in
                RuntimeConfig.shared.updateTopLevel(key, newValue)
            }
    }
}

/// The speech-language picker. Applies immediately (it changes how the next dictation is
/// transcribed, not a draft the Save button should hold).
struct SpeechLanguagePicker: View {
    @State private var code = RuntimeConfig.shared.speechLanguage ?? ""

    var body: some View {
        Picker(selection: $code) {
            Text(t("Automatic")).tag("")
            Divider()
            ForEach(ParakeetTranscriber.supportedLanguages, id: \.code) { lang in
                Text(lang.name).tag(lang.code)
            }
        } label: {
            Text(t("Speech language"))
        }
        .onChange(of: code) { _, newValue in
            RuntimeConfig.shared.updateTopLevel("speech_language", newValue.isEmpty ? nil : newValue)
        }
        Text(t("Better Voice recognizes most European languages. Automatic works for most people; pick your language if short dictations come out in the wrong alphabet. Filler-word removal only runs for English."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
