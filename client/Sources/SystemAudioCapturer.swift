@preconcurrency import AVFoundation
import CoreAudio

/// System audio capturer (B3.2)
///
/// Captures system audio output using a **Core Audio process tap** (macOS 14.4+) plus a private
/// aggregate device — NOT ScreenCaptureKit. This means it needs only the narrow "System Audio
/// Recording" consent (NSAudioCaptureUsageDescription / kTCCServiceAudioCapture, the purple dot),
/// not the full Screen Recording permission.
///
/// Typical scenario: recording the other party's voice in apps like Zoom during meeting mode.
///
/// BetterVoice2 is an offline/batch pipeline (no live SpeechAnalyzer feed): this capturer only
/// writes the tapped audio to a WAV file, which a later import step hands to `ImportPipeline`.
///
/// Calling `start()` is what triggers the macOS "System Audio Recording" TCC prompt on first
/// use — there is no separate request call.
///
/// Notes:
/// - The tap excludes the current process so Better Voice's own output isn't recorded.
final class SystemAudioCapturer: NSObject, @unchecked Sendable {

    enum CaptureError: Error {
        case alreadyCapturing
        case tapCreateFailed(OSStatus)
        case noTapFormat(OSStatus)
        case aggregateCreateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
    }

    private let audioFileURL: URL

    /// Reports a normalized (0...1) amplitude for each captured buffer; a later task drives a
    /// recording indicator with it. Invoked on the main queue (hopped off the IO queue), so a
    /// slow closure can't back up the capture queue and drop frames. `@Sendable` because it's
    /// dispatched across queues (matches `VoiceSession`'s convention).
    var onAudioLevel: (@Sendable (Float) -> Void)?

    // WAV writing (shared implementation)
    private lazy var wavWriter = PCMWavWriter(url: audioFileURL, logLabel: "SysAudio WAV saved")

    // Core Audio tap state
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    private let sampleQueue = DispatchQueue(label: "com.drkpxl.bettervoice2.system-audio")
    private var bufferCount = 0

    /// Guards `start()`/`stop()`/`close()` against misordered or re-entrant calls. `start()`
    /// flips it true only after fully creating the tap+aggregate+IOProc; `stop()`/`close()`
    /// flip it false. Mutated under `stateLock` so a second `start()` can't race in and orphan
    /// the first tap+aggregate+IOProc for the process lifetime.
    private let stateLock = NSLock()
    private var isCapturing = false

    /// - Parameter audioFileURL: destination for the captured audio; the `.wav` extension is
    ///   enforced regardless of what's passed (e.g. `meeting.m4a` → `meeting.wav`).
    init(audioFileURL: URL) {
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        super.init()
    }

    /// Creates the process tap + aggregate device and starts the IO proc.
    /// Starting the tap is what triggers the system-audio TCC prompt on first use.
    ///
    /// IMPORTANT — a thrown error does NOT detect permission denial. There is no public API to
    /// query or request the "System Audio Recording" consent. If the user has denied it, the tap,
    /// aggregate device, and IO proc still all return `noErr` and `start()` succeeds — the tap
    /// simply delivers *silence*. So a caller wiring up Start-Meeting/permission flow cannot rely
    /// on a throw to know it was denied; it must detect silence after the fact (and/or do a
    /// best-effort preflight + prompt-and-verify) rather than trusting a clean `start()`.
    ///
    /// Throws `CaptureError.alreadyCapturing` if called again before `stop()`/`close()`.
    func start() async throws {
        let canStart = stateLock.withLock { () -> Bool in
            if isCapturing { return false }
            isCapturing = true
            return true
        }
        guard canStart else { throw CaptureError.alreadyCapturing }

        // If any step below fails (throws), roll the guard back so a later retry isn't blocked.
        // The throw paths themselves handle Core Audio teardown (destroy tap / cleanupCoreAudio()).
        var started = false
        defer { if !started { setCapturing(false) } }

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

        started = true
        Logger.log("Meeting", "SystemAudioCapturer started (Core Audio tap, excludedProcesses=\(excluded.count), fmt=\(format))")
    }

    /// Stops capture + finalizes WAV. No-op if not currently capturing.
    func stop() async {
        let wasCapturing = stateLock.withLock { () -> Bool in
            if isCapturing { isCapturing = false; return true }
            return false
        }
        guard wasCapturing else { return }

        cleanupCoreAudio()
        // Finalize ON the IO queue so it's ordered strictly after any write() the IO proc may
        // still be executing — AudioDeviceStop doesn't guarantee an in-flight IO block returned.
        sampleQueue.sync { wavWriter.finalize() }
        Logger.log("Meeting", "SystemAudioCapturer stopped, bufferCount=\(bufferCount)")
    }

    /// Tears down any live tap/aggregate/IOProc and finalizes the WAV. Idempotent; safe to call
    /// after `stop()`. Unlike the previous version this also runs `cleanupCoreAudio()` so a
    /// `close()` following a successful `start()` doesn't leak the tap+aggregate+IOProc.
    func close() {
        stateLock.withLock { isCapturing = false }

        cleanupCoreAudio()  // idempotent
        sampleQueue.sync { wavWriter.finalize() }  // ordered after any in-flight write()
    }

    /// Sets the capturing flag under the lock (used by `start()`'s rollback `defer`).
    private func setCapturing(_ value: Bool) {
        stateLock.withLock { isCapturing = value }
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

        // Deep-copy so the buffer outlives the IO callback.
        let srcABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: view.audioBufferList))
        let dstABL = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for i in 0..<min(srcABL.count, dstABL.count) {
            if let src = srcABL[i].mData, let dst = dstABL[i].mData {
                memcpy(dst, src, Int(srcABL[i].mDataByteSize))
            }
        }

        process(pcmBuffer: owned)
    }

    /// Shared downstream pipeline: write WAV and report the amplitude level.
    private func process(pcmBuffer: AVAudioPCMBuffer) {
        bufferCount += 1
        if bufferCount <= 3 {
            Logger.log("Meeting", "SysAudio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // Compute the level inline (cheap) on this IO queue, but hop the CALLBACK to the main
        // queue: a slow future closure must not back up the serial capture queue and drop frames.
        if let onAudioLevel, let level = Self.rmsLevel(of: pcmBuffer) {
            DispatchQueue.main.async { onAudioLevel(level) }
        }

        // Write WAV (raw system stream; diarized offline from this file at import — one half of
        // the two-file meeting capture, see `MicCapturer`'s doc comment for the other half).
        wavWriter.write(buffer: pcmBuffer)
    }

    /// Normalized (0...1) RMS amplitude of a buffer's channel 0, for float or int16 PCM.
    ///
    /// Core Audio process taps deliver INTERLEAVED Float32, so channel-0 samples are strided:
    /// `channelData[0][i * buffer.stride]`, where `stride == channelCount` for interleaved data
    /// (and 1 for deinterleaved). Reading contiguously (stride 1) would mix channels together and,
    /// for stereo, only cover the first half of the time window. We iterate by `buffer.stride` so
    /// the level reflects channel 0 across the whole buffer regardless of layout.
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let stride = buffer.stride

        if let channelData = buffer.floatChannelData {
            let ptr = channelData[0]
            var sumSquares: Double = 0
            for i in 0..<frameCount {
                let s = Double(ptr[i * stride])
                sumSquares += s * s
            }
            return Float((sumSquares / Double(frameCount)).squareRoot())
        }
        if let channelData = buffer.int16ChannelData {
            let ptr = channelData[0]
            var sumSquares: Double = 0
            for i in 0..<frameCount {
                let v = Double(ptr[i * stride]) / 32768.0
                sumSquares += v * v
            }
            return Float((sumSquares / Double(frameCount)).squareRoot())
        }
        return nil
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
