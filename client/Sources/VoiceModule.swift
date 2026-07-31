import AVFoundation
import Foundation
import ApplicationServices
import CoreAudio
import BetterVoiceCore

/// Voice module
/// Interaction: press right Command to start recording+transcription -> press right Command again to stop -> auto-inject
@MainActor
final class VoiceModule {
    let name = "Voice"
    var isActive = false

    enum State {
        case idle
        case recording
        /// Audio captured, engine running. Distinct from `.recording` so the HUD can say which is
        /// happening (decision 4) -- with batch transcription there is now a real, if brief, gap
        /// between "stop talking" and "text appears", and showing nothing during it reads as a hang.
        case transcribing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// State change callback (used by UI indicators)
    var onStateChange: ((State) -> Void)?

    /// Real-time audio level callback (raw RMS, 0...1, used for the waveform indicator; only triggered by the dictation flow, meetings don't use this module)
    var onAudioLevel: ((Float) -> Void)?

    private var recorder: DictationRecorder?
    private let pipeline = VoicePipeline()

    /// Audio shorter than this is treated as a mis-press and discarded silently. Decision 11: a
    /// fat-fingered hotkey is not a fault and must not raise a notification.
    private static let minimumDictationSeconds: TimeInterval = 0.3

    /// Past this much recorded audio, transcription takes long enough to be worth acknowledging.
    /// Parakeet runs at roughly 0.004s per second of speech, so a minute of audio transcribes in a
    /// quarter of a second -- below this there is nothing a user could perceive.
    private static let longDictationSeconds: TimeInterval = 60
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

    /// Whether the speech models are on disk and dictation can actually run.
    ///
    /// Mirrored here as a plain flag, refreshed by the app's phase observer, because the hotkey path
    /// has to decide *synchronously* whether to open the mic. Awaiting the store on the press would
    /// mean either dropping the press or starting capture optimistically — and starting optimistically
    /// is exactly what 1.1.0 did: the recording began, the stop worked, and then transcription parked
    /// on an invisible 470 MB download behind a HUD that still looked like a live mic.
    private(set) var modelsReady = false
    private(set) var modelFraction: Double = 0

    /// Raised when the hotkey is pressed while the models are still coming down, with the current
    /// 0...1 fraction. The app turns it into user-visible feedback; without it the press would be
    /// silently swallowed, which reads as a broken hotkey.
    var onModelsUnavailable: ((Double) -> Void)?

    /// Fold the latest model phase in. Called from the app's observer.
    func applyModelPhase(_ phase: AsrModelPhase) {
        switch phase {
        case .installed:
            modelsReady = true
            modelFraction = 1
        case .downloading(let fraction):
            modelsReady = false
            modelFraction = fraction
        case .notInstalled, .failed:
            modelsReady = false
            modelFraction = 0
        }
    }

    func onHotKeyDown() {
        switch state {
        case .idle:
            // Refuse the press rather than record audio we cannot transcribe yet. Declining costs the
            // user one dictation; recording optimistically costs them the whole app, because the
            // stop-press then parks in `.transcribing` for the length of a 470 MB download with no way
            // out but force-quitting.
            guard modelsReady else {
                Logger.log("Voice", "Dictation unavailable: speech model not ready (\(Int(modelFraction * 100))%)")
                onModelsUnavailable?(modelFraction)
                return
            }
            startRecording()
        case .recording:
            stopAndProcess()
        case .transcribing:
            Logger.log("Voice", "Ignored hotkey, transcribing")
        }
    }

    func onHotKeyUp() {
        // No action on key release
    }

    private func startRecording() {
        guard AudioCapture.isAuthorized else {
            Logger.log("Voice", "Not authorized, requesting permissions")
            AudioCapture.requestPermission()
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

        let voiceSession = DictationRecorder()
        self.recorder = voiceSession
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
            guard case .recording = self.state, self.recorder === voiceSession else {
                Logger.log("Voice", "Start aborted during cue lead (stopped before capture opened)")
                return
            }

            do {
                try await voiceSession.start()
                // A Stop can also land while start() is awaiting (first use can take seconds:
                // model download, prepareToAnalyze) — stop() saw isRunning == false and reset the
                // module to idle, so tear the just-opened capture back down instead of leaving the
                // mic live behind an idle UI.
                guard case .recording = self.state, self.recorder === voiceSession else {
                    Logger.log("Voice", "Stopped during start — closing orphaned capture session")
                    _ = await voiceSession.stop()
                    return
                }
                Logger.log("Voice", "Recording... press hotkey again to stop")
            } catch {
                Logger.log("Voice", "Failed to start: \(error)")
                // Only reset if this session is still the current one — the user may have already
                // started a newer session, which this must not clobber mid-recording.
                if self.recorder === voiceSession {
                    recorder = nil
                    state = .idle
                }
            }
        }
    }

    private func stopAndProcess() {
        guard let recorder else {
            state = .idle
            return
        }

        let tStop0 = CFAbsoluteTimeGetCurrent()
        let recordingMs = Int((tStop0 - recordingStartT) * 1000)
        state = .transcribing
        Logger.log("Voice", "Stopping... (recorded \(recordingMs)ms)")

        Task {
            let captured = await recorder.stop()
            let captureMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            self.recorder = nil

            // Nothing captured at all: the mic produced no buffers, or they disagreed about format.
            // Silent -- decision 11 reserves notifications for real faults, and there is nothing here
            // the user can act on.
            guard let buffer = captured else {
                Logger.log("Voice", "No audio captured; nothing to transcribe")
                state = .idle
                return
            }

            let audio = CapturedAudio(buffer)

            // A mis-pressed hotkey. Also silent, and checked before the silence test because it is
            // cheaper and the more common cause.
            guard audio.duration >= Self.minimumDictationSeconds else {
                Logger.log("Voice", "Discarded \(String(format: "%.2f", audio.duration))s dictation (below \(Self.minimumDictationSeconds)s)")
                state = .idle
                return
            }

            // Silent capture -- a muted or misrouted mic. Silent per decision 11, but logged with the
            // RMS so a support question has something to go on.
            let level = AudioSilenceCheck.isEffectivelySilent(
                frameCount: Int(buffer.frameLength),
                rms: Self.rms(of: buffer)
            )
            guard !level else {
                Logger.log("Voice", "Captured audio is silent; skipping transcription")
                state = .idle
                return
            }

            if audio.duration >= Self.longDictationSeconds {
                Logger.log("Voice", "Long dictation (\(Int(audio.duration))s) — transcription will take a moment")
            }

            let tAsr = CFAbsoluteTimeGetCurrent()
            let transcript: Transcript
            do {
                transcript = try await ParakeetTranscriber.shared.transcribe(audio: audio)
            } catch {
                // A real fault, and the first error channel dictation has ever had. Before this, a
                // failed dictation was indistinguishable from saying nothing.
                Logger.log("Voice", "Transcription failed: \(error)")
                Notify.warn(
                    t("Dictation failed"),
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
                state = .idle
                return
            }
            let asrMs = Int((CFAbsoluteTimeGetCurrent() - tAsr) * 1000)

            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // The engine ran and returned nothing. Distinct from the guards above: the audio was
                // long enough and not silent, so this is speech the engine could not resolve. Still
                // silent -- there is no action to offer -- but logged as its own case.
                Logger.log("Voice", "Engine returned empty text for \(String(format: "%.1f", audio.duration))s of audio")
                state = .idle
                return
            }

            Logger.log("Voice", "Transcribed via \(transcript.engineID): \(text)")

            let tPipe = CFAbsoluteTimeGetCurrent()
            await pipeline.process(
                transcription: TranscriptionResult(fullText: text, timestamp: Date()),
                targetApp: pinnedApp,
                focusTarget: pinnedFocus
            )
            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - tPipe) * 1000)
            let voiceTotalMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            Logger.log("Voice", "Timing: recording=\(recordingMs)ms capture_stop=\(captureMs)ms asr=\(asrMs)ms pipeline=\(pipelineMs)ms voice_total=\(voiceTotalMs)ms")
            state = .idle
        }
    }

    /// RMS of channel 0, for the silence gate. Handles both Int16 and Float32 capture, because the
    /// built-in mic and a Bluetooth mic differ here -- assuming one would make the gate a no-op on
    /// the other.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let data = buffer.int16ChannelData {
            return WaveformMath.rms(int16: UnsafeBufferPointer(start: data[0], count: frames))
        }
        if let data = buffer.floatChannelData {
            var sum: Double = 0
            for i in 0..<frames { sum += Double(data[0][i]) * Double(data[0][i]) }
            return Float((sum / Double(frames)).squareRoot())
        }
        return 0
    }
}
