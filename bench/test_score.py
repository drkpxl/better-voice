"""Tests for the bake-off normalizer and scorer.

The normalizer decides whether the whole experiment means anything, so it is tested first and
hardest. The critical property is the one in `test_formatting_is_free`: engines that emit
punctuation and casing must not be penalized against engines that don't.

Run: python3 bench/test_score.py
"""

from __future__ import annotations

import sys

from score import (
    cer,
    strip_fillers,
    char_errors,
    jargon_recall,
    normalize,
    number_to_words,
    wer,
    word_errors,
)

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def check_close(label: str, actual: float, expected: float, tol: float = 1e-9) -> None:
    if abs(actual - expected) > tol:
        FAILURES.append(f"{label}\n    expected: {expected}\n    actual:   {actual}")


# ---------------------------------------------------------------------------
# The crux: formatting differences must cost nothing
# ---------------------------------------------------------------------------

def test_formatting_is_free() -> None:
    """Whisper/Apple style vs Parakeet TDT style for identical speech must score 0.0 WER.

    If this test fails the entire bake-off is invalid -- the chart would rank engines by how much
    punctuation they emit rather than by what they heard.
    """
    apple_style = "We're moving the deadline to Friday, and I'll tell the team."
    parakeet_style = "we are moving the deadline to friday and i will tell the team"
    check_close("punctuation+casing+contractions are free", wer(apple_style, parakeet_style), 0.0)

    check_close(
        "trailing period only",
        wer("Ship it.", "ship it"),
        0.0,
    )
    check_close(
        "smart quotes and em dash",
        wer("It’s fine — really", "it is fine really"),
        0.0,
    )


def test_numbers_converge() -> None:
    check("digits spell out", normalize("25"), "twenty five")
    check("hyphenated words match digits", normalize("twenty-five"), "twenty five")
    check_close("25 vs twenty-five", wer("25 people", "twenty-five people"), 0.0)
    check("comma groups", normalize("1,200"), "one thousand two hundred")
    check("decimal", normalize("3.5"), "three point five")
    check("percent glyph", normalize("15%"), "fifteen percent")
    check("dollars", normalize("$40"), "forty dollars")
    check("zero", number_to_words(0), "zero")
    check("teens", number_to_words(17), "seventeen")
    check("round hundred", number_to_words(300), "three hundred")
    check("compound", number_to_words(1234), "one thousand two hundred thirty four")


def test_known_limitation_hundreds_reading() -> None:
    """Documented limitation: spoken-form ambiguity in multi-digit numbers does not converge.

    "1200" canonicalizes to "one thousand two hundred", but a speaker may say "twelve hundred",
    and a year "2026" may be read "twenty twenty six". Resolving this needs an alternatives-aware
    matcher, not a single canonical form.

    This does not bias the ranking: the same normalizer applies to every engine, so an engine
    writing digits takes the same penalty as any other. It inflates absolute WER slightly and
    cancels in the paired per-cell comparisons the experiment actually relies on.
    """
    assert wer("1,200 skiers", "twelve hundred skiers") > 0.0, "expected non-convergence"
    assert wer("in 2026", "in twenty twenty six") > 0.0, "expected non-convergence"
    # But the unambiguous readings still converge, which is what keeps this tolerable.
    check_close("unambiguous still converges", wer("1,200 skiers", "one thousand two hundred skiers"), 0.0)


def test_fillers_are_preserved() -> None:
    """Cleanup removing "um" must be visible as a difference, or the cleanup stage is unmeasurable."""
    assert "um" in normalize("Um, so I think we should ship")
    check("filler kept", normalize("Um, so we ship"), "um so we ship")
    # A cleanup stage that strips fillers should score as deletions against a verbatim reference.
    counts = word_errors("um so we should uh ship it", "so we should ship it")
    check("two fillers deleted", (counts.deletions, counts.substitutions, counts.insertions), (2, 0, 0))
    # Spelling variants of the same filler converge.
    check_close("umm == um", wer("um yeah", "umm yeah"), 0.0)


def test_idempotent() -> None:
    samples = [
        "It's 25% -- and $40, don't you think?",
        "Um... the Summit Pass, you know, 1,200 people",
        "",
        "already normal text",
    ]
    for s in samples:
        once = normalize(s)
        check(f"idempotent: {s!r}", normalize(once), once)


# ---------------------------------------------------------------------------
# Edit distance mechanics
# ---------------------------------------------------------------------------

def test_error_breakdown() -> None:
    counts = word_errors("the quick brown fox", "the quick brown fox")
    check("identical", (counts.errors, counts.reference_length), (0, 4))
    check_close("identical rate", counts.rate, 0.0)

    counts = word_errors("the quick brown fox", "the slow brown fox")
    check("one substitution", (counts.substitutions, counts.deletions, counts.insertions), (1, 0, 0))
    check_close("wer 1/4", counts.rate, 0.25)

    counts = word_errors("the quick brown fox", "the brown fox")
    check("one deletion", (counts.substitutions, counts.deletions, counts.insertions), (0, 1, 0))

    counts = word_errors("the brown fox", "the quick brown fox")
    check("one insertion", (counts.substitutions, counts.deletions, counts.insertions), (0, 0, 1))

    # WER can exceed 1.0 when the hypothesis is much longer -- that is correct, not a bug.
    counts = word_errors("hello", "hello hello hello")
    check_close("wer > 1 allowed", counts.rate, 2.0)


def test_empty_edges() -> None:
    check_close("both empty", wer("", ""), 0.0)
    check_close("empty ref, nonempty hyp is 1.0 not inf", wer("", "something here"), 1.0)
    check_close("empty hyp against ref", wer("a b c d", ""), 1.0)
    # A crashed engine emitting nothing should score 1.0, not poison an aggregate with infinity.
    check_close("crashed engine", wer("the meeting is friday", ""), 1.0)


def test_cer_is_finer_than_wer() -> None:
    """One mangled long word is a full word error but only a few character errors."""
    ref, hyp = "the Northstar lift", "the Northstr lift"
    check_close("wer counts whole word", wer(ref, hyp), 1 / 3)
    assert cer(ref, hyp) < wer(ref, hyp), "CER should be gentler on a near-miss"
    counts = char_errors("abc", "abc")
    check("cer identical", counts.errors, 0)


# ---------------------------------------------------------------------------
# Jargon recall
# ---------------------------------------------------------------------------

def test_jargon_recall() -> None:
    hyp = "we should update the Summit Pass page and check the Northstar lift"
    found, total, missing = jargon_recall(hyp, ["Summit Pass", "Northstar", "Ridgeline"])
    check("recall counts", (found, total), (2, 3))
    check("names what was missed", missing, ["Ridgeline"])

    # Multi-word terms need adjacency, not just both words present somewhere.
    found, total, missing = jargon_recall("the pass was icon quality", ["Summit Pass"])
    check("no false positive on scattered words", (found, total), (0, 1))

    # Casing and punctuation in the term list must not matter.
    found, _, _ = jargon_recall("welcome to summit pass", ["Summit Pass"])
    check("term matching is normalized", found, 1)

    check("empty term list", jargon_recall("anything", []), (0, 0, []))


def test_strip_fillers_removes_discourse_openers() -> None:
    out, removed = strip_fillers("Okay, now it is recording. Alright, Summit Pass. Yeah, bothers me too.")
    check("openers gone", out, "Now it is recording. Summit Pass. Bothers me too.")
    check("removals reported", [r.rstrip(",") for r in removed], ["Okay", "Alright", "Yeah"])


def test_strip_fillers_removes_um_uh_anywhere() -> None:
    out, removed = strip_fillers("The uh thing is um fine.")
    check("mid-sentence fillers gone", out, "The thing is fine.")
    check("both reported", removed, ["uh", "um"])


def test_strip_fillers_is_conservative_about_ambiguous_words() -> None:
    """Ambiguous words are only filler at a sentence opening; mid-sentence they carry meaning."""
    out, _ = strip_fillers("We did it like we talked about, so that is it.")
    check("mid-sentence like/so kept", out, "We did it like we talked about, so that is it.")
    out, _ = strip_fillers("Turn right at the lift.")
    check("'right' as direction kept", out, "Turn right at the lift.")
    out, _ = strip_fillers("I do not know.")
    check("a real clause is not a filler", out, "I do not know.")


def test_strip_fillers_recapitalizes_and_preserves_structure() -> None:
    out, _ = strip_fillers("Okay, we ship Friday! Yeah? Fine.")
    check("capitalized after removal, delimiters kept", out, "We ship Friday! Fine.")
    # A sentence that was ONLY filler disappears rather than leaving empty punctuation.
    out, _ = strip_fillers("Um. We ship.")
    check("filler-only sentence dropped", out, "We ship.")


def test_strip_fillers_noop_on_clean_text() -> None:
    clean = "We should move the deadline to Friday."
    out, removed = strip_fillers(clean)
    check("unchanged", out, clean)
    check("nothing removed", removed, [])


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            FAILURES.append(f"{test.__name__}: assertion failed: {exc}")
        except Exception as exc:  # noqa: BLE001 - surface any error as a failure
            FAILURES.append(f"{test.__name__}: raised {type(exc).__name__}: {exc}")

    if FAILURES:
        print(f"FAIL — {len(FAILURES)} failure(s):\n")
        for f in FAILURES:
            print(f"  {f}\n")
        return 1
    print(f"PASS — {len(tests)} test functions, all checks green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
