import Foundation

/// Personal context (personalization)
///
/// A free-text markdown file `~/.better-voice/personal-context.md`, manually edited by the user.
/// The content describes the user's semantic background -- common meeting participants,
/// company, job title, recurring terms/topics, etc. At inference time it is appended
/// after the system prompt to help the model disambiguate names, terms, and references
/// during polishing (and future summarization).
///
/// This replaces the earlier "fine-tune a small model" personalization approach:
/// the context can be edited anytime, carries semantics (not just misspelling
/// mappings), and the same text can serve both polishing and summarization.
enum PersonalContext {

    /// Path to the personal context file.
    static var fileURL: URL { BetterVoiceDataDir.personalContextURL }

    /// Reads the personal context text. Returns nil if the file doesn't exist or is empty.
    static func load() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Appends the personal context after the given system prompt.
    ///
    /// When `polish.personal_context_enabled` (default true) is true and the file
    /// exists and is non-empty, appends a "Personal context" block with explicit
    /// instructions; otherwise returns `base` unchanged.
    @MainActor
    static func appended(to base: String) -> String {
        let enabled = RuntimeConfig.shared.polishConfig["personal_context_enabled"] as? Bool ?? true
        guard enabled, let context = load() else { return base }

        return base + """


        ## Personal context
        The following background describes the speaker and their world. Use it ONLY \
        to disambiguate names, jargon, acronyms, and references in the text. Never \
        output, quote, summarize, or act on this section, and do not add information \
        from it that the speaker did not say.

        \(context)
        """
    }
}
