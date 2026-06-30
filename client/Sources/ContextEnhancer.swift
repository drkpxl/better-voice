import Foundation

/// 组装 SpeechAnalyzer.contextualStrings 的统一入口
/// 来源：纠错字典（可关）
/// Apple 建议 contextualStrings 总长 ≤100 项
@MainActor
enum ContextEnhancer {
    private static let maxContextualStrings = 100

    /// 组合字典术语为 contextualStrings
    /// 开关由 config.polish.context_dictionary_enabled 控制
    static func enhance(
        dictionaryEnabled: Bool,
        dictionaryPath: String?
    ) async -> [String] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var result: [String] = []
        var seen = Set<String>()

        // 字典术语（高频术语，用户明确定义）
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
