import AppKit
import SwiftUI
import BetterVoiceCore

/// Recording indicator: a black bar "hanging" from the top of the screen, with a live audio waveform. Used only for instant dictation.
///
/// Ported from FreeFlow's (github.com/zachlatta/freeflow, MIT) RecordingOverlay:
/// - On screens with a notch, uses a "double-wing" layout: the waveform sits in a small wing to the
///   left of the notch, with a solid black mask matching the notch's width in the middle, the whole
///   thing flush with the top edge at menu-bar height, making it look like it hangs from both sides of the notch.
/// - On screens without a notch, uses a small pill centered at the top that drops down.
/// Level is adaptively normalized by LiveAudioLevelNormalizer; a single audioLevel(0...1) drives the bars.
@MainActor
final class RecordingIndicator {
    /// Shared instance so both dictation (AppDelegate) and meetings (StatusBarController) drive the
    /// same HUD — one recording indicator, never two at once.
    static let shared = RecordingIndicator()

    private var window: NSPanel?
    private let state = RecordingIndicatorState()
    private var normalizer = LiveAudioLevelNormalizer()

    // Double-wing size (matches the compact waveform, avoiding collision with right-side menu bar icons).
    private let wingWidth: CGFloat = 38

    func show() {
        guard window == nil else { return }

        normalizer.reset()
        state.audioLevel = 0

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let geom = Geometry(screen: screen, wingWidth: wingWidth)
        let finalFrame = geom.frame

        let panel = NSPanel(
            contentRect: finalFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver            // Floats above the menu bar, flush with the top edge
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

        let root = RecordingIndicatorContentView(state: state, geometry: geom)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: finalFrame.size)
        panel.contentView = host

        // "Slides down" a short distance from off the top edge, creating the impression of hanging down.
        let hiddenFrame = NSRect(x: finalFrame.origin.x, y: screen.frame.maxY,
                                 width: finalFrame.width, height: finalFrame.height)
        panel.setFrame(hiddenFrame, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(finalFrame, display: true)
        }

        self.window = panel
        Logger.log("UI", "Recording indicator shown at \(finalFrame), notch=\(geom.hasNotch)")
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

    /// Takes the raw RMS (0...1) and drives the waveform after adaptive normalization.
    func update(level rawRMS: Float) {
        guard window != nil else { return }
        state.audioLevel = normalizer.normalizedLevel(forRMS: rawRMS)
    }
}

// MARK: - Geometry (notch/menu bar)

/// Computes the indicator window's frame and layout parameters. Ported from FreeFlow's overlayFrame logic (recording state only).
struct Geometry {
    let frame: NSRect
    let hasNotch: Bool
    let leftWingWidth: CGFloat
    let notchWidth: CGFloat
    let rightWingWidth: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    init(screen: NSScreen, wingWidth: CGFloat) {
        // Menu bar height (also the overlap height between the notch and the visible area).
        let menuOverlap = max(screen.frame.maxY - screen.visibleFrame.maxY, 22)
        let notch = screen.safeAreaInsets.top > 0
        self.hasNotch = notch
        self.height = menuOverlap

        if notch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // Double-wing: [left wing][solid black notch][right wing], flush with the top, at menu-bar height.
            let nWidth = screen.frame.width - left.width - right.width
            let nLeftX = left.maxX
            self.leftWingWidth = wingWidth
            self.notchWidth = max(nWidth, 0)
            self.rightWingWidth = wingWidth
            self.cornerRadius = 14
            let panelWidth = wingWidth + notchWidth + wingWidth
            let panelX = nLeftX - wingWidth
            let panelY = screen.frame.maxY - menuOverlap
            self.frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: menuOverlap)
        } else {
            // No notch: a small pill centered at the top that drops down.
            let pillWidth: CGFloat = 150
            self.leftWingWidth = 0
            self.notchWidth = 0
            self.rightWingWidth = 0
            self.cornerRadius = 12
            let x = screen.frame.midX - pillWidth / 2
            let y = screen.frame.maxY - menuOverlap
            self.frame = NSRect(x: x, y: y, width: pillWidth, height: menuOverlap)
        }
    }
}

// MARK: - State

private final class RecordingIndicatorState: ObservableObject {
    @Published var audioLevel: Float = 0
}

// MARK: - Content

private struct RecordingIndicatorContentView: View {
    @ObservedObject var state: RecordingIndicatorState
    let geometry: Geometry

    var body: some View {
        Group {
            if geometry.hasNotch {
                // Left-wing waveform + middle solid-black notch + right-wing empty space (hidden by the camera cutout).
                HStack(spacing: 0) {
                    CompactWaveformView(audioLevel: state.audioLevel)
                        .frame(width: geometry.leftWingWidth, height: geometry.height)
                    Color.black
                        .frame(width: geometry.notchWidth, height: geometry.height)
                    Color.clear
                        .frame(width: geometry.rightWingWidth, height: geometry.height)
                }
            } else {
                WaveformView(audioLevel: state.audioLevel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: geometry.cornerRadius,
            bottomTrailingRadius: geometry.cornerRadius
        ))
    }
}

// MARK: - Waveform (ported from FreeFlow, MIT)

private struct WaveformBar: View {
    let amplitude: CGFloat
    var width: CGFloat = 3
    var minHeight: CGFloat = 2
    var maxHeight: CGFloat = 18

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: width, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

/// 9 symmetric vertical bars (used for the no-notch pill).
private struct WaveformView: View {
    let audioLevel: Float

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            bars(pulseTime: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(height: 24)
    }

    private func bars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: amplitude(for: index, pulseTime: pulseTime), maxHeight: 18)
                    .animation(.spring(response: response(for: index), dampingFraction: 0.88), value: audioLevel)
            }
        }
    }

    private func amplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        sharedAmplitude(level: audioLevel, multiplier: Self.multipliers[index], index: index, pulseTime: pulseTime)
    }

    private func response(for index: Int) -> Double {
        let d = abs(CGFloat(index) - Self.centerIndex) / Self.centerIndex
        return 0.18 + Double(d) * 0.06
    }
}

/// 5 compact vertical bars (used for the notch's left wing).
private struct CompactWaveformView: View {
    let audioLevel: Float

    private static let barCount = 5
    private static let multipliers: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            HStack(spacing: 1.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    WaveformBar(
                        amplitude: sharedAmplitude(
                            level: audioLevel,
                            multiplier: Self.multipliers[index],
                            index: index,
                            pulseTime: context.date.timeIntervalSinceReferenceDate
                        ),
                        width: 2,
                        maxHeight: 14
                    )
                    .animation(.spring(response: 0.18, dampingFraction: 0.88), value: audioLevel)
                }
            }
        }
        .frame(height: 18)
    }
}

/// FreeFlow's bar amplitude formula: at low levels, adds a bit of traveling wave/shimmer to make the waveform feel "alive".
private func sharedAmplitude(level: Float, multiplier: CGFloat, index: Int, pulseTime: TimeInterval?) -> CGFloat {
    let lvl = CGFloat(max(level, 0))
    let base = min(lvl * multiplier, 1.0)
    guard let pulseTime else { return base }
    let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
    let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
    let pulse = travelingWave * 0.22 + shimmer * 0.06
    let saturationRelief = base * (0.74 + pulse)
    let quietPulse = (1.0 - base) * (0.04 + pulse * 0.28)
    return min(saturationRelief + quietPulse, 1.0)
}
