import AppKit
import BetterVoiceCore
import Foundation

/// Custom vocabulary (roadmap §7)
///
/// A user-edited markdown file `<SupportDir>/vocabulary.md` (see `SupportDir.swift`), hot-reloaded
/// and editable in-app (Settings → Edit Vocabulary...) via `TextFileEditorScene.swift`.
/// Complements personal context: the context file carries *meaning* (who/what the user talks
/// about), the vocabulary carries *spellings*. Two kinds of entries:
///
///   - `terms`: correct spellings ("FluidAudio", "GitHub"). Injected as a terse list into the
///     polish system prompt, and applied as case-normalization replacements (any case-variant
///     at a word boundary becomes the canonical spelling).
///   - `replacements`: explicit misheard→correct fixes ({"from": "fluid audio", "to":
///     "FluidAudio"}). Applied deterministically AFTER the model, so exact terms are
///     guaranteed even when the model misses — or when polish is disabled. Deliberately NOT
///     injected into the prompt: that would teach the model the misspellings.
///
/// Matching semantics live in `BetterVoiceCore/VocabularyRules.swift` (tested):
/// case-insensitive, word-boundary, longest-then-leftmost on overlap, no chaining.
@MainActor
final class Vocabulary {
    static let shared = Vocabulary()

    private(set) var terms: [String] = []
    private(set) var replacements: [VocabularyReplacement] = []

    private var fileURL: URL { SupportDir.vocabularyURL }
    private var fileWatcher: DispatchSourceFileSystemObject?

    private init() {
        load()
        armWatcher()
    }

    // MARK: - Applying

    /// Deterministic post-replacements. Applied to dictation final text and meeting turn
    /// text — the seams where text becomes user-visible/persisted.
    func apply(to text: String) -> String {
        guard !text.isEmpty, !(terms.isEmpty && replacements.isEmpty) else { return text }
        let result = VocabularyRules.apply(text, terms: terms, replacements: replacements)
        if result != text {
            Logger.log("Vocabulary", "Applied replacements (\(text.count) -> \(result.count) chars)")
        }
        return result
    }

    /// Terse vocabulary block appended to the polish system prompt; nil when there are no
    /// terms. Kept short and inline (capped at ~600 chars of terms) — the PersonalContext
    /// lesson: large injected blocks get echoed into short dictations by local models.
    var promptBlock: String? {
        guard !terms.isEmpty else { return nil }
        var included: [String] = []
        var chars = 0
        for term in terms {
            chars += term.count + 2
            if chars > 600 {
                Logger.log("Vocabulary", "Prompt block capped: \(terms.count - included.count) of \(terms.count) terms dropped")
                break
            }
            included.append(term)
        }
        guard !included.isEmpty else { return nil }
        return """


        ## Vocabulary
        The speaker uses these exact spellings. When a word in the text plausibly \
        matches one of them, use the exact spelling as written here: \
        \(included.joined(separator: ", ")).
        """
    }

    // MARK: - Editing / import

    /// Creates the vocabulary file from the starter template if it doesn't exist yet. Called
    /// before opening the in-app editor window (`TextFileEditorScene.swift`); does not open
    /// anything itself.
    func ensureCreated() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        SupportDir.ensureExists()
        try? Self.template.write(to: fileURL, atomically: true, encoding: .utf8)
        load()
        armWatcher()
    }

    /// Starter template: both sections start empty so no example entry ever rewrites real
    /// text. Kept in sync with `renderVocabularyMarkdown`'s prose (Core owns the canonical
    /// render used by `save()`; this is just the very first file a user ever sees).
    static let template = renderVocabularyMarkdown(terms: [], replacements: [])

    /// Merges new terms (e.g. from the onboarding Vocabulary step) into the existing list,
    /// skipping blanks and anything already present (case-insensitively) — additive only, so
    /// re-running onboarding (Setup Guide) can never drop a term added later in Settings.
    /// `replacements` are untouched. No-ops (and doesn't touch the file) if nothing new to add.
    func addTerms(_ newTerms: [String]) {
        var seen = Set(terms.map { $0.lowercased() })
        var merged = terms
        for raw in newTerms {
            let term = raw.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            merged.append(term)
        }
        let addedCount = merged.count - terms.count
        guard addedCount > 0 else { return }
        terms = merged
        save()
        Logger.log("Vocabulary", "Added \(addedCount) term(s) from onboarding")
    }

    /// Replace all entries from the structured editor (`VocabularyFormView`) and persist via the
    /// canonical `renderVocabularyMarkdown` (same path as `importCSV`). No-op when nothing changed,
    /// so the form can call this on every edit without redundant writes or churning the watcher.
    func update(terms newTerms: [String], replacements newReplacements: [VocabularyReplacement]) {
        guard newTerms != terms || newReplacements != replacements else { return }
        terms = newTerms
        replacements = newReplacements
        save()
        Logger.log("Vocabulary", "Updated from editor: \(terms.count) terms, \(replacements.count) replacements")
    }

    /// Import "from,to" CSV rows into `replacements` (an imported row wins over an existing
    /// one with the same `from`, case-insensitively; within the file, the last row wins).
    /// Returns the number of rows imported (0 for an unreadable/empty file).
    func importCSV(from url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.log("Vocabulary", "CSV import failed: cannot read \(url.path) as UTF-8")
            return 0
        }
        var seen = Set<String>()
        let imported = VocabularyRules.parseCSV(text)
            .reversed()
            .filter { seen.insert($0.from.lowercased()).inserted }
            .reversed()
        guard !imported.isEmpty else { return 0 }

        replacements = replacements.filter { !seen.contains($0.from.lowercased()) } + imported
        save()
        Logger.log("Vocabulary", "Imported \(imported.count) replacements from \(url.lastPathComponent)")
        return imported.count
    }

    // MARK: - Load / save / watch

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            terms = []
            replacements = []
            return
        }
        (terms, replacements) = parseVocabularyMarkdown(text)
        Logger.log("Vocabulary", "Loaded \(terms.count) terms, \(replacements.count) replacements")
    }

    /// Persist current entries back into the file as the canonical rendered markdown. Note:
    /// this regenerates the fixed instructional prose too — used only by the programmatic writes
    /// (`addTerms`, `importCSV`, `update`); the in-app editor's Save writes the user's raw text
    /// directly, so hand-added prose is never clobbered by a normal edit.
    private func save() {
        let text = renderVocabularyMarkdown(terms: terms, replacements: replacements)
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.log("Vocabulary", "Failed to save: \(error)")
        }
    }

    /// Hot reload. Unlike RuntimeConfig's plain `.write` watch, editors (and our own `save()`)
    /// replace the file atomically — a rename that orphans a watch on the old inode — so we
    /// also watch `.delete`/`.rename` and re-arm after every event. When the file doesn't
    /// exist yet, watch the data directory instead so first creation is picked up.
    private func armWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil

        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let watchPath = fileExists ? fileURL.path : SupportDir.url.path
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let mask: DispatchSource.FileSystemEvent = fileExists ? [.write, .delete, .rename] : .write
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.load()
            self.armWatcher()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }
}
