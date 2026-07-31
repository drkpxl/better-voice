import AppKit
import BetterVoiceCore
import Foundation

/// Personal context (personalization)
///
/// A free-text markdown file `<SupportDir>/personal-context.md` (see `SupportDir.swift`), manually
/// edited by the user.
/// The content describes the user's semantic background -- common meeting participants,
/// company, job title, recurring terms/topics, etc. At inference time it is appended
/// after the system prompt to help the model disambiguate names, terms, and references
/// during meeting summarization -- the only consumer, now that dictation cleanup is gone. It was
/// never used for dictation anyway: a short input caused local models to echo the whole block into
/// the user's text.
///
/// This replaces the earlier "fine-tune a small model" personalization approach:
/// the context can be edited anytime and carries semantics, not just misspelling
/// mappings (those live in `Vocabulary`).
enum PersonalContext {

    /// Path to the personal context file.
    static var fileURL: URL { SupportDir.personalContextURL }

    /// Creates the personal context file from the starter template if it doesn't exist yet.
    /// Called before opening the in-app editor window (`TextFileEditorScene.swift`); does not
    /// open anything itself. Shared by Settings and onboarding.
    static func ensureCreated() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        SupportDir.ensureExists()
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Starter template written on first creation, to help users get going.
    static let template = """
    # Personal context

    This file gives the local AI background about you so it spells names, jargon,
    and acronyms correctly when summarizing meetings. It is used only for
    disambiguation — it is never added to your summaries.

    Edit freely. Useful things to include:
    - Your name and how it's spelled.
    - Your company / team and what it does.
    - Your role / title.
    - People you talk to often (names + roles).
    - Recurring projects, products, tools, and acronyms.

    ## About me


    ## People


    ## Projects & terms

    """

    /// Reads the raw personal context file. Returns nil if it doesn't exist or is entirely blank.
    ///
    /// This is the *editing* accessor: it deliberately returns the file verbatim, scaffolding and
    /// all, because `WelcomeWindow.persistPersonalContext` writes the editor's text straight back
    /// over the file. Returning anything trimmed or filtered here would make onboarding silently
    /// destroy the user's headings. For the value to put in a prompt, use `promptContext()`.
    static func load() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The context worth sending to a model: what the user actually wrote, or nil if that's nothing.
    ///
    /// `load()` cannot answer this — an untouched starter template is not empty, so a plain
    /// `isEmpty` check treats a blank form as real background and ships it on every polish and
    /// summary. See `PersonalContextRules.authoredContent` for the reasoning and the measurements.
    static func promptContext() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let authored = PersonalContextRules.authoredContent(in: text, scaffolding: template)
        return authored.isEmpty ? nil : authored
    }

    /// Appends the personal context after the given system prompt.
    ///
    /// When `personal_context_enabled` (default true) is true and the user has written
    /// something into the file, appends a "Personal context" block with explicit instructions;
    /// otherwise returns `base` unchanged. An untouched starter template counts as nothing written.
    @MainActor
    static func appended(to base: String) -> String {
        guard RuntimeConfig.shared.personalContextEnabled, let context = promptContext() else { return base }

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
