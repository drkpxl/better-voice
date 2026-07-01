import Foundation
import FluidAudio
import Synchronization

/// Incrementally diarizes system-channel audio in fixed chunks on a single background task,
/// bounding peak memory (only ~one chunk of samples is held at a time). Uses ONE reused
/// `DiarizerManager` so speaker IDs stay stable across chunks and embeddings are retained.
///
/// Concurrency model: the class stores only Sendable state — the AsyncStream + its
/// continuation, plain value config, and a `Mutex`-guarded consumer-task handle. The
/// non-Sendable `DiarizerManager`, plus the mutable `pending`/`out` accumulators, live
/// entirely INSIDE the single consumer task and never escape it, so the type is cleanly
/// `Sendable` with no `@unchecked`. `[Float]` chunks crossing via the stream are Sendable.
final class SystemDiarizationChunker: Sendable {

    private let stream: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let sampleRate: Int
    private let chunkSeconds: Double

    /// Deadline the caller applies to `finish()` (see `MeetingSession.finishTimeoutSec`).
    /// Exposed so the call site and the chunker agree on one value.
    let finishTimeoutSec: TimeInterval

    /// Handle to the single consumer task. Written once in `start()`, read once in `finish()`;
    /// `Mutex` makes it Sendable-safe without `@unchecked`.
    private let consumerTask = Mutex<Task<[TimedSpeakerSegment], Never>?>(nil)

    init(sampleRate: Int, chunkSeconds: Double = 60, finishTimeoutSec: TimeInterval = 120) {
        self.sampleRate = sampleRate
        self.chunkSeconds = chunkSeconds
        self.finishTimeoutSec = finishTimeoutSec
        // `.unbounded`: audio yielded via add(_:) before the consumer catches up (notably during
        // a first-run model download) accumulates rather than being dropped. We accept transient
        // growth over `.bufferingNewest`, which would discard samples and degrade diarization.
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
    }

    /// Begin consuming. Downloads models inside the consumer task, then diarizes chunks as they arrive.
    func start() {
        let stream = self.stream
        let sampleRate = self.sampleRate
        let chunkSize = Int(chunkSeconds * Double(sampleRate))
        let task = Task<[TimedSpeakerSegment], Never>(priority: .userInitiated) {
            await Self.consume(
                stream: stream,
                sampleRate: sampleRate,
                chunkSize: chunkSize
            )
        }
        // Guard against a double start() spawning a second consumer on the same (single-shot) stream.
        consumerTask.withLock {
            guard $0 == nil else {
                task.cancel()
                return
            }
            $0 = task
        }
    }

    /// Feed system samples (called off the main thread from the audio path). Ordered, non-blocking.
    func add(_ samples: [Float]) {
        continuation.yield(samples)
    }

    /// Finish: stop accepting input, flush the tail chunk, and return ALL accumulated segments
    /// (global-timed, stable ids). Safe to call once.
    func finish() async -> [TimedSpeakerSegment] {
        continuation.finish()
        guard let task = consumerTask.withLock({ $0 }) else { return [] }
        return await task.value
    }

    // MARK: - Consumer (runs entirely on one background task)

    /// Consume ordered sample batches from `stream`, diarizing fixed `chunkSize` chunks with a
    /// single reused `DiarizerManager` (created here, never escapes). Processed samples are
    /// discarded from `pending` as they are consumed, so peak retained audio is ~one chunk.
    private static func consume(
        stream: AsyncStream<[Float]>,
        sampleRate: Int,
        chunkSize: Int
    ) async -> [TimedSpeakerSegment] {
        // Models: if unavailable, diarization is simply skipped (the mic "me" timeline still
        // merges downstream). Drain the stream so `add(_:)` never blocks its caller.
        guard let models = try? await DiarizerModels.downloadIfNeeded() else {
            Logger.log("Meeting", "[Chunker] Diarization models unavailable; skipping system diarization")
            for await _ in stream {}
            return []
        }

        // DiarizerManager is NOT Sendable — created and used only here, confined to this task.
        let diarizer = DiarizerManager(config: DiarizerConfig())
        diarizer.initialize(models: models)
        Logger.log("Meeting", "[Chunker] Models ready; chunk=\(chunkSize) samples (~\(chunkSize / max(sampleRate, 1))s)")

        var pending: [Float] = []
        var processedSamples = 0
        var out: [TimedSpeakerSegment] = []
        var chunkIndex = 0

        // Diarize one chunk at the correct global offset and append its segments.
        //
        // Timeout note: `withThrowingTimeout`'s operation closure is `@Sendable`, but the
        // reused `diarizer` is non-Sendable and MUST stay confined to this task — capturing it
        // in a racing/detached child task would (a) not compile cleanly and (b) be genuinely
        // unsafe: a timed-out chunk's diarization would keep touching the shared diarizer
        // concurrently with the next chunk. So chunks are diarized sequentially with exclusive
        // access and no hard per-chunk timeout. This is safe by construction: the work runs on
        // this background task (never blocks the MainActor), and each call is bounded by the
        // fixed chunk size (~one chunk of audio), so `finish()` completes in bounded time.
        func diarizeChunk(_ samples: [Float], atOffsetSamples offset: Int) {
            let t = Double(offset) / Double(sampleRate)
            do {
                let result = try diarizer.performCompleteDiarization(samples, sampleRate: sampleRate, atTime: t)
                out.append(contentsOf: result.segments)
                Logger.log("Meeting", "[Chunker] chunk \(chunkIndex) @\(String(format: "%.1f", t))s → \(result.segments.count) segments")
            } catch {
                Logger.log("Meeting", "[Chunker] chunk \(chunkIndex) @\(String(format: "%.1f", t))s failed: \(error)")
            }
            chunkIndex += 1
        }

        for await batch in stream {
            pending.append(contentsOf: batch)
            while pending.count >= chunkSize {
                let c = Array(pending[0..<chunkSize])
                pending.removeFirst(chunkSize)  // discard processed samples → bounds memory
                let offset = processedSamples
                processedSamples += chunkSize
                diarizeChunk(c, atOffsetSamples: offset)
            }
        }

        // Flush the tail: diarize only if there is at least ~1s of audio; drop a sub-1s tail.
        if pending.count >= sampleRate {
            diarizeChunk(pending, atOffsetSamples: processedSamples)
        } else if !pending.isEmpty {
            Logger.log("Meeting", "[Chunker] Dropping sub-1s tail (\(pending.count) samples)")
        }
        pending.removeAll()

        Logger.log("Meeting", "[Chunker] Done: \(out.count) segments across \(chunkIndex) chunk(s)")
        return out
    }
}
