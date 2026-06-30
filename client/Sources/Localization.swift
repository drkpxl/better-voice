import Foundation

/// Localized string lookup. The key IS the English source text; values live in
/// `Resources/en.lproj/Localizable.strings`. To add a language, copy that folder
/// to `<lang>.lproj` and translate the values — no code changes required.
///
/// Supports interpolation: `t("Model: \(name)")` resolves against the catalog
/// key `"Model: %@"`.
func t(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
