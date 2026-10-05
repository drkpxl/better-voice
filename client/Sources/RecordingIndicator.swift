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
    /// Shared instance so the recording HUD is a single panel — one indicator, never two at once.
    static let shared = RecordingIndicator()

    /// Which flow currently wants the "you're being recorded" HUD visible. The panel is a shared
    /// singleton but dictation and meeting recording overlap (a dictation can finish while a
    /// meeting is still capturing), so hiding is REFERENCE-COUNTED by owner: the panel only tears
    /// down once the last owner releases it. Without this, dictation's `.processing`/`.idle`
    /// `hide` would rip down the HUD mid-meeting — a privacy-relevant "recording light went out
    /// while still recording" bug.
    enum Owner {
        case dictation
        case meeting
    }
    private var owners: Set<Owner> = []

    private var window: NSPanel?
    private let state = RecordingIndicatorState()
    private var normalizer = LiveAudioLevelNormalizer()

    // Double-wing size (matches the compact waveform, avoiding collision with right-side menu bar icons).
    private let wingWidth: CGFloat = 38

    /// Show the live-recording HUD (mic/system-audio-driven waveform) on behalf of `owner`.
    /// Idempotent per owner; the first owner materializes the panel.
    func show(owner: Owner) {
        let wasEmpty = owners.isEmpty
        owners.insert(owner)
        // Only reset the normalizer/level when the panel is coming up fresh — a second owner
        // joining an already-visible HUD must not zero the level the first owner is driving.
        if wasEmpty {
            normalizer.reset()
            state.audioLevel = 0
            state.previewText = ""
            announce(t("Recording"))
        }
        ensureWindow()
    }

    private func ensureWindow() {
        guard window == nil else { return }

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

    /// Release `owner`'s claim on the HUD. The panel only actually tears down once NO owner still
    /// wants it — so a dictation finishing while a meeting records leaves the HUD up.
    func hide(owner: Owner) {
        owners.remove(owner)
        // The live transcript belongs to dictation; a meeting keeping the HUD up mustn't keep it.
        if owner == .dictation { hidePreview() }
        guard owners.isEmpty else {
            Logger.log("UI", "Recording indicator: \(owner) released, still shown for \(owners)")
            return
        }
        if let panel = window {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        window = nil
        hidePreview()
        Logger.log("UI", "Recording indicator hidden")
    }

    // MARK: - Live transcript

    private var previewPanel: NSPanel?
    private static let previewSize = NSSize(width: 440, height: 56)

    /// Show (or update) the live transcript under the HUD. Empty text hides it.
    func setPreview(_ text: String) {
        guard let hud = window else { return }
        state.previewText = text
        guard !text.isEmpty else { hidePreview(); return }
        guard previewPanel == nil else { return }

        let size = Self.previewSize
        let frame = NSRect(
            x: hud.frame.midX - size.width / 2,
            y: hud.frame.minY - size.height - 8,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: LivePreviewView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        previewPanel = panel
    }

    private func hidePreview() {
        state.previewText = ""
        guard let panel = previewPanel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        previewPanel = nil
    }

    /// VoiceOver: say what the HUD is doing, since the HUD itself is not focusable.
    func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Takes the raw RMS (0...1) and drives the waveform after adaptive normalization.
    func update(level rawRMS: Float) {
        guard window != nil else { return }
        state.audioLevel = normalizer.normalizedLevel(forRMS: rawRMS)
    }

    /// Switch the HUD to its post-capture appearance while the engine runs (decision 4).
    ///
    /// The HUD used to be torn down at this point, which was fine when transcription had already
    /// finished streaming by the time the hotkey was released. With batch transcription there is a real
    /// gap between "stop talking" and "text appears", and hiding the HUD across it left nothing on
    /// screen -- indistinguishable from the dictation having been dropped.
    func setTranscribing(_ transcribing: Bool) {
        guard window != nil else { return }
        state.isTranscribing = transcribing
        if transcribing {
            state.audioLevel = 0
            // The preview was a guess at work in progress; the real text is about to be inserted.
            hidePreview()
            announce(t("Transcribing"))
        }
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

@MainActor
@Observable
private final class RecordingIndicatorState {
    var audioLevel: Float = 0
    /// True once capture has stopped and the engine is running. The waveform has nothing to show at
    /// that point -- no audio is arriving -- so the bars switch to a "working" sweep instead of
    /// sitting frozen, which is what "stopped updating" would otherwise look like.
    var isTranscribing = false
    /// Live transcript while recording (see `LiveDictationPreview`); empty when there is none.
    var previewText = ""
}

// MARK: - Content

private struct RecordingIndicatorContentView: View {
    let state: RecordingIndicatorState
    let geometry: Geometry

    var body: some View {
        if geometry.hasNotch {
            notchWings
        } else {
            // No notch to hang from: a Liquid Glass pill, which reads as part of the system UI
            // rather than a black slab over the menu bar.
            WaveformView(audioLevel: state.audioLevel, transcribing: state.isTranscribing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular.tint(.black.opacity(0.55)), in: pillShape)
        }
    }

    private var pillShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: geometry.cornerRadius,
            bottomTrailingRadius: geometry.cornerRadius
        )
    }

    /// The notch's wings stay solid black: anything else would show the seam against the notch.
    private var notchWings: some View {
        Group {
            if geometry.hasNotch {
                // Left-wing waveform + middle solid-black notch + right-wing empty space (hidden by the camera cutout).
                HStack(spacing: 0) {
                    CompactWaveformView(audioLevel: state.audioLevel, transcribing: state.isTranscribing)
                        .frame(width: geometry.leftWingWidth, height: geometry.height)
                    Color.black
                        .frame(width: geometry.notchWidth, height: geometry.height)
                    Color.clear
                        .frame(width: geometry.rightWingWidth, height: geometry.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(pillShape)
    }
}

/// The live transcript bubble under the HUD: the last two lines of what's been heard, newest at
/// the end (head-truncated, so the start falls away as you keep talking).
private struct LivePreviewView: View {
    let state: RecordingIndicatorState

    var body: some View {
        Text(state.previewText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Solid brand purple, not glass: glass over a light desktop read as white-on-gray.
            // White on the brand's deep purple (#5847d6) is 6.4:1.
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: NSColor(srgbRed: 0x58 / 255, green: 0x47 / 255, blue: 0xd6 / 255, alpha: 0.96)))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            )
            .padding(6)   // room for the shadow inside the panel
            .animation(.easeOut(duration: 0.15), value: state.previewText)
            .accessibilityHidden(true)   // announced via the HUD, not read on every update
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
    var transcribing = false

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
        transcribing
            ? workingAmplitude(index: index, count: Self.barCount, time: pulseTime ?? 0)
            : sharedAmplitude(level: audioLevel, multiplier: Self.multipliers[index], index: index, pulseTime: pulseTime)
    }

    private func response(for index: Int) -> Double {
        let d = abs(CGFloat(index) - Self.centerIndex) / Self.centerIndex
        return 0.18 + Double(d) * 0.06
    }
}

/// 5 compact vertical bars (used for the notch's left wing).
private struct CompactWaveformView: View {
    let audioLevel: Float
    var transcribing = false

    private static let barCount = 5
    private static let multipliers: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            HStack(spacing: 1.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    WaveformBar(
                        amplitude: transcribing
                            ? workingAmplitude(index: index, count: Self.barCount, time: context.date.timeIntervalSinceReferenceDate)
                            : sharedAmplitude(
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

/// "Working" look while the engine runs: a single bump sweeping across the bars, clearly distinct
/// from the live, level-driven waveform so the switch from listening to transcribing is visible.
private func workingAmplitude(index: Int, count: Int, time: TimeInterval) -> CGFloat {
    let phase = (time * 1.6).truncatingRemainder(dividingBy: 1)        // 0...1, ~0.6s per sweep
    let center = phase * Double(count + 1) - 0.5
    let distance = abs(Double(index) - center)
    return CGFloat(0.12 + 0.6 * max(0, 1 - distance / 1.5))
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
