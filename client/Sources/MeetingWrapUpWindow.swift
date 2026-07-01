import AppKit
import SwiftUI
import BetterVoiceCore

/// Meeting wrap-up panel: after speakers are diagnosed and before the summary is generated,
/// lets the user name the speakers and confirm the meeting type.
/// Uses NSWindow + NSHostingView (same approach as HotKeySettingsWindow).
/// `present(...)` uses withCheckedContinuation to bridge a one-shot user input into async.
///
/// Behavior:
/// - "Summarize": returns the entered names + selected type.
/// - "Skip" or closing the window: returns empty names + the (preselected/default) type — a summary is still generated.
@MainActor
final class MeetingWrapUpWindow {
    static let shared = MeetingWrapUpWindow()

    private var window: NSWindow?
    private var closeDelegate: WindowCloseDelegate?

    struct Speaker: Identifiable {
        let id: String       // speakerId (e.g. "1")
        let snippet: String
        var name: String = ""
    }

    struct Outcome {
        let names: [String: String]   // speakerId -> user-entered name
        let type: MeetingType
    }

    /// The currently pending continuation callback. Set when show() is called, cleared on resolve.
    private var pendingCompletion: ((Outcome) -> Void)?

    /// Presents the panel and waits for the user to act.
    func present(speakers: [(id: String, snippet: String)], inferredType: MeetingType) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.show(speakers: speakers, inferredType: inferredType) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    private func show(
        speakers: [(id: String, snippet: String)],
        inferredType: MeetingType,
        completion: @escaping (Outcome) -> Void
    ) {
        // Defensive: if a panel is already pending, close the old window first and resolve
        // its continuation with a skip (so we neither leak the pending await nor leave an orphaned window).
        if let stale = pendingCompletion {
            pendingCompletion = nil
            close()
            stale(Outcome(names: [:], type: inferredType))
        }

        pendingCompletion = completion

        let viewModel = WrapUpViewModel(
            speakers: speakers.map { Speaker(id: $0.id, snippet: $0.snippet) },
            selectedType: inferredType
        )

        // Unified resolution: resolves exactly once. fromWindowClose=true means AppKit is already
        // closing the window (X button), so window.close() must not be called again here
        // (to avoid re-entering AppKit's window-close flow).
        let resolve: (Outcome, Bool) -> Void = { [weak self] outcome, fromWindowClose in
            guard let self, let comp = self.pendingCompletion else { return }
            self.pendingCompletion = nil
            if fromWindowClose {
                self.detachWindow()
            } else {
                self.close()
            }
            comp(outcome)
        }

        viewModel.onSummarize = { vm in
            var names: [String: String] = [:]
            for s in vm.speakers {
                let n = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { names[s.id] = n }
            }
            resolve(Outcome(names: names, type: vm.selectedType), false)
        }
        viewModel.onSkip = { vm in
            resolve(Outcome(names: [:], type: vm.selectedType), false)
        }

        let host = NSHostingView(rootView: MeetingWrapUpContentView(viewModel: viewModel))
        let height: CGFloat = min(820, 340 + CGFloat(max(speakers.count, 1)) * 120)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: height)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = t("Wrap up meeting")
        win.contentView = host
        win.minSize = NSSize(width: 540, height: 420)
        win.center()
        win.isReleasedWhenClosed = false

        // Closing via the red X == Skip (a summary is still generated). fromWindowClose=true avoids re-entering close().
        let delegate = WindowCloseDelegate {
            resolve(Outcome(names: [:], type: viewModel.selectedType), true)
        }
        win.delegate = delegate
        self.closeDelegate = delegate

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    /// Programmatically closes the window (button path).
    func close() {
        guard let win = window else { return }
        win.delegate = nil          // Clear the delegate first so closing doesn't trigger windowWillClose
        window = nil
        closeDelegate = nil
        win.orderOut(nil)
        win.contentView = nil
        win.close()
    }

    /// Only releases the reference (AppKit is already closing the window, X button path); close() is not called again.
    private func detachWindow() {
        window?.delegate = nil
        window = nil
        closeDelegate = nil
    }
}

// MARK: - Window Close Delegate

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - ViewModel

@Observable
@MainActor
final class WrapUpViewModel {
    var speakers: [MeetingWrapUpWindow.Speaker]
    var selectedType: MeetingType

    var onSummarize: ((WrapUpViewModel) -> Void)?
    var onSkip: ((WrapUpViewModel) -> Void)?

    init(speakers: [MeetingWrapUpWindow.Speaker], selectedType: MeetingType) {
        self.speakers = speakers
        self.selectedType = selectedType
    }
}

// MARK: - SwiftUI View

struct MeetingWrapUpContentView: View {
    @Bindable var viewModel: WrapUpViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Meeting ended"))
                .font(.headline)

            Picker(selection: $viewModel.selectedType) {
                ForEach(MeetingType.allCases) { type in
                    Text(type.defaultDisplayName).tag(type)
                }
            } label: {
                Text(t("Meeting type"))
            }
            .pickerStyle(.menu)

            Divider()

            if viewModel.speakers.isEmpty {
                Text(t("No distinct speakers were detected."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(t("Name the speakers (optional)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach($viewModel.speakers) { $speaker in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(t("Speaker")) \(speaker.id)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.orange)
                                if !speaker.snippet.isEmpty {
                                    Text("“\(speaker.snippet)”")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                TextField(t("Name"), text: $speaker.name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(t("Skip")) { viewModel.onSkip?(viewModel) }
                    .keyboardShortcut(.cancelAction)
                Button(t("Summarize")) { viewModel.onSummarize?(viewModel) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
