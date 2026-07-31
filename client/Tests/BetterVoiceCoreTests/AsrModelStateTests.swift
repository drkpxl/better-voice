import XCTest
@testable import BetterVoiceCore

final class AsrModelStateTests: XCTestCase {

    /// Every phase read goes through here because `XCTAssertEqual` takes autoclosures, which cannot
    /// contain `await` -- the value has to be hoisted out. Doing it in one place keeps the assertions
    /// readable and forwards `file`/`line` so failures point at the caller.
    private func expect(_ store: AsrModelStore,
                        _ phase: AsrModelPhase,
                        file: StaticString = #filePath,
                        line: UInt = #line) async {
        let actual = await store.phase
        XCTAssertEqual(actual, phase, file: file, line: line)
    }

    // MARK: - First query

    func testFreshStoreReportsInstalledWhenTheDownloaderSaysSo() async {
        let downloader = FakeDownloader(installed: true)
        let store = AsrModelStore(downloader: downloader)

        await expect(store, .installed)
        let downloads = await downloader.downloadCount
        XCTAssertEqual(downloads, 0)
    }

    func testFreshStoreReportsNotInstalledWhenTheDownloaderSaysSo() async {
        let store = AsrModelStore(downloader: FakeDownloader(installed: false))
        await expect(store, .notInstalled)
    }

    func testRepeatedPhaseReadsDoNotReProbe() async {
        let downloader = FakeDownloader(installed: true)
        let store = AsrModelStore(downloader: downloader)

        _ = await store.phase
        _ = await store.phase

        let probes = await downloader.probeCount
        XCTAssertEqual(probes, 1)
    }

    // MARK: - prepare: the happy path

    func testPrepareWalksNotInstalledThroughDownloadingToInstalled() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.closeDownloadGate()
        let store = AsrModelStore(downloader: downloader)

        await expect(store, .notInstalled)

        let prepare = Task { try await store.prepare() }
        await downloader.waitUntilDownloadStarted()
        await expect(store, .downloading(fraction: 0))

        await downloader.report(0.4)
        await expect(store, .downloading(fraction: 0.4))

        await downloader.openDownloadGate()
        try await prepare.value
        await expect(store, .installed)

        let downloads = await downloader.downloadCount
        XCTAssertEqual(downloads, 1)
    }

    func testPrepareWhenAlreadyInstalledDoesNotDownload() async throws {
        let downloader = FakeDownloader(installed: true)
        let store = AsrModelStore(downloader: downloader)

        try await store.prepare()
        try await store.prepare()

        await expect(store, .installed)
        let downloads = await downloader.downloadCount
        XCTAssertEqual(downloads, 0)
    }

    // MARK: - prepare: single-flight

    /// The one that matters: a launch warm-up racing the user's first import must not fetch 470 MB
    /// twice.
    ///
    /// Deterministic without sleeps or yields, via two rendezvous the fake owns:
    ///
    /// 1. `rendezvousProbes(2)` holds both callers inside `isInstalled` until *both* have arrived, so
    ///    they are guaranteed to be racing. Without it the first `prepare()` could finish outright
    ///    before the second even started, and the second would then skip the download for the wrong
    ///    reason -- a test that passes without ever exercising the single-flight.
    /// 2. The closed download gate holds the winner inside `download`, so the loser cannot observe an
    ///    already-finished download either.
    ///
    /// The invocation count is asserted only *after* both calls return. Asserting it mid-flight would be
    /// the one timing-dependent thing left: a broken single-flight enters the second `download` at some
    /// unspecified later moment, so an early read could see 1 and pass.
    func testTwoConcurrentPreparesCauseExactlyOneDownload() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.rendezvousProbes(2)
        await downloader.closeDownloadGate()
        let store = AsrModelStore(downloader: downloader)

        async let first: Void = store.prepare()
        async let second: Void = store.prepare()

        await downloader.waitUntilDownloadStarted()
        await expect(store, .downloading(fraction: 0))
        await downloader.openDownloadGate()
        _ = try await (first, second)

        let downloads = await downloader.downloadCount
        XCTAssertEqual(downloads, 1)
        await expect(store, .installed)

        // If this trips, `prepare()` no longer probes before starting a download and the rendezvous
        // above stopped pinning the interleaving -- the count assertion has gone weak, not wrong.
        let timedOut = await downloader.probeRendezvousTimedOut
        XCTAssertFalse(timedOut, "the two callers never met inside isInstalled; this test's determinism is stale")
    }

    // MARK: - prepare: failure and retry

    func testFailedDownloadRecordsTheReasonAndRethrows() async {
        let downloader = FakeDownloader(installed: false)
        await downloader.failNextDownload(with: FakeFailure(description: "network dropped"))
        let store = AsrModelStore(downloader: downloader)

        do {
            try await store.prepare()
            XCTFail("expected the download failure to propagate")
        } catch {
            XCTAssertEqual("\(error)", "network dropped")
        }
        await expect(store, .failed(reason: "network dropped"))
    }

    /// A warm-up that failed on a flaky network must not poison the first real use.
    func testPrepareRetriesAfterFailureAndSucceeds() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.failNextDownload(with: FakeFailure(description: "network dropped"))
        let store = AsrModelStore(downloader: downloader)

        try? await store.prepare()
        await expect(store, .failed(reason: "network dropped"))

        try await store.prepare()
        await expect(store, .installed)

        let downloads = await downloader.downloadCount
        XCTAssertEqual(downloads, 2)
    }

    // MARK: - Progress

    func testProgressIsClampedIntoTheUnitRange() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.closeDownloadGate()
        let store = AsrModelStore(downloader: downloader)
        let prepare = Task { try await store.prepare() }
        await downloader.waitUntilDownloadStarted()

        await downloader.report(-0.5)
        await expect(store, .downloading(fraction: 0))
        await downloader.report(0.25)
        await expect(store, .downloading(fraction: 0.25))
        await downloader.report(7)
        await expect(store, .downloading(fraction: 1))

        await downloader.openDownloadGate()
        try await prepare.value
    }

    func testProgressNeverMovesBackwards() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.closeDownloadGate()
        let store = AsrModelStore(downloader: downloader)
        let prepare = Task { try await store.prepare() }
        await downloader.waitUntilDownloadStarted()

        await downloader.report(0.5)
        await expect(store, .downloading(fraction: 0.5))
        await downloader.report(0.3)
        await expect(store, .downloading(fraction: 0.5))
        await downloader.report(.nan)
        await expect(store, .downloading(fraction: 0.5))

        await downloader.openDownloadGate()
        try await prepare.value
    }

    /// A tick arriving after the download settled must not drag the phase back to `.downloading`, which
    /// would leave the UI showing a progress bar forever for a finished download.
    func testProgressAfterCompletionCannotResurrectDownloading() async throws {
        let downloader = FakeDownloader(installed: false)
        let store = AsrModelStore(downloader: downloader)

        try await store.prepare()
        await expect(store, .installed)

        await downloader.report(0.42)
        await expect(store, .installed)
    }

    func testFoldedFractionClampsAndHoldsTheFloor() {
        XCTAssertEqual(MonotonicFraction.folded(-1, notBelow: 0), 0)
        XCTAssertEqual(MonotonicFraction.folded(0.25, notBelow: 0), 0.25)
        XCTAssertEqual(MonotonicFraction.folded(2, notBelow: 0), 1)
        XCTAssertEqual(MonotonicFraction.folded(0.3, notBelow: 0.5), 0.5)
        XCTAssertEqual(MonotonicFraction.folded(.nan, notBelow: 0.5), 0.5)
        XCTAssertEqual(MonotonicFraction.folded(.infinity, notBelow: 0.5), 0.5)
        XCTAssertEqual(MonotonicFraction.folded(-.infinity, notBelow: 0.5), 0.5)
    }

    // MARK: - Cancellation

    func testCancelMidDownloadLeavesNotInstalledAndAllowsRetry() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.closeDownloadGate()
        let store = AsrModelStore(downloader: downloader)

        let prepare = Task { try await store.prepare() }
        await downloader.waitUntilDownloadStarted()
        await store.cancel()

        do {
            try await prepare.value
            XCTFail("expected the cancelled download to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        await expect(store, .notInstalled)

        await downloader.openDownloadGate()
        try await store.prepare()
        await expect(store, .installed)

        let downloads = await downloader.downloadCount
        XCTAssertEqual(downloads, 2)
    }

    func testCancelWhileInstalledDoesNotUninstall() async {
        let store = AsrModelStore(downloader: FakeDownloader(installed: true))

        await expect(store, .installed)
        await store.cancel()
        await expect(store, .installed)
    }

    func testCancelWhileIdleIsSafe() async {
        let store = AsrModelStore(downloader: FakeDownloader(installed: false))

        await store.cancel()
        await expect(store, .notInstalled)
    }

    // MARK: - Removal

    func testRemoveFromInstalledGoesToNotInstalled() async throws {
        let downloader = FakeDownloader(installed: true)
        let store = AsrModelStore(downloader: downloader)
        await expect(store, .installed)

        try await store.remove()

        await expect(store, .notInstalled)
        let removals = await downloader.removeCount
        XCTAssertEqual(removals, 1)
    }

    func testRemoveWhileIdleIsSafeAndPrepareStillWorks() async throws {
        let downloader = FakeDownloader(installed: false)
        let store = AsrModelStore(downloader: downloader)

        try await store.remove()
        await expect(store, .notInstalled)

        try await store.prepare()
        await expect(store, .installed)
    }

    func testFailedRemovalRethrowsAndStillDoesNotClaimInstalled() async {
        let downloader = FakeDownloader(installed: true)
        await downloader.failRemoval(with: FakeFailure(description: "busy file"))
        let store = AsrModelStore(downloader: downloader)
        await expect(store, .installed)

        do {
            try await store.remove()
            XCTFail("expected the removal failure to propagate")
        } catch {
            XCTAssertEqual("\(error)", "busy file")
        }
        await expect(store, .notInstalled)
    }

    func testRemoveDuringDownloadCancelsItAndDoesNotClaimInstalled() async throws {
        let downloader = FakeDownloader(installed: false)
        await downloader.closeDownloadGate()
        let store = AsrModelStore(downloader: downloader)

        let prepare = Task { try await store.prepare() }
        await downloader.waitUntilDownloadStarted()
        try await store.remove()

        await expect(store, .notInstalled)
        let removals = await downloader.removeCount
        XCTAssertEqual(removals, 1)

        do {
            try await prepare.value
            XCTFail("expected the interrupted download to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        // The cancelled download's own completion must not come back and claim `.installed` for models
        // that were just deleted.
        await expect(store, .notInstalled)
    }
}

// MARK: - Fake downloader

private struct FakeFailure: Error, CustomStringConvertible {
    let description: String
}

/// A downloader the test can hold at a suspension point, fail on demand, and count.
///
/// An `actor` so the counters need no locking, and so every wait below parks a caller on a continuation
/// instead of sleeping -- nothing in this file is a timeout.
private actor FakeDownloader: AsrModelDownloader {

    private(set) var downloadCount = 0
    private(set) var removeCount = 0
    private(set) var probeCount = 0

    private var installed: Bool
    private var pendingDownloadFailure: Error?
    private var removalFailure: Error?
    private var reportProgress: (@Sendable (Double) -> Void)?

    init(installed: Bool = false) {
        self.installed = installed
    }

    // MARK: Arrangement

    func failNextDownload(with error: Error) { pendingDownloadFailure = error }
    func failRemoval(with error: Error) { removalFailure = error }

    /// Push a progress tick through the handler the store gave us. Callable after the download has
    /// finished, which is how the late-tick case is tested.
    func report(_ fraction: Double) { reportProgress?(fraction) }

    // MARK: AsrModelDownloader

    var isInstalled: Bool {
        get async {
            probeCount += 1
            await arriveAtProbeRendezvous()
            return installed
        }
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCount += 1
        reportProgress = progress
        releaseDownloadStartWaiters()
        try await waitForDownloadGate()
        if let failure = pendingDownloadFailure {
            pendingDownloadFailure = nil
            throw failure
        }
        installed = true
    }

    func removeCachedModels() async throws {
        removeCount += 1
        if let removalFailure { throw removalFailure }
        installed = false
    }

    // MARK: Download gate

    private var gateIsOpen = true
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func closeDownloadGate() { gateIsOpen = false }

    func openDownloadGate() {
        gateIsOpen = true
        releaseGateWaiters()
    }

    private func waitForDownloadGate() async throws {
        if !gateIsOpen {
            // Cancellation-aware on purpose: the store cancels the shared download task, and a
            // continuation that ignored that would hang the run instead of exercising the cancel path.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if gateIsOpen || Task.isCancelled {
                        continuation.resume()
                    } else {
                        gateWaiters.append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.releaseGateWaiters() }
            }
        }
        try Task.checkCancellation()
    }

    private func releaseGateWaiters() {
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: "download has started" signal

    private var downloadStartWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once `download` has been entered at least `count` times -- the only way for a test to
    /// know the store is genuinely mid-download without polling.
    func waitUntilDownloadStarted(atLeast count: Int = 1) async {
        if downloadCount >= count { return }
        await withCheckedContinuation { downloadStartWaiters.append($0) }
    }

    private func releaseDownloadStartWaiters() {
        let waiters = downloadStartWaiters
        downloadStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Probe rendezvous

    private var probeRendezvousTarget: Int?
    private var probeArrivals = 0
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var probeWatchdog: Task<Void, Never>?
    private(set) var probeRendezvousTimedOut = false

    /// Hold every caller inside `isInstalled` until `count` of them have arrived, then release all.
    func rendezvousProbes(_ count: Int) {
        probeRendezvousTarget = count
        // A watchdog so an implementation change that stops probing fails an assertion instead of
        // hanging the suite. It never fires on the passing path, where the rendezvous fills at once.
        probeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.timeOutProbeRendezvous()
        }
    }

    private func arriveAtProbeRendezvous() async {
        guard let target = probeRendezvousTarget else { return }
        probeArrivals += 1
        guard probeArrivals < target else {
            probeRendezvousTarget = nil
            probeWatchdog?.cancel()
            releaseProbeWaiters()
            return
        }
        await withCheckedContinuation { probeWaiters.append($0) }
    }

    private func timeOutProbeRendezvous() {
        guard probeRendezvousTarget != nil else { return }
        probeRendezvousTarget = nil
        probeRendezvousTimedOut = true
        releaseProbeWaiters()
    }

    private func releaseProbeWaiters() {
        let waiters = probeWaiters
        probeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
