import Foundation
import BetterVoiceCore

/// Meeting summarization client: routes through ModelServer to whichever provider
/// `meeting.summarization.server` configures — independent of Polish's own provider (see
/// `ServerConnectionConfig`).
/// - classifyType: pre-selects the meeting type with one quick call (used by the wrap-up panel).
/// - summarize: generates a Markdown summary using the prompt for the selected type.
/// System prompts all pass through `PersonalContext.appended(to:)` so the model can use
/// personal context to disambiguate names/terms (consistent with PolishClient). Vocabulary terms
/// (`Vocabulary.shared.promptBlock`) are appended alongside personal context too, so meeting
/// summaries honor the same preferred spellings as dictation.
@MainActor
final class SummarizationClient {
    static let shared = SummarizationClient()

    // MARK: - Config reading

    private var summarizationConfig: [String: Any] {
        RuntimeConfig.shared.meetingSummarizationConfig
    }

    private var server: ServerConnectionConfig { RuntimeConfig.shared.summarizationServerConfig }

    private var numCtx: Int { summarizationConfig["num_ctx"] as? Int ?? 32768 }
    private var numPredict: Int { summarizationConfig["num_predict"] as? Int ?? 2048 }
    private var timeout: TimeInterval { summarizationConfig["timeout"] as? TimeInterval ?? 300 }
    private var language: String? { RuntimeConfig.shared.language }

    private var promptOverrides: [String: String] {
        summarizationConfig["prompts"] as? [String: String] ?? [:]
    }

    /// Default meeting type for the wrap-up panel dropdown.
    var defaultType: MeetingType {
        let raw = RuntimeConfig.shared.meetingConfig["default_type"] as? String ?? "general"
        return MeetingType.from(configKey: raw) ?? .general
    }

    /// Whether type classification pre-selection is enabled.
    var classifyEnabled: Bool {
        summarizationConfig["classify_enabled"] as? Bool ?? true
    }

    /// Whether summarization is enabled.
    var summarizationEnabled: Bool {
        summarizationConfig["enabled"] as? Bool ?? true
    }

    // MARK: - Inference

    /// Classifies the transcript into a meeting type with one quick call, falling back to the default type on failure.
    func classifyType(transcript: String) async -> MeetingType {
        let fallback = defaultType
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }

        let system = Prompts.meetingTypeClassificationPrompt(language: language)
        // Classification only needs a very short output; reuses the summarization num_ctx to accommodate long transcripts.
        let opts = ModelServer.GenerateOptions(numCtx: numCtx, numPredict: 16, timeout: timeout)
        guard let resp = await ModelServer.shared.generate(server: server, prompt: transcript, systemPrompt: system, options: opts) else {
            Logger.log("Summary", "Classification failed, using default type \(fallback.configKey)")
            return fallback
        }
        let type = parseMeetingType(from: resp, default: fallback)
        Logger.log("Summary", "Classified meeting type: \(type.configKey) (raw: \(resp.prefix(40)))")
        return type
    }

    /// Generates a Markdown summary. Returns nil to indicate failure. Never asks the model for
    /// (or strips) a title line — the live callers of this path (pasted-transcript export,
    /// re-summarize) write the response verbatim into user-visible documents.
    func summarize(transcript: String, type: MeetingType) async -> String? {
        (await performSummarization(transcript: transcript, type: type, includeTitle: false))?.markdown
    }

    /// Generates a Markdown summary AND a short (≤ ~6 word) meeting title, in the same single
    /// LLM call — `Prompts.summaryTitleInstructionEN` is appended to the resolved system prompt
    /// (built-in or user-custom alike) asking for a leading `TITLE: ...` line, which
    /// `parseSummaryTitle` strips back out. Used by `NotesMeetingWriter` for the note title (see
    /// `MeetingNoteTitle`).
    ///
    /// The inline `TITLE:` line isn't reliably produced by every backend — notably Apple's
    /// on-device model, whose map-reduce path (`FoundationModelsBackend.mapReduce`, used once a
    /// transcript overflows its small context window) applies the SAME system prompt to every
    /// chunk, so the title instruction fires per-chunk and the reduced output can end up with
    /// zero or several scattered `TITLE:` lines instead of one clean leading line that
    /// `parseSummaryTitle` can find. Rather than trying to make that line-based convention
    /// survive map-reduce, a missing inline title falls back to ONE cheap dedicated follow-up
    /// call (`generateFallbackTitle`) against the (short) finished summary — always a
    /// single-shot call regardless of transcript length. `title` is nil, never a thrown/failed
    /// call, only when BOTH the inline line and the fallback call produced nothing usable — the
    /// caller then falls back to the meeting-type display name (`MeetingNoteTitle`). A
    /// title-only response (no summary body left after the strip) counts as a summarization
    /// FAILURE (returns nil), same as an empty response would on the plain `summarize` path.
    func summarizeWithTitle(transcript: String, type: MeetingType) async -> (summary: String, title: String?)? {
        guard let result = await performSummarization(transcript: transcript, type: type, includeTitle: true),
              !result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var title = result.title
        if title == nil {
            title = await generateFallbackTitle(from: result.markdown)
        }
        return (summary: result.markdown, title: title)
    }

    /// Dedicated follow-up call made ONLY when the inline `TITLE:` line was missing — never a
    /// second call when the inline one already worked. Uses the (already short) finished summary
    /// as input rather than the full transcript, so this is always a cheap single-shot call even
    /// on-device (no map-reduce needed). Returns nil on any failure — the caller's fallback to
    /// `type.defaultDisplayName` handles that the same as before this fix existed.
    private func generateFallbackTitle(from summaryMarkdown: String) async -> String? {
        let excerpt = String(summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !excerpt.isEmpty else { return nil }

        let system = PersonalContext.appended(to: Prompts.titleOnlyInstructionEN + (Vocabulary.shared.promptBlock ?? ""))
        let opts = ModelServer.GenerateOptions(numCtx: numCtx, numPredict: 32, timeout: timeout)
        guard let raw = await ModelServer.shared.generate(server: server, prompt: excerpt, systemPrompt: system, options: opts) else {
            Logger.log("Summary", "Fallback title call produced nothing; falling back to type display name")
            return nil
        }
        let title = sanitizeGeneratedTitle(raw)
        Logger.log("Summary", "Fallback title: \(title ?? "(none)") (raw: \(raw.prefix(60)))")
        return title
    }

    /// The one underlying LLM call both `summarize` and `summarizeWithTitle` share — never call
    /// this twice for the same transcript, that's what `summarizeWithTitle` is for. Only the
    /// `includeTitle` path requests a `TITLE:` line and parses it out; without it the raw
    /// response is returned untouched.
    private func performSummarization(
        transcript: String,
        type: MeetingType,
        includeTitle: Bool
    ) async -> (title: String?, markdown: String)? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var base = Prompts.summarizationPrompt(for: type, overrides: promptOverrides, language: language)
        if includeTitle {
            base += "\n\n" + Prompts.summaryTitleInstructionEN
        }
        let system = PersonalContext.appended(to: base + (Vocabulary.shared.promptBlock ?? ""))
        // Benchmark verdict: think:true is a net loss for local summarization — the reasoning eats the
        // num_predict budget and returns an EMPTY summary at 2048 (or 18× slower at 6144), with no quality
        // gain over think:false. Kept off. Large cloud models handle thinking fine, but even there the
        // non-thinking summary was just as good, so we don't special-case it.
        let opts = ModelServer.GenerateOptions(numCtx: numCtx, numPredict: numPredict, timeout: timeout)
        Logger.log("Summary", "Summarizing (\(type.configKey), num_ctx=\(numCtx), provider=\(server.api), model=\(server.model))")
        guard let raw = await ModelServer.shared.generate(server: server, prompt: transcript, systemPrompt: system, options: opts) else {
            return nil
        }
        // Small on-device models sometimes echo the injected "Personal context" block into the
        // summary despite being told not to. Strip that first — which also re-floats the requested
        // TITLE: line to the top so `parseSummaryTitle` can consume it — then clear any stray
        // TITLE: lines the model scattered into the body.
        let deleaked = stripEchoedContext(raw, personalContext: PersonalContext.load())
        if includeTitle {
            let parsed = parseSummaryTitle(from: deleaked)
            return (parsed.title, stripStrayTitleLines(parsed.markdown))
        }
        return (title: nil, markdown: stripStrayTitleLines(deleaked))
    }
}
