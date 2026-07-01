@preconcurrency import AVFoundation
import CoreAudio
import Speech

/// System audio capturer (B3.2)
///
/// Captures system audio output using a **Core Audio process tap** (macOS 14.4+) plus a private
/// aggregate device — NOT ScreenCaptureKit. This means it needs only the narrow "System Audio
/// Recording" consent (NSAudioCaptureUsageDescription / kTCCServiceAudioCapture, the purple dot),
/// not the full Screen Recording permission.
///
/// Typical scenario: recording the other party's voice in apps like Zoom during meeting mode.
///
/// External interface aligns with MeetingCaptureDelegate:
/// - Yields PCM samples to inputBuilder (consumed by SpeechAnalyzer)
/// - Writes a WAV file (persisted audio; diarized offline at stop)
///
/// Notes:
/// - The tap excludes the current process so Better Voice's own output isn't recorded.
/// - In `both` mode this is the system/remote channel: it feeds the live analyzer; the mic
///   is a separate channel transcribed offline at stop (no mixing).
final class SystemAudioCapturer: NSObject, @unchecked Sendable {

    enum CaptureError: Error {
        case tapCreateFailed(OSStatus)
        case noTapFormat(OSStatus)
        case aggregateCreateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
    }

    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL

    // Format conversion
    private var analyzerConverter: AVAudioConverter?

    // WAV writing (shared implementation)
    private lazy var wavWriter = PCMWavWriter(url: audioFileURL, logLabel: "SysAudio WAV saved")

    // Core Audio tap state
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    private let sampleQueue = DispatchQueue(label: "com.antigravity.we.system-audio")
    private var bufferCount = 0

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat?,
        audioFileURL: URL
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        super.init()
    }

    /// Creates the process tap + aggregate device and starts the IO proc.
    /// Starting the tap is what triggers the system-audio TCC prompt on first use.
    func start() async throws {
        // 1. Tap all system audio, excluding our own process so we don't record ourselves.
        let excluded = Self.excludedProcessObjects()
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.name = "BetterVoice System Audio"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw CaptureError.tapCreateFailed(tapStatus)
        }
        tapID = newTapID

        // 2. Read the tap's audio format so we can wrap its buffers.
        guard let format = Self.readTapFormat(tapID) else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CaptureError.noTapFormat(kAudio_ParamError)
        }
        tapFormat = format

        // 3. Build a private aggregate device that includes the tap. Its main sub-device is the
        //    *clock* for the IO proc — the tap itself captures all system audio regardless of which
        //    device that is. We normally anchor to the default output device so the clock matches
        //    playback. BUT when the default output is a Bluetooth device that's ALSO the mic (AirPods
        //    used for both), macOS switches it to hands-free SCO, and pulling that same SCO endpoint
        //    into our capture aggregate contends with the system's duplex link — playback to the
        //    user's ears cuts out entirely. So when the output is Bluetooth we anchor the clock to a
        //    built-in output instead: the AirPods stay free for normal SCO playback, and we get a
        //    rock-solid 48kHz clock (which also structurally avoids the SCO 2× speed bug).
        let aggregateUID = UUID().uuidString
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BetterVoice-SystemTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString
            ]]
        ]
        if let clockUID = Self.aggregateClockDeviceUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
        }

        var newAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggID)
        guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CaptureError.aggregateCreateFailed(aggStatus)
        }
        aggregateDeviceID = newAggID

        // The tap advertises a nominal format (`kAudioTapPropertyFormat`, e.g. 48kHz), but the IO proc
        // delivers at whatever rate the aggregate's clock actually runs at. Guessing that rate from
        // device properties is fragile — it produced 2× fast on SCO output, then 2× slow once we moved
        // the clock to built-in — because the device we'd guess from (default output) isn't necessarily
        // the clock. Instead, read the aggregate's OWN input stream format: that is exactly what the IO
        // proc hands us, correct for any device/clock/SCO state. Always wrap with it; only if the read
        // fails do we leave the tap's nominal format. No per-device rate heuristics.
        if let aggFormat = Self.readDeviceInputFormat(aggregateDeviceID) {
            let changed = abs(aggFormat.sampleRate - format.sampleRate) > 1 || aggFormat.channelCount != format.channelCount
            Logger.log("Meeting", "System tap wrap: tap=\(format.sampleRate)Hz/\(format.channelCount)ch → delivered=\(aggFormat.sampleRate)Hz/\(aggFormat.channelCount)ch\(changed ? " (authoritative)" : " (matches)")")
            tapFormat = aggFormat
        } else {
            Logger.log("Meeting", "System tap wrap: aggregate input format unavailable — using tap nominal \(format.sampleRate)Hz")
        }

        // 4. Install the IO proc that receives tapped audio.
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            self?.handleTapInput(inInputData)
        }
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, sampleQueue, ioBlock)
        guard procStatus == noErr, let procID = newProcID else {
            cleanupCoreAudio()
            throw CaptureError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            cleanupCoreAudio()
            throw CaptureError.startFailed(startStatus)
        }

        Logger.log("Meeting", "SystemAudioCapturer started (Core Audio tap, excludedProcesses=\(excluded.count), fmt=\(format))")
    }

    /// Stops capture + finalizes WAV
    func stop() async {
        cleanupCoreAudio()
        wavWriter.finalize()
        Logger.log("Meeting", "SystemAudioCapturer stopped, bufferCount=\(bufferCount)")
    }

    func close() {
        wavWriter.finalize()
    }

    private func cleanupCoreAudio() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Tap input handling

    /// Wraps the tap's AudioBufferList into an owned PCM buffer and runs the shared pipeline.
    private func handleTapInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              let view = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData),
              view.frameLength > 0,
              let owned = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: view.frameLength) else { return }
        owned.frameLength = view.frameLength

        // Deep-copy so the buffer outlives the IO callback (inputBuilder may retain it).
        let srcABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: view.audioBufferList))
        let dstABL = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for i in 0..<min(srcABL.count, dstABL.count) {
            if let src = srcABL[i].mData, let dst = dstABL[i].mData {
                memcpy(dst, src, Int(srcABL[i].mDataByteSize))
            }
        }

        process(pcmBuffer: owned)
    }

    /// Shared downstream pipeline: feed SpeechAnalyzer, write WAV, and emit 16kHz mono for diarization.
    private func process(pcmBuffer: AVAudioPCMBuffer) {
        bufferCount += 1
        if bufferCount <= 3 {
            Logger.log("Meeting", "SysAudio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // --- Branch 1: feed SpeechAnalyzer ---
        let analyzerBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat
            || pcmBuffer.format.channelCount != targetFormat.channelCount {
            if analyzerConverter == nil {
                analyzerConverter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Meeting", "SysAudio analyzer converter: \(pcmBuffer.format) → \(targetFormat)")
            }
            guard let converter = analyzerConverter,
                  let converted = convertPCM(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 3 { Logger.log("Meeting", "SysAudio #\(bufferCount): analyzer conversion failed") }
                return
            }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = pcmBuffer
        }

        // Feed SpeechAnalyzer (system channel → live transcript in both/system modes).
        let input = AnalyzerInput(buffer: analyzerBuffer)
        inputBuilder.yield(input)

        // Write WAV (raw system stream; diarized offline from this file at stop)
        wavWriter.write(buffer: analyzerBuffer)
    }

    // MARK: - Core Audio helpers

    /// The current process's audio object(s) to exclude from a global tap (so we don't record ourselves).
    private static func excludedProcessObjects() -> [AudioObjectID] {
        let obj = processObject(for: ProcessInfo.processInfo.processIdentifier)
        return obj != kAudioObjectUnknown ? [obj] : []
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        return status == noErr ? objectID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func readTapFormat(_ tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// The aggregate device's actual input stream format (authoritative rate the IO proc delivers at,
    /// which reflects the output-device clock — unlike the tap's advertised nominal format).
    private static func readDeviceInputFormat(_ deviceID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// The current default output device's AudioObjectID (the tap's effective clock source).
    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The UID to use as the aggregate's clock/main sub-device. Normally the default output device
    /// (so the tap clock matches playback). But a Bluetooth output that's also the active mic gets
    /// switched to hands-free SCO, and wrapping that SCO endpoint in our capture aggregate cuts the
    /// user's playback out — so when the default output is Bluetooth we anchor to a built-in output
    /// instead (stable 48kHz, no SCO contention). Falls back to the default output when there's no
    /// built-in output to borrow.
    private static func aggregateClockDeviceUID() -> String? {
        guard let outID = defaultOutputDeviceID() else { return nil }
        if deviceTransportType(outID).map(isBluetoothTransport) == true,
           let builtIn = builtInOutputDeviceUID() {
            Logger.log("Meeting", "System tap: default output is Bluetooth — anchoring aggregate clock to built-in output to avoid SCO playback cutout")
            return builtIn
        }
        return deviceUID(outID)
    }

    private static func isBluetoothTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// A device's UID string.
    private static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    /// A device's transport type (e.g. built-in, Bluetooth, USB), or nil if unavailable.
    private static func deviceTransportType(_ deviceID: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private static func deviceHasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// UID of a built-in output device (stable, never SCO) to use as a safe aggregate clock; nil if none.
    private static func builtInOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return nil }
        for dev in devices where deviceTransportType(dev) == kAudioDeviceTransportTypeBuiltIn && deviceHasOutputStreams(dev) {
            return deviceUID(dev)
        }
        return nil
    }
}
