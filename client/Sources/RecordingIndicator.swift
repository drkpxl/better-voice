import AppKit
import SwiftUI
import WECore

/// 录音指示器：模仿 macOS 原生听写的浮动面板
/// 深色毛玻璃背景 + 麦克风图标 + 实时音频波形 + 文字提示
@MainActor
final class RecordingIndicator {
    private var window: NSWindow?
    private var model: WaveformLevelModel?

    func show() {
        guard window == nil else { return }

        let panelSize = NSSize(width: 220, height: 48)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let origin = NSPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.visibleFrame.minY + 80
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

        let model = WaveformLevelModel()
        self.model = model

        let hostingView = NSHostingView(rootView: RecordingIndicatorContentView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.window = panel

        Logger.log("UI", "Recording indicator shown")
    }

    func hide() {
        model = nil
        window?.orderOut(nil)
        window = nil
        Logger.log("UI", "Recording indicator hidden")
    }

    /// 更新音频电平（原始 RMS，0...1）。读取波形配置后归一化并写入环形缓冲。
    func update(level rawRMS: Float) {
        guard let model else { return }

        let config = RuntimeConfig.shared.waveformConfig
        let noiseFloor = Float(config["noise_floor"] as? Double ?? 0.02)
        let sensitivity = Float(config["sensitivity"] as? Double ?? 1.0)

        let level = WaveformMath.normalizedLevel(rms: rawRMS, noiseFloor: noiseFloor, sensitivity: sensitivity)
        model.push(level)
    }
}

// MARK: - 波形数据模型

/// 最近若干个归一化电平样本的环形缓冲，驱动 SwiftUI 波形视图刷新
@MainActor
@Observable
final class WaveformLevelModel {
    static let historyLimit = 48

    private(set) var history: [Float] = []

    func push(_ level: Float) {
        history.append(level)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}

// MARK: - 面板内容视图

private struct RecordingIndicatorContentView: View {
    let model: WaveformLevelModel

    var body: some View {
        ZStack {
            VisualEffectBlur()

            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)

                WaveformView(history: model.history)
                    .frame(width: 100, height: 26)

                Text(t("Listening..."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: 220, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 毛玻璃背景（HUD 风格）
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 实时音频电平波形：从归一化电平环形缓冲绘制等距竖条
private struct WaveformView: View {
    let history: [Float]

    private let barCount = 24
    private let minBarHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let samples = displaySamples()
                guard !samples.isEmpty else { return }

                let spacing: CGFloat = 2
                let barWidth = max(1, (size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
                let midY = size.height / 2

                for (i, level) in samples.enumerated() {
                    let height = max(minBarHeight, CGFloat(level) * size.height)
                    let x = CGFloat(i) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(path, with: .color(.white.opacity(0.85)))
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: history)
    }

    /// 取最近 barCount 个样本；不足时左侧用 0 填充，保持靠右对齐（最新样本在最右侧）
    private func displaySamples() -> [Float] {
        if history.count >= barCount {
            return Array(history.suffix(barCount))
        }
        return Array(repeating: 0, count: barCount - history.count) + history
    }
}
