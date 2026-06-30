import AppKit
import SwiftUI
import WECore

/// 录音指示器：从屏幕顶部中央「滑下」的黑色小药丸，内含实时音频波形。
/// 仅用于即时听写（VoiceModule），不用于会议。
///
/// 波形渲染与电平归一化移植自 FreeFlow（github.com/zachlatta/freeflow, MIT）：
/// 单个 audioLevel(0...1) 驱动 9 条对称白色竖条；电平由 LiveAudioLevelNormalizer
/// 自适应归一化（自动噪声地板/峰值跟踪），故无需手工噪声阈值。
@MainActor
final class RecordingIndicator {
    private var window: NSPanel?
    private let state = RecordingIndicatorState()
    private var normalizer = LiveAudioLevelNormalizer()

    private let panelWidth: CGFloat = 120
    private let panelHeight: CGFloat = 32

    func show() {
        guard window == nil else { return }

        normalizer.reset()
        state.audioLevel = 0

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let x = screen.frame.midX - panelWidth / 2
        let finalY = screen.frame.maxY - panelHeight   // 紧贴屏幕顶边
        let finalFrame = NSRect(x: x, y: finalY, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: finalFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver            // 浮在菜单栏之上
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

        let host = NSHostingView(rootView: RecordingIndicatorContentView(state: state))
        host.frame = NSRect(origin: .zero, size: finalFrame.size)
        panel.contentView = host

        // 从顶边外滑入
        let hiddenFrame = NSRect(x: x, y: screen.frame.maxY, width: panelWidth, height: panelHeight)
        panel.setFrame(hiddenFrame, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(finalFrame, display: true)
        }

        self.window = panel
        Logger.log("UI", "Recording indicator shown")
    }

    func hide() {
        if let panel = window {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        window = nil
        Logger.log("UI", "Recording indicator hidden")
    }

    /// 输入原始 RMS（0...1），经自适应归一化后驱动波形。
    func update(level rawRMS: Float) {
        guard window != nil else { return }
        state.audioLevel = normalizer.normalizedLevel(forRMS: rawRMS)
    }
}

// MARK: - State

private final class RecordingIndicatorState: ObservableObject {
    @Published var audioLevel: Float = 0
}

// MARK: - Content

private struct RecordingIndicatorContentView: View {
    @ObservedObject var state: RecordingIndicatorState

    var body: some View {
        ZStack {
            WaveformView(audioLevel: state.audioLevel, showsActivityPulse: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }
}

// MARK: - Waveform (ported from FreeFlow, MIT)

private struct WaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 20

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

private struct WaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    waveformBars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                waveformBars(pulseTime: nil)
            }
        }
        .frame(height: 24)
    }

    private func waveformBars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: barAmplitude(for: index, pulseTime: pulseTime))
                    .animation(
                        .spring(response: barResponse(for: index), dampingFraction: 0.88)
                            .delay(barDelay(for: index)),
                        value: audioLevel
                    )
            }
        }
    }

    private func barAmplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        let level = CGFloat(max(audioLevel, 0))
        let baseAmplitude = min(level * Self.multipliers[index], 1.0)

        guard let pulseTime else { return baseAmplitude }

        let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = travelingWave * 0.22 + shimmer * 0.06

        let saturationRelief = baseAmplitude * (0.74 + pulse)
        let quietPulse = (1.0 - baseAmplitude) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }

    private func barResponse(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        let normalizedDistance = distance / Self.centerIndex
        return 0.18 + Double(normalizedDistance) * 0.06
    }

    private func barDelay(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        return Double(distance) * 0.01
    }
}
