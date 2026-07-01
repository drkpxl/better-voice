import Foundation

/// A seam for matching and enrolling speaker voice embeddings across meetings.
///
/// This is the documented hook the (later) speaker-fingerprinting work will implement with real
/// persistence. It deliberately carries NO persistence, file I/O, or pipeline wiring — the only
/// concrete conformance here is an in-memory implementation used for testing the interface shape.
public protocol SpeakerRegistry {
    /// Returns the best-matching enrolled speaker id and its cosine distance (0 = identical,
    /// up to 2 = opposite), or nil if no enrolled speaker is within the registry's threshold.
    func match(_ embedding: [Float]) -> (id: String, distance: Float)?
    /// Enroll or update a speaker's reference embedding. Implementations may average with any
    /// existing embedding for that id (running centroid) or replace it — document which.
    mutating func upsert(id: String, embedding: [Float])
}

/// In-memory `SpeakerRegistry` using cosine distance. No persistence — value-type storage only.
///
/// `upsert` maintains a **running centroid** per id: the first upsert stores the embedding with a
/// count of 1; each later upsert updates the stored reference to the incremental mean
/// `newRef = (oldRef * n + embedding) / (n + 1)` and bumps the count to `n + 1`. If an upsert's
/// length differs from the stored reference for that id, the stored value is simply **replaced**
/// (count reset to 1) rather than averaged.
///
/// `match` returns the enrolled id with the smallest cosine distance to the query, but only when
/// that distance is `<= threshold`; otherwise `nil`. References whose length differs from the
/// query are skipped defensively, and zero-norm vectors never match.
public struct InMemorySpeakerRegistry: SpeakerRegistry, Sendable {
    /// Maximum cosine DISTANCE (0…2) for a query to count as a match. Tune later.
    private let threshold: Float
    private var references: [String: (embedding: [Float], count: Int)] = [:]

    public init(threshold: Float = 0.35) {
        self.threshold = threshold
    }

    /// Number of enrolled speakers.
    public var count: Int { references.count }

    public func match(_ embedding: [Float]) -> (id: String, distance: Float)? {
        var best: (id: String, distance: Float)?
        for (id, ref) in references {
            guard ref.embedding.count == embedding.count else { continue }   // skip mismatched length
            let distance = cosineDistance(embedding, ref.embedding)
            guard distance.isFinite else { continue }                        // zero-norm → no match
            if best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        guard let winner = best, winner.distance <= threshold else { return nil }
        return winner
    }

    public mutating func upsert(id: String, embedding: [Float]) {
        guard let existing = references[id], existing.embedding.count == embedding.count else {
            references[id] = (embedding, 1)   // new id, or length changed → replace
            return
        }
        let n = Float(existing.count)
        var updated = [Float](repeating: 0, count: embedding.count)
        for i in 0..<embedding.count {
            updated[i] = (existing.embedding[i] * n + embedding[i]) / (n + 1)
        }
        references[id] = (updated, existing.count + 1)
    }
}

// MARK: - Cosine helpers (Foundation-only; no Accelerate)

/// Cosine similarity of two equal-length vectors. Returns 0 if either vector has zero norm
/// (so cosine distance becomes 1 — a non-match rather than a divide-by-zero).
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    guard na > 0, nb > 0 else { return .nan }   // zero-norm → signal no-match via NaN distance
    return dot / (sqrt(na) * sqrt(nb))
}

/// Cosine distance = `1 - cosineSimilarity` (0 = identical … 2 = opposite). NaN for zero-norm
/// inputs so callers can treat them as non-matches.
func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    1 - cosineSimilarity(a, b)
}
