import AppKit
import SwiftUI

/// Hotkey recorder root, shown by the `Window(id: WindowID.hotkey)` scene (scenes migration,
/// roadmap §9). A fresh view model per appearance, seeded from the on-disk config — same as
/// the old per-`show()` singleton. Hosts BOTH bindings (dictation + meeting), see
/// `HotKeySettingsViewModel`.
struct HotKeyRootView: View {
    @State private var viewModel: HotKeySettingsViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let viewModel {
                HotKeySettingsContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .frame(width: 420, height: 420)
        .onAppear {
            let vm = HotKeySettingsViewModel(
                dictation: HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig),
                meeting: HotKeyConfig.load(from: RuntimeConfig.shared.meetingHotKeyConfig, fallback: .meetingDefault)
            )
            vm.onSave = { dictation, meeting in
                // Save both to config + hot-reload both bindings on GlobalHotKey.
                RuntimeConfig.shared.updateHotKeyConfig(dictation.toDictionary())
                RuntimeConfig.shared.updateMeetingHotKeyConfig(meeting.toDictionary())
                GlobalHotKey.shared.reload(config: dictation)
                GlobalHotKey.shared.reloadMeeting(config: meeting)
                Logger.log("HotKey", "User saved hotkeys: dictation=\(dictation.displayName), meeting=\(meeting.displayName)")
                dismiss()
            }
            vm.onCancel = { dismiss() }
            viewModel = vm
        }
        .onDisappear { viewModel = nil }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class HotKeySettingsViewModel {
    var dictationCurrent: HotKeyConfig
    var dictationCaptured: HotKeyConfig?
    var dictationConflictWarning: String?

    var meetingCurrent: HotKeyConfig
    var meetingCaptured: HotKeyConfig?
    var meetingConflictWarning: String?

    var onSave: ((_ dictation: HotKeyConfig, _ meeting: HotKeyConfig) -> Void)?
    var onCancel: (() -> Void)?

    init(dictation: HotKeyConfig, meeting: HotKeyConfig) {
        self.dictationCurrent = dictation
        self.meetingCurrent = meeting
    }

    /// The value that would actually be saved for each binding right now (captured if the user
    /// re-recorded it this session, else whatever was already on disk).
    private var effectiveDictation: HotKeyConfig { dictationCaptured ?? dictationCurrent }
    private var effectiveMeeting: HotKeyConfig { meetingCaptured ?? meetingCurrent }

    /// Disabled when neither binding actually changed, OR when both bindings now resolve to the
    /// SAME key+modifiers — saving that would make the two hotkeys indistinguishable (whichever
    /// callback the tap dispatches to first would always win), so it's blocked rather than saved
    /// silently ambiguous.
    var saveDisabled: Bool {
        let dictationUnchanged = dictationCaptured == nil || dictationCaptured == dictationCurrent
        let meetingUnchanged = meetingCaptured == nil || meetingCaptured == meetingCurrent
        if dictationUnchanged && meetingUnchanged { return true }
        return effectiveDictation == effectiveMeeting
    }

    func updateDictationCaptured(_ config: HotKeyConfig) {
        dictationCaptured = config
        refreshConflictWarnings()
    }

    func updateMeetingCaptured(_ config: HotKeyConfig) {
        meetingCaptured = config
        refreshConflictWarnings()
    }

    private func refreshConflictWarnings() {
        let dictation = effectiveDictation
        let meeting = effectiveMeeting

        dictationConflictWarning = HotKeyConflictChecker.isConflicting(dictation)
            ? t("This shortcut may conflict with system shortcuts.") : nil
        meetingConflictWarning = HotKeyConflictChecker.isConflicting(meeting)
            ? t("This shortcut may conflict with system shortcuts.") : nil

        // Same-binding conflict between Better Voice's own two hotkeys takes priority over (and
        // overrides) either system-shortcut warning above — it's the one that blocks Save.
        if dictation == meeting {
            let sameWarning = t("Dictation and Meeting can't use the same hotkey.")
            dictationConflictWarning = sameWarning
            meetingConflictWarning = sameWarning
        }
    }

    func save() {
        onSave?(effectiveDictation, effectiveMeeting)
    }

    func cancel() {
        onCancel?()
    }
}

// MARK: - SwiftUI View

struct HotKeySettingsContentView: View {
    @Bindable var viewModel: HotKeySettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hotkeySection(
                title: t("Dictation Hotkey"),
                current: viewModel.dictationCaptured ?? viewModel.dictationCurrent,
                warning: viewModel.dictationConflictWarning,
                onCapture: { viewModel.updateDictationCaptured($0) }
            )

            Divider()

            hotkeySection(
                title: t("Meeting Hotkey"),
                current: viewModel.meetingCaptured ?? viewModel.meetingCurrent,
                warning: viewModel.meetingConflictWarning,
                onCapture: { viewModel.updateMeetingCaptured($0) }
            )

            Text(t("Click a button, then press your desired hotkey. It can be a single modifier (like Right Option) or a combination (like ⌥+.). Press Esc to cancel."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button(t("Cancel")) { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(t("Save")) { viewModel.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.saveDisabled)
            }
        }
        .padding(20)
        .tint(Color.brandAccent)
    }

    @ViewBuilder
    private func hotkeySection(
        title: String,
        current: HotKeyConfig,
        warning: String?,
        onCapture: @escaping (HotKeyConfig) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            HotKeyRecorderView(current: current, onCapture: onCapture)

            if let warning {
                HStack(alignment: .top, spacing: 6) {
                    Text("⚠️")
                    Text(warning)
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }
}

// MARK: - HotKeyRecorder (recording control)

struct HotKeyRecorderView: View {
    let current: HotKeyConfig
    let onCapture: (HotKeyConfig) -> Void

    @State private var isRecording: Bool = false
    @State private var pressedFlags: NSEvent.ModifierFlags = []
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(buttonLabel)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isRecording
                              ? Color.red.opacity(0.18)
                              : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isRecording ? Color.red.opacity(0.6) : Color.gray.opacity(0.3),
                                lineWidth: isRecording ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitor() }
    }

    private var buttonLabel: String {
        isRecording ? t("Press hotkey... (Esc to cancel)") : current.displayName
    }

    private func toggleRecording() {
        if isRecording { stopMonitor() }
        else { startMonitor() }
    }

    private func startMonitor() {
        isRecording = true
        pressedFlags = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
            return nil  // Block the event from being passed to the app
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        isRecording = false
        pressedFlags = []
    }

    private func handleEvent(_ event: NSEvent) {
        // Esc exits recording (not captured)
        if event.type == .keyDown && event.keyCode == 53 {
            stopMonitor()
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.type == .keyDown {
            // Combination key (or a plain letter key — not recommended, but still accepted; it's the user's choice)
            let cfg = HotKeyConfig(
                keyCode: event.keyCode,
                modifierFlags: mods.rawValue,
                isModifierOnly: false,
                displayName: HotKeyFormatter.displayName(
                    keyCode: event.keyCode,
                    modifiers: mods,
                    isModifierOnly: false
                )
            )
            onCapture(cfg)
            stopMonitor()
        } else if event.type == .flagsChanged {
            // Detect modifier-only: if some modifiers are pressed and then all released, treat it as modifier-only
            let newMods = mods
            if newMods.isEmpty && !pressedFlags.isEmpty {
                // All released. Capture the keyCode from the most recent flagsChanged event as the modifier key
                let cfg = HotKeyConfig(
                    keyCode: event.keyCode,
                    modifierFlags: 0,
                    isModifierOnly: true,
                    displayName: HotKeyFormatter.displayName(
                        keyCode: event.keyCode,
                        modifiers: [],
                        isModifierOnly: true
                    )
                )
                onCapture(cfg)
                stopMonitor()
            } else {
                pressedFlags = newMods
            }
        }
    }
}
