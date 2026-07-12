import Foundation

/// Meeting type that selects which summarization prompt template is used.
public enum MeetingType: String, Sendable, CaseIterable, Identifiable {
    case general
    case oneOnOne
    case standup

    public var id: String { rawValue }

    /// Stable key used in the config `prompts` override dictionary.
    public var configKey: String {
        switch self {
        case .general:  return "general"
        case .oneOnOne: return "one_on_one"
        case .standup:  return "standup"
        }
    }

    /// Resolve from a config key (e.g. "one_on_one"). Returns nil for unknown values.
    public static func from(configKey: String) -> MeetingType? {
        let key = configKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.configKey == key }
    }

    /// Plain-English display name (the UI layer may localize further).
    public var defaultDisplayName: String {
        switch self {
        case .general:  return "General"
        case .oneOnOne: return "1:1"
        case .standup:  return "Status / Standup"
        }
    }
}
