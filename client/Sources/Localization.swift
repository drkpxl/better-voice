import Foundation

/// 轻量级双语字符串助手，便于逐步本地化界面而不引入 String Catalog 构建复杂度。
/// 语言来自 config.json 的 "language"，缺省时跟随系统；以 "zh" 开头视为中文。
///
/// Lightweight bilingual string helper. Lets us localize the UI incrementally
/// without the build complexity of a String Catalog. Language comes from
/// config.json "language" (falling back to the system language); anything
/// starting with "zh" is treated as Chinese, everything else as English.
enum L10n {
    @MainActor
    static var isChinese: Bool {
        let lang = RuntimeConfig.shared.language
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
        return lang.lowercased().hasPrefix("zh")
    }

    /// 返回当前语言对应的字符串。/ Returns the string for the current language.
    @MainActor
    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
