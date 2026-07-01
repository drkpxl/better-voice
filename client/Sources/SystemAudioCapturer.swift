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

    // WAV writing
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?

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
        finalizeWAV()
        Logger.log("Meeting", "SystemAudioCapturer stopped, bufferCount=\(bufferCount)")
    }

    func close() {
        finalizeWAV()
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
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
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
        writeToWAV(buffer: analyzerBuffer)

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
                      let converted = convert(buffer: pcmBuffer, using: converter, to: diaFmt) else {
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

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

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

    // MARK: - WAV writing (isomorphic to MeetingCaptureDelegate)

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            fileHandle?.write(Data(count: 44))
            wavDataSize = 0
        }

        let abl = buffer.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return }
        let byteCount = Int(abl.mBuffers.mDataByteSize)
        let data = Data(bytes: mData, count: byteCount)
        fileHandle?.write(data)
        wavDataSize += UInt32(byteCount)
    }

    private func finalizeWAV() {
        guard let fh = fileHandle, let fmt = wavFormat else {
            fileHandle = nil
            return
        }

        let asbd = fmt.streamDescription.pointee
        let numChannels = UInt16(asbd.mChannelsPerFrame)
        let sampleRate = UInt32(asbd.mSampleRate)
        let bitsPerSample = UInt16(asbd.mBitsPerChannel)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.appendSysLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendSysLE(UInt32(16))
        header.appendSysLE(UInt16(1))
        header.appendSysLE(numChannels)
        header.appendSysLE(sampleRate)
        header.appendSysLE(byteRate)
        header.appendSysLE(blockAlign)
        header.appendSysLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendSysLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Meeting", "SysAudio WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - Format conversion (isomorphic to MeetingCaptureDelegate)

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let consumed = Box(false)
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return buffer
        }

        return (error == nil && output.frameLength > 0) ? output : nil
    }
}

// MARK: - Data little-endian helpers (distinct naming to avoid conflicts)

private extension Data {
    mutating func appendSysLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendSysLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
