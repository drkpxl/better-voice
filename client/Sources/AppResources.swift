import Foundation

extension Bundle {
    /// The SwiftPM resource bundle (localized strings, editor.html), resolved for BOTH the
    /// shipped .app layout and `swift build` development runs.
    ///
    /// Do NOT use `Bundle.module` directly anywhere in this app. SwiftPM's generated accessor
    /// for EXECUTABLE targets only checks two places: (1) the app-bundle ROOT
    /// (`BetterVoice2.app/BetterVoice2_BetterVoice2.bundle`) — where nothing may legally live in
    /// a signed app — and (2) the absolute build-machine path baked in at compile time
    /// (`/Users/runner/work/...` for CI builds). Neither exists on a user's machine, so the
    /// first `Bundle.module` touch fatalErrors.
    ///
    /// `build-dmg.sh` and the Makefile place the bundle at `Contents/Resources` (the
    /// conventional location), so look there first; fall back to `Bundle.module` for
    /// unpackaged development runs, where the baked build path is correct.
    static let appResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BetterVoice2_BetterVoice2.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
