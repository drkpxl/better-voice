import AVFoundation
import FluidAudio
import BetterVoiceCore

/// Acoustic vocabulary boosting: after Parakeet transcribes a dictation, a small CTC model scores
/// the audio against the user's vocabulary and swaps in a term where the audio supports it — so a
/// name Parakeet heard as "cooper net ease" can come out as "Kubernetes". FluidAudio's CTC word
/// spotter + rescorer (NeMo's CTC-WS method), used the way its own CLI does.
///
/// Complements, never replaces, `Vocabulary.apply` (exact word-boundary replacement), which still
/// runs afterwards: boosting fixes what was mis-heard, replacement fixes how a correctly heard word
/// is spelled.
///
/// Dictation only. The spotter needs the whole recording as 16 kHz samples in memory, which is fine
/// for a dictation and not for an hour-long meeting; meetings keep exact replacement plus the
/// vocabulary block in the summary prompt.
///
/// Best effort: the ~100 MB CTC model is fetched the first time it's needed (only when the user
/// has a vocabulary and the setting is on), and any failure returns the text unchanged.
actor VocabularyBooster {
    static let shared = VocabularyBooster()

    private static let variant: CtcModelVariant = .ctc110m

    private var spotter: CtcKeywordSpotter?
    private var tokenizer: CtcTokenizer?
    private var loading: Task<Void, Error>?

    /// The rescorer is built for one vocabulary; rebuilt when the terms change.
    private var rescorer: VocabularyRescorer?
    private var context: CustomVocabularyContext?
    private var rescorerTerms: [VocabularyBoostTerms.Term] = []

    var isReady: Bool { spotter != nil }

    /// Download (first time) and load the CTC model. Idempotent; a failure clears so a later call retries.
    func prepare() async throws {
        if spotter != nil { return }
        let task = loading ?? Task { try await self.load() }
        loading = task
        do {
            try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    private func load() async throws {
        let models = try await CtcModels.downloadAndLoad(variant: Self.variant)
        let dir = CtcModels.defaultCacheDirectory(for: Self.variant)
        tokenizer = try await CtcTokenizer.load(from: dir)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        Logger.log("Boost", "CTC vocabulary model ready")
    }

    /// `text` with vocabulary terms the audio supports swapped in, or `text` unchanged.
    ///
    /// - Parameters:
    ///   - tokenTimings: Parakeet's token timings for `text` (the rescorer aligns against them).
    ///   - buffer: the audio that produced `text`, any format.
    func rescore(
        text: String,
        tokenTimings: [TokenTiming],
        buffer: AVAudioPCMBuffer,
        terms: [VocabularyBoostTerms.Term]
    ) async -> String {
        guard !terms.isEmpty, !tokenTimings.isEmpty, !text.isEmpty else { return text }
        do {
            try await prepare()
            guard let spotter, let (rescorer, context) = try await rescorerFor(terms, spotter: spotter) else { return text }

            let samples = try AudioConverter().resampleBuffer(buffer)
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: context, minScore: nil)
            guard !spot.logProbs.isEmpty else { return text }

            let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
            let output = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: sizeConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: sizeConfig.minSimilarity
            )
            guard output.wasModified else { return text }
            // Re-apply the suggestions ourselves through the safety filter instead of trusting
            // `output.text` — see `BoostReplacementFilter` for the word-deleting case it stops.
            let swaps = output.replacements.compactMap { r -> BoostReplacementFilter.Swap? in
                guard r.shouldReplace, let replacement = r.replacementWord else { return nil }
                return BoostReplacementFilter.Swap(original: r.originalWord, replacement: replacement)
            }
            let aliases = Dictionary(uniqueKeysWithValues: terms.map { ($0.text.lowercased(), $0.aliases) })
            let boosted = BoostReplacementFilter.apply(to: text, swaps: swaps, aliases: aliases)
            Logger.log("Boost", "Suggested: \(swaps.map { "'\($0.original)'→'\($0.replacement)'" }.joined(separator: ", ")); changed: \(boosted != text)")
            return boosted
        } catch {
            Logger.log("Boost", "Vocabulary boosting skipped: \(error)")
            return text
        }
    }

    private func rescorerFor(
        _ terms: [VocabularyBoostTerms.Term],
        spotter: CtcKeywordSpotter
    ) async throws -> (VocabularyRescorer, CustomVocabularyContext)? {
        if let rescorer, let context, terms == rescorerTerms { return (rescorer, context) }
        guard let tokenizer else { return nil }

        let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: term.text, aliases: term.aliases.isEmpty ? nil : term.aliases, ctcTokenIds: ids)
        }
        guard !tokenized.isEmpty else { return nil }
        let context = CustomVocabularyContext(terms: tokenized)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: Self.variant)
        )
        self.rescorer = rescorer
        self.context = context
        self.rescorerTerms = terms
        Logger.log("Boost", "Vocabulary rescorer built for \(tokenized.count) term(s)")
        return (rescorer, context)
    }
}
