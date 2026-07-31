import Foundation

/// Synthesis of *phrase*-level spans from word-level ASR output.
///
/// Apple's `SpeechTranscriber` handed phrases over for free -- one `result.isFinal` per phrase --
/// while Parakeet emits only words. `SegmentBuffer.Entry` and `groupIntoTurns` both consume phrases,
/// and speaker attribution is driven entirely off phrase spans, so a bad split here shows up as a
/// wrong speaker label rather than as an error. Nothing downstream can detect it. That is why this
/// lives in Core as pure, Foundation-only, deterministic code with its own test suite instead of a
/// few lines inline in `ImportPipeline`.
public enum PhraseSegmentation {

    // MARK: - Tuning

    /// Default inter-word gap (seconds) above which a phrase ends.
    ///
    /// 0.6s sits above a natural inter-word pause and below a sentence pause, so phrases break where
    /// a listener would hear a break. It is deliberately *not* `meeting.segment_pause_sec`
    /// (default 1.5s): that value decides when a *batch of phrases* is flushed downstream as one
    /// segment, a much coarser question. One number serving both would couple two unrelated tunings
    /// -- retuning the flush pause would silently re-cut every phrase and move every speaker
    /// boundary.
    public static let defaultMaxGapSec: TimeInterval = 0.6

    // MARK: - Phrases

    /// Group `words` into phrases, splitting on sentence-final punctuation or a long inter-word gap.
    ///
    /// A phrase ends when either rule fires:
    /// - the word's text ends in `.`, `!` or `?` (optionally followed by a closing quote or bracket,
    ///   as in `he said "stop."`) -- the split is *after* that word;
    /// - the next word starts more than `maxGapSec` after this one ends -- the split is *between*
    ///   them.
    ///
    /// The gap comparison is strictly greater-than, so a gap of *exactly* `maxGapSec` keeps the two
    /// words in one phrase. That is the opposite inclusivity from `SegmentBuffer.feed`, which flushes
    /// on `gap >= pauseThresholdSec`; the two are answering different questions and are not meant to
    /// agree. No epsilon is applied: word timings come from a model at ~10ms resolution, so a gap
    /// landing within float noise of the threshold is not a case that occurs, and an epsilon would
    /// only make the contract untestable.
    ///
    /// Spacing: each phrase's `text` has exactly one space between words and none at its edges (see
    /// `joinWords`). Both consumers concatenate phrase text with a bare `.joined()` --
    /// `groupIntoTurns` and `SegmentBuffer.flushInternal` -- so **the caller must insert its own
    /// separator** when feeding these phrases onward. Apple's segments carried their own leading
    /// space, which is why neither consumer supplies one.
    ///
    /// Word order is taken as given and never sorted: the engine's word order is authoritative for
    /// the text, and reordering by timestamp would scramble the transcript to fix the span. So a
    /// non-monotonic run (overlapping or out-of-order timings) yields a negative gap, which never
    /// splits -- such a run collapses into one phrase rather than fragmenting. See `end` below for
    /// how the span is kept sane in that case.
    ///
    /// - Parameters:
    ///   - words: words in engine emission order. Words whose text is empty or all whitespace are
    ///     dropped first (see below).
    ///   - maxGapSec: inter-word gap above which a phrase ends. Defaults to `defaultMaxGapSec`.
    /// - Returns: phrases in input order. Empty for empty input, or for input with no visible text.
    ///   Never contains a phrase with empty text.
    public static func phrases(from words: [TimedWord],
                               maxGapSec: TimeInterval = PhraseSegmentation.defaultMaxGapSec) -> [Phrase] {
        // Drop text-less words before any timing math. Such a word contributes nothing to the phrase
        // text, but keeping it would let it define a phrase's start or end (stretching the span over
        // silence) and, worse, bridge a real gap: a padding token covering 3s of silence reads as two
        // zero-length gaps and would hold two sentences in a single phrase.
        let usable = words.filter { !isBlank($0.text) }
        guard !usable.isEmpty else { return [] }

        var result: [Phrase] = []
        var current: [TimedWord] = []

        func flush() {
            // Empty `current` is the normal case, not an error: when punctuation and a gap both fall
            // on the same boundary the punctuation rule has already flushed, so the gap rule finds
            // nothing to flush. Returning here is what keeps that from emitting an empty phrase.
            guard let first = current.first, let last = current.last else { return }
            // `end` is the LAST word's end, not the maximum end across the phrase's words. Word order
            // is time order for every engine we support, and taking a maximum would let one word with
            // a bogus long end stretch the phrase across a speaker change -- a mislabeled turn, which
            // is a worse failure than a phrase that ends slightly early.
            // Clamped to `start` so the span can never come out inverted: `Phrase` enforces no such
            // invariant, and a negative duration would reach logs, exports and `assignSpeaker`. The
            // clamp turns a pathological word run into an explicit zero-duration span, which
            // `assignSpeaker` already reports as confidence 0.
            result.append(Phrase(text: joinWords(current), start: first.start, end: max(first.start, last.end)))
            current.removeAll(keepingCapacity: true)
        }

        for word in usable {
            if let previous = current.last, word.start - previous.end > maxGapSec {
                flush()
            }
            current.append(word)
            if endsSentence(word.text) {
                flush()
            }
        }
        flush()

        return result
    }

    // MARK: - Joining

    /// Join words into one string with exactly one space between them and no space at either edge.
    ///
    /// The single place that decides spacing, because engines disagree about it: SentencePiece-based
    /// engines mark word-initial tokens with a leading space and hand back `" word"`, while others
    /// hand back `"word"`. Joining naively double-spaces the first convention and runs the second
    /// together, and a single array can mix them (the first token of an utterance often carries no
    /// marker). Trimming each word's edges and re-joining makes the input convention stop mattering.
    ///
    /// Interior whitespace is left alone. An engine may emit a multi-token unit as one `TimedWord`
    /// ("New York"), and collapsing its insides would be rewriting transcript content rather than
    /// fixing spacing.
    ///
    /// Words that are empty or all whitespace are dropped rather than joined, so they cannot leave a
    /// double space behind.
    ///
    /// Not punctuation-aware: a token that is *only* punctuation still gets a space in front of it
    /// (`"hmm ."`). Parakeet attaches punctuation to the preceding word so standalone punctuation
    /// tokens do not occur; if an engine ever emits them, this function is the one place to fix it.
    public static func joinWords(_ words: [TimedWord]) -> String {
        words
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Joining phrases

    /// Characters that must never be preceded by an inserted space when they open a piece.
    /// Sentence-final marks are here too, because a phrase can legitimately begin with one when an
    /// engine splits mid-sentence.
    private static let noSpaceBefore: Set<Character> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "'", "\"", "\u{2019}", "\u{201D}", "%", "…"
    ]

    /// Concatenate phrase texts, inserting a single space only where one is actually missing.
    ///
    /// Exists because the two engines disagree about spacing and both consumers used to concatenate
    /// with a bare `.joined()` and no separator at all (`SpeakerAlignment.groupIntoTurns`,
    /// `SegmentBuffer.flushInternal`). That worked only because Apple's segments carry their own
    /// leading space — the `SpeakerAlignmentTests` fixture encodes `"Hello "` with a trailing space to
    /// match. Parakeet's phrases come out of `joinWords` trimmed, so the same `.joined()` produced
    /// `"One.Two."`: silent space loss, no crash, nothing to flag it.
    ///
    /// Rather than force one convention on both engines and rewrite the fixtures, this is
    /// convention-agnostic. It inserts a space between two pieces only when the left does not already
    /// end with whitespace, the right does not already begin with it, and the right does not open with
    /// punctuation that must hug the previous word. So Apple's `"Hello "` + `"world."` stays
    /// `"Hello world."` byte-for-byte, and Parakeet's `"Hello"` + `"world."` becomes the same thing.
    ///
    /// The punctuation guard is the reason a plain `joined(separator: " ")` was not good enough: an
    /// engine that splits a phrase before a comma would otherwise yield `"Hello , world"`.
    public static func joinPhraseTexts(_ texts: [String]) -> String {
        var result = ""
        for text in texts where !text.isEmpty {
            if !result.isEmpty,
               let last = result.last, !last.isWhitespace,
               let first = text.first, !first.isWhitespace,
               !noSpaceBefore.contains(first) {
                result.append(" ")
            }
            result += text
        }
        return result
    }

    // MARK: - Sentence-final punctuation

    private static let sentenceFinalMarks: Set<Character> = [".", "!", "?"]

    /// Characters that may sit *after* the sentence-final mark and must be stepped over to find it.
    private static let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»", "›"]

    /// Words whose trailing period is an abbreviation mark, not a sentence end.
    ///
    /// Deliberately short rather than exhaustive, because the two failure directions are not
    /// symmetric. A missed abbreviation splits a phrase mid-sentence, and `groupIntoTurns` merges the
    /// two halves straight back into one turn when the speaker is unchanged -- nearly free. A wrong
    /// non-split leaves a phrase spanning a real sentence boundary, which is where a phrase can end
    /// up straddling a speaker change and take the wrong label. So this list covers the forms that
    /// actually recur in dictated and meeting speech and stops there.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "rev", "hon", "sr", "jr",
        "st", "mt", "ave", "blvd", "vs", "etc", "al", "approx",
        "inc", "ltd", "co", "corp", "dept", "fig", "vol",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun"
    ]

    /// Whether `text` ends a sentence, i.e. whether a phrase break belongs after this word.
    private static func endsSentence(_ text: String) -> Bool {
        // Step back over trailing whitespace and closers: in `he said "stop."` the mark is one
        // character in from the end, and the leading-space convention can leave a trailing space too.
        var core = Substring(text)
        while let last = core.last, last.isWhitespace || closingCharacters.contains(last) {
            core = core.dropLast()
        }
        guard let mark = core.last, sentenceFinalMarks.contains(mark) else { return false }
        // `!` and `?` are never abbreviation marks, so they end a sentence unconditionally. Only the
        // period is ambiguous, and only the period gets the checks below. Note that a period anywhere
        // *other* than the end is never even looked at, which is what makes "3.5" and "example.com"
        // safe without a special case.
        guard mark == "." else { return true }

        let stem = core.dropLast()
        if stem.isEmpty { return true }                                  // a lone "." token really is a sentence end
        if stem.count == 1, let only = stem.first, only.isLetter { return false }  // an initial: "J.", "A."
        if isDottedInitialism(stem) { return false }                     // "U.S.", "e.g.", "a.m.", "Ph.D."
        if abbreviations.contains(stem.lowercased()) { return false }    // "Dr.", "etc.", "Sept."
        return true
    }

    /// Whether `stem` (a trailing-period word with the period removed) looks like a dotted
    /// initialism: every dot-separated part is one or two letters, as in `U.S`, `e.g`, `a.m`, `Ph.D`.
    ///
    /// Requiring non-empty parts is what keeps an ellipsis out: `"..."` has stem `".."`, whose parts
    /// are empty, so it is treated as a sentence end rather than as an initialism.
    private static func isDottedInitialism(_ stem: Substring) -> Bool {
        guard stem.contains(".") else { return false }
        return stem.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.count <= 2 && part.allSatisfy(\.isLetter)
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
