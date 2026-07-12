import Foundation

/// The fixed, hidden Application Support directory that holds Better Voice's small support
/// files: `speakers.json` (cross-meeting voice fingerprint book), `vocabulary.md` and
/// `personal-context.md` (user-edited markdown), and `meeting-history.jsonl` (per-segment
/// streaming durability).
///
/// Meetings themselves live in Apple Notes (see `NotesScript`/`NotesHTML`) — there is nothing
/// left for the user to point at, so unlike the old `Workspace` (a user-chosen, Finder-visible
/// folder picked during onboarding) this root is simply fixed at
/// `~/Library/Application Support/BetterVoice2/`, auto-created, and never shown to the user.
///
/// Static accessors (mirroring the members `Workspace` used to expose, so dependents barely
/// changed when this replaced it) resolve against `url`. Tests and the `--bench-meeting` /
/// `--bench-polish` CLIs call `configure(root:)` up front to redirect `url` at an isolated
/// scratch directory instead of the real Application Support path.
enum SupportDir {

    // MARK: - Root

    // `nonisolated(unsafe)`: access is externally synchronized per this type's contract — any
    // override is set once up front (tests / BENCH, before any accessor below is read) and only
    // read afterward, so the Swift 6 mutable-global-state check is opted out of here rather than
    // forcing every path accessor onto the main actor.
    nonisolated(unsafe) private static var overrideRoot: URL?

    /// The support directory root. Defaults to the fixed Application Support path; tests and
    /// the BENCH CLI redirect this via `configure(root:)`.
    static var url: URL {
        overrideRoot ?? defaultRoot
    }

    private static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("BetterVoice2", isDirectory: true)
    }()

    /// Redirects `url` at an explicit directory — for tests and the BENCH CLI only. There is no
    /// UserDefaults-backed persistence to opt out of (unlike `Workspace.configure`'s old
    /// `persist:` flag): the real root is fixed, so only tests ever need to override it.
    static func configure(root: URL) {
        overrideRoot = root
        ensureExists()
        Logger.log("SupportDir", "Configured root: \(root.path)")
    }

    // MARK: - Sidecar / document file URLs

    enum FileName {
        static let vocabulary      = "vocabulary.md"
        static let personalContext = "personal-context.md"
        static let speakers        = "speakers.json"
        static let meetingHistory  = "meeting-history.jsonl"
    }

    static var vocabularyURL: URL      { url.appendingPathComponent(FileName.vocabulary) }
    static var personalContextURL: URL { url.appendingPathComponent(FileName.personalContext) }
    static var speakersURL: URL        { url.appendingPathComponent(FileName.speakers) }
    static var meetingHistoryURL: URL  { url.appendingPathComponent(FileName.meetingHistory) }

    // MARK: - Initialization

    /// Create the support directory if it doesn't already exist. Called once at app launch (see
    /// `AppDelegate.applicationDidFinishLaunching`) so it's always present before any dependent
    /// (SpeakerStore, Vocabulary, PersonalContext, MeetingHistory) does its first file I/O, and
    /// by `configure(root:)` for tests/BENCH.
    static func ensureExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Every dependent store degrades gracefully on write failure, so this is the one
            // place a broken support dir is visible at all — vocabulary/personal-context/speaker
            // persistence silently stops working without it.
            Logger.log("SupportDir", "FAILED to create support directory at \(url.path): \(error)")
        }
    }
}
