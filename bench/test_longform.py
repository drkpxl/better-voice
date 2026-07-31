"""Tests for the long-form stability checks.

Two properties matter more than the rest:

`test_ordinary_repetition_never_fails` -- real speech stutters and repeats, and the meeting fixture's
own healthy transcripts contain a two-word phrase repeated four times. A detector that failed on that
would cry wolf on every engine and get ignored, which is worse than not having it.

`test_report_carries_no_transcript_text` -- the report is written into a tracked file and the fixture
recording is confidential. This asserts the report cannot leak what was said.

Run: python3 bench/test_longform.py
"""

from __future__ import annotations

import json
import sys

import longform
from longform import (
    LongFormReport,
    analyze,
    bucket_density,
    distinct_ngram_ratio,
    longest_loop,
    speaker_coverage,
    word_times,
)

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def check_close(label: str, actual, expected, tol: float = 1e-6) -> None:
    if actual is None or abs(actual - expected) > tol:
        FAILURES.append(f"{label}\n    expected: {expected}\n    actual:   {actual}")


def codes(report: LongFormReport) -> list:
    return [f.code for f in report.findings]


def fails(report: LongFormReport) -> list:
    return [f.code for f in report.findings if f.severity == "fail"]


def warns(report: LongFormReport) -> list:
    return [f.code for f in report.findings if f.severity == "warn"]


def healthy_words(n: int) -> list:
    """A transcript with no degenerate structure: distinct tokens with light natural repetition."""
    vocab = ["we", "should", "move", "the", "deadline", "to", "friday", "and", "tell", "the", "team",
             "about", "capacity", "before", "the", "next", "review"]
    return [vocab[i % len(vocab)] + ("" if i % 5 else str(i)) for i in range(n)]


# ---------------------------------------------------------------------------
# The load-bearing properties
# ---------------------------------------------------------------------------

def test_ordinary_repetition_never_fails() -> None:
    """A spoken stutter is a WARN at most, never a FAIL, at any repeat count.

    Calibration fact this pins down: the healthy Whisper transcript on the meeting fixture repeats a
    two-word phrase 4x consecutively. That is speech the cleanup stage removes, not a broken model.
    """
    tokens = healthy_words(600)
    # 4 consecutive repeats of a 2-word phrase, as observed in real healthy output.
    tokens[100:108] = ["you", "know"] * 4
    report = analyze(" ".join(tokens), audio_s=200.0, expected_words=600)
    check("4x two-word repeat does not fail", fails(report), [])
    check("4x two-word repeat is below the warn threshold too", "loop" in codes(report), False)

    # Even far past the warn threshold it stays a warn: a human adjudicates, the check does not.
    tokens = healthy_words(600)
    tokens[100:130] = ["you", "know"] * 15
    report = analyze(" ".join(tokens), audio_s=200.0, expected_words=600)
    check("15x repeat warns", "loop" in warns(report), True)
    check("15x repeat still does not fail", fails(report), [])


def test_report_carries_no_transcript_text() -> None:
    """to_dict() must be numbers only -- it is written into a tracked file."""
    sentinel = "zzsecretcontentzz"
    text = " ".join(healthy_words(300) + [sentinel] * 3)
    report = analyze(text, audio_s=100.0, expected_words=300)
    serialized = json.dumps(report.to_dict())
    check("no transcript text in the serialized report", sentinel in serialized, False)
    for key, value in report.to_dict().items():
        if isinstance(value, str) and value not in ("wordTimings", "segments"):
            FAILURES.append(f"to_dict carries a free-text field: {key}={value!r}")
        if isinstance(value, list) and any(isinstance(v, str) and len(v) > 24 for v in value):
            FAILURES.append(f"to_dict carries long strings in {key}: {value!r}")


# ---------------------------------------------------------------------------
# Truncation
# ---------------------------------------------------------------------------

def test_truncation_detected() -> None:
    report = analyze(" ".join(healthy_words(3000)), audio_s=3450.0, expected_words=10500)
    check("truncation fails", "truncated" in fails(report), True)
    check("truncated flag set", report.truncated, True)
    check_close("word ratio", report.word_ratio, 3000 / 10500)


def test_healthy_word_count_passes() -> None:
    report = analyze(" ".join(healthy_words(10400)), audio_s=3450.0, expected_words=10500)
    check("healthy count does not flag truncation", report.truncated, False)
    check("healthy count does not flag overrun", report.overrun, False)


def test_overrun_is_a_warning_not_a_failure() -> None:
    """Expanding contractions legitimately inflates word counts, so this cannot be a hard failure."""
    report = analyze(" ".join(healthy_words(14000)), audio_s=3450.0, expected_words=10500)
    check("overrun warns", "overrun" in warns(report), True)
    check("overrun does not fail", "overrun" in fails(report), False)


def test_word_checks_skipped_without_an_expectation() -> None:
    """No baseline band means no guessing: the check is skipped, not invented."""
    report = analyze(" ".join(healthy_words(100)), audio_s=3450.0, expected_words=None)
    check("no word ratio", report.word_ratio, None)
    check("no truncation claim", report.truncated, False)


def test_empty_output_fails() -> None:
    report = analyze("", audio_s=3450.0, expected_words=10500)
    check("empty fails", fails(report), ["empty"])
    check("not ok", report.ok, False)


# ---------------------------------------------------------------------------
# Degeneracy: the primary loop signal
# ---------------------------------------------------------------------------

def test_ngram_collapse_fails() -> None:
    """Wholesale degeneracy is the unambiguous case, so it is the FAIL."""
    report = analyze("the lift is closed today " * 400, audio_s=3450.0, expected_words=10500)
    check("degenerate fails", "degenerate" in fails(report), True)
    check("not ok", report.ok, False)
    if report.distinct_ngram_ratio is None or report.distinct_ngram_ratio > 0.2:
        FAILURES.append(f"expected a collapsed n-gram ratio, got {report.distinct_ngram_ratio}")


def test_healthy_ngram_ratio_is_near_one() -> None:
    ratio = distinct_ngram_ratio(healthy_words(2000))
    if ratio is None or ratio < 0.95:
        FAILURES.append(f"healthy 5-gram ratio should be near 1.0, got {ratio}")
    check("too short for n-grams returns None", distinct_ngram_ratio(["a", "b"]), None)


def test_localized_loop_barely_moves_the_global_ratio() -> None:
    """Why both signals exist: one bad stretch is a warn, not a collapse.

    Mirrors real measured behavior -- whisper-tiny looped a 5-word phrase 12.8x on the meeting fixture
    while its distinct-n-gram ratio stayed at 0.987, close to the healthy 0.997.
    """
    tokens = healthy_words(4000)
    tokens[2000:2060] = ["and", "then", "we", "can", "ship"] * 12
    report = analyze(" ".join(tokens), audio_s=3450.0, expected_words=4000)
    check("localized loop warns", "loop" in warns(report), True)
    check("localized loop does not fail", fails(report), [])
    if report.distinct_ngram_ratio is None or report.distinct_ngram_ratio < 0.9:
        FAILURES.append(f"a localized loop should barely move the ratio, got "
                        f"{report.distinct_ngram_ratio}")


def test_longest_loop_math() -> None:
    check("period 1 repeated 5x", longest_loop(["a"] * 5)[:2], (1, 5.0))
    period, repeats, start = longest_loop("x y a b a b a b z".split())
    check("period 2 found", period, 2)
    check_close("3 repeats", repeats, 3.0)
    check("start index", start, 2)
    check("no repetition at all", longest_loop("a b c d e".split()), (0, 0.0, None))
    check("empty", longest_loop([]), (0, 0.0, None))


# ---------------------------------------------------------------------------
# Timeline
# ---------------------------------------------------------------------------

def test_word_times_from_word_timings() -> None:
    raw = {"wordTimings": [{"word": "one", "startTime": 0.0}, {"word": "two", "startTime": 1.5}]}
    times, source = word_times(raw)
    check("source", source, "wordTimings")
    check("times", times, [0.0, 1.5])
    # A multi-token entry must contribute one timestamp per token, or the alignment desynchronizes.
    times, _ = word_times({"wordTimings": [{"word": "twenty five", "startTime": 2.0}]})
    check("multi-token entry", times, [2.0, 2.0])
    check("entry without a start is skipped",
          word_times({"wordTimings": [{"word": "x"}]}), ([], None))


def test_word_times_from_segments() -> None:
    raw = {"segments": [{"start": 0.0, "end": 4.0, "text": "a b c d"},
                        {"start": 10.0, "end": 12.0, "text": "e f"}]}
    times, source = word_times(raw)
    check("source", source, "segments")
    check("spread evenly inside each segment", times, [0.0, 1.0, 2.0, 3.0, 10.0, 11.0])
    check("no timings at all", word_times({}), ([], None))


def test_bucket_density_is_by_audio_time_not_word_index() -> None:
    """The property that makes late collapse detectable at all.

    A transcript covering only the first half of the audio is perfectly uniform when sliced by word
    index and obviously broken when sliced by time. Slicing by time is the whole point.
    """
    times = [i * 0.1 for i in range(500)]   # 50s of words, in a 100s file
    density = bucket_density(times, 100.0, buckets=10)
    check("10 buckets", len(density), 10)
    if not all(v > 0 for v in density[:5]):
        FAILURES.append(f"first half should be populated: {density}")
    check("second half empty", density[5:], [0.0] * 5)
    check("no times", bucket_density([], 100.0), [])
    check("no duration", bucket_density([1.0], 0.0), [])


def test_late_collapse_detected() -> None:
    # Dense through 80% of the file, then nothing.
    times = [i * 0.05 for i in range(int(2760 / 0.05))]
    report = analyze(" ".join(healthy_words(len(times))), audio_s=3450.0,
                     raw={"wordTimings": [{"word": "w", "startTime": t} for t in times]})
    check("coverage failure", "coverage" in fails(report), True)
    check("late_collapse flag", report.late_collapse, True)


def test_empty_bucket_fails_but_thin_bucket_warns() -> None:
    def report_for(gap_words: int):
        times = []
        for bucket in range(10):
            n = gap_words if bucket == 4 else 100
            times += [bucket * 10.0 + i * (10.0 / max(n, 1)) for i in range(n)]
        return analyze(" ".join(healthy_words(len(times))), audio_s=100.0,
                       raw={"wordTimings": [{"word": "w", "startTime": t} for t in times]})

    check("an empty bucket fails", "empty-bucket" in fails(report_for(1)), True)
    check("a thin bucket only warns", "dropout" in warns(report_for(15)), True)
    check("a thin bucket does not fail", fails(report_for(15)), [])


def test_missing_timings_warns_rather_than_failing() -> None:
    """Whisper reports no timings; that is a gap in what can be checked, not a broken engine."""
    report = analyze(" ".join(healthy_words(10500)), audio_s=3450.0, expected_words=10500, raw={})
    check("no-timeline warns", "no-timeline" in warns(report), True)
    check("no-timeline does not fail", fails(report), [])
    check("report still ok", report.ok, True)


def test_healthy_full_length_transcript_is_clean() -> None:
    """Zero false alarms on healthy input, with timings present."""
    times = [i * (3450.0 / 10500) for i in range(10500)]
    report = analyze(" ".join(healthy_words(10500)), audio_s=3450.0, expected_words=10500,
                     raw={"wordTimings": [{"word": "w", "startTime": t} for t in times]})
    check("no findings at all", codes(report), [])
    check("ok", report.ok, True)


# ---------------------------------------------------------------------------
# Diarization coverage
# ---------------------------------------------------------------------------

def test_speaker_coverage() -> None:
    raw = {"segments": [{"start": 0.0, "end": 40.0, "speaker": "S1", "text": "x"},
                        {"start": 40.0, "end": 90.0, "speaker": "S2", "text": "y"},
                        {"start": 90.0, "end": 100.0, "speaker": "", "text": "z"}]}
    check_close("attributed fraction", speaker_coverage(raw, 100.0), 0.9)
    check("no segments", speaker_coverage({}, 100.0), None)
    check("no duration", speaker_coverage(raw, None), None)
    check("nothing attributed",
          speaker_coverage({"segments": [{"start": 0, "end": 5, "speaker": "", "text": "a"}]}, 10.0),
          None)


def test_thresholds_sit_outside_the_measured_healthy_band() -> None:
    """Guards the calibration itself: healthy output measured 0.997-0.998 distinct 5-grams,
    per-decile density 0.87-1.06 of median, coverage 0.9998. If a threshold is ever tightened past
    those, the checker starts failing known-good engines."""
    if longform.DISTINCT_NGRAM_FLOOR >= 0.99:
        FAILURES.append("DISTINCT_NGRAM_FLOOR is inside the healthy band")
    if longform.LATE_DENSITY_FLOOR >= 0.87:
        FAILURES.append("LATE_DENSITY_FLOOR is inside the healthy band")
    if longform.COVERAGE_FLOOR >= 0.9998:
        FAILURES.append("COVERAGE_FLOOR is inside the healthy band")
    if longform.TRUNCATION_RATIO >= 0.99:
        FAILURES.append("TRUNCATION_RATIO is inside the healthy band")
    if longform.LOOP_REPEAT_WARN <= 4:
        FAILURES.append("LOOP_REPEAT_WARN is at or below the worst healthy observation (4.0)")


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
