import Foundation
import ApplicationServices
import CoreAudio

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
    /// switch swallows it, short enough not to read as input lag. Applied only when the default
    /// input is Bluetooth (`defaultInputIsBluetooth()`) — on the built-in or a wired mic there is
    /// no route switch to outrun, and the lead would just cost the first ~200ms of speech from
    /// anyone who talks the instant they press the hotkey.
    private static let startCueLeadMs: UInt64 = 200

    /// Whether the system default audio INPUT is a Bluetooth device — the only routes where
    /// opening capture triggers the SCO switch that swallows the start cue (see `startCueLeadMs`).
    private static func defaultInputIsBluetooth() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return false }

        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

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
            // capture going live a beat later doesn't cost usable speech. Bluetooth inputs ONLY:
            // wired/built-in mics have no route switch, so there the lead would just clip the first
            // word of anyone who speaks the instant they press the hotkey.
            if Self.defaultInputIsBluetooth() {
                try? await Task.sleep(for: .milliseconds(Self.startCueLeadMs))
            }

            // A Stop pressed during that lead must not bring capture up behind it (which would leave
            // the mic running with the module already idle) — bail if the state has moved on.
            guard case .recording = self.state, self.session === voiceSession else {
                Logger.log("Voice", "Start aborted during cue lead (stopped before capture opened)")
                return
            }

            do {
                try await voiceSession.start()
                // A Stop can also land while start() is awaiting (first use can take seconds:
                // model download, prepareToAnalyze) — stop() saw isRunning == false and reset the
                // module to idle, so tear the just-opened capture back down instead of leaving the
                // mic live behind an idle UI.
                guard case .recording = self.state, self.session === voiceSession else {
                    Logger.log("Voice", "Stopped during start — closing orphaned capture session")
                    _ = await voiceSession.stop()
                    return
                }
                Logger.log("Voice", "Recording... press hotkey again to stop")
            } catch {
                Logger.log("Voice", "Failed to start: \(error)")
                // Only reset if this session is still the current one — the user may have already
                // started a newer session, which this must not clobber mid-recording.
                if self.session === voiceSession {
                    session = nil
                    state = .idle
                }
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
