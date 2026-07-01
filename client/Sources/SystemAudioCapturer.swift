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
/// - Pushes 16kHz Float32 mono samples to onDiarizationSamples (consumed by diarization)
/// - Writes a WAV file (persisted audio)
///
/// Notes:
/// - The tap excludes the current process so Better Voice's own output isn't recorded.
/// - Current version does not mix with the mic (handled separately in B4 via AudioMixer).
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
    private let diarizationSampleRate: Int
    private let onDiarizationSamples: @Sendable ([Float]) -> Void
    private let mixer: AudioMixer?

    // Format conversion
    private var analyzerConverter: AVAudioConverter?
    private var diarizationConverter: AVAudioConverter?

    // Separate target format: 16kHz Float32 mono
    private lazy var diarizationFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(diarizationSampleRate),
            channels: 1,
            interleaved: false
        )
    }()

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
        audioFileURL: URL,
        diarizationSampleRate: Int,
        onDiarizationSamples: @escaping @Sendable ([Float]) -> Void,
        mixer: AudioMixer? = nil
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        self.diarizationSampleRate = diarizationSampleRate
        self.onDiarizationSamples = onDiarizationSamples
        self.mixer = mixer
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

        // 3. Build a private aggregate device that includes the tap (and the default output
        //    device as the clock source, so playback continues normally while we tap it).
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
        if let outputUID = Self.defaultOutputDeviceUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var newAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggID)
        guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CaptureError.aggregateCreateFailed(aggStatus)
        }
        aggregateDeviceID = newAggID

        // The tap advertises its nominal format (`kAudioTapPropertyFormat`, e.g. 48kHz), but the IO
        // proc is clocked by the aggregate's main sub-device — the default OUTPUT device. When that's
        // a Bluetooth headset in hands-free (SCO) mode (AirPods on a call), the real rate drops to
        // ~24kHz, so the tap delivers half the samples per second. Wrapping those buffers with the
        // tap's 48kHz format then "downsamples" data that was really 24kHz → captured system audio
        // plays back 2× too fast, which wrecks transcription and diarization.
        //
        // The aggregate device's input stream format is exactly what the IO proc delivers, so it's
        // the authoritative wrap format — use it wholesale (rate + channels + interleave) when it
        // disagrees with the tap. Fall back to the tap's layout at the output device's nominal rate
        // only if the aggregate format is unavailable; otherwise leave the tap format untouched.
        let outRate = Self.defaultOutputDeviceSampleRate() ?? 0
        let aggFormat = Self.readDeviceInputFormat(aggregateDeviceID)
        if let aggFormat, abs(aggFormat.sampleRate - format.sampleRate) > 1 {
            Logger.log("Meeting", "System tap rate mismatch: tap=\(format.sampleRate)Hz → aggregate=\(aggFormat.sampleRate)Hz (out=\(outRate)) — using aggregate input format")
            tapFormat = aggFormat
        } else if outRate > 1, abs(outRate - format.sampleRate) > 1,
                  let corrected = AVAudioFormat(
                      commonFormat: format.commonFormat,
                      sampleRate: outRate,
                      channels: format.channelCount,
                      interleaved: format.isInterleaved) {
            Logger.log("Meeting", "System tap rate mismatch: tap=\(format.sampleRate)Hz → output=\(outRate)Hz (aggregate format unavailable) — correcting rate")
            tapFormat = corrected
        } else {
            Logger.log("Meeting", "System tap format: tap=\(format.sampleRate)Hz (agg=\(aggFormat?.sampleRate ?? 0) out=\(outRate), no correction)")
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

        // Feed SpeechAnalyzer (in B4 mixing mode, the mixer yields uniformly instead)
        if mixer == nil {
            let input = AnalyzerInput(buffer: analyzerBuffer)
            inputBuilder.yield(input)
        }

        // Write WAV (raw system stream, kept even in mixing mode)
        wavWriter.write(buffer: analyzerBuffer)

        // --- Branch 2: 16kHz Float32 mono samples → mixer or diarization ---
        if let diaFmt = diarizationFormat {
            let diaBuffer: AVAudioPCMBuffer
            if pcmBuffer.format.sampleRate != diaFmt.sampleRate
                || pcmBuffer.format.commonFormat != diaFmt.commonFormat
                || pcmBuffer.format.channelCount != diaFmt.channelCount {
                if diarizationConverter == nil {
                    diarizationConverter = AVAudioConverter(from: pcmBuffer.format, to: diaFmt)
                    Logger.log("Meeting", "SysAudio diarization converter: \(pcmBuffer.format) → \(diaFmt)")
                }
                guard let converter = diarizationConverter,
                      let converted = convertPCM(buffer: pcmBuffer, using: converter, to: diaFmt) else {
                    return
                }
                diaBuffer = converted
            } else {
                diaBuffer = pcmBuffer
            }

            if let floatData = diaBuffer.floatChannelData {
                let frameCount = Int(diaBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                if let mixer {
                    mixer.feedSystem(samples)
                } else {
                    onDiarizationSamples(samples)
                }
            }
        }
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

    /// Default output device nominal sample rate — fallback for the true delivery rate when the
    /// aggregate's input format is unavailable (also logged for SCO/A2DP visibility).
    private static func defaultOutputDeviceSampleRate() -> Double? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var rate = Double(0)
        var rateSize = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private static func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
