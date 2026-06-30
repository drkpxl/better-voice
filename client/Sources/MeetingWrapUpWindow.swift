import AppKit
import SwiftUI
import WECore

/// 会议收尾面板：诊断出说话人后、生成摘要前，让用户给说话人命名并确认会议类型。
/// 用 NSWindow + NSHostingView（与 HotKeySettingsWindow 同栈）。
/// `present(...)` 用 withCheckedContinuation 把一次性的用户输入桥接成 async。
///
/// 行为：
/// - "Summarize"：返回输入的名字 + 选定类型。
/// - "Skip" 或关闭窗口：返回空名字 + （预选/默认）类型——仍然会生成摘要。
@MainActor
final class MeetingWrapUpWindow {
    static let shared = MeetingWrapUpWindow()

    private var window: NSWindow?
    private var closeDelegate: WindowCloseDelegate?

    struct Speaker: Identifiable {
        let id: String       // speakerId（如 "1"）
        let snippet: String
        var name: String = ""
    }

    struct Outcome {
        let names: [String: String]   // speakerId -> 用户输入的名字
        let type: MeetingType
    }

    /// 展示面板并等待用户操作。窗口已开时直接返回默认（不应发生）。
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
        // 防御：若已有窗口，先收尾旧的（理论上不会并发）。
        if window != nil { close() }

        let viewModel = WrapUpViewModel(
            speakers: speakers.map { Speaker(id: $0.id, snippet: $0.snippet) },
            selectedType: inferredType
        )

        var didComplete = false
        let finish: (Outcome) -> Void = { [weak self] outcome in
            guard !didComplete else { return }
            didComplete = true
            self?.close()
            completion(outcome)
        }

        viewModel.onSummarize = { vm in
            var names: [String: String] = [:]
            for s in vm.speakers {
                let n = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { names[s.id] = n }
            }
            finish(Outcome(names: names, type: vm.selectedType))
        }
        viewModel.onSkip = { vm in
            finish(Outcome(names: [:], type: vm.selectedType))
        }

        let host = NSHostingView(rootView: MeetingWrapUpContentView(viewModel: viewModel))
        let height: CGFloat = min(560, 220 + CGFloat(max(speakers.count, 1)) * 64)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: height)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = t("Wrap up meeting")
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false

        // 红叉关闭 == Skip（仍生成摘要）。
        let delegate = WindowCloseDelegate { viewModel.onSkip?(viewModel) }
        win.delegate = delegate
        self.closeDelegate = delegate

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        closeDelegate = nil
    }
}

// MARK: - 窗口关闭代理

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

// MARK: - SwiftUI 视图

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
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($viewModel.speakers) { $speaker in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(t("Speaker")) \(speaker.id)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                }
                                if !speaker.snippet.isEmpty {
                                    Text("“\(speaker.snippet)”")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                TextField(t("Name"), text: $speaker.name)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
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
