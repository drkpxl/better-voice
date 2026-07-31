"""Tracked baseline of measured engine results, plus regression detection and ranking.

`bench/runs/` is gitignored and disposable -- it holds 110MB of confidential meeting audio and gets
wiped. But the *numbers* measured from those fixtures are the only thing that makes a new model's
score meaningful, so they live in a small tracked file (`results/baseline.json`) that survives the
run directory being deleted.

**Aggregate numbers only.** No transcript text, no samples, no speaker labels, nothing derived from
what was said in the meeting -- word counts and wall-clock times are statistics, not content. This is
enforced by construction: every function here builds records from scalars, and the long-form report
contributes only `LongFormReport.to_dict()`, which is itself text-free.

Two jobs:

1. **Ranking a new model.** Where does an engine measured today land among engines measured before?
2. **Detecting drift.** Re-running a known engine on fixed audio against fixed references should
   reproduce its recorded numbers. When it does not, something moved that is not the model -- a
   normalizer change, a dependency upgrade, thermal throttling, a different macOS speech model
   shipped in an OS update. That is worth knowing loudly, because silent drift invalidates every
   comparison made after it.

Thresholds are deliberately crude absolute numbers rather than a statistical model. With one fixture
recording there is no sampling distribution to appeal to, so a t-test would be false precision.

Stdlib only. Python 3.9 compatible.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import longform

BASELINE_PATH = Path(__file__).resolve().parent / "results" / "baseline.json"
SCHEMA = 1

# --- materiality thresholds ----------------------------------------------
# WER: absolute, in WER units (0.02 = 2 percentage points). The design doc already treats gaps under
# ~1 point as ties, and cleanup is nondeterministic run to run, so 2 points is the smallest move
# worth calling a regression rather than noise.
WER_TOLERANCE = 0.02
# Throughput: relative. Wall-clock on a laptop swings with thermals and background load, so this is
# loose on purpose -- it catches "the model got 3x slower", not "the fan was on".
RTFX_TOLERANCE = 0.25
# Long-form word count: relative to the recorded value. The four measured engines span 1% of each
# other, so 5% is comfortably outside honest engine-to-engine variation.
WORDS_TOLERANCE = 0.05

# Which kinds of movement fail a regression check by default. Timing is excluded: a slow run is
# usually the machine, not the model, and failing on it would train people to ignore the check.
FAILING_KINDS = ("accuracy", "stability")


@dataclass
class Delta:
    """One metric that moved between the baseline and a fresh measurement."""

    metric: str
    kind: str            # "accuracy" | "timing" | "stability"
    baseline: object
    measured: object
    material: bool
    detail: str = ""

    @property
    def direction(self) -> str:
        """Whether the change is an improvement, for metrics where that is defined.

        WER down is better; RTFx and word count have no inherent good direction (more words is only
        better if they are correct, which is exactly what this fixture cannot tell us).
        """
        try:
            if self.baseline is None or self.measured is None:
                return "changed"
            if self.measured == self.baseline:
                return "same"
            if not _is_wer(self.metric):
                return "up" if self.measured > self.baseline else "down"
            return "better" if self.measured < self.baseline else "worse"
        except TypeError:
            return "changed"

    def render(self) -> str:
        mark = "MOVED" if self.material else "  ok "
        base = _fmt(self.metric, self.baseline)
        meas = _fmt(self.metric, self.measured)
        arrow = f"{base} -> {meas}"
        extra = f"  ({self.detail})" if self.detail else ""
        return f"  [{mark}] {self.metric:<28} {arrow:<28} {self.direction}{extra}"


def _is_wer(metric: str) -> bool:
    """Metrics arrive dot-qualified ("dictation.wer_intended"), so test the leaf, not the prefix."""
    return metric.rsplit(".", 1)[-1].startswith("wer")


def _fmt(metric: str, value) -> str:
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if _is_wer(metric) and isinstance(value, (int, float)):
        return f"{value:.1%}"
    if isinstance(value, float):
        return f"{value:g}"
    return str(value)


# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------

def empty_baseline() -> dict:
    return {"schema": SCHEMA, "fixtures": {}, "engines": {}}


def load(path: Path = BASELINE_PATH) -> dict:
    if not path.exists():
        return empty_baseline()
    try:
        data = json.loads(path.read_text())
    except Exception:  # noqa: BLE001
        return empty_baseline()
    if not isinstance(data, dict) or "engines" not in data:
        return empty_baseline()
    return data


def save(baseline: dict, path: Path = BASELINE_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(baseline)
    payload["schema"] = SCHEMA
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


def merge_engine(baseline: dict, engine: str, record: dict) -> dict:
    """Merge one engine's record, per fixture.

    Merging per fixture rather than replacing the engine wholesale matters: evaluating a new model on
    the dictation fixture alone must not erase a meeting measurement that took twenty minutes to
    produce. Same reasoning as one-file-per-engine in the ASR stage.
    """
    engines = baseline.setdefault("engines", {})
    existing = dict(engines.get(engine) or {})
    for fixture, values in record.items():
        if values:
            existing[fixture] = values
    engines[engine] = existing
    return baseline


# ---------------------------------------------------------------------------
# Building records
# ---------------------------------------------------------------------------

def dictation_record(cells: list, asr_rec: dict) -> dict:
    """Baseline record for the dictation fixture, from that engine's scored cells.

    Keeps two accuracy numbers because they answer different questions and the distinction is the one
    the whole bake-off turned on: the raw cell is the ASR stage alone (deterministic, so drift in it
    is unambiguous), and the best-of-cleanup cell is the end-to-end pipeline number that ranks
    engines. Storing only one would either hide which cleanup a model needs or make the ranking
    incomparable to the published table.
    """
    if not cells:
        return {}
    raw = next((c for c in cells if c.get("cleanup") == "none"), None)
    scored = [c for c in cells if c.get("wer_intended") is not None]
    best = min(scored, key=lambda c: c["wer_intended"]) if scored else None
    base = raw or best
    if base is None:
        return {}

    record = {
        "wer_verbatim": base.get("wer_verbatim"),
        "wer_intended": base.get("wer_intended"),
        "wer_nofiller": base.get("wer_nofiller"),
        "jargon_found": base.get("jargon_found"),
        "jargon_total": base.get("jargon_total"),
        "asr_warm_s": asr_rec.get("warm_s"),
        "rtfx": base.get("rtfx"),
        "cleanup_cells": len([c for c in cells if c.get("cleanup") != "none"]),
    }
    if best is not None:
        record["wer_intended_best"] = best.get("wer_intended")
        record["best_cleanup"] = best.get("cleanup")
    return record


def meeting_record(asr_rec: dict, report=None, measured_on: str = "full") -> dict:
    """Baseline record for the meeting fixture: throughput and stability, never accuracy.

    There is no reference transcript for this recording, so WER is not merely absent, it is
    unavailable in principle. Recording a WER-shaped field here would invite someone to fill it in
    from one engine's output, which would make that engine the ground truth.
    """
    audio_s = asr_rec.get("audio_s")
    warm_s = asr_rec.get("warm_s")
    record = {
        "warm_s": warm_s,
        "rtfx": round(audio_s / warm_s, 1) if audio_s and warm_s else None,
        "words": len((asr_rec.get("text") or "").split()),
        "measured_on": measured_on,
    }
    if asr_rec.get("n_speakers"):
        record["n_speakers"] = asr_rec.get("n_speakers")
    if asr_rec.get("n_segments"):
        record["n_segments"] = asr_rec.get("n_segments")
    coverage = longform.speaker_coverage(asr_rec.get("raw") or {}, audio_s)
    if coverage is not None:
        record["speaker_coverage"] = round(coverage, 3)
    if report is not None:
        record["stability"] = report.to_dict()
    return record


# ---------------------------------------------------------------------------
# Regression detection
# ---------------------------------------------------------------------------

def _absolute(metric: str, kind: str, base, meas, tolerance: float) -> Delta:
    if base is None or meas is None:
        return Delta(metric, kind, base, meas, material=False,
                     detail="not measured on both sides")
    moved = abs(meas - base)
    return Delta(metric, kind, base, meas, material=moved > tolerance,
                 detail=f"moved {moved * 100:.1f} points, tolerance {tolerance * 100:.0f} points"
                 if _is_wer(metric) else f"moved {moved:g}")


def _relative(metric: str, kind: str, base, meas, tolerance: float) -> Delta:
    if not base or meas is None:
        return Delta(metric, kind, base, meas, material=False,
                     detail="not measured on both sides")
    moved = abs(meas - base) / abs(base)
    return Delta(metric, kind, base, meas, material=moved > tolerance,
                 detail=f"moved {moved:.0%}, tolerance {tolerance:.0%}")


def compare_engine(base_rec: dict, meas_rec: dict) -> list:
    """Every metric that both sides measured, with materiality decided per metric."""
    deltas: list = []
    bd = (base_rec or {}).get("dictation") or {}
    md = (meas_rec or {}).get("dictation") or {}
    if bd and md:
        for metric in ("wer_verbatim", "wer_intended", "wer_intended_best"):
            if metric in bd or metric in md:
                deltas.append(_absolute(f"dictation.{metric}", "accuracy",
                                        bd.get(metric), md.get(metric), WER_TOLERANCE))
        deltas.append(_relative("dictation.rtfx", "timing", bd.get("rtfx"), md.get("rtfx"),
                                RTFX_TOLERANCE))

    bm = (base_rec or {}).get("meeting") or {}
    mm = (meas_rec or {}).get("meeting") or {}
    if bm and mm:
        # A slice and the full file are not comparable on either axis, so say so instead of
        # reporting a 90% word-count "regression" that is really a different measurement.
        if bm.get("measured_on") != mm.get("measured_on"):
            deltas.append(Delta("meeting.measured_on", "stability", bm.get("measured_on"),
                                mm.get("measured_on"), material=False,
                                detail="different span measured; word count and RTFx not compared"))
        else:
            deltas.append(_relative("meeting.words", "stability", bm.get("words"), mm.get("words"),
                                    WORDS_TOLERANCE))
            deltas.append(_relative("meeting.rtfx", "timing", bm.get("rtfx"), mm.get("rtfx"),
                                    RTFX_TOLERANCE))
        base_ok = (bm.get("stability") or {}).get("ok")
        meas_ok = (mm.get("stability") or {}).get("ok")
        if base_ok is not None and meas_ok is not None and base_ok != meas_ok:
            deltas.append(Delta("meeting.stability.ok", "stability", base_ok, meas_ok,
                                material=True,
                                detail="long-form stability verdict flipped"))
    return deltas


def compare(baseline: dict, measured: dict) -> dict:
    """Compare a map of freshly measured engine records against the baseline.

    Returns `{"engines": {name: [Delta]}, "new": [...], "unmeasured": [...]}`. New engines are not a
    regression, and engines the baseline knows but this run did not touch are not either -- both are
    reported so the caller can say which comparison it actually made.
    """
    known = baseline.get("engines") or {}
    out = {"engines": {}, "new": [], "unmeasured": []}
    for name, rec in sorted(measured.items()):
        if name not in known:
            out["new"].append(name)
            continue
        out["engines"][name] = compare_engine(known[name], rec)
    out["unmeasured"] = sorted(set(known) - set(measured))
    return out


def material(deltas: list, kinds: tuple = FAILING_KINDS) -> list:
    return [d for d in deltas if d.material and d.kind in kinds]


# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------

RANK_METRICS = ("wer_intended_best", "wer_intended")


def ranking(baseline: dict, metric: str = "wer_intended_best") -> list:
    """`[(engine, value)]` sorted best-first on a dictation metric.

    Falls back to `wer_intended` for engines that were never run through the cleanup grid, so an
    engine measured raw-only still appears rather than silently vanishing from the table.
    """
    rows = []
    for name, rec in (baseline.get("engines") or {}).items():
        d = rec.get("dictation") or {}
        value = d.get(metric)
        if value is None and metric == "wer_intended_best":
            value = d.get("wer_intended")
        if value is not None:
            rows.append((name, value))
    return sorted(rows, key=lambda kv: (kv[1], kv[0]))


def rank_of(baseline: dict, engine: str, value: float, metric: str = "wer_intended_best") -> dict:
    """Where `value` lands among baselined engines, excluding `engine`'s own recorded entry.

    Excluding it is the point: when re-evaluating a known engine you want its new number ranked
    against the *others*, not against its own stale record, which would report it as tied with
    itself.
    """
    others = [(n, v) for n, v in ranking(baseline, metric) if n != engine]
    better = [(n, v) for n, v in others if v < value]
    worse = [(n, v) for n, v in others if v >= value]
    return {
        "position": len(better) + 1,
        "total": len(others) + 1,
        "beats": [n for n, _ in worse],
        "behind": [n for n, _ in better],
        "ahead_of_leader": not better,
        "nearest_better": better[-1] if better else None,
        "nearest_worse": worse[0] if worse else None,
    }


def format_ranking(baseline: dict, engine: str, value: float,
                   metric: str = "wer_intended_best") -> list:
    """Ranking as printable lines, with the new engine spliced into the standing table."""
    info = rank_of(baseline, engine, value, metric)
    lines = [f"Ranked {info['position']} of {info['total']} on {metric} "
             f"(dictation fixture, lower is better)"]
    others = [(n, v) for n, v in ranking(baseline, metric) if n != engine]
    rows = sorted(others + [(engine, value)], key=lambda kv: (kv[1], kv[0]))
    for name, v in rows:
        marker = "->" if name == engine else "  "
        lines.append(f"  {marker} {v:6.1%}  {name}")
    if info["ahead_of_leader"]:
        lines.append("  New leader on this fixture.")
    elif info["nearest_better"]:
        nb, nv = info["nearest_better"]
        lines.append(f"  {value - nv:+.1%} vs the next engine up ({nb}).")
    if abs(value - rows[0][1]) <= WER_TOLERANCE and rows[0][0] != engine:
        lines.append(f"  Within the {WER_TOLERANCE:.0%} tolerance of the leader "
                     f"({rows[0][0]}) -- treat as tied, break it with a blind preference ranking.")
    return lines
