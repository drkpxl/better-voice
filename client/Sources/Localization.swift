import Foundation

/// Localized string lookup. The key IS the English source text; values live in
/// `Resources/en.lproj/Localizable.strings`. To add a language, copy that folder
/// to `<lang>.lproj` and translate the values — no code changes required.
///
/// Supports interpolation: `t("Model: \(name)")` resolves against the catalog
/// key `"Model: %@"`.
func t(_ key: String.LocalizationValue) -> String {
    // .appResources, NOT .module — see AppResources.swift (shipped apps crash on .module).
    String(localized: key, bundle: .appResources)
}
