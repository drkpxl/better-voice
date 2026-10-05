import Foundation

/// Language decisions that don't need the engine.
public enum SpeechLanguageRules {
    /// Whether the English filler-word pass (`FillerStripper`) should run.
    ///
    /// Its word list is English ("um", "uh", sentence-opening "so"/"well"), and several entries are
    /// real words elsewhere (German "so", Dutch "wel"), so running it on other languages deletes
    /// content. With an explicit speech language the answer is simply "is it English". On Automatic
    /// the engine doesn't report what it detected, so the user's primary system language stands in.
    ///
    /// - Parameters:
    ///   - speechLanguage: the configured code ("en", "de", …), or nil/empty for Automatic.
    ///   - preferredLanguages: `Locale.preferredLanguages` (BCP-47, most preferred first).
    public static func fillerStrippingApplies(speechLanguage: String?, preferredLanguages: [String]) -> Bool {
        if let code = speechLanguage?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            return primarySubtag(code) == "en"
        }
        guard let first = preferredLanguages.first else { return true }
        return primarySubtag(first) == "en"
    }

    /// "en-US" → "en", "zh-Hans-CN" → "zh".
    public static func primarySubtag(_ tag: String) -> String {
        String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }
}
