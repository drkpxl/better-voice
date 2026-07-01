import Foundation
import BetterVoiceCore

/// Incrementally runs VAD on the mic channel in fixed chunks so the raw mic buffer never grows to
/// the whole meeting. Synchronous + NSLock-guarded (VAD is cheap CPU, no model). Fed off the audio
/// thread via add(); finish() returns the merged global speech intervals at stop().
///
/// Concurrency model: `@unchecked Sendable` with ALL mutable state (`pending`, `processedSamples`,
/// `accumulatedIntervals`) guarded by a single private `NSLock`. This matches AudioMixer's
/// established pattern for lock-guarded audio state and stays strict-concurrency-clean. VAD
/// (`detectSpeechIntervals`) is a pure, model-free function that runs in ~microseconds for 60s of
/// audio, so running it under the lock in `add(_:)` is fine.
///
/// This is the *streaming* counterpart of Core's `detectSpeechIntervalsChunked`: this class keeps
/// the incremental `add()`/`removeFirst` mechanism for bounded memory, but the per-chunk global
/// offset and boundary-merge math is the same (tested via the pure Core function). Two accepted
/// boundary behaviors follow from that shared math:
///   (a) `minSpeechSec` is applied per chunk before the global merge, so a sub-`minSpeechSec` run
///       split exactly on a chunk boundary can be dropped — accepted as boundary-local (full-length
///       runs split at a boundary are still stitched by the merge).
///   (b) The noise floor is estimated per chunk (local adaptation to room-tone drift over a long
///       meeting), not once globally.
final class MicVoiceActivityChunker: @unchecked Sendable {

    private let sampleRate: Int
    private let chunkSize: Int

    private let lock = NSLock()
    private var pending: [Float] = []
    private var processedSamples: Int = 0
    private var accumulatedIntervals: [SpeechInterval] = []

    /// Same hangover default as `detectSpeechIntervals`'s `minSilenceSec`; used to stitch runs
    /// split at chunk boundaries back together in `finish()`.
    private static let boundaryMergeMinSilenceSec: TimeInterval = 0.20

    init(sampleRate: Int, chunkSeconds: Double = 60) {
        self.sampleRate = sampleRate
        self.chunkSize = Int(chunkSeconds * Double(sampleRate))
    }

    /// Run VAD on `chunk` and append its intervals shifted into global time. Caller holds the lock.
    private func processChunk(_ chunk: [Float]) {
        let offset = Double(processedSamples) / Double(sampleRate)
        let speech = detectSpeechIntervals(samples: chunk, sampleRate: sampleRate)
        accumulatedIntervals.append(contentsOf: speech.map {
            SpeechInterval(start: $0.start + offset, end: $0.end + offset)
        })
        processedSamples += chunk.count
    }

    /// Feed mic samples (called off the main thread). Runs VAD on any complete chunks and discards them.
    func add(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: samples)
        while pending.count >= chunkSize {
            let chunk = Array(pending[0..<chunkSize])
            pending.removeFirst(chunkSize)  // discard processed samples → bounds memory
            processChunk(chunk)
        }
    }

    /// Flush the tail, return all speech intervals (global times), boundary-merged.
    func finish() -> [SpeechInterval] {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            processChunk(pending)
            pending.removeAll()
        }
        return mergeAdjacentSpeechIntervals(accumulatedIntervals, minSilenceSec: Self.boundaryMergeMinSilenceSec)
    }
}
