import Foundation

/// 本地化字符串查找。键即英文原文；翻译位于 Resources/Localizable.xcstrings。
/// 新增语言只需在 String Catalog 中增加一列，无需改代码。
///
/// Localized string lookup. The key IS the English source text; translations
/// live in `Resources/Localizable.xcstrings`. To add a language (e.g. German),
/// add a localization in that catalog — no code changes required.
///
/// Supports interpolation: `t("Model: \(name)")` resolves against the catalog
/// key `"Model: %@"`.
func t(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
