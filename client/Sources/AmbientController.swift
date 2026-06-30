import CoreAudio
import Foundation

/// G1: voice gating -- ambient mode
/// Uses CoreAudio HAL VAD (hardware-level voice activity detection) instead of manual hotkey triggering
/// When speech start is detected -> recording starts automatically; when speech ends + settle delay elapses -> recording stops automatically
///
/// Not mutually exclusive with hotkey mode: the hotkey still works while ambient mode is on (manual override)
@MainActor
final class AmbientController {
    static let shared = AmbientController()

    private(set) var isEnabled = false
    private var deviceID: AudioDeviceID = 0
    private var isSpeaking = false
    private var settleWork: DispatchWorkItem?

    /// Settle delay after speech ends (prevents a mid-sentence pause from being misread as the end)
    var settleDelay: TimeInterval = 0.8

    /// Minimum speech duration (filters out coughs/noise)
    var minimumDuration: TimeInterval = 0.5
    private var speechStartTime: Date?

    /// Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    func start() {
        guard !isEnabled else { return }

        // Get the default input device
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &size, &devID
        )
        guard status == noErr, devID != 0 else {
            Logger.log("Ambient", "Failed to get default input device: \(status)")
            return
        }
        self.deviceID = devID

        // Enable HAL VAD
        var enable: UInt32 = 1
        var vadEnableAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let enableStatus = AudioObjectSetPropertyData(
            devID, &vadEnableAddr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &enable
        )
        guard enableStatus == noErr else {
            Logger.log("Ambient", "HAL VAD not supported on this device: \(enableStatus)")
            return
        }

        // Listen for VAD state changes
        var vadStateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerStatus = AudioObjectAddPropertyListenerBlock(
            devID, &vadStateAddr,
            DispatchQueue.global(qos: .userInteractive)
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleVADChange()
            }
        }

        guard listenerStatus == noErr else {
            Logger.log("Ambient", "Failed to add VAD listener: \(listenerStatus)")
            return
        }

        isEnabled = true
        Logger.log("Ambient", "HAL VAD enabled (device=\(devID), settle=\(settleDelay)s)")
    }

    func stop() {
        guard isEnabled else { return }

        // Disable VAD
        var disable: UInt32 = 0
        var vadEnableAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            deviceID, &vadEnableAddr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &disable
        )

        settleWork?.cancel()
        settleWork = nil
        isSpeaking = false
        isEnabled = false
        Logger.log("Ambient", "HAL VAD disabled")
    }

    // MARK: - VAD state changes

    private func handleVADChange() {
        var state: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &state)

        let speaking = state != 0

        if speaking && !isSpeaking {
            // Speech started
            isSpeaking = true
            speechStartTime = Date()
            settleWork?.cancel()
            Logger.log("Ambient", "Voice detected")
            onSpeechStart?()

        } else if !speaking && isSpeaking {
            // Speech may have ended -- start the settle delay
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isSpeaking else { return }
                self.isSpeaking = false

                // Check the minimum duration
                if let start = self.speechStartTime,
                   Date().timeIntervalSince(start) < self.minimumDuration {
                    Logger.log("Ambient", "Too short, ignored")
                    return
                }

                Logger.log("Ambient", "Voice ended (after \(self.settleDelay)s settle)")
                self.onSpeechEnd?()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
        }
    }
}
