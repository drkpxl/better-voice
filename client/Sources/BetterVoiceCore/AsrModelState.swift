import Foundation
import Synchronization

// MARK: - Phase

/// What the Parakeet model cache is doing, as onboarding and Settings need to see it.
///
/// Four cases, and deliberately no more. There is **no partial-capability mode** in this migration --
/// until the 470 MB download finishes, transcription cannot happen at all -- so every consumer is
/// answering one of two questions: "may I transcribe?" (`.installed`) and "what do I show the user
/// instead?" (the other three). Cases that would only refine the second answer were left out:
///
/// - No `.unknown` / `.checking`. Whether the store has asked the downloader yet is an artefact of
///   the first `AsrModelStore.phase` read, which resolves it *before* returning. Publishing it would
///   force every `switch` in the UI to render a state with no meaning to the user, and the onboarding
///   screen would flash it on every appearance.
/// - No `.cancelled`. A user who cancelled gets exactly the `.notInstalled` treatment -- a "Download
///   models" button -- because a partial download is not usable. The extra case would carry no
///   information and add a branch at every call site.
/// - No `.paused`. Nothing in `AsrModels.downloadAndLoad` can pause today. Adding the case before the
///   capability exists would publish a state the store cannot enter.
public enum AsrModelPhase: Sendable, Equatable {
    /// Nothing usable on disk. Also where a cancelled download and a failed removal land.
    case notInstalled
    /// A download is running. `fraction` is in `0...1` and never decreases within one download. It is
    /// **not** a promise of a terminal `1.0` -- see `AsrModelStore.prepare()`.
    case downloading(fraction: Double)
    /// Models are on disk; transcription may proceed.
    case installed
    /// The last attempt failed, and the next `prepare()` will retry.
    ///
    /// `reason` is diagnostic text for logs and an error detail line, not user-facing copy. A `String`
    /// rather than the `Error` so the phase stays `Equatable` and `Sendable` for view diffing; the
    /// `Error` itself is rethrown by `prepare()` to whoever asked.
    case failed(reason: String)
}

// MARK: - Downloader seam

/// The one side of this feature that touches the world: fetching, deleting and detecting the models.
///
/// Exists so `AsrModelStore` can be a pure state machine that unit-tests without CoreML, the network,
/// or 470 MB of disk. The real conformance wraps `AsrModels.downloadAndLoad` app-side and is not this
/// target's business.
public protocol AsrModelDownloader: Sendable {

    /// Whether a usable model set is already on disk.
    ///
    /// Non-throwing on purpose. A probe that *cannot tell* (unreadable directory, a permissions
    /// failure, a half-written cache) must answer `false`: that costs a redundant download, whereas
    /// answering `true` strands the user with an engine that will not load and no download UI to
    /// recover in. Bias toward the recoverable failure.
    var isInstalled: Bool { get async }

    /// Fetch the models, reporting `0...1` completion as it goes.
    ///
    /// `progress` is `@escaping` because real conformances hand it to a download library's own stored
    /// handler, and `@Sendable` because it will be called from whatever thread that library uses. It
    /// may be called any number of times -- including zero, out of order, and with values outside
    /// `0...1`. `AsrModelStore` folds it rather than trusting it, so an implementation does not need
    /// to sanitise its own ticks.
    ///
    /// Must honour task cancellation. `AsrModelStore.cancel()` cancels the shared download task, and
    /// an implementation that ignores cancellation leaves every joined caller suspended forever.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Delete the cached models. Called whether or not anything is installed, so "nothing to delete"
    /// is a success, not an error.
    func removeCachedModels() async throws
}

// MARK: - Store

/// Single owner of "do we have the Parakeet models, and if not, what is happening about it".
///
/// This gate is the largest first-run abandonment risk in the Parakeet migration: 470 MB, no
/// partial-capability mode, and two independent triggers -- a launch warm-up and the user's first
/// import -- that can fire milliseconds apart. Everything below exists for one of those facts.
///
/// An `actor`, not a pure `struct` state machine behind a thin actor. Each transition here is two or
/// three lines; what is actually hard is that they *interleave*. Every `await` is a reentrancy point,
/// the download is one shared `Task` joined by N callers, and progress arrives off-actor. A value type
/// would still have to carry that `Task` and the generation counter, so the split would relocate the
/// concurrency rather than remove it -- and it would invite the trap of testing the pure half
/// exhaustively and the interleaved half barely, which is the reverse of where the bugs are. The one
/// genuinely pure rule *is* split out: `MonotonicFraction`, which has its own synchronous tests.
///
/// Deliberately not `Observable` and not publishing an `AsyncStream`: this target is Foundation-only,
/// and every phase write funnels through `commit(_:)` so exactly one place needs to change when
/// app-side wiring wants push updates.
public actor AsrModelStore {

    private let downloader: any AsrModelDownloader

    /// The phase as last committed. Meaningless until `hasResolved`: a fresh store has asked the
    /// downloader nothing, so `.notInstalled` is a guess and not an answer. Kept as a non-optional
    /// pair rather than an `AsrModelPhase?` so pattern matches below read as themselves.
    private var committed: AsrModelPhase = .notInstalled
    private var hasResolved = false

    /// The in-flight download, shared by every caller. Actor methods interleave at suspension points,
    /// so a bare "is a download running" boolean would not be a mutex -- this is the single-flight.
    /// Cleared the moment the download settles, so the *next* `prepare()` retries instead of joining a
    /// dead task and inheriting its failure forever.
    private var inFlight: Task<Void, any Error>?

    /// Bumped by anything that supersedes an in-flight download: `cancel()`, `remove()`, and each new
    /// download. Every completion carries the generation it was started under and writes nothing if it
    /// no longer matches. Without this, a cancelled download that ran to completion anyway would come
    /// back and commit `.installed` for models the user just deleted -- silently, and with no way for
    /// the UI to notice.
    private var generation = 0

    /// Progress for the current download, held off-actor -- see `MonotonicFraction`. Non-nil only
    /// while a download is running.
    private var progress: MonotonicFraction?

    public init(downloader: any AsrModelDownloader) {
        self.downloader = downloader
    }

    // MARK: - Reading

    /// The current phase, resolving the on-disk question on first read.
    ///
    /// The first read probes `downloader.isInstalled`, which is why this is an effectful getter: a
    /// store constructed at launch must be able to answer "does onboarding need to show the download
    /// screen?" without anyone calling `prepare()` first. Later reads are free.
    ///
    /// Two concurrent first reads may both probe. That is accepted and not single-flighted: unlike the
    /// download, `isInstalled` is a cheap, side-effect-free check, and the machinery to deduplicate it
    /// would cost more than the duplicate.
    public var phase: AsrModelPhase {
        get async {
            if hasResolved { return resolved() }
            let installed = await downloader.isInstalled
            // Reentrancy: the probe suspended, so a `prepare()` or `remove()` may have answered the
            // question properly while we were away. Its answer is fresher than ours -- never clobber
            // it with a stale probe.
            if hasResolved { return resolved() }
            commit(installed ? .installed : .notInstalled)
            return resolved()
        }
    }

    // MARK: - Preparation

    /// Ensure the models are on disk, downloading them if they are not.
    ///
    /// Idempotent and single-flighted: two concurrent callers -- the classic case being a launch
    /// warm-up racing the user's first import -- produce **one** download and both await it. A caller
    /// that finds the models already installed does no work at all.
    ///
    /// Rethrows the download's error *and* records it in `phase`. Both, because the two consumers
    /// differ: onboarding renders `.failed`, while a first import needs to know not to proceed.
    ///
    /// Progress is reported through `phase`, not a callback, and carries no guarantee of a terminal
    /// `1.0` -- a downloader may report nothing at all. `.installed` is the completion signal.
    ///
    /// Cancelling the *calling* task does not stop the download; call `cancel()`. The download is
    /// shared, so one caller walking away must not tear it out from under the other.
    public func prepare() async throws {
        guard let task = await downloadTask() else { return }
        try await task.value
    }

    /// The download to await, or nil when the models are already there and nothing needs to run.
    private func downloadTask() async -> Task<Void, any Error>? {
        // Join first, and *without* probing: a running download already answers the question, and
        // probing `isInstalled` mid-download would only report the half-written truth.
        if let running = inFlight { return running }

        // Probe on every call rather than trusting `committed`. The cache can vanish under us --
        // Settings "delete models", a user clearing the app's support directory, a failed migration --
        // and a stale `.installed` here does not fail here. It fails later, at transcription time,
        // where there is no download UI to recover in.
        if await downloader.isInstalled {
            // Only claim installed if nothing started downloading while the probe was suspended;
            // stamping over a live `.downloading` would flick the UI to done and back. Returning
            // `inFlight` rather than nil so such a caller still joins that download.
            if inFlight == nil { commit(.installed) }
            return inFlight
        }

        // The probe suspended, so its "not installed" may already be stale. Two ways:
        if let running = inFlight { return running }
        // ...and the subtler one -- a download that started *and finished* while we were suspended
        // leaves `inFlight` nil, so the committed phase is the only surviving evidence that we must
        // not immediately re-download 470 MB.
        if hasResolved, case .installed = committed { return nil }

        return beginDownload()
    }

    private func beginDownload() -> Task<Void, any Error> {
        generation += 1
        let generation = self.generation
        let fraction = MonotonicFraction()
        progress = fraction
        commit(.downloading(fraction: 0))

        // Hoisted so the task body never has to reach back through `self` for it.
        let downloader = self.downloader
        let task = Task { [weak self] in
            do {
                try await downloader.download(progress: { fraction.report($0) })
            } catch {
                // Settle the state BEFORE rethrowing. Joined callers resume when this task completes,
                // and they must find `inFlight` already cleared -- otherwise a caller that retries
                // immediately on failure would join the very task that just failed.
                await self?.finish(.failure(error), generation: generation)
                throw error
            }
            await self?.finish(.success(()), generation: generation)
        }
        inFlight = task
        return task
    }

    private func finish(_ result: Result<Void, any Error>, generation: Int) {
        // A stale generation means this download was cancelled or superseded, or the cache was removed
        // under it. Its outcome is no longer the truth about anything on disk.
        guard generation == self.generation else { return }
        inFlight = nil
        progress = nil
        switch result {
        case .success:
            // Trusting the downloader's non-throwing return instead of re-probing `isInstalled`. A
            // "downloaded but reports missing" contradiction has no phase to express it and no
            // recovery beyond retrying, which the next `prepare()` already does.
            commit(.installed)
        case .failure(let error):
            // Cancellation is not a failure to show an error banner for -- the user asked for it --
            // and `.notInstalled` is also the accurate claim, since a partial download is unusable.
            // Reached when the *downloader* reports cancellation; `cancel()` commits the phase itself.
            commit(error is CancellationError ? .notInstalled : .failed(reason: "\(error)"))
        }
    }

    // MARK: - Cancellation

    /// Stop the current download, if any, leaving nothing claiming to be in progress.
    ///
    /// Explicit rather than inherited from the caller's task, because the download is shared: a first
    /// import whose task is cancelled must not rip the download out from under the onboarding screen
    /// showing its progress bar. Only a caller that means "stop downloading" calls this.
    ///
    /// Safe while idle or installed. Joined callers see the download's `CancellationError`.
    public func cancel() {
        let wasDownloading = isDownloading
        invalidateInFlight()
        // Only claim `.notInstalled` if a download was actually running. Cancelling while installed
        // must not un-install anything -- that is `remove()`'s job.
        if wasDownloading { commit(.notInstalled) }
    }

    // MARK: - Removal

    /// Delete the cached models -- the Settings "delete models" affordance.
    ///
    /// Safe to call while idle: the removal is still attempted, because only the downloader knows
    /// whether a half-written cache is sitting there from an interrupted run.
    ///
    /// Cancels any in-flight download first. Deleting files under a live download would leave a
    /// partially-written model directory that the next `isInstalled` probe could report as present.
    ///
    /// The phase ends at `.notInstalled` **even when the removal throws**, and the error is rethrown so
    /// Settings can still surface it. That bias is deliberate: after a failed removal we do not know
    /// what is on disk, and a partially-removed cache will not load. Continuing to claim `.installed`
    /// is the direction that strands the user; claiming `.notInstalled` costs at worst one redundant
    /// download.
    public func remove() async throws {
        invalidateInFlight()
        let generation = self.generation
        // Deferred so it also runs on the throwing path -- that is the whole point of it being here.
        // Generation-guarded because `removeCachedModels` suspends: a `prepare()` that slipped in
        // behind us owns the phase now, and stamping `.notInstalled` over its `.downloading` would show
        // a "Download models" button for a download that is already running.
        defer { if generation == self.generation { commit(.notInstalled) } }
        try await downloader.removeCachedModels()
    }

    // MARK: - State

    /// Retire anything in flight: after this, every completion and progress tick from work started
    /// earlier is stale. Bumps unconditionally, so callers do not have to reason about whether a
    /// download happened to be running.
    private func invalidateInFlight() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        progress = nil
    }

    /// The single place the phase changes, so a future stream of updates has one place to publish from.
    private func commit(_ phase: AsrModelPhase) {
        committed = phase
        hasResolved = true
    }

    /// `committed` with any progress reported since it was written folded in. Folding on read (rather
    /// than writing the phase from the progress callback) is what keeps a late tick from resurrecting
    /// `.downloading` after the download already settled: once `committed` moves off `.downloading`,
    /// the fraction stops being consulted at all.
    private func resolved() -> AsrModelPhase {
        guard case .downloading = committed, let progress else { return committed }
        return .downloading(fraction: progress.value)
    }

    private var isDownloading: Bool {
        if case .downloading = committed { return true }
        return false
    }
}

// MARK: - Progress

/// A download's completion fraction, held outside the actor behind a lock.
///
/// Off-actor on purpose. The downloader calls its progress handler synchronously from its own thread,
/// so the alternative is spawning a `Task` per tick to hop onto the actor -- which is both heavier and
/// *unordered*, since nothing promises that enqueued actor jobs run in the order they were created.
/// Ticks would then arrive shuffled, and a 0.5 landing after a 0.9 would drag a progress bar backwards.
/// A lock-protected fold has neither problem, and it makes the fraction readable synchronously from
/// inside the actor.
///
/// The fold is monotonic and clamped, which is a correctness requirement rather than paranoia:
/// a real multi-file download can report a per-file fraction that resets, and `NSProgress`-style
/// sources emit junk (negatives, NaN) around startup and failure.
final class MonotonicFraction: Sendable {

    private let storage = Mutex<Double>(0)

    /// The highest fraction reported so far, always in `0...1`.
    var value: Double { storage.withLock { $0 } }

    func report(_ fraction: Double) {
        storage.withLock { $0 = Self.folded(fraction, notBelow: $0) }
    }

    /// Clamp `fraction` into `0...1`, then refuse to go below `floor`.
    ///
    /// Non-finite input yields `floor` rather than a clamp: NaN has no ordering, so letting it through
    /// would poison every later comparison against the high-water mark, and an infinity is garbage
    /// rather than a claim of completion. Both cases mean "this tick told us nothing", and holding the
    /// last known value is the honest response.
    static func folded(_ fraction: Double, notBelow floor: Double) -> Double {
        guard fraction.isFinite else { return floor }
        return max(floor, min(1, max(0, fraction)))
    }
}
