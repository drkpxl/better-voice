import Foundation
import FluidAudio

/// Owns the ONE `OfflineDiarizerManager` for the whole app run (roadmap §9).
///
/// The manager is non-Sendable; this actor is its confinement — replacing the old
/// create-use-drop-inside-a-detached-task pattern, which reloaded ~100 MB of VBx models from
/// disk at every meeting stop AND built a separate throwaway manager just for the start()-time
/// warm-up. Now warm-up, stop()-time diarization, and every later meeting share one prepared
/// instance.
actor OfflineDiarizerHost {
    static let shared = OfflineDiarizerHost()

    /// Clustering threshold for the offline VBx pipeline. FluidAudio's config value is a COSINE
    /// SIMILARITY (converted internally to a Euclidean merge distance, `sqrt(2-2s)`), so HIGHER
    /// = less merging = more speakers. FluidAudio's 0.6 default under-splits multi-speaker audio:
    /// on the 5-speaker `.fixtures/videoplayback.wav` it collapsed everything into 1 speaker
    /// (DER-proxy fer=0.614). Threshold sweep on that fixture (fer / speakers found):
    /// 0.30–0.55 → 0.614 / 1; 0.65 → 0.416 / 2; 0.70 → 0.353 / 3; 0.75 → 0.303 / 3;
    /// 0.80–0.85 → 0.344 / 3; **0.90 → 0.202 / 4** — beating the old online chunker (fer=0.284).
    /// Robustness: on the real ~3-speaker `.fixtures/bluetooth-sco-24k-recovered.wav`, 0.90 found
    /// 4 balanced speakers vs 2 at 0.6 (both off by one; no spurious fragmentation).
    /// Deliberately a constant, not a user config key.
    private static let clusteringThreshold = 0.90

    /// Carries the non-Sendable manager. `@unchecked Sendable` is sound because all use is
    /// serialized: `prepare()` is single-flighted via `preparing`, and the app never overlaps
    /// two diarization passes (meetings are serialized by MeetingCoordinator's
    /// isFinishingMeeting gate). The box exists because Swift 6's region checker rejects
    /// awaiting a non-Sendable value's async methods when that value is actor-stored state —
    /// the old create-use-drop pattern dodged this by never storing the manager anywhere.
    private struct ManagerBox: @unchecked Sendable {
        let manager: OfflineDiarizerManager
    }

    private var box: ManagerBox?

    /// In-flight preparation, shared by concurrent callers. Actor methods interleave at
    /// suspension points, so a bare `box == nil` check is NOT a mutex: the start()-time
    /// warm-up racing a fast stop() would otherwise build two managers concurrently.
    private var preparing: Task<ManagerBox, Error>?

    /// Create and prepare the shared manager; a no-op once prepared. On failure the in-flight
    /// task is cleared so the next call retries (a failed first-run model download at warm-up
    /// gets its proper retry + error report at stop()).
    func prepare() async throws {
        _ = try await preparedBox()
    }

    /// Diarize a WAV with the shared manager, preparing it first when needed. `progress`, when
    /// supplied, is forwarded to FluidAudio's per-chunk `(chunksProcessed, totalChunks)` callback.
    func process(
        _ url: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [TimedSpeakerSegment] {
        let box = try await preparedBox()
        return try await Self.diarize(box, url: url, progress: progress)
    }

    private func preparedBox() async throws -> ManagerBox {
        if let box { return box }
        let task = preparing ?? Task { try await Self.makeManager() }
        preparing = task
        do {
            let fresh = try await task.value
            box = fresh
            return fresh
        } catch {
            preparing = nil
            throw error
        }
    }

    /// Nonisolated on purpose: the manager is created, prepared, and boxed in one isolation
    /// region, so no cross-isolation send of a non-Sendable value ever happens.
    private nonisolated static func makeManager() async throws -> ManagerBox {
        let manager = OfflineDiarizerManager(
            config: OfflineDiarizerConfig(clusteringThreshold: clusteringThreshold)
        )
        try await manager.prepareModels()
        return ManagerBox(manager: manager)
    }

    /// Nonisolated on purpose: caller and callee share one isolation, so unboxing and using
    /// the manager crosses no boundary the region checker would reject.
    private nonisolated static func diarize(
        _ box: ManagerBox,
        url: URL,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [TimedSpeakerSegment] {
        try await box.manager.process(url, progressCallback: progress).segments
    }
}
