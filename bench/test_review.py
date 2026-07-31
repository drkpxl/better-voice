"""Tests for timestamp mapping and the review TUI's decision logic.

The curses layer is untested (it needs a terminal), which is exactly why all decision logic lives in
`ReviewState` as pure methods -- editing the reference wrongly would silently corrupt every downstream
WER number.

Run: python3 bench/test_review.py
"""

from __future__ import annotations

import sys

from consensus import ABSENT
from review_tui import CUSTOM, ReviewState
from timings import clock, expand_source_words, map_timestamps

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


# ---------------------------------------------------------------------------
# timings
# ---------------------------------------------------------------------------

def test_clock() -> None:
    check("zero", clock(0), "0:00")
    check("seconds", clock(9.7), "0:09")
    check("minutes", clock(116.2), "1:56")
    check("none", clock(None), "--:--")


def test_expand_source_words() -> None:
    """A source word normalizing to several tokens must yield one entry per token, all sharing its
    start time -- dropping the extras would desynchronize the alignment."""
    got = expand_source_words([
        {"word": "25", "startTime": 1.0},
        {"word": "percent,", "startTime": 2.0},
    ])
    check("digits expand, all share the start", got, [("twenty", 1.0), ("five", 1.0), ("percent", 2.0)])
    check("missing startTime skipped", expand_source_words([{"word": "hi"}]), [])


def test_map_timestamps_exact() -> None:
    tokens = ["the", "lift", "opens", "at", "nine"]
    timings = [
        {"word": "The", "startTime": 0.0}, {"word": "lift", "startTime": 0.5},
        {"word": "opens", "startTime": 1.0}, {"word": "at", "startTime": 1.5},
        {"word": "nine", "startTime": 2.0},
    ]
    check("exact alignment", map_timestamps(tokens, timings), [0.0, 0.5, 1.0, 1.5, 2.0])


def test_map_timestamps_interpolates_gaps() -> None:
    """Consensus tokens the timing engine never produced get interpolated, not left blank."""
    tokens = ["a", "b", "c", "d", "e"]
    timings = [{"word": "a", "startTime": 0.0}, {"word": "e", "startTime": 4.0}]
    got = map_timestamps(tokens, timings)
    check("endpoints anchored", (got[0], got[-1]), (0.0, 4.0))
    assert all(t is not None for t in got), got
    assert got[1] < got[2] < got[3], f"interpolation must be monotonic: {got}"


def test_map_timestamps_edges_and_empty() -> None:
    tokens = ["x", "y", "z"]
    # Anchor only in the middle: leading tokens take the first anchor, trailing the last.
    got = map_timestamps(tokens, [{"word": "y", "startTime": 5.0}])
    check("edges extend the anchor", got, [5.0, 5.0, 5.0])
    check("no timings -> all None", map_timestamps(tokens, []), [None, None, None])
    check("no tokens", map_timestamps([], [{"word": "a", "startTime": 0.0}]), [])


# ---------------------------------------------------------------------------
# ReviewState
# ---------------------------------------------------------------------------

def _state() -> ReviewState:
    return ReviewState(
        tokens=["the", "northstar", "lift", "is", "closed"],
        sites=[
            {"index": 1, "options": {"northstar": 5, "northstor": 2}, "chosen": "northstar"},
            {"index": 4, "options": {"closed": 4, "close": 3}, "chosen": "closed"},
        ],
        timestamps=[0.0, 0.5, 1.0, 1.5, 2.0],
    )


def test_options_ordering() -> None:
    s = _state()
    opts = s.options()
    check("votes descending", [o.token for o in opts[:2]], ["northstar", "northstor"])
    check("delete offered", ABSENT in [o.token for o in opts], True)
    check("custom offered last", opts[-1].token, CUSTOM)


def test_accepting_consensus_records_no_edit() -> None:
    """Selecting the word already in the draft must not create a spurious edit."""
    s = _state()
    s.accept()                        # cursor 0 == "northstar" == current token
    check("no edit for a no-op", s.edits, {})
    check("still counted as decided", s.decided, {0})
    check("advanced", s.index, 1)


def test_accepting_alternative_records_edit() -> None:
    s = _state()
    s.cursor = 1                      # "northstor"
    s.accept()
    check("edit recorded", s.edits, {1: "northstor"})
    check("applied", s.final_tokens(), ["the", "northstor", "lift", "is", "closed"])


def test_delete_option() -> None:
    s = _state()
    s.cursor = [o.token for o in s.options()].index(ABSENT)
    s.accept()
    check("word removed", s.final_tokens(), ["the", "lift", "is", "closed"])


def test_deletion_does_not_shift_unreviewed_sites() -> None:
    """Edits are keyed by original index, so deleting token 1 must not move site index 4."""
    s = _state()
    s.cursor = [o.token for o in s.options()].index(ABSENT)
    s.accept()                        # delete "northstar"
    check("second site still points at 'closed'", s.current_token(), "closed")
    s.cursor = 1                      # "close"
    s.accept()
    check("both edits applied correctly", s.final_tokens(), ["the", "lift", "is", "close"])


def test_custom_requires_text() -> None:
    """Pressing enter on the CUSTOM row must not commit an edit by itself."""
    s = _state()
    s.cursor = [o.token for o in s.options()].index(CUSTOM)
    s.accept()
    check("no edit from bare CUSTOM", s.edits, {})
    check("did not advance", s.index, 0)


def test_cursor_wraps_and_index_clamps() -> None:
    s = _state()
    n = len(s.options())
    s.move_cursor(-1)
    check("cursor wraps backward", s.cursor, n - 1)
    s.move_cursor(1)
    check("cursor wraps forward", s.cursor, 0)
    s.advance(-5)
    check("index clamps at 0", s.index, 0)
    s.advance(99)
    check("index clamps at end", s.index, len(s.sites) - 1)
    check("at_end", s.at_end(), True)


def test_context_and_timestamp() -> None:
    s = _state()
    before, after = s.context()
    check("context before", before, "the")
    check("context after", after, "lift is closed")
    check("timestamp of site token", s.timestamp(), 0.5)


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
