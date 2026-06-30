import Foundation

/// Loads ~/.better-voice/correction-dictionary.json
/// File format: {"correct term": {"errors": [...], "frequency": N, "source": "..."}, ...}
/// Injected into SA's contextualStrings, using the correct terms as hints
@MainActor
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private(set) var terms: [String] = []
    private(set) var loadedPath: String?

    private init() {}

    /// Loads the dictionary, returns whether it succeeded
    @discardableResult
    func load(from path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.log("Dict", "Load failed: \(expanded)")
            terms = []
            loadedPath = nil
            return false
        }

        let keys = Array(json.keys)
        terms = keys
        loadedPath = expanded
        Logger.log("Dict", "Loaded \(keys.count) terms from \(expanded)")
        return true
    }
}
