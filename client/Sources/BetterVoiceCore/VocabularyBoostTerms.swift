import Foundation

/// Turns the user's vocabulary into the term list the engine's vocabulary booster scores against.
///
/// Every spelling the user wants to see becomes one term: plain terms as themselves, and each
/// replacement's `to` with its `from` ("cooper net ease" → "Kubernetes") as an alias, so the
/// booster knows what the mis-hearing sounds like. Terms that differ only by case merge, keeping
/// the first spelling. Very short terms are dropped — acoustic matching on two letters fires on
/// everything ("or" → "VR").
public enum VocabularyBoostTerms {
    public struct Term: Equatable, Sendable {
        public let text: String
        public let aliases: [String]
    }

    public static let minimumLength = 3

    public static func build(terms: [String], replacements: [VocabularyReplacement]) -> [Term] {
        var order: [String] = []
        var spelling: [String: String] = [:]
        var aliases: [String: [String]] = [:]

        func add(_ raw: String, alias: String?) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumLength else { return }
            let key = text.lowercased()
            if spelling[key] == nil {
                spelling[key] = text
                order.append(key)
                aliases[key] = []
            }
            if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alias.isEmpty, alias.lowercased() != key,
               !(aliases[key] ?? []).contains(where: { $0.lowercased() == alias.lowercased() }) {
                aliases[key, default: []].append(alias)
            }
        }

        for term in terms { add(term, alias: nil) }
        for r in replacements { add(r.to, alias: r.from) }

        return order.map { Term(text: spelling[$0]!, aliases: aliases[$0] ?? []) }
    }
}
