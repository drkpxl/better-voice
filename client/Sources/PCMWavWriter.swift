@preconcurrency import AVFoundation
import BetterVoiceCore

/// Streams PCM frames to a `.wav` file, patching the 44-byte header on `finalize()`.
///
/// Single implementation shared by `SystemAudioCapturer` and `MeetingCaptureDelegate`,
/// which previously carried byte-for-byte copies of this logic. Opens lazily on the first
/// `write(_:)` (capturing the audio format), streams frames buffered in memory and flushed
/// roughly once per second (instead of a syscall per callback), then seeks to 0 and writes
/// the real header via `makeWavHeader` once the total data size is known.
///
/// Not thread-safe: callers invoke `write`/`finalize` serially from a single capture queue,
/// matching the previous per-class behavior.
final class PCMWavWriter {
    private let url: URL
    private let logLabel: String

    private var fileHandle: FileHandle?
    private var format: AVAudioFormat?
    private var dataSize: UInt32 = 0
    private var pending = Data()
    private var flushThreshold = 0   // bytes ≈ 1s of audio; set when the format is known

    init(url: URL, logLabel: String) {
        self.url = url
        self.logLabel = logLabel
    }

    /// Append a buffer's PCM bytes. Opens the file on first call.
    func write(buffer: AVAudioPCMBuffer) {
        if fileHandle == nil {
            format = buffer.format
            let asbd = buffer.format.streamDescription.pointee
            flushThreshold = Int(asbd.mSampleRate) * Int(asbd.mBytesPerFrame)  // ~1s
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: url)
            fileHandle?.write(Data(count: 44))  // header placeholder, patched in finalize()
            dataSize = 0
        }

        let abl = buffer.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return }
        let byteCount = Int(abl.mBuffers.mDataByteSize)
        pending.append(Data(bytes: mData, count: byteCount))
        dataSize += UInt32(byteCount)

        if pending.count >= flushThreshold {
            flushPending()
        }
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        fileHandle?.write(pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// Flush remaining bytes and overwrite the placeholder with the real header. Idempotent.
    func finalize() {
        guard let fh = fileHandle, let fmt = format else {
            fileHandle = nil
            return
        }
        flushPending()

        let asbd = fmt.streamDescription.pointee
        let header = makeWavHeader(
            sampleRate: UInt32(asbd.mSampleRate),
            channels: UInt16(asbd.mChannelsPerFrame),
            bitsPerSample: UInt16(asbd.mBitsPerChannel),
            dataSize: dataSize
        )

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Meeting", "\(logLabel): \(url.lastPathComponent) (\(dataSize) bytes)")
    }
}
