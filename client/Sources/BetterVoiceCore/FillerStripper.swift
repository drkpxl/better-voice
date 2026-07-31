import Foundation

/// Deterministic removal of discourse fillers from dictated text.
///
/// This is what replaced the LLM cleanup stage for the one job that stage was genuinely doing.
/// Measured against a hand-corrected reference, cleanup was worth **0.0 WER points** on the backend
/// the app shipped and at best 1.1 points anywhere (`bench/results/2026-07-30-results.json`), while
/// costing about 4s of a 5s wait. But part of that 1 point was filler removal, and unlike the rest of
/// what cleanup did — punctuation and capitalization, which Parakeet emits itself — nothing else
/// replaced it. A model was never needed to delete "um".
///
/// Ported from `bench/score.py`'s `strip_fillers`, deliberately: that is the implementation the
/// bake-off's no-filler column was computed with, so keeping the two in step means the shipped
/// behaviour is the behaviour that was measured. `FillerStripperTests` pins the shared cases.
///
/// **Conservative by construction, in two tiers.** The whole risk here is deleting a real word. A
/// stripper that removes meaning is far worse than one that leaves an "um" in, because the user cannot
/// see what went missing — the dictation just quietly says something else.
public enum FillerStripper {

    /// Non-words. No English sentence needs them, so they are removed wherever they appear.
    private static let alwaysFiller: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "hm", "hmm", "mm", "mmm", "mhm",
    ]

    /// Real words that are usually discourse markers when they OPEN a sentence and usually meaningful
    /// anywhere else. "So" starting a sentence is filler; "so I went home" is a conjunction. "Like" at
    /// the front is filler; "I like it" is a verb. Restricting them to sentence-initial position is
    /// what makes the removal safe -- position, not a guess about intent.
    private static let sentenceInitialFiller: Set<String> = [
        "okay", "ok", "alright", "yeah", "yep", "yup", "so", "well", "right", "anyway", "like",
    ]

    /// Result of a strip, with the removed words so the edit is auditable rather than invisible.
    public struct Result: Sendable, Equatable {
        public let text: String
        public let removed: [String]

        public init(text: String, removed: [String]) {
            self.text = text
            self.removed = removed
        }
    }

    /// Remove fillers, preserving sentence structure and punctuation.
    ///
    /// Sentence-initial markers are stripped as a *run*, so "Um, okay, so I think" loses all three
    /// openers rather than only the first. Everything after that opening run is only checked against
    /// the always-filler set.
    ///
    /// Capitalization is repaired only when an opener was actually removed -- otherwise text the user
    /// deliberately began in lower case would be silently rewritten.
    public static func strip(_ text: String) -> Result {
        guard !text.isEmpty else { return Result(text: text, removed: []) }

        var removed: [String] = []
        var sentences: [String] = []

        for (body, delimiter) in splitKeepingDelimiters(text) {
            let words = body.split(whereSeparator: \.isWhitespace).map(String.init)

            // Leading run: both tiers apply here.
            var index = 0
            while index < words.count {
                let bare = normalize(words[index])
                guard alwaysFiller.contains(bare) || sentenceInitialFiller.contains(bare) else { break }
                removed.append(words[index])
                index += 1
            }

            // Remainder: only true non-words are dropped.
            var kept: [String] = []
            for word in words[index...] {
                if alwaysFiller.contains(normalize(word)) {
                    removed.append(word)
                    continue
                }
                kept.append(word)
            }

            guard !kept.isEmpty else { continue }
            var sentence = kept.joined(separator: " ")
            if index > 0, let first = sentence.first, first.isLowercase {
                sentence = first.uppercased() + sentence.dropFirst()
            }
            sentences.append(sentence + delimiter)
        }

        return Result(
            text: sentences.joined(separator: " ").trimmingCharacters(in: .whitespaces),
            removed: removed
        )
    }

    /// Strip a word to its comparable core: no punctuation, lowercased, apostrophes kept.
    ///
    /// Apostrophes survive so "um" never matches inside a contraction and a possessive is not turned
    /// into a different word.
    private static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "\u{2019}"
        }.map(Character.init))
    }

    /// Split into (body, trailing-punctuation) pairs, keeping the punctuation so sentence structure
    /// survives the round trip. A body with no terminator yields an empty delimiter.
    private static func splitKeepingDelimiters(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var body = ""
        var delimiter = ""

        for character in text {
            if character == "." || character == "!" || character == "?" {
                delimiter.append(character)
            } else {
                // A non-terminator after a run of terminators closes the sentence.
                if !delimiter.isEmpty {
                    out.append((body, delimiter))
                    body = ""
                    delimiter = ""
                }
                body.append(character)
            }
        }
        if !body.trimmingCharacters(in: .whitespaces).isEmpty || !delimiter.isEmpty {
            out.append((body, delimiter))
        }
        return out
    }
}
