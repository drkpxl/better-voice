"""Tests for ROVER-style consensus reference building.

Run: python3 bench/test_consensus.py
"""

from __future__ import annotations

import sys

from consensus import ABSENT, build_consensus

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def test_unanimous_needs_no_review() -> None:
    """Identical transcripts must yield zero disagreement sites -- otherwise the user is sent to
    review words nobody disagreed about."""
    text = "we are moving the deadline to friday"
    result = build_consensus({"a": text, "b": text, "c": text})
    check("consensus text", result.text, text)
    check("no sites", result.sites, [])
    check("fully unanimous", result.unanimous_fraction, 1.0)
    check("all engines agree with consensus", set(result.per_engine_wer_to_consensus.values()), {0.0})


def test_majority_overrules_one_engine_error() -> None:
    result = build_consensus({
        "a": "the northstar lift is closed",
        "b": "the northstar lift is closed",
        "c": "the northstor lift is closed",  # one engine mishears
    })
    check("majority wins", result.text, "the northstar lift is closed")
    check("one contested site", len(result.sites), 1)
    site = result.sites[0]
    check("site names the loser", sorted(site.options), ["northstar", "northstor"])
    check("chose the majority reading", site.chosen, "northstar")


def test_majority_drops_a_word_the_pivot_hallucinated() -> None:
    """If most engines heard nothing there, the consensus should not keep the extra word."""
    result = build_consensus({
        "a": "we should ship the very build today",
        "b": "we should ship the build today",
        "c": "we should ship the build today",
        "d": "we should ship the build today",
    })
    check("extra word dropped", result.text, "we should ship the build today")


def test_recovers_a_word_the_pivot_missed() -> None:
    """A word a majority heard but the alignment backbone lacks must be recovered.

    The pivot is forced to the deficient transcript on purpose. With automatic pivot selection the
    central transcript would already contain "hard" (a majority-held word makes a transcript more
    central), so this path would never run and the test would pass without exercising it.
    """
    transcripts = {
        "deficient": "move the deadline to friday",   # missing "hard"
        "b": "move the hard deadline to friday",
        "c": "move the hard deadline to friday",
        "d": "move the hard deadline to friday",
    }
    result = build_consensus(transcripts, pivot="deficient")
    check("recovered the missing word", result.text, "move the hard deadline to friday")
    check("recovery is flagged for review", len(result.sites), 1)
    check("site shows the recovered token", result.sites[0].chosen, "hard")

    # And with automatic pivot selection the same input still lands correctly, by the vote path.
    auto = build_consensus(transcripts)
    check("auto pivot avoids the deficient transcript", auto.pivot != "deficient", True)
    check("auto pivot result", auto.text, "move the hard deadline to friday")


def test_minority_insertion_is_not_recovered() -> None:
    """A word only a minority heard must NOT enter the reference, even with a deficient pivot --
    otherwise one hallucinating engine can inject words into the ground truth."""
    result = build_consensus(
        {
            "pivot_engine": "ship the build today",
            "b": "ship the build today",
            "c": "ship the build today",
            "hallucinating": "ship the final build today now",
        },
        pivot="pivot_engine",
    )
    check("minority words rejected", result.text, "ship the build today")


def test_pivot_is_the_central_transcript() -> None:
    """Two engines agree closely and one is an outlier; the outlier must not become the backbone."""
    result = build_consensus({
        "good_one": "the quarterly numbers look strong this season",
        "good_two": "the quarterly numbers look strong this season",
        "outlier": "quarter number look strange the season here now",
    })
    check("outlier is not the pivot", result.pivot in ("good_one", "good_two"), True)
    check("consensus follows the agreeing pair", result.text, "the quarterly numbers look strong this season")


def test_normalization_is_applied_before_voting() -> None:
    """Formatting differences must not register as disagreements needing review."""
    result = build_consensus({
        "apple": "We're shipping on Friday, finally.",
        "parakeet": "we are shipping on friday finally",
        "whisper": "We are shipping on Friday finally!",
    })
    check("no sites from punctuation alone", result.sites, [])
    check("normalized consensus", result.text, "we are shipping on friday finally")


def test_refuses_with_too_few_engines() -> None:
    for bad in ({"a": "one engine only"}, {"a": "x", "b": "y"}, {"a": "", "b": "", "c": ""}):
        try:
            build_consensus(bad)
        except ValueError:
            continue
        FAILURES.append(f"expected ValueError for {bad!r} but consensus was produced")


def test_empty_transcripts_are_excluded_not_counted() -> None:
    """A crashed engine returning "" must not get a vote for 'nothing was said'."""
    result = build_consensus({
        "a": "the lift opens at nine",
        "b": "the lift opens at nine",
        "c": "the lift opens at nine",
        "crashed": "",
    })
    check("crashed engine ignored", result.text, "the lift opens at nine")
    check("crashed engine absent from report", "crashed" in result.per_engine_wer_to_consensus, False)
    check("no spurious ABSENT votes", any(ABSENT in s.options for s in result.sites), False)


def test_site_render_is_reviewable() -> None:
    result = build_consensus({
        "a": "the northstar lift is closed today for maintenance",
        "b": "the northstar lift is closed today for maintenance",
        "c": "the northstor lift is closed today for maintenance",
    })
    rendered = result.sites[0].render()
    assert "northstar" in rendered and "northstor" in rendered, rendered
    assert "support" in rendered, rendered
    # Context must locate the word in the sentence for the user.
    assert "lift" in rendered, rendered


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            FAILURES.append(f"{test.__name__}: assertion failed: {exc}")
        except Exception as exc:  # noqa: BLE001
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
