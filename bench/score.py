"""Text normalization and WER/CER scoring for the ASR + cleanup pipeline bake-off.

The normalizer is the correctness crux of the whole experiment. Engines differ in how much
*formatting* they emit -- Whisper and Apple produce punctuation and casing, Parakeet TDT produces
neither -- so scoring raw text would penalize models for being more featureful and invert the
ranking. Every hypothesis and every reference goes through the identical normalizer before any
edit distance is computed.

Deliberately NOT normalized away: filler words ("um", "uh"), false starts, and repetitions. The
verbatim reference keeps them, and the whole point of the cleanup stage is that it removes them --
stripping them here would make the cleanup stage unmeasurable.

Stdlib only, so runners can call it under `uv run` with no dependency resolution.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Number spelling
# ---------------------------------------------------------------------------
# Digits are expanded to words rather than words collapsed to digits: "25" -> "twenty five" is a
# simple deterministic algorithm, whereas parsing "twenty-five" -> 25 needs a compound-number
# grammar. After hyphens become spaces, a reference written "twenty-five" and a hypothesis written
# "25" both land on "twenty five".

_ONES = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen",
]
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def _under_thousand(n: int) -> list[str]:
    out: list[str] = []
    if n >= 100:
        out += [_ONES[n // 100], "hundred"]
        n %= 100
        if n == 0:
            return out
    if n < 20:
        out.append(_ONES[n])
    else:
        out.append(_TENS[n // 10])
        if n % 10:
            out.append(_ONES[n % 10])
    return out


def number_to_words(n: int) -> str:
    """Spell a non-negative integer. Scales up to billions, which is far past anything spoken."""
    if n == 0:
        return "zero"
    parts: list[str] = []
    for scale_value, scale_name in ((1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand")):
        if n >= scale_value:
            parts += _under_thousand(n // scale_value) + [scale_name]
            n %= scale_value
    if n:
        parts += _under_thousand(n)
    return " ".join(parts)


# ---------------------------------------------------------------------------
# Contractions
# ---------------------------------------------------------------------------
# Expanded rather than stripped, because engines disagree about whether to emit "we're" or "we are"
# and that disagreement is formatting, not a transcription error.

_CONTRACTIONS = {
    "aren't": "are not", "can't": "cannot", "couldn't": "could not",
    "didn't": "did not", "doesn't": "does not", "don't": "do not",
    "hadn't": "had not", "hasn't": "has not", "haven't": "have not",
    "he'd": "he would", "he'll": "he will", "he's": "he is",
    "i'd": "i would", "i'll": "i will", "i'm": "i am", "i've": "i have",
    "isn't": "is not", "it'd": "it would", "it'll": "it will", "it's": "it is",
    "let's": "let us", "shouldn't": "should not", "she'd": "she would",
    "she'll": "she will", "she's": "she is", "that's": "that is",
    "there's": "there is", "they'd": "they would", "they'll": "they will",
    "they're": "they are", "they've": "they have", "wasn't": "was not",
    "we'd": "we would", "we'll": "we will", "we're": "we are", "we've": "we have",
    "weren't": "were not", "what's": "what is", "won't": "will not",
    "wouldn't": "would not", "you'd": "you would", "you'll": "you will",
    "you're": "you are", "you've": "you have",
}

# Symbols an engine may render either as a glyph or as a word.
_SYMBOLS = {"%": " percent ", "&": " and ", "+": " plus ", "=": " equals ", "@": " at "}

_FILLER_SPELLINGS = {"erm": "um", "hmm": "hm", "mmm": "hm", "uhh": "uh", "umm": "um", "ah": "uh"}


def normalize(text: str) -> str:
    """Canonicalize text for scoring. Idempotent: normalize(normalize(x)) == normalize(x)."""
    if not text:
        return ""

    # Unicode fold first so smart quotes and dashes behave like their ASCII forms.
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("’", "'").replace("‘", "'")
    text = text.replace("“", '"').replace("”", '"')
    text = re.sub(r"[‐-―]", "-", text)

    text = text.lower()

    # Currency needs the symbol moved behind the amount before generic symbol substitution.
    text = re.sub(r"\$\s*([\d,.]+)", r"\1 dollars", text)

    for symbol, replacement in _SYMBOLS.items():
        text = text.replace(symbol, replacement)

    # Hyphens and slashes to spaces, so "twenty-five" and "twenty five" converge.
    text = re.sub(r"[-/]", " ", text)

    # Contractions, on word boundaries so "don't" inside a longer token is left alone.
    for contraction, expansion in _CONTRACTIONS.items():
        text = re.sub(rf"\b{re.escape(contraction)}\b", expansion, text)

    # Numbers are spelled BEFORE punctuation is stripped, because the comma in "1,200" and the
    # point in "3.5" are part of the number. Stripping first would split them into separate runs
    # and yield "one two hundred" / "three five".
    def _spell(match: re.Match[str]) -> str:
        token = match.group(0).replace(",", "")
        if "." in token:
            whole, _, frac = token.partition(".")
            head = number_to_words(int(whole)) if whole else "zero"
            return head + " point " + " ".join(_ONES[int(d)] for d in frac if d.isdigit())
        return number_to_words(int(token))

    # Thousands separators must be well-formed groups of three, so a list like "1, 200" is treated
    # as two numbers rather than one.
    text = re.sub(r"\d+(?:,\d{3})*(?:\.\d+)?", _spell, text)

    # Drop remaining punctuation. Apostrophes go too: any contraction not in the table above
    # collapses to a bare token ("y'all" -> "yall") consistently on both sides of the comparison.
    text = re.sub(r"[^\w\s]", " ", text)

    tokens = [_FILLER_SPELLINGS.get(t, t) for t in text.split()]
    return " ".join(tokens)


# ---------------------------------------------------------------------------
# Edit distance
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ErrorCounts:
    substitutions: int
    deletions: int
    insertions: int
    reference_length: int

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def rate(self) -> float:
        """Errors per reference token. Empty reference with a non-empty hypothesis is 1.0, not
        infinity, so a single degenerate cell cannot swamp an aggregate."""
        if self.reference_length == 0:
            return 0.0 if self.errors == 0 else 1.0
        return self.errors / self.reference_length


def alignment_ops(reference: list[str], hypothesis: list[str]) -> list[tuple[str, int | None, int | None]]:
    """Levenshtein alignment as an explicit op list, in forward order.

    Each op is `(kind, ref_index, hyp_index)` where kind is "match", "sub", "del" (present in
    reference, absent from hypothesis) or "ins" (present in hypothesis only); the unused index is
    None. Exposed rather than kept private because consensus voting needs the alignment itself, not
    just the error counts.
    """
    n, m = len(reference), len(hypothesis)
    # cost[i][j] = distance between reference[:i] and hypothesis[:j]
    cost = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        cost[i][0] = i
    for j in range(1, m + 1):
        cost[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            if reference[i - 1] == hypothesis[j - 1]:
                cost[i][j] = cost[i - 1][j - 1]
            else:
                cost[i][j] = 1 + min(
                    cost[i - 1][j - 1],  # substitution
                    cost[i - 1][j],      # deletion
                    cost[i][j - 1],      # insertion
                )

    ops: list[tuple[str, int | None, int | None]] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and reference[i - 1] == hypothesis[j - 1] and cost[i][j] == cost[i - 1][j - 1]:
            ops.append(("match", i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + 1:
            ops.append(("sub", i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            ops.append(("del", i - 1, None))
            i -= 1
        else:
            ops.append(("ins", None, j - 1))
            j -= 1
    ops.reverse()
    return ops


def _align(reference: list[str], hypothesis: list[str]) -> ErrorCounts:
    """Error counts broken out by kind, rather than a single distance -- the breakdown is what tells
    you whether a cleanup stage is over-deleting or hallucinating."""
    ops = alignment_ops(reference, hypothesis)
    kinds = [kind for kind, _, _ in ops]
    return ErrorCounts(
        substitutions=kinds.count("sub"),
        deletions=kinds.count("del"),
        insertions=kinds.count("ins"),
        reference_length=len(reference),
    )


def word_errors(reference: str, hypothesis: str) -> ErrorCounts:
    """Word-level errors between two strings, normalizing both."""
    return _align(normalize(reference).split(), normalize(hypothesis).split())


def char_errors(reference: str, hypothesis: str) -> ErrorCounts:
    """Character-level errors, normalizing both and ignoring spaces.

    CER is the tiebreak when WER is dominated by one badly-mangled long word: a single wrong
    compound term costs a full word error but only a few character errors.
    """
    ref = list(normalize(reference).replace(" ", ""))
    hyp = list(normalize(hypothesis).replace(" ", ""))
    return _align(ref, hyp)


def wer(reference: str, hypothesis: str) -> float:
    return word_errors(reference, hypothesis).rate


def cer(reference: str, hypothesis: str) -> float:
    return char_errors(reference, hypothesis).rate


# ---------------------------------------------------------------------------
# Jargon recall
# ---------------------------------------------------------------------------


def jargon_recall(hypothesis: str, terms: list[str]) -> tuple[int, int, list[str]]:
    """Fraction of domain terms surviving verbatim in the hypothesis.

    Multi-word terms are matched as normalized token subsequences, so "Summit Pass" must appear as
    adjacent tokens rather than as two words scattered across the transcript. Returns
    (found, total, missing) -- the missing list is the actionable part, since it names exactly
    which vocabulary an engine cannot hear.
    """
    if not terms:
        return (0, 0, [])
    hyp_tokens = normalize(hypothesis).split()
    missing: list[str] = []
    found = 0
    for term in terms:
        needle = normalize(term).split()
        if not needle:
            continue
        hit = any(
            hyp_tokens[i : i + len(needle)] == needle
            for i in range(len(hyp_tokens) - len(needle) + 1)
        )
        if hit:
            found += 1
        else:
            missing.append(term)
    return (found, len(terms), missing)


# ---------------------------------------------------------------------------
# Filler stripping
# ---------------------------------------------------------------------------
# Used to derive a second, filler-free variant of the intended reference, so the ranking can be
# checked for sensitivity to whether the reference keeps discourse markers. Deliberately split into
# two tiers: words that are ALWAYS filler, and words that are only filler when they open a sentence.
# "like" mid-sentence ("like we talked about") is meaningful; "Like, we talked about" is not, and only
# position distinguishes them -- so this runs on raw text, before punctuation is normalized away.

_ALWAYS_FILLER = {"um", "umm", "uh", "uhh", "er", "erm", "hm", "hmm", "mm", "mmm", "mhm"}
_SENTENCE_INITIAL_FILLER = {
    "okay", "ok", "alright", "yeah", "yep", "yup", "so", "well", "right", "anyway", "like",
}


def strip_fillers(text: str) -> tuple[str, list[str]]:
    """Remove discourse fillers. Returns (text, removed_words) so the edit is auditable.

    Conservative by design: an ambiguous word is only dropped when it opens a sentence, because a
    stripper that removed meaningful words would corrupt the reference it is meant to improve.
    """
    removed: list[str] = []
    out_sentences: list[str] = []

    # Keep the delimiter attached so sentence structure survives the round trip.
    parts = re.split(r"([.!?]+)", text)
    chunks: list[tuple[str, str]] = []
    for i in range(0, len(parts), 2):
        body = parts[i]
        delim = parts[i + 1] if i + 1 < len(parts) else ""
        if body.strip() or delim:
            chunks.append((body, delim))

    for body, delim in chunks:
        words = body.split()
        # Strip a run of discourse markers from the front of the sentence.
        start = 0
        while start < len(words):
            bare = re.sub(r"[^\w']", "", words[start]).lower()
            if bare in _SENTENCE_INITIAL_FILLER or bare in _ALWAYS_FILLER:
                removed.append(words[start])
                start += 1
            else:
                break
        kept = []
        for word in words[start:]:
            bare = re.sub(r"[^\w']", "", word).lower()
            if bare in _ALWAYS_FILLER:
                removed.append(word)
                continue
            kept.append(word)
        if kept:
            sentence = " ".join(kept)
            # Recapitalize when the original opener was removed.
            if start > 0 and sentence[:1].islower():
                sentence = sentence[0].upper() + sentence[1:]
            out_sentences.append(sentence + delim)

    return (" ".join(out_sentences).strip(), removed)
