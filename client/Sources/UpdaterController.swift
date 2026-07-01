import AppKit
import Sparkle
import BetterVoiceCore

/// Wraps Sparkle's standard updater so the menu bar can reflect update availability.
///
/// We use `SPUStandardUpdaterController` (not a custom user driver) for Sparkle's well-tested
/// update window — release notes + "Install & Relaunch" — which is exactly the requested
/// "show what changed / restart to update" UX. The `SPUUpdaterDelegate` hooks flip
/// `availableUpdateVersion` and fire `onUpdateStateChange` so `StatusBarController` can show an
/// "Update to X…" menu item. Scheduling (check on launch, at most every 14 days) is declared
/// in Info.plist via `SUEnableAutomaticChecks` / `SUScheduledCheckInterval`.
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    /// Display version of a found update, or nil when none is known. Drives the menu item.
    private(set) var availableUpdateVersion: String?

    /// Called whenever `availableUpdateVersion` changes so the menu can rebuild.
    var onUpdateStateChange: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        // startingUpdater: true begins Sparkle's scheduled-check lifecycle immediately
        // (it checks shortly after launch once the interval has elapsed).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// User-initiated check: shows Sparkle's progress UI and a "you're up to date" dialog when
    /// no update is found. Also re-presents the update window when an update is already known.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.availableUpdateVersion = version
            Logger.log("Updater", "Update available: \(version)")
            self.onUpdateStateChange?()
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            if self.availableUpdateVersion != nil {
                self.availableUpdateVersion = nil
                self.onUpdateStateChange?()
            }
            Logger.log("Updater", "No update found")
        }
    }
}
