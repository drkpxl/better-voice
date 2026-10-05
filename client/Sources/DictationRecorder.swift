import AVFoundation
import Foundation

/// Captures a dictation into memory and hands back one buffer.
///
/// Dictation never writes audio to disk. Parakeet's `AsrManager` accepts an `AVAudioPCMBuffer`
/// directly (and resamples it internally), so a WAV would be pure overhead — a file written, read
/// back, and deleted seconds later, with a lifecycle to get wrong and speech on disk in the
/// meantime. Meetings still write one, because diarization genuinely needs the file.
///
/// Memory is bounded by how long someone holds a hotkey. Capture is typically 48 kHz float32 mono,
/// so ~192 KB per second: a 30-second dictation is ~6 MB and a 5-minute one ~58 MB. That is fine for
/// dictation and would not be for a meeting, which is the other reason meetings keep the file path —
/// `transcribe(url:)` routes to FluidAudio's disk-backed chunking above ~30s, and the in-memory
/// overload has no such fallback.
@MainActor
final class DictationRecorder {

    private let capturer: MicCapturer
    /// Accumulated buffers in arrival order. Written from the capture queue, read only after `stop()`
    /// has torn the session down, so the lock covers the whole overlap.
    private let collected = BufferBox()

    var onAudioLevel: ((Float) -> Void)?

    init() {
        // nil destination: capture to memory, write nothing.
        capturer = MicCapturer(audioFileURL: nil)
    }

    func start() async throws {
        collected.reset()
        capturer.onAudioLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.onAudioLevel?(level) }
        }
        capturer.onPCMBuffer = { [collected] buffer in collected.append(buffer) }
        try await capturer.start()
    }

    /// Stops capture and returns everything captured as one buffer, or nil if nothing was.
    ///
    /// `capturer.stop()` synchronises on the capture queue before returning, so no buffer can still
    /// be arriving when the concatenation below reads the collection.
    func stop() async -> AVAudioPCMBuffer? {
        await capturer.stop()
        capturer.onPCMBuffer = nil
        capturer.onAudioLevel = nil
        return Self.concatenate(collected.drain())
    }

    /// How many buffers have been captured so far.
    var capturedBufferCount: Int { collected.count }

    /// The most recent `maxSeconds` of audio captured so far, as one buffer, without disturbing
    /// the recording — the live preview's input. Nil before the first buffer arrives.
    func snapshotTail(maxSeconds: TimeInterval) -> AVAudioPCMBuffer? {
        let all = collected.snapshot()
        guard let rate = all.first?.format.sampleRate, rate > 0 else { return nil }
        let budget = AVAudioFrameCount(maxSeconds * rate)
        var tail: [AVAudioPCMBuffer] = []
        var frames: AVAudioFrameCount = 0
        for buffer in all.reversed() {
            tail.append(buffer)
            frames += buffer.frameLength
            if frames >= budget { break }
        }
        return Self.concatenate(tail.reversed())
    }

    /// Synchronous teardown for the app-quitting path.
    func close() {
        capturer.close()
        capturer.onPCMBuffer = nil
        capturer.onAudioLevel = nil
        collected.reset()
    }

    /// Splice buffers into one. Returns nil for an empty input, or if the buffers disagree about
    /// format — concatenating mismatched formats would produce plausible-looking garbage rather than
    /// an error, and a mid-recording format change means the capture was not what we think it was.
    private static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        guard buffers.allSatisfy({ $0.format == format }) else {
            Logger.log("Voice", "Capture format changed mid-recording; discarding \(buffers.count) buffers")
            return nil
        }

        let totalFrames = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalFrames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }
        out.frameLength = 0

        for buffer in buffers {
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { continue }
            let destOffset = Int(out.frameLength)
            let channels = Int(format.channelCount)

            if let src = buffer.floatChannelData, let dst = out.floatChannelData {
                for ch in 0..<channels {
                    dst[ch].advanced(by: destOffset).update(from: src[ch], count: frames)
                }
            } else if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
                for ch in 0..<channels {
                    dst[ch].advanced(by: destOffset).update(from: src[ch], count: frames)
                }
            } else if let src = buffer.int32ChannelData, let dst = out.int32ChannelData {
                for ch in 0..<channels {
                    dst[ch].advanced(by: destOffset).update(from: src[ch], count: frames)
                }
            } else {
                // An unhandled sample format would otherwise silently contribute silence, which
                // reads downstream as "the user said nothing" rather than "we could not copy this".
                Logger.log("Voice", "Unsupported capture sample format: \(format)")
                return nil
            }
            out.frameLength += buffer.frameLength
        }
        return out
    }
}

/// Lock-guarded buffer collection. The capture queue appends; the main actor drains after teardown.
/// A plain array would be a data race across those two, and `AVAudioPCMBuffer` is not `Sendable`, so
/// the box is `@unchecked` with the lock as the justification.
private final class BufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { buffers.append(buffer) }
    }

    /// A copy of the collection so far (the buffers themselves are shared, and never mutated
    /// after capture hands them over).
    func snapshot() -> [AVAudioPCMBuffer] {
        lock.withLock { buffers }
    }

    var count: Int { lock.withLock { buffers.count } }

    func drain() -> [AVAudioPCMBuffer] {
        lock.withLock {
            let out = buffers
            buffers = []
            return out
        }
    }

    func reset() {
        lock.withLock { buffers = [] }
    }
}
