import AppKit
import SwiftUI

/// Hotkey settings window
///
/// Embeds SwiftUI using NSWindow + NSHostingView. Same hybrid stack as TranscriptPanel.
@MainActor
final class HotKeySettingsWindow {
    static let shared = HotKeySettingsWindow()

    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let initialConfig = HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig)
        let viewModel = HotKeySettingsViewModel(current: initialConfig)
        viewModel.onSave = { [weak self] newConfig in
            // Save to config + reload GlobalHotKey
            RuntimeConfig.shared.updateHotKeyConfig(newConfig.toDictionary())
            GlobalHotKey.shared.reload(config: newConfig)
            Logger.log("HotKey", "User saved hotkey: \(newConfig.displayName)")
            self?.close()
        }
        viewModel.onCancel = { [weak self] in
            self?.close()
        }

        let host = NSHostingView(rootView: HotKeySettingsContentView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 240)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = t("WE Set Hotkey")
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class HotKeySettingsViewModel {
    var current: HotKeyConfig
    var captured: HotKeyConfig?
    var conflictWarning: String?

    var onSave: ((HotKeyConfig) -> Void)?
    var onCancel: (() -> Void)?

    init(current: HotKeyConfig) {
        self.current = current
    }

    var saveDisabled: Bool {
        captured == nil || captured == current
    }

    func updateCaptured(_ config: HotKeyConfig) {
        captured = config
        if HotKeyConflictChecker.isConflicting(config) {
            conflictWarning = t("This shortcut may conflict with system shortcuts.")
        } else {
            conflictWarning = nil
        }
    }

    func save() {
        guard let c = captured else { return }
        onSave?(c)
    }

    func cancel() {
        onCancel?()
    }
}

// MARK: - SwiftUI View

struct HotKeySettingsContentView: View {
    @Bindable var viewModel: HotKeySettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Record / Stop Hotkey"))
                .font(.headline)

            HotKeyRecorderView(
                current: viewModel.captured ?? viewModel.current,
                onCapture: { config in
                    viewModel.updateCaptured(config)
                }
            )

            if let w = viewModel.conflictWarning {
                HStack(alignment: .top, spacing: 6) {
                    Text("⚠️")
                    Text(w)
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Text(t("Click the button, then press your desired hotkey. It can be a single modifier (like Right Option) or a combination (like ⌘+⇧+R). Press Esc to cancel."))
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
