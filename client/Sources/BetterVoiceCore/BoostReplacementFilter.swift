import Foundation

/// Applies the vocabulary booster's suggested swaps, keeping only the safe ones.
///
/// FluidAudio's rescorer sometimes "matches" a vocabulary term against a longer span that merely
/// contains it, and replaces the whole span — measured: "…review the Terraform Plan in Grafana."
/// became "…review the Grafana", silently deleting three words, and "baseline makes is" became
/// "Baseline Makes". So a swap that shrinks the word count is rejected when the span contains the
/// term's own words plus extras (that is deletion, not correction). Otherwise a shrinking swap
/// needs either to be one of the user's own "heard as" aliases ("cooper net ease" → "Kubernetes"),
/// or to spell much the same letters ("Kuba needs" → "Kubernetes"). Swaps that keep or grow the
/// word count still have to spell much the same letters as the term: on real speech the rescorer
/// proposes plenty of acoustically "supported" nonsense — measured in live use, "…match our brand
/// styles" became "…match our brand Emmie", and it suggested "functionally it does" → "Ikon Pass".
///
/// Punctuation around a replaced span is kept: the rescorer's span carries the sentence's period,
/// and its replacement doesn't.
public enum BoostReplacementFilter {
    public struct Swap: Equatable, Sendable {
        public let original: String
        public let replacement: String
        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
    }

    /// - Parameters:
    ///   - text: the engine's transcript.
    ///   - swaps: the rescorer's accepted replacements, in transcript order.
    ///   - aliases: per term (lowercased), the spellings it is known to be mis-heard as.
    public static func apply(to text: String, swaps: [Swap], aliases: [String: [String]]) -> String {
        // The rescorer doesn't report positions and doesn't list swaps in transcript order, so each
        // span is located by its first remaining occurrence. A replaced span becomes the term,
        // which no longer matches the original, so a repeated word is handled one at a time.
        var result = text
        for swap in swaps where isSafe(swap, aliases: aliases) {
            guard let range = wordRange(of: swap.original, in: result) else { continue }
            let (lead, _, trail) = splitPunctuation(swap.original)
            let (_, core, _) = splitPunctuation(swap.replacement)
            result.replaceSubrange(range, with: lead + core + trail)
        }
        return result
    }

    /// First occurrence of `span` that isn't part of a longer word ("Tig" must not match "Tight").
    private static func wordRange(of span: String, in text: String) -> Range<String.Index>? {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: span) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: .regularExpression)
    }

    /// How alike (letters only) a span and the term must be. 0.5 keeps every correction measured on
    /// the jargon clips (the weakest: "SAOIS" → "Saoirse", 0.57) and rejects unrelated words.
    static let minimumSimilarity = 0.5

    static func isSafe(_ swap: Swap, aliases: [String: [String]]) -> Bool {
        let original = normalized(swap.original)
        let replacement = normalized(swap.replacement)
        guard !replacement.isEmpty else { return false }
        // The user's own "heard as" alias for the term is always trusted.
        if (aliases[replacement] ?? []).contains(where: { normalized($0) == original }) { return true }
        let originalWords = original.split(separator: " ")
        let replacementWords = replacement.split(separator: " ")
        // The term itself plus extra words: the swap would only delete the extras.
        if originalWords.count > replacementWords.count, contains(originalWords, replacementWords) { return false }
        // Otherwise the span must look like a mis-hearing of the term, whatever the word counts.
        return letterSimilarity(original, replacement) >= minimumSimilarity
    }

    private static func contains(_ words: [Substring], _ run: [Substring]) -> Bool {
        guard !run.isEmpty, run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }

    /// 1 − edit distance / longer length, over letters only ("kuba needs" vs "kubernetes").
    static func letterSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.filter(\.isLetter)), y = Array(b.filter(\.isLetter))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    private static func normalized(_ s: String) -> String {
        splitPunctuation(s).core.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).count
    }

    /// Leading punctuation, the rest, trailing punctuation.
    private static func splitPunctuation(_ s: String) -> (lead: String, core: String, trail: String) {
        let isPunct: (Character) -> Bool = { $0.isPunctuation || $0.isWhitespace }
        let lead = String(s.prefix(while: isPunct))
        let afterLead = s.dropFirst(lead.count)
        let trail = String(afterLead.reversed().prefix(while: isPunct).reversed())
        let core = String(afterLead.dropLast(trail.count))
        return (lead, core, trail)
    }
}
