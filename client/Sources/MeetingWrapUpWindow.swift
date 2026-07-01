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
        let quotes: [String] // a few representative turns, to help identify the voice
        var name: String = ""
    }

    struct Outcome {
        let names: [String: String]   // speakerId -> user-entered name
        let type: MeetingType
    }

    /// The currently pending continuation callback. Set when show() is called, cleared on resolve.
    private var pendingCompletion: ((Outcome) -> Void)?

    /// Presents the panel and waits for the user to act.
    func present(speakers: [(id: String, quotes: [String])], inferredType: MeetingType) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.show(speakers: speakers, inferredType: inferredType) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    private func show(
        speakers: [(id: String, quotes: [String])],
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
            speakers: speakers.map { Speaker(id: $0.id, quotes: $0.quotes) },
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

        let width: CGFloat = 620

        // Measure the content's natural height (cards laid out inline, no scroll)
        // at our fixed width, then clamp to what fits on screen. This makes the
        // window exactly as tall as it needs to be for the number of speakers,
        // and only scrolls when that would run off the display.
        let probe = NSHostingView(rootView: MeetingWrapUpContentView(viewModel: viewModel, scrolls: false))
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.widthAnchor.constraint(equalToConstant: width).isActive = true
        probe.layoutSubtreeIfNeeded()
        let natural = probe.fittingSize.height

        let screenCap = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let needsScroll = natural > screenCap
        let height = min(natural, screenCap)

        let host = NSHostingView(rootView: MeetingWrapUpContentView(viewModel: viewModel, scrolls: needsScroll))
        host.sizingOptions = []   // we set the window size explicitly; don't let SwiftUI override it
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = t("Wrap up meeting")
        win.contentView = host
        win.minSize = NSSize(width: width, height: min(height, 300))
        win.center()
        win.isReleasedWhenClosed = false

        // Closing via the red X == Skip (a summary is still generated). fromWindowClose=true avoids re-entering close().
        let delegate = WindowCloseDelegate {
            resolve(Outcome(names: [:], type: viewModel.selectedType), true)
        }
        win.delegate = delegate
        self.closeDelegate = delegate

        // Accessory apps lose the activation race, so belt-and-suspenders: float
        // above other windows, activate the app first, then force the window front.
        win.level = .floating                 // stay above normal windows until dismissed
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.activate()                      // non-deprecated (macOS 26); activate BEFORE ordering
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()            // reliable even if activation is refused
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
    /// When true the speaker list is wrapped in a ScrollView (used when the
    /// content is taller than the screen). When false it lays out inline so the
    /// window can be measured / sized to fit exactly.
    var scrolls: Bool = true
    @FocusState private var focusedSpeaker: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header + meeting type (fixed height).
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Name the speakers"))
                        .font(.title3.weight(.semibold))
                    Text(t("Match each voice to a name. You can skip this — a summary is generated either way."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(selection: $viewModel.selectedType) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.defaultDisplayName).tag(type)
                    }
                } label: {
                    Text(t("Meeting type"))
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            speakerList

            Divider()

            // Footer actions (fixed height, always visible).
            HStack {
                Spacer()
                Button(t("Skip")) { viewModel.onSkip?(viewModel) }
                    .keyboardShortcut(.cancelAction)
                Button(t("Summarize")) { viewModel.onSummarize?(viewModel) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .tint(Color.brandAccent)
    }

    @ViewBuilder
    private var speakerList: some View {
        if viewModel.speakers.isEmpty {
            Text(t("No distinct speakers were detected."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
                .padding(.horizontal, 20)
        } else {
            let cards = VStack(alignment: .leading, spacing: 14) {
                ForEach($viewModel.speakers) { $speaker in
                    speakerCard($speaker)
                }
            }
            .padding(20)

            if scrolls {
                ScrollView { cards }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cards
            }
        }
    }

    @ViewBuilder
    private func speakerCard(_ speaker: Binding<MeetingWrapUpWindow.Speaker>) -> some View {
        let quotes = speaker.wrappedValue.quotes
        VStack(alignment: .leading, spacing: 10) {
            if !quotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                        Text("“\(quote)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Name entry, clearly labeled as the action for this speaker.
            HStack(spacing: 8) {
                Text("\(t("Speaker")) \(speaker.wrappedValue.id)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandAccent)
                    .fixedSize()
                TextField(t("is…  (type a name)"), text: speaker.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedSpeaker, equals: speaker.wrappedValue.id)
                    .onSubmit { advanceFocus(after: speaker.wrappedValue.id) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Return in a name field jumps to the next unnamed speaker, or drops focus
    /// (so the default Summarize button can take Return) once at the last one.
    private func advanceFocus(after id: String) {
        let ids = viewModel.speakers.map(\.id)
        guard let idx = ids.firstIndex(of: id), idx + 1 < ids.count else {
            focusedSpeaker = nil
            return
        }
        focusedSpeaker = ids[idx + 1]
    }
}
