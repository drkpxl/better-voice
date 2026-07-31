import Foundation
import BetterVoiceCore

/// System prompts (English). Summarization only -- the dictation-cleanup prompt went away with the
/// cleanup stage itself.
enum Prompts {

    // MARK: - Meeting summarization templates

    private static let summarizeCommonRulesEN = """
    The input is a meeting transcript. Each line is "Speaker: text" (speakers may \
    be named or labelled "Speaker N"). The transcript came from speech-to-text and \
    may contain small errors — use judgement.

    Rules:
    - Refer to people by the names/labels used in the transcript. Never invent names or facts.
    - Be factual and complete. Do not include anything that was not said, but do not leave out \
    anything that was.
    - Output GitHub-flavoured Markdown only — no preamble, no code fences around the whole answer.
    - Write in the language the meeting was conducted in.
    """

    /// Extra instruction the title-requesting summarization path (`summarizeWithTitle`, used by
    /// the Apple Notes writer) appends AFTER prompt resolution — so it applies on top of the
    /// built-in templates AND user-custom prompt overrides alike, while the plain `summarize`
    /// path (pasted-transcript export, re-summarize) never asks for or strips a title line.
    static let summaryTitleInstructionEN = """
    Additionally: before the summary, output exactly one line "TITLE: <short title>" — a short, \
    plain-text title (6 words or fewer, no trailing punctuation, no markdown) naming what the \
    meeting was about — then a blank line, then the summary itself as described above.
    """

    /// Dedicated follow-up "give me just a title" prompt — used by
    /// `SummarizationClient.generateFallbackTitle` only when the inline `TITLE:` line above
    /// wasn't produced (see that function's doc comment). Deliberately narrower/simpler than
    /// `summaryTitleInstructionEN`: this call's whole prompt IS the title request, so there is no
    /// leading-line convention to parse — `sanitizeGeneratedTitle` (Core) still defensively
    /// cleans up quotes/labels/markdown a model might add anyway.
    static let titleOnlyInstructionEN = """
    You write short titles for meeting notes. Given a meeting summary or transcript excerpt, \
    reply with ONLY a short, plain-text title (3–6 words) naming what the meeting was about — \
    no quotes, no markdown, no trailing punctuation, no "Title:" label, no preamble or \
    explanation. Just the title text itself, on one line.
    """

    /// Summary — general meeting.
    static let summarizeGeneralEN = """
    You are a meeting-notes assistant. Summarize the meeting for someone who missed it.

    \(summarizeCommonRulesEN)

    Structure the summary as:
    ## Summary
    A paragraph of what the meeting was about and any outcome.
    ## Key points
    Bullet points covering EVERY distinct topic and decision discussed, including ones raised in \
    the middle of the meeting. Do not omit a topic because the meeting moved on from it.
    ## Action items
    Bullet points as "- [owner] action" for every commitment or follow-up. Omit the \
    section only if there were genuinely none.
    """

    /// Summary — 1:1.
    static let summarizeOneOnOneEN = """
    You are a notes assistant for a 1:1 conversation between two people. Capture it \
    so both participants remember what was discussed and agreed.

    \(summarizeCommonRulesEN)

    Structure the summary as:
    ## Summary
    A short paragraph of the overall conversation and tone.
    ## Topics discussed
    Bullet points grouped by topic, attributing views to the right person where it matters.
    ## Feedback & growth
    Any feedback, concerns, or development/career points raised (omit if none).
    ## Action items
    "- [owner] action" for every commitment made by either person (omit if none).
    """

    /// Summary — status / standup.
    static let summarizeStandupEN = """
    You are a notes assistant for a status/standup meeting. Produce a crisp status digest.

    \(summarizeCommonRulesEN)

    Structure the summary as:
    ## Status by person
    For each participant who reported: "### Name" then bullets for what they did, are \
    doing next, and anything notable.
    ## Blockers
    Bullet points of blockers/risks raised, with who is affected (omit if none).
    ## Action items
    "- [owner] action" for every follow-up agreed (omit if none).
    """

    /// Meeting-type classification.
    static let meetingTypeClassificationEN = """
    Classify the meeting transcript into exactly one type. Reply with ONLY one of \
    these words, nothing else:
    one_on_one — a conversation between two people / a 1:1.
    standup — a status update, standup, or scrum where people report progress.
    general — anything else.
    """

    /// Built-in summarization prompt for a meeting type.
    static func builtinSummarizationPrompt(for type: MeetingType, language: String? = nil) -> String {
        switch type {
        case .general:  return summarizeGeneralEN
        case .oneOnOne: return summarizeOneOnOneEN
        case .standup:  return summarizeStandupEN
        }
    }

    /// Selected summarization system prompt: a config override wins, else the built-in template.
    static func summarizationPrompt(for type: MeetingType, overrides: [String: String], language: String? = nil) -> String {
        resolveSummarizationPrompt(type: type, overrides: overrides) {
            builtinSummarizationPrompt(for: $0)
        }
    }

    /// Meeting-type classification system prompt.
    static func meetingTypeClassificationPrompt(language: String? = nil) -> String {
        meetingTypeClassificationEN
    }
}
