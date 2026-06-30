import Foundation

/// Unified entry point for assembling SpeechAnalyzer.contextualStrings
/// Source: the correction dictionary (can be disabled)
/// Apple recommends keeping the total contextualStrings count <=100
@MainActor
enum ContextEnhancer {
    private static let maxContextualStrings = 100

    /// Combines dictionary terms into contextualStrings
    /// Controlled by the config.polish.context_dictionary_enabled toggle
    static func enhance(
        dictionaryEnabled: Bool,
        dictionaryPath: String?
    ) async -> [String] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var result: [String] = []
        var seen = Set<String>()

        // Dictionary terms (high-frequency terms explicitly defined by the user)
        var dictCount = 0
        if dictionaryEnabled, let path = dictionaryPath {
            CorrectionDictionary.shared.load(from: path)
            for term in CorrectionDictionary.shared.terms {
                guard result.count < maxContextualStrings else { break }
                if seen.insert(term).inserted {
                    result.append(term)
                    dictCount += 1
                }
            }
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        Logger.log("Ctx", "enhance: dict=\(dictCount) total=\(result.count) elapsedMs=\(elapsedMs)")
        return result
    }
}
