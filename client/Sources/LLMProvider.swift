import SwiftUI

/// The summarization provider choice, in one place.
///
/// The picker and the endpoint default were duplicated verbatim in `SettingsWindow` and
/// `WelcomeWindow`, and both copies carried a comment acknowledging it ("Mirrors Settings'
/// `providerPicker` tags exactly"). A known duplication with a note asking the next reader to keep it
/// in sync is a drift waiting to happen, and the drift is user-visible: add a provider to one screen
/// and onboarding and Settings would offer different lists, or worse, agree on a label while
/// disagreeing on the tag written to config.
///
/// The tag strings are the contract — they are what `ServerConnectionConfig.api` persists and what
/// `ModelServer` dispatches on, so they must match `LLMBackend`'s `apiType` values exactly.
enum LLMProvider: String, CaseIterable {
    case apple
    case ollama
    case openai

    /// Localized label for the picker. `Ollama` is a product name and deliberately not localized.
    var label: String {
        switch self {
        case .apple:  return t("Apple on-device")
        case .ollama: return "Ollama"
        case .openai: return t("OpenAI-compatible")
        }
    }

    /// Ollama's well-known local default. No such universal default exists for an arbitrary
    /// OpenAI-compatible server, and Apple on-device has no endpoint at all, so both are blank —
    /// which is also what the "is this configured" checks read as "nothing to reach".
    var defaultEndpoint: String {
        self == .ollama ? "http://localhost:11434" : ""
    }

    /// Endpoint default for a raw tag, for the call sites that hold `String` rather than this enum.
    /// An unrecognized tag yields "" rather than trapping: the value comes from persisted config, and
    /// a config written by a newer build must not crash an older one.
    static func defaultEndpoint(forTag tag: String) -> String {
        LLMProvider(rawValue: tag)?.defaultEndpoint ?? ""
    }
}

/// The provider picker, shared by Settings and onboarding so their lists cannot diverge.
struct LLMProviderPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                Text(provider.label).tag(provider.rawValue)
            }
        } label: {
            Text(t("Provider"))
        }
    }
}
