import Foundation
import ApplicationServices

/// Voice module
/// Interaction: press right Command to start recording+transcription -> press right Command again to stop -> auto-inject
@MainActor
final class VoiceModule {
    let name = "Voice"
    var isActive = false

    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// State change callback (used by UI indicators)
    var onStateChange: ((State) -> Void)?

    /// Real-time audio level callback (raw RMS, 0...1, used for the waveform indicator; only triggered by the dictation flow, meetings don't use this module)
    var onAudioLevel: ((Float) -> Void)?

    private var session: VoiceSession?
    private let pipeline = VoicePipeline()
    private var pinnedApp: AppIdentity?
    private var pinnedFocus: AXUIElement?   // the exact text field focused when recording started
    private var recordingStartT: CFAbsoluteTime = 0

    /// How long to let the start cue play before opening the capture session — see the note in
    /// `startRecording()`. Long enough for the "Pop" to be heard before a Bluetooth mic's SCO route
    /// switch swallows it, short enough not to read as input lag.
    private static let startCueLeadMs: UInt64 = 200

    func onHotKeyDown() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            Logger.log("Voice", "Ignored hotkey, processing")
        }
    }

    func onHotKeyUp() {
        // No action on key release
    }

    private func startRecording() {
        guard VoiceSession.isAuthorized else {
            Logger.log("Voice", "Not authorized, requesting permissions")
            VoiceSession.requestPermissions()
            return
        }

        // Set to recording immediately to prevent rapid repeated key presses from creating multiple sessions
        state = .recording
        recordingStartT = CFAbsoluteTimeGetCurrent()

        // Pin the currently focused app and text field, so we can paste back into exactly
        // where the user started even if they click elsewhere while transcription runs.
        pinnedApp = AppIdentity.current()
        pinnedFocus = FocusTarget.capture()
        Logger.log("Voice", "Pinned app: \(pinnedApp?.bundleID ?? "unknown")")

        let voiceSession = VoiceSession()
        self.session = voiceSession
        voiceSession.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }

        Task {
            // Let the start cue (DictationSound.playStart(), fired synchronously on the .recording
            // transition above) be HEARD before we open the capture session. On a Bluetooth mic
            // (AirPods) starting capture switches the earbuds into hands-free SCO, and that route
            // switch swallows whatever is playing at that instant — which is exactly why the start
            // "Pop" was inaudible while the stop cue (played after switching back) came through. A
            // short lead lets the cue land first; it also reads as the "you can talk now" signal, so
            // capture going live a beat later doesn't cost usable speech.
            try? await Task.sleep(for: .milliseconds(Self.startCueLeadMs))

            // A Stop pressed during that lead must not bring capture up behind it (which would leave
            // the mic running with the module already idle) — bail if the state has moved on.
            guard case .recording = self.state, self.session === voiceSession else {
                Logger.log("Voice", "Start aborted during cue lead (stopped before capture opened)")
                return
            }

            do {
                try await voiceSession.start()
                Logger.log("Voice", "Recording... press hotkey again to stop")
            } catch {
                Logger.log("Voice", "Failed to start: \(error)")
                session = nil
                state = .idle
            }
        }
    }

    private func stopAndProcess() {
        guard let session else {
            state = .idle
            return
        }

        let tStop0 = CFAbsoluteTimeGetCurrent()
        let recordingMs = Int((tStop0 - recordingStartT) * 1000)
        state = .processing
        Logger.log("Voice", "Stopping... (recorded \(recordingMs)ms)")

        Task {
            let result = await session.stop()
            let stopMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            self.session = nil

            guard !result.fullText.isEmpty else {
                Logger.log("Voice", "Empty transcription, skipping")
                state = .idle
                return
            }

            Logger.log("Voice", "Transcribed: \(result.fullText)")

            let tPipe = CFAbsoluteTimeGetCurrent()
            await pipeline.process(
                transcription: result,
                targetApp: pinnedApp,
                focusTarget: pinnedFocus
            )
            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - tPipe) * 1000)
            let voiceTotalMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            Logger.log("Voice", "Timing: recording=\(recordingMs)ms stop_finalize=\(stopMs)ms pipeline=\(pipelineMs)ms voice_total=\(voiceTotalMs)ms")
            state = .idle
        }
    }
}
