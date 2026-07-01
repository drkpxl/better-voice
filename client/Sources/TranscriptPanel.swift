import AppKit
import SwiftUI
import BetterVoiceCore

// MARK: - ViewModel

/// Data source for the transcript panel, drives SwiftUI view refreshes
@Observable
@MainActor
final class TranscriptViewModel {
    var segments: [MeetingSegment] = []
    var volatileText: String = ""
    var duration: TimeInterval = 0
    var wordCount: Int = 0
    var isRecording: Bool = false

    /// Format time as MM:SS
    func formatTimestamp(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - SwiftUI View

/// Transcript panel content view
struct TranscriptContentView: View {
    let viewModel: TranscriptViewModel

    var body: some View {
        VStack(spacing: 0) {
            // transcript content area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.segments) { segment in
                            segmentRow(segment)
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.segments.count) {
                    // auto-scroll to the bottom
                    if let last = viewModel.segments.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // bottom status bar
            statusBar
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    // MARK: - Single transcript row

    @ViewBuilder
    private func segmentRow(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // timestamp
            Text("[\(viewModel.formatTimestamp(segment.startTime))]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // speaker label
            if let speaker = segment.speakerLabel(prefix: t("Speaker"), localLabel: t("You")) {
                Text(speaker + ":")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }

            // text content
            Text(segment.text)
                .font(.system(.body, design: .default))
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .opacity(segment.isFinal ? 1.0 : 0.6)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            // recording status
            if viewModel.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(t("Recording"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
                Text(t("Stopped"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // duration
            Text(viewModel.formatTimestamp(viewModel.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // character count
            Text("· " + t("\(String(viewModel.wordCount)) characters"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Panel controller

/// Floating meeting transcript panel, never steals focus, always stays on top
@MainActor
final class TranscriptPanelController {
    private var panel: NSPanel?
    private let viewModel = TranscriptViewModel()

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.title = t("Better Voice Meeting Transcript")
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        panel.minSize = NSSize(width: 280, height: 200)

        // center on screen
        if let screen = NSScreen.main {
            let x = screen.frame.maxX - 420
            let y = screen.frame.midY - 250
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingView = NSHostingView(rootView: TranscriptContentView(viewModel: viewModel))
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel

        Logger.log("Transcript", "Panel shown")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        Logger.log("Transcript", "Panel hidden")
    }

    /// Update the transcript content
    func updateTranscript(segments: [MeetingSegment]) {
        viewModel.segments = segments
    }

    /// Append a single transcript segment
    func appendSegment(_ segment: MeetingSegment) {
        viewModel.segments.append(segment)
    }

    /// Update the bottom status bar
    func updateStatus(duration: TimeInterval, wordCount: Int) {
        viewModel.duration = duration
        viewModel.wordCount = wordCount
    }

    /// Set the recording status
    func setRecording(_ recording: Bool) {
        viewModel.isRecording = recording
    }

    /// Clear all transcripts
    func clear() {
        viewModel.segments.removeAll()
        viewModel.duration = 0
        viewModel.wordCount = 0
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }
}
