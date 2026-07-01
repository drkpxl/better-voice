import Foundation
import BetterVoiceCore

/// Incrementally runs VAD on the mic channel in fixed chunks so the raw mic buffer never grows to
/// the whole meeting. Synchronous + NSLock-guarded (VAD is cheap CPU, no model). Fed off the audio
/// thread via add(); finish() returns the merged global speech intervals at stop().
///
/// Concurrency model: `@unchecked Sendable` with ALL mutable state (`pending`, `processedSamples`,
/// `out`) guarded by a single private `NSLock`. This matches AudioMixer's established pattern for
/// lock-guarded audio state and stays strict-concurrency-clean. VAD (`detectSpeechIntervals`) is a
/// pure, model-free function that runs in ~microseconds for 60s of audio, so running it under the
/// lock in `add(_:)` is fine.
final class MicVoiceActivityChunker: @unchecked Sendable {

    private let sampleRate: Int
    private let chunkSize: Int

    private let lock = NSLock()
    private var pending: [Float] = []
    private var processedSamples: Int = 0
    private var out: [SpeechInterval] = []

    /// Same hangover default as `detectSpeechIntervals`'s `minSilenceSec`; used to stitch runs
    /// split at chunk boundaries back together in `finish()`.
    private static let boundaryMergeMinSilenceSec: TimeInterval = 0.20

    init(sampleRate: Int, chunkSeconds: Double = 60) {
        self.sampleRate = sampleRate
        self.chunkSize = Int(chunkSeconds * Double(sampleRate))
    }

    /// Feed mic samples (called off the main thread). Runs VAD on any complete chunks and discards them.
    func add(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: samples)
        while pending.count >= chunkSize {
            let chunk = Array(pending[0..<chunkSize])
            pending.removeFirst(chunkSize)  // discard processed samples → bounds memory
            let offset = Double(processedSamples) / Double(sampleRate)
            let speech = detectSpeechIntervals(samples: chunk, sampleRate: sampleRate)
            out.append(contentsOf: speech.map {
                SpeechInterval(start: $0.start + offset, end: $0.end + offset)
            })
            processedSamples += chunkSize
        }
    }

    /// Flush the tail, return all speech intervals (global times), boundary-merged.
    func finish() -> [SpeechInterval] {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            let offset = Double(processedSamples) / Double(sampleRate)
            let speech = detectSpeechIntervals(samples: pending, sampleRate: sampleRate)
            out.append(contentsOf: speech.map {
                SpeechInterval(start: $0.start + offset, end: $0.end + offset)
            })
            processedSamples += pending.count
            pending.removeAll()
        }
        return mergeAdjacentSpeechIntervals(out, minSilenceSec: Self.boundaryMergeMinSilenceSec)
    }
}
