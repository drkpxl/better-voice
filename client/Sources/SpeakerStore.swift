import Foundation
import BetterVoiceCore

/// App-layer persistence for the cross-meeting voice fingerprint book (`KnownSpeakers`),
/// backed by `<SupportDir>/speakers.json` (pattern of `RuntimeConfig`).
///
/// Thin wrapper over the tested Core type: `suggestions(for:)` and `learn(names:embeddings:)`
/// are each one line over `KnownSpeakers`, so this class is not unit-tested (file I/O only) —
/// its logic is covered by `KnownSpeakersTests`.
@MainActor
final class SpeakerStore {
    static let shared = SpeakerStore()

    /// Resolved from the support directory on every access — it's auto-created at app launch
    /// (or by tests/BENCH's `SupportDir.configure(root:)`) before any speaker I/O runs.
    private var fileURL: URL { SupportDir.speakersURL }
    private var book: KnownSpeakers

    private init() {
        self.book = Self.load(from: SupportDir.speakersURL)
    }

    private static func load(from url: URL) -> KnownSpeakers {
        guard FileManager.default.fileExists(atPath: url.path) else { return KnownSpeakers() }
        do {
            let data = try Data(contentsOf: url)
            let book = try JSONDecoder().decode(KnownSpeakers.self, from: data)
            Logger.log("Speakers", "Loaded \(book.profiles.count) known speaker(s) from \(url.path)")
            return book
        } catch {
            Logger.log("Speakers", "Failed to load speakers.json, starting empty: \(error)")
            return KnownSpeakers()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(book)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.log("Speakers", "Failed to save speakers.json: \(error)")
        }
    }

    /// Suggest a known name for each meeting speaker's embedding (speakerId -> name), deduped so
    /// no two speakers are suggested the same profile. See `KnownSpeakers.suggestNames(for:)`.
    func suggestions(for embeddings: [String: [Float]]) -> [String: String] {
        book.suggestNames(for: embeddings)
    }

    /// Learn/refresh voice profiles from the names the user confirmed in the wrap-up panel.
    /// Only speakers present in BOTH `names` and `embeddings` are enrolled (an empty `names` map,
    /// e.g. the user pressed Skip, learns nothing). Persists immediately.
    func learn(names: [String: String], embeddings: [String: [Float]]) {
        guard !names.isEmpty else { return }
        var changed = false
        for (speakerId, name) in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let embedding = embeddings[speakerId] else { continue }
            book.learn(name: trimmed, embedding: embedding)
            changed = true
        }
        guard changed else { return }
        save()
        Logger.log("Speakers", "Learned voice profile(s); book now has \(book.profiles.count) speaker(s)")
    }
}
