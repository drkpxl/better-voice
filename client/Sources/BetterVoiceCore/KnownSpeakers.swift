import Foundation

/// A persisted, named voice profile: the running-centroid embedding of one person.
public struct SpeakerProfile: Codable, Sendable, Equatable {
    public var name: String        // display casing = first seen
    public var embedding: [Float]  // running centroid (see InMemorySpeakerRegistry doc)
    public var sampleCount: Int

    public init(name: String, embedding: [Float], sampleCount: Int) {
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
    }
}

/// Cross-meeting fingerprint book: a set of named voice profiles, matched/updated by cosine
/// distance. Pure value type — persistence (reading/writing `<workspace>/speakers.json`)
/// lives in the app layer (`SpeakerStore`).
///
/// Implements the `SpeakerRegistry` seam (`Sources/BetterVoiceCore/SpeakerRegistry.swift`) using
/// the profile NAME as the registry id, so `KnownSpeakers` can be dropped in anywhere that seam
/// is expected.
///
/// Name identity is `trimmed.lowercased()` (so "Sam" and " sam " are the same person), but the
/// first-seen casing is kept for display. `learn` updates the matched profile's embedding as a
/// running centroid, exactly like `InMemorySpeakerRegistry.upsert`: `newRef = (oldRef * n +
/// embedding) / (n + 1)`, count incremented; a length mismatch replaces the stored embedding
/// (count reset to 1) instead of averaging.
public struct KnownSpeakers: Codable, Sendable, Equatable, SpeakerRegistry {
    public private(set) var profiles: [SpeakerProfile] = []

    /// Same tested default as `InMemorySpeakerRegistry`. Voices are noisier across meetings
    /// (mic vs. compressed system audio) than within one, so keep this conservative and always
    /// let the user edit/correct a suggested name.
    public static let matchThreshold: Float = 0.35

    public init() {}

    /// Index of the profile matching `name` (case/whitespace-insensitive), if any.
    private func profileIndex(forName name: String) -> Int? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profiles.firstIndex { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
    }

    /// Best-matching enrolled profile for `embedding`, or nil when the closest one is farther
    /// than `threshold` (or the book is empty).
    public func bestMatch(for embedding: [Float],
                          threshold: Float = Self.matchThreshold) -> (name: String, distance: Float)? {
        var best: (name: String, distance: Float)?
        for profile in profiles {
            guard profile.embedding.count == embedding.count else { continue }
            let distance = cosineDistance(embedding, profile.embedding)
            guard distance.isFinite else { continue }
            if best == nil || distance < best!.distance {
                best = (profile.name, distance)
            }
        }
        guard let winner = best, winner.distance <= threshold else { return nil }
        return winner
    }

    /// Enroll or refresh a named voice profile. Merges into the existing profile for `name`
    /// (case/whitespace-insensitive) as a running centroid, keeping the first-seen casing.
    public mutating func learn(name: String, embedding: [Float]) {
        if let idx = profileIndex(forName: name) {
            let existing = profiles[idx]
            guard existing.embedding.count == embedding.count else {
                profiles[idx] = SpeakerProfile(name: existing.name, embedding: embedding, sampleCount: 1)
                return
            }
            let n = Float(existing.sampleCount)
            var updated = [Float](repeating: 0, count: embedding.count)
            for i in 0..<embedding.count {
                updated[i] = (existing.embedding[i] * n + embedding[i]) / (n + 1)
            }
            profiles[idx] = SpeakerProfile(name: existing.name, embedding: updated, sampleCount: existing.sampleCount + 1)
        } else {
            profiles.append(SpeakerProfile(name: name, embedding: embedding, sampleCount: 1))
        }
    }

    /// For each meeting speaker embedding, suggest the enrolled profile name it best matches —
    /// but each profile is suggested to at most ONE speaker (the one with the smallest distance),
    /// so two meeting speakers never both get named "Sam".
    public func suggestNames(for embeddings: [String: [Float]],
                             threshold: Float = Self.matchThreshold) -> [String: String] {
        // Collect every (speakerId, profileName, distance) candidate within threshold.
        var candidates: [(speakerId: String, name: String, distance: Float)] = []
        for (speakerId, embedding) in embeddings {
            guard let match = bestMatch(for: embedding, threshold: threshold) else { continue }
            candidates.append((speakerId, match.name, match.distance))
        }
        // Closest matches win first, so a profile is claimed by its nearest speaker.
        candidates.sort { $0.distance < $1.distance }

        var suggestions: [String: String] = [:]
        var claimedNames: Set<String> = []
        for candidate in candidates {
            guard suggestions[candidate.speakerId] == nil, !claimedNames.contains(candidate.name) else { continue }
            suggestions[candidate.speakerId] = candidate.name
            claimedNames.insert(candidate.name)
        }
        return suggestions
    }

    // MARK: - SpeakerRegistry conformance (profile name = registry id)

    public func match(_ embedding: [Float]) -> (id: String, distance: Float)? {
        guard let m = bestMatch(for: embedding) else { return nil }
        return (id: m.name, distance: m.distance)
    }

    public mutating func upsert(id: String, embedding: [Float]) {
        learn(name: id, embedding: embedding)
    }
}
