import Foundation
import FluidAudio
import Synchronization
import BetterVoiceCore

/// The real `AsrModelDownloader` behind `AsrModelStore` — the one place that touches FluidAudio's
/// model cache.
///
/// **Loading is folded into `download`.** The protocol only promises to put models on disk, but
/// `AsrModels.downloadAndLoad` compiles every model as it loads them, and that compile is the slow
/// half of a cold start. Splitting it out would leave the compile sitting in a silent gap *after* the
/// phase the UI reports as `.downloading` — which is the precise shape of the 1.1.0 hang this seam
/// exists to remove. The loaded set is stashed for `ParakeetTranscriber` to collect via `take()`, so
/// nothing is ever loaded twice.
final class ParakeetModelDownloader: AsrModelDownloader {

    private let version: AsrModelVersion

    /// Where this build keeps its models. Channel-specific, for the same reason the log directory,
    /// bundle id, TCC grants and UserDefaults already are: a dev build must not be able to disturb
    /// the release install's state. The model cache was the one piece of per-channel state still
    /// shared, and it is the most expensive to rebuild — 470 MB — so a dev run that deleted or
    /// half-wrote it cost the release app a full re-download and made real UAT impossible.
    private let cacheDirectory: URL

    /// `…/Application Support/FluidAudio/Models/<repo>` for release builds, `…/FluidAudio-Dev/…`
    /// for dev. Derived from FluidAudio's own default rather than rebuilt from string literals, so
    /// a change to the library's layout carries over instead of silently diverging.
    private static func cacheDirectory(for version: AsrModelVersion) -> URL {
        let standard = AsrModels.defaultCacheDirectory(for: version)
        // Same channel test as `Logger` — dev bundles carry a `.dev` id (see scripts/apply-channel.sh).
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false else { return standard }

        let repoFolder = standard.lastPathComponent              // <repo>
        let modelsDir = standard.deletingLastPathComponent()     // …/FluidAudio/Models
        let root = modelsDir.deletingLastPathComponent()         // …/FluidAudio
        return root.deletingLastPathComponent()                  // …/Application Support
            .appendingPathComponent(root.lastPathComponent + "-Dev")
            .appendingPathComponent(modelsDir.lastPathComponent)
            .appendingPathComponent(repoFolder)
    }

    /// Models loaded by the last successful `download`, awaiting collection. Held behind a lock
    /// rather than on an actor because `download` runs on `AsrModelStore`'s shared task while
    /// `take()` is called from `ParakeetTranscriber`, and `AsrModels` is `Sendable`.
    private let loaded = Mutex<AsrModels?>(nil)

    /// What the fetch is doing right now, in words, for the menu bar to show.
    ///
    /// A LABEL rather than a percentage, because there is no honest percentage to show.
    /// `AsrModels.download` runs `DownloadUtils.loadModels` once per model file, and each of those
    /// calls restarts its own `fractionCompleted` at 0.5 and ends at 1.0 — so across the four files
    /// the number sweeps the same range four times, and `MonotonicFraction` (correctly refusing to go
    /// backwards) pins it at 1.0 once the first file lands. Measured on a real cold start it read 0%
    /// for 3m20s of a 3m40s download, then jumped to 100%: worse than no number, because a bar frozen
    /// at 0% is exactly what "the app has hung" looks like.
    private let activityLabel = Mutex<String?>(nil)

    init(version: AsrModelVersion) {
        self.version = version
        self.cacheDirectory = Self.cacheDirectory(for: version)
        Logger.log("ASR", "Model cache: \(cacheDirectory.path)")
    }

    /// Human-readable description of the current fetch stage, or nil when nothing is running.
    var activity: String? {
        activityLabel.withLock { $0 }
    }

    /// The models loaded by the most recent download, cleared as they are handed over.
    ///
    /// Returns nil when the store short-circuited on an already-installed cache and never ran a
    /// download — the caller loads from disk itself in that case.
    func take() -> AsrModels? {
        loaded.withLock { stashed in
            defer { stashed = nil }
            return stashed
        }
    }

    /// Cheap path-existence probe, per the protocol's "bias toward the recoverable failure" rule.
    ///
    /// Deliberately NOT `AsrModels.isModelValid`, which instantiates every `MLModel` to check them —
    /// seconds of work, on a call the store makes on every `prepare()`. The cost of this weaker probe
    /// is a cache whose files all exist but are half-written reporting `true`; `download` below
    /// recovers from exactly that, which is the trade this pairing is built around.
    var isInstalled: Bool {
        get async {
            AsrModels.modelsExist(at: cacheDirectory, version: version)
        }
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        // `self` rather than a hoisted local: `Mutex` is non-copyable, so the lock cannot be bound to
        // a local and captured. The type is `Sendable` (its only storage is `let`s and `Mutex`es),
        // which is what lets it cross into this `@Sendable` handler.
        let handler: DownloadUtils.ProgressHandler = { [self] update in
            // The fraction still goes to the store: `AsrModelStore` is the tested owner of the phase,
            // and `.downloading` needs a value. Nothing renders it as a percentage — see `activity`.
            progress(update.fractionCompleted)

            let label: String
            switch update.phase {
            case .listing:
                label = t("Preparing download…")
            case .downloading(let completed, let total):
                // `total == 0` is the library's "already local, nothing to fetch" signal, not a
                // divide-by-zero waiting to happen — render it as plain activity rather than "0 of 0".
                label = total > 0
                    ? t("Downloading speech model — file \(completed + 1) of \(total)")
                    : t("Downloading speech model…")
            case .compiling(let name):
                label = name.isEmpty ? t("Compiling speech model…") : t("Compiling \(name)…")
            }

            let changed = activityLabel.withLock { current -> Bool in
                guard current != label else { return false }
                current = label
                return true
            }
            // Log only on change: the handler fires per file and per compile, and a line per tick
            // would bury the transitions that actually explain a slow start.
            if changed { Logger.log("ASR", label) }
        }

        defer { activityLabel.withLock { $0 = nil } }

        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(
                to: cacheDirectory,
                version: version,
                progressHandler: handler
            )
        } catch {
            // A present-but-incomplete cache. `AsrModels.download` early-returns when every required
            // path merely *exists* (`modelsExist` stats paths, it does not read them), so a first run
            // interrupted partway — the user quitting an app that looked hung, which is exactly how
            // 1.1.0 failed — leaves files that skip the fetch and then throw here at load. Without
            // this branch that state never heals: every subsequent launch takes the same early return
            // and fails identically. `loadWithAutoRecovery` reads as though it covers this; it does
            // not, it is a plain `load`.
            Logger.log("ASR", "Model load failed (\(error)); forcing a clean re-download")
            _ = try await AsrModels.download(
                to: cacheDirectory,
                force: true,
                version: version,
                progressHandler: handler
            )
            models = try await AsrModels.load(from: cacheDirectory, version: version)
        }

        loaded.withLock { $0 = models }
    }

    /// Load the models already on disk, from THIS build's cache.
    ///
    /// Exists so `ParakeetTranscriber` never has to reach for `AsrModels.loadFromCache`, which
    /// resolves the default (release) directory and would have a dev build quietly running against
    /// the release install's models.
    func loadInstalled() async throws -> AsrModels {
        try await AsrModels.load(from: cacheDirectory, version: version)
    }

    func removeCachedModels() async throws {
        loaded.withLock { $0 = nil }
        // `cacheDirectory`, NOT `AsrModels.defaultCacheDirectory` — otherwise a dev build's "delete
        // models" would erase the RELEASE install's 470 MB cache.
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        try FileManager.default.removeItem(at: cacheDirectory)
    }
}
