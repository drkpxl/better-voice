"""Tests for the tracked baseline: record building, regression detection, and ranking.

The two tests worth reading first:

`test_meeting_record_carries_no_transcript_text` -- the baseline is a tracked file and the meeting
recording is confidential, so this asserts the record cannot carry what was said.

`test_merge_preserves_the_other_fixture` -- evaluating an engine on the dictation fixture alone must
not erase a meeting measurement that took twenty minutes to produce. Same class of data-loss bug as
the shared asr.json that this harness already got bitten by once.

Run: python3 bench/test_baseline.py
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import baseline
from baseline import (
    RTFX_TOLERANCE,
    WER_TOLERANCE,
    compare,
    compare_engine,
    dictation_record,
    format_ranking,
    load,
    material,
    meeting_record,
    merge_engine,
    rank_of,
    ranking,
    save,
)

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def cell(engine="e", cleanup="none", wer_intended=0.25, **kw) -> dict:
    base = {
        "engine": engine, "cleanup": cleanup, "wer_verbatim": 0.20,
        "wer_intended": wer_intended, "wer_nofiller": 0.28, "jargon_found": 2,
        "jargon_total": 5, "rtfx": 260.0,
    }
    base.update(kw)
    return base


def by_metric(deltas: list) -> dict:
    return {d.metric: d for d in deltas}


class FakeReport:
    def __init__(self, ok=True, words=10500):
        self._ok = ok
        self._words = words

    def to_dict(self) -> dict:
        return {"ok": self._ok, "words": self._words, "findings": []}


# ---------------------------------------------------------------------------
# Confidentiality and data safety
# ---------------------------------------------------------------------------

def test_meeting_record_carries_no_transcript_text() -> None:
    sentinel = "zzsecretcontentzz"
    asr_rec = {"text": f"a b {sentinel} c", "warm_s": 100.0, "audio_s": 3450.0,
               "raw": {"segments": [{"start": 0, "end": 10, "speaker": "S1",
                                     "text": f"{sentinel} spoken here"}]}}
    record = meeting_record(asr_rec, FakeReport())
    serialized = json.dumps(record)
    check("no transcript text in the meeting record", sentinel in serialized, False)
    check("word count is kept (a statistic, not content)", record["words"], 4)


def test_meeting_record_has_no_accuracy_field() -> None:
    """There is no reference for this fixture, so a WER-shaped slot would invite someone to fill it
    in from one engine's output -- making that engine the ground truth."""
    record = meeting_record({"text": "a b", "warm_s": 10.0, "audio_s": 100.0}, FakeReport())
    leaked = [k for k in record if "wer" in k.lower() or "accuracy" in k.lower()]
    check("no accuracy fields", leaked, [])
    check("rtfx computed", record["rtfx"], 10.0)


def test_merge_preserves_the_other_fixture() -> None:
    base = {"engines": {"e": {"dictation": {"wer_intended": 0.3},
                              "meeting": {"warm_s": 100.0, "words": 10500}}}}
    merge_engine(base, "e", {"dictation": {"wer_intended": 0.25}})
    check("dictation updated", base["engines"]["e"]["dictation"]["wer_intended"], 0.25)
    check("meeting survived", base["engines"]["e"]["meeting"]["words"], 10500)

    merge_engine(base, "e", {"meeting": {}})
    check("an empty fixture record does not wipe the existing one",
          base["engines"]["e"]["meeting"]["words"], 10500)


def test_load_save_roundtrip_and_corruption_tolerance() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "baseline.json"
        check("missing file gives an empty baseline", load(path)["engines"], {})
        save({"engines": {"e": {"dictation": {"wer_intended": 0.2}}}}, path)
        loaded = load(path)
        check("roundtrip", loaded["engines"]["e"]["dictation"]["wer_intended"], 0.2)
        check("schema stamped", loaded["schema"], baseline.SCHEMA)
        path.write_text("{ not json")
        check("corrupt file gives an empty baseline rather than raising", load(path)["engines"], {})


# ---------------------------------------------------------------------------
# Record building
# ---------------------------------------------------------------------------

def test_dictation_record_keeps_raw_and_best_separately() -> None:
    cells = [
        cell(cleanup="none", wer_intended=0.253),
        cell(cleanup="qwen3.5-4b", wer_intended=0.242),
        cell(cleanup="gemma4-12b", wer_intended=0.260),
    ]
    record = dictation_record(cells, {"warm_s": 0.441})
    check("raw number comes from the no-cleanup cell", record["wer_intended"], 0.253)
    check("best number", record["wer_intended_best"], 0.242)
    check("best cleanup named", record["best_cleanup"], "qwen3.5-4b")
    check("cleanup cell count", record["cleanup_cells"], 2)
    check("warm seconds from the ASR record", record["asr_warm_s"], 0.441)


def test_dictation_record_with_no_cleanup_grid() -> None:
    record = dictation_record([cell(cleanup="none", wer_intended=0.30)], {"warm_s": 1.0})
    check("raw present", record["wer_intended"], 0.30)
    check("best falls back to the only cell", record["wer_intended_best"], 0.30)
    check("no cleanup cells", record["cleanup_cells"], 0)
    check("empty input gives an empty record", dictation_record([], {}), {})


def test_dictation_record_ignores_unscored_cells() -> None:
    """A cell with no intended reference cannot be the 'best'."""
    cells = [cell(cleanup="none", wer_intended=None), cell(cleanup="apple-on-device",
                                                           wer_intended=0.4)]
    record = dictation_record(cells, {"warm_s": 1.0})
    check("best skips the unscored cell", record["wer_intended_best"], 0.4)


# ---------------------------------------------------------------------------
# Regression detection
# ---------------------------------------------------------------------------

def test_wer_tolerance() -> None:
    base = {"dictation": {"wer_intended": 0.25, "rtfx": 100.0}}
    small = compare_engine(base, {"dictation": {"wer_intended": 0.25 + WER_TOLERANCE / 2,
                                                "rtfx": 100.0}})
    check("a sub-tolerance move is not material",
          by_metric(small)["dictation.wer_intended"].material, False)
    big = compare_engine(base, {"dictation": {"wer_intended": 0.25 + WER_TOLERANCE * 2,
                                              "rtfx": 100.0}})
    check("a move past tolerance is material",
          by_metric(big)["dictation.wer_intended"].material, True)
    check("direction named", by_metric(big)["dictation.wer_intended"].direction, "worse")
    better = compare_engine(base, {"dictation": {"wer_intended": 0.10, "rtfx": 100.0}})
    check("an improvement is still flagged -- fixed audio should reproduce",
          by_metric(better)["dictation.wer_intended"].material, True)
    check("improvement direction", by_metric(better)["dictation.wer_intended"].direction, "better")


def test_rtfx_is_relative_and_classified_as_timing() -> None:
    base = {"dictation": {"wer_intended": 0.25, "rtfx": 100.0}}
    deltas = by_metric(compare_engine(base, {"dictation": {"wer_intended": 0.25, "rtfx": 40.0}}))
    rtfx = deltas["dictation.rtfx"]
    check("a 60% slowdown is material", rtfx.material, True)
    check("classified as timing", rtfx.kind, "timing")
    check("timing does not fail a check by default", material(list(deltas.values())), [])

    within = by_metric(compare_engine(base, {"dictation": {
        "wer_intended": 0.25, "rtfx": 100.0 * (1 - RTFX_TOLERANCE / 2)}}))
    check("machine noise is not material", within["dictation.rtfx"].material, False)


def test_meeting_word_count_drift_is_material() -> None:
    base = {"meeting": {"words": 10500, "rtfx": 30.0, "measured_on": "full"}}
    deltas = by_metric(compare_engine(base, {"meeting": {"words": 5000, "rtfx": 30.0,
                                                         "measured_on": "full"}}))
    check("halved word count is material", deltas["meeting.words"].material, True)
    check("classified as stability", deltas["meeting.words"].kind, "stability")
    check("stability fails a check", len(material(list(deltas.values()))), 1)


def test_stability_verdict_flip_is_material() -> None:
    base = {"meeting": {"words": 10500, "rtfx": 30.0, "measured_on": "full",
                        "stability": {"ok": True}}}
    meas = {"meeting": {"words": 10500, "rtfx": 30.0, "measured_on": "full",
                        "stability": {"ok": False}}}
    deltas = by_metric(compare_engine(base, meas))
    check("flip detected", deltas["meeting.stability.ok"].material, True)


def test_slice_and_full_are_not_compared() -> None:
    """A 5-minute slice against the full file would report a 90% word-count 'regression' that is
    really a different measurement."""
    base = {"meeting": {"words": 10500, "rtfx": 30.0, "measured_on": "full"}}
    meas = {"meeting": {"words": 900, "rtfx": 3.0, "measured_on": "slice:300"}}
    deltas = by_metric(compare_engine(base, meas))
    check("word count not compared", "meeting.words" in deltas, False)
    check("rtfx not compared", "meeting.rtfx" in deltas, False)
    check("the mismatch itself is reported", "meeting.measured_on" in deltas, True)
    check("but is not a failure", material(list(deltas.values())), [])


def test_missing_metrics_are_not_regressions() -> None:
    deltas = compare_engine({"dictation": {"wer_intended": 0.25}}, {"dictation": {}})
    for delta in deltas:
        if delta.material:
            FAILURES.append(f"unmeasured metric reported as material: {delta.metric}")
    check("no meeting comparison when neither side has one",
          [d for d in deltas if d.metric.startswith("meeting")], [])


def test_compare_classifies_new_and_unmeasured_engines() -> None:
    base = {"engines": {"known": {"dictation": {"wer_intended": 0.25, "rtfx": 10.0}},
                        "absent": {"dictation": {"wer_intended": 0.30}}}}
    result = compare(base, {"known": {"dictation": {"wer_intended": 0.25, "rtfx": 10.0}},
                            "fresh": {"dictation": {"wer_intended": 0.20}}})
    check("new engine listed", result["new"], ["fresh"])
    check("compared engine", sorted(result["engines"]), ["known"])
    check("baselined but not measured here", result["unmeasured"], ["absent"])
    check("a new engine is not a regression", material(result["engines"]["known"]), [])


def test_material_filters_by_kind() -> None:
    base = {"dictation": {"wer_intended": 0.25, "rtfx": 100.0}}
    deltas = compare_engine(base, {"dictation": {"wer_intended": 0.40, "rtfx": 10.0}})
    check("default kinds exclude timing", [d.metric for d in material(deltas)],
          ["dictation.wer_intended"])
    strict = material(deltas, ("accuracy", "stability", "timing"))
    check("strict includes timing", len(strict), 2)


def test_wer_metrics_render_as_percentages() -> None:
    """Dot-qualified metric names must still be recognized as WER, or the report prints raw floats."""
    delta = compare_engine({"dictation": {"wer_intended": 0.25}},
                           {"dictation": {"wer_intended": 0.40}})[0]
    rendered = delta.render()
    if "25.0%" not in rendered or "40.0%" not in rendered:
        FAILURES.append(f"WER not rendered as a percentage: {rendered}")
    if "points" not in rendered:
        FAILURES.append(f"WER movement should be stated in points: {rendered}")


# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------

def sample_baseline() -> dict:
    return {"engines": {
        "fast-bad": {"dictation": {"wer_intended": 0.40, "wer_intended_best": 0.376}},
        "slow-good": {"dictation": {"wer_intended": 0.19, "wer_intended_best": 0.186}},
        "middle": {"dictation": {"wer_intended": 0.26, "wer_intended_best": 0.242}},
        "raw-only": {"dictation": {"wer_intended": 0.30}},
        "no-dictation": {"meeting": {"words": 10500}},
    }}


def test_ranking_orders_best_first_with_fallback() -> None:
    rows = ranking(sample_baseline())
    check("best first", [n for n, _ in rows], ["slow-good", "middle", "raw-only", "fast-bad"])
    check("raw-only engine falls back to its raw number", dict(rows)["raw-only"], 0.30)
    check("an engine with no dictation record is omitted", "no-dictation" in dict(rows), False)


def test_rank_of_excludes_the_engines_own_stale_entry() -> None:
    """Re-evaluating a known engine must rank the new number against the OTHERS, not against its own
    recorded value -- which would report it as tied with itself."""
    info = rank_of(sample_baseline(), "middle", 0.242)
    check("ranked against the other three", info["total"], 4)
    check("second place", info["position"], 2)
    check("own stale entry not among those it beats", "middle" in info["beats"], False)
    check("nearest better", info["nearest_better"][0], "slow-good")


def test_rank_of_new_leader() -> None:
    info = rank_of(sample_baseline(), "brand-new", 0.10)
    check("first", info["position"], 1)
    check("leader flag", info["ahead_of_leader"], True)
    check("nothing better", info["nearest_better"], None)


def test_format_ranking_splices_the_new_engine_in() -> None:
    lines = format_ranking(sample_baseline(), "brand-new", 0.20)
    joined = "\n".join(lines)
    check("new engine marked", "->" in joined and "brand-new" in joined, True)
    check("ranked line present", "Ranked 2 of" in joined, True)
    arrowed = [ln for ln in lines if ln.strip().startswith("->")]
    check("exactly one marked row", len(arrowed), 1)

    # Within tolerance of the leader must be called a tie rather than a win.
    tie = "\n".join(format_ranking(sample_baseline(), "brand-new", 0.186 + WER_TOLERANCE / 2))
    check("tie called out", "tied" in tie, True)


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
