import Foundation

/// Engine-neutral transcription types.
///
/// These live in `BetterVoiceCore` rather than beside the `Transcriber` protocol because
/// `PhraseSegmentation` consumes `TimedWord` and the test target can only import Core. Keeping the
/// data here and the protocol app-side is the same split as `VocabularyRules` / `Vocabulary`.

/// One word with its audio timing, as every ASR engine can report it.
///
/// `text` is the word **exactly as the engine emitted it**, which matters: SentencePiece-based
/// engines carry a leading-space marker on word-initial tokens, so some engines hand back `" word"`
/// and others `"word"`. Nothing here normalizes that — `PhraseSegmentation.joinWords` is the single
/// place that decides spacing, so the hazard is handled once instead of at every call site.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// Engine confidence in `0…1`, or nil when the engine does not report one.
    public let confidence: Double?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// A full transcription result, independent of which engine produced it.
///
/// **`phrases` is the contract, not `words`.** Both downstream consumers work in phrases —
/// `SegmentBuffer.Entry` and `groupIntoTurns` — and the two engines arrive at phrases from opposite
/// directions:
///
/// - Apple's import path gets phrases *for free*, one per `result.isFinal`, via the
///   `.audioTimeRange` attribute. It never requests or reads per-word timings, and reads no
///   confidence at all on that path. So `AppleSpeechTranscriber` can only fill `phrases`, and
///   `words` is necessarily empty for it. Synthesizing per-word timings by subdividing a phrase
///   would be inventing data.
/// - Parakeet emits words and no phrases, so `ParakeetTranscriber` fills `words` and derives
///   `phrases` through `PhraseSegmentation`.
///
/// An earlier draft of this type made `words` the primary unit. That was wrong, and would have
/// forced the Apple conformance to fabricate word timings purely to satisfy the shape.
public struct Transcript: Sendable, Equatable {
    /// The engine's own full text. Kept verbatim rather than recomputed from `phrases`, because an
    /// engine's joined text is authoritative for its own spacing and punctuation conventions.
    public let text: String
    /// Phrase-level spans — the unit every consumer downstream of the seam actually wants. Always
    /// populated by a successful transcription; empty only when the engine returned nothing.
    public let phrases: [Phrase]
    /// Word-level timings when the engine reports them, else empty. Empty is normal, not an error:
    /// Apple's import path never requests them, and some engines emit none at all (Parakeet Unified,
    /// Whisper without a second alignment pass). Callers must check `hasWordTimings`.
    public let words: [TimedWord]
    public let audioDuration: TimeInterval
    /// Which engine produced this, for history and log provenance (e.g. "apple", "parakeet-tdt-v3").
    public let engineID: String

    public init(
        text: String,
        phrases: [Phrase],
        words: [TimedWord] = [],
        audioDuration: TimeInterval,
        engineID: String
    ) {
        self.text = text
        self.phrases = phrases
        self.words = words
        self.audioDuration = audioDuration
        self.engineID = engineID
    }

    /// Whether per-word timings are available. Nothing on the import path needs them today —
    /// diarization aligns on *phrase* spans — so this gates future word-level features only.
    public var hasWordTimings: Bool { !words.isEmpty }
}

/// A phrase-level span: the unit `SegmentBuffer.Entry` and `groupIntoTurns` both consume.
///
/// Apple's `SpeechTranscriber` handed these over for free as `result.isFinal` segments. Parakeet
/// emits words, so `PhraseSegmentation` has to synthesize them — and the synthesis has to satisfy the
/// contract `SpeakerAlignmentTests` already pins, since speaker attribution is driven off these spans.
public struct Phrase: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var span: PhraseSpan { PhraseSpan(start: start, end: end) }
}
