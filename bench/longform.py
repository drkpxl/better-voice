"""Long-form stability checks for the meeting fixture.

The meeting recording has no reference transcript, so WER is unavailable and the interesting
question is different: **did the engine survive 57 minutes of audio at all?** Long-form ASR fails in
specific, recognizable ways, and every one of them produces output that looks fine if you only read
the first paragraph:

- **Truncation** — the engine stops early (chunker drops the tail, a context window fills, an
  internal buffer wraps). Signature: word count far below what the audio duration implies.
- **Repetition loop** — the classic autoregressive degeneracy, where the model emits the same span
  until the segment ends. Signature: the distinct-n-gram ratio collapses, because thousands of words
  of output carry only a handful of distinct n-grams.
- **Late collapse** — quality holds for the first N minutes and then the output thins out or stops
  tracking the audio. Signature: word density in the final buckets far below the median, or the last
  word timestamp well before the end of the file.

**The primary loop signal is the distinct-n-gram ratio, not consecutive-phrase repetition.** Measured
across the four healthy engines on this fixture the ratio sits in 0.997-0.998, while genuine
degeneracy drives it toward 0.6 or lower -- an enormous margin that needs no tuning. Consecutive
repetition, by contrast, is something real speech does constantly: the healthy Whisper transcript
repeats a two-word phrase four times in a row, which is a spoken stutter that the cleanup stage
exists to remove, not a model falling apart. So that detector is a WARN with its threshold set well
above the worst healthy observation, and it is a smoke alarm rather than a measurement.

**FAIL vs WARN.** FAIL is reserved for unambiguous evidence that the engine broke: truncation,
n-gram collapse, a timeline that stops early, an empty decile, or a collapsed tail. Everything
softer -- ordinary repetition, a word count above the band, a thin-but-present stretch, absent
timings -- is a WARN for a human to adjudicate. The check exists to catch a model that fell apart on
long audio, so it is tuned for zero false alarms on healthy input.

Every threshold below sits far outside the spread observed on the four measured engines
(distinct-5-gram 0.997-0.998, per-decile density 0.87-1.06 of median, coverage 0.9998). That
calibration set is n=4: treat the soft thresholds as provisional.

Numbers only: `LongFormReport.to_dict()` is deliberately free of transcript text so it can be
written into the tracked baseline file. The recording is confidential; its aggregate statistics are
not.

Stdlib only. Python 3.9 compatible.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field

# --- truncation / overrun -------------------------------------------------
# Ratio of measured words to expected words. 0.8 is well below the 0.997-1.007 the healthy engines
# span, so normal engine-to-engine variation in what counts as a word cannot trip it.
TRUNCATION_RATIO = 0.80
OVERRUN_RATIO = 1.25          # WARN only: expanding contractions inflates word counts legitimately

# --- degeneracy (the primary loop signal) ---------------------------------
# Distinct n-grams over total n-grams. Healthy is 0.997+ on this fixture; a model stuck in a
# repetition loop emits thousands of words carrying a handful of distinct n-grams and lands near 0.6.
# The floor sits in the empty space between those two regimes, which is why it needs no tuning.
NGRAM = 5
DISTINCT_NGRAM_FLOOR = 0.85

# --- consecutive repetition (WARN only) -----------------------------------
# A loop here is a token sequence of period p repeated back to back. Periods beyond ~40 words are not
# degeneracy, they are someone restating a point.
#
# The threshold is deliberately crude: one number, no period-scaled table. The worst healthy
# observation across the four measured engines is 4.0 consecutive repeats (a two-word spoken stutter),
# and 8 is double that. A table fitted to n=4 transcripts would be fitting noise and would mis-fire on
# engine five. Treat this as a smoke alarm that prompts a human to look, never as a measurement --
# hence severity "warn", always.
MAX_LOOP_PERIOD = 40
LOOP_REPEAT_WARN = 8

# --- timeline ------------------------------------------------------------
BUCKETS = 10
COVERAGE_FLOOR = 0.95         # healthy is 0.9998
LATE_DENSITY_FLOOR = 0.35     # fraction of median bucket density, applied to the final buckets
EMPTY_DENSITY_FLOOR = 0.05    # a bucket this far below median is effectively empty audio: FAIL
GAP_DENSITY_FLOOR = 0.20      # thin but present: WARN
LATE_BUCKETS = 2


@dataclass(frozen=True)
class Finding:
    code: str
    detail: str
    severity: str = "fail"    # "fail" = broken output, "warn" = suspicious but usable

    def render(self) -> str:
        mark = "FAIL" if self.severity == "fail" else "warn"
        return f"[{mark}] {self.code}: {self.detail}"


@dataclass
class LongFormReport:
    words: int = 0
    expected_words: int | None = None
    word_ratio: float | None = None
    truncated: bool = False
    overrun: bool = False
    loop_period: int = 0
    loop_repeats: float = 0.0
    loop_at_word: int | None = None
    looped: bool = False
    distinct_ngram_ratio: float | None = None
    timeline_source: str | None = None
    coverage: float | None = None
    bucket_wps: list = field(default_factory=list)
    late_density: float | None = None      # final-buckets density / median density
    worst_bucket: int | None = None
    worst_bucket_density: float | None = None
    late_collapse: bool = False
    findings: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(f.severity == "fail" for f in self.findings)

    def summary(self) -> str:
        bits = [f"{self.words} words"]
        if self.word_ratio is not None:
            bits.append(f"{self.word_ratio:.0%} of expected")
        if self.coverage is not None:
            bits.append(f"coverage {self.coverage:.1%}")
        if self.loop_repeats >= 2:
            bits.append(f"longest loop {self.loop_repeats:.1f}x")
        bits.append("STABLE" if self.ok else "UNSTABLE")
        return "  ".join(bits)

    def to_dict(self) -> dict:
        """Baseline-safe: aggregate numbers only, never transcript text."""
        return {
            "ok": self.ok,
            "words": self.words,
            "word_ratio": round(self.word_ratio, 4) if self.word_ratio is not None else None,
            "truncated": self.truncated,
            "overrun": self.overrun,
            "looped": self.looped,
            "loop_period": self.loop_period,
            "loop_repeats": round(self.loop_repeats, 2),
            "distinct_ngram_ratio": (round(self.distinct_ngram_ratio, 4)
                                     if self.distinct_ngram_ratio is not None else None),
            "timeline_source": self.timeline_source,
            "coverage": round(self.coverage, 4) if self.coverage is not None else None,
            "late_density": round(self.late_density, 3) if self.late_density is not None else None,
            "late_collapse": self.late_collapse,
            "findings": [f.code for f in self.findings],
        }


# ---------------------------------------------------------------------------
# Repetition
# ---------------------------------------------------------------------------

def longest_loop(tokens: list) -> tuple:
    """Most-repeated consecutive span, as `(period, repeats, start_index)`.

    For each period p, the longest run of `tokens[i] == tokens[i + p]` gives the number of times the
    p-word phrase repeated back to back (run/p + 1). Scanning periods up to MAX_LOOP_PERIOD is
    O(40n) -- 400k comparisons on a 10k-word transcript, cheap enough to run on every long-form
    result rather than only on suspicious ones.

    Ranked by raw repeat count against the single LOOP_REPEAT_WARN threshold. Repeats are a float
    because a partial final repetition ("a b c a b c a") is still evidence.
    """
    n = len(tokens)
    best = (0, 0.0, None)
    best_repeats = 0.0
    for period in range(1, min(MAX_LOOP_PERIOD, max(n - 1, 0)) + 1):
        run = 0
        best_run = 0
        best_i = None
        for i in range(n - period):
            if tokens[i] == tokens[i + period]:
                run += 1
                if run > best_run:
                    best_run, best_i = run, i - run + 1
            else:
                run = 0
        if not best_run:
            continue
        repeats = best_run / period + 1.0
        if repeats > best_repeats:
            best_repeats = repeats
            best = (period, repeats, best_i)
    return best


def distinct_ngram_ratio(tokens: list, n: int = NGRAM) -> float | None:
    """Distinct n-grams over total n-grams. A global degeneracy measure that catches many small
    loops scattered through the file, which `longest_loop` (a single longest run) would miss."""
    if len(tokens) < n + 1:
        return None
    grams = [tuple(tokens[i:i + n]) for i in range(len(tokens) - n + 1)]
    return len(set(grams)) / len(grams)


# ---------------------------------------------------------------------------
# Timeline
# ---------------------------------------------------------------------------

def word_times(raw: dict) -> tuple:
    """Per-word timestamps from whatever timing an engine reported: `(times, source)`.

    Three shapes are handled because the engines genuinely differ: fluidaudiocli emits
    `wordTimings`, the app's bench CLI emits `segments` with speaker attribution, and the MLX
    Whisper runner emits `segments` without. Words inside a segment are spread evenly across it --
    approximate, but the check only needs density per six-minute bucket, not per word.
    """
    raw = raw or {}
    timings = raw.get("wordTimings") or []
    if timings:
        out = []
        for entry in timings:
            start = entry.get("startTime")
            if start is None:
                continue
            pieces = (entry.get("word") or "").split()
            out += [float(start)] * max(1, len(pieces))
        if out:
            return (out, "wordTimings")

    segments = raw.get("segments") or []
    if segments:
        out = []
        for segment in segments:
            start = segment.get("start")
            if start is None:
                continue
            words = (segment.get("text") or "").split()
            if not words:
                continue
            end = segment.get("end")
            span = max(0.0, float(end) - float(start)) if end is not None else 0.0
            for i in range(len(words)):
                out.append(float(start) + span * i / len(words))
        if out:
            return (out, "segments")

    return ([], None)


def speaker_coverage(raw: dict, audio_s: float | None) -> float | None:
    """Fraction of the audio sitting inside a segment attributed to a named speaker.

    A diarization quality signal that needs no reference: an engine can report the right speaker
    count while attributing only half the audio, and speaker count alone would call that a success.
    Returns None when the engine did not attribute speakers at all.
    """
    segments = (raw or {}).get("segments") or []
    if not segments or not audio_s:
        return None
    total = 0.0
    for segment in segments:
        if not (segment.get("speaker") or "").strip():
            continue
        start, end = segment.get("start"), segment.get("end")
        if start is None or end is None:
            continue
        total += max(0.0, float(end) - float(start))
    if not total:
        return None
    return min(total / audio_s, 1.0)


def bucket_density(times: list, audio_s: float, buckets: int = BUCKETS) -> list:
    """Words per second in each of `buckets` equal slices of the audio.

    Bucketed by AUDIO TIME rather than by position in the transcript, which is the whole point: a
    transcript that covers only the first 40 minutes looks perfectly uniform when sliced by word
    index and obviously broken when sliced by time.
    """
    if not times or not audio_s or audio_s <= 0 or buckets <= 0:
        return []
    width = audio_s / buckets
    counts = [0] * buckets
    for t in times:
        index = int(t / width)
        if index < 0:
            index = 0
        elif index >= buckets:
            index = buckets - 1
        counts[index] += 1
    return [c / width for c in counts]


# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

def analyze(text: str, audio_s: float | None = None, expected_words: int | None = None,
            raw: dict | None = None, buckets: int = BUCKETS) -> LongFormReport:
    """Stability report for one long-form transcript.

    `expected_words` comes from the baseline (the healthy band measured on this fixture). Without it
    the word-count checks are skipped rather than guessed at -- a fabricated expectation would
    either flag every engine or none.
    """
    tokens = (text or "").split()
    report = LongFormReport(words=len(tokens), expected_words=expected_words)
    findings: list = []

    if not tokens:
        report.findings = [Finding("empty", "engine produced no text at all")]
        return report

    if expected_words:
        report.word_ratio = len(tokens) / expected_words
        if report.word_ratio < TRUNCATION_RATIO:
            report.truncated = True
            findings.append(Finding(
                "truncated",
                f"{len(tokens)} words is {report.word_ratio:.0%} of the expected {expected_words}; "
                f"output stops well short of the audio",
            ))
        elif report.word_ratio > OVERRUN_RATIO:
            report.overrun = True
            findings.append(Finding(
                "overrun",
                f"{len(tokens)} words is {report.word_ratio:.0%} of the expected {expected_words}; "
                f"possibly repeated or hallucinated text, but expanding contractions inflates word "
                f"counts legitimately -- read a sample before concluding",
                severity="warn",
            ))

    # Primary loop signal: wholesale degeneracy collapses this, ordinary speech does not touch it.
    report.distinct_ngram_ratio = distinct_ngram_ratio(tokens)
    if report.distinct_ngram_ratio is not None and report.distinct_ngram_ratio < DISTINCT_NGRAM_FLOOR:
        findings.append(Finding(
            "degenerate",
            f"only {report.distinct_ngram_ratio:.1%} of {NGRAM}-grams are distinct "
            f"(healthy is 99.7%+); the output is largely repeated text",
        ))

    # Secondary, WARN-only: real speech stutters, so this cannot be a failure on its own.
    period, repeats, at = longest_loop(tokens)
    report.loop_period, report.loop_repeats, report.loop_at_word = period, repeats, at
    if period and repeats >= LOOP_REPEAT_WARN:
        report.looped = True
        findings.append(Finding(
            "loop",
            f"{period}-word phrase repeats {repeats:.1f}x consecutively at word {at}; "
            f"could be degeneracy or could be speech -- listen to that moment",
            severity="warn",
        ))

    times, source = word_times(raw or {})
    report.timeline_source = source
    if times and audio_s:
        report.coverage = max(times) / audio_s
        if report.coverage < COVERAGE_FLOOR:
            report.late_collapse = True
            findings.append(Finding(
                "coverage",
                f"last timed word is at {max(times):.0f}s of {audio_s:.0f}s "
                f"({report.coverage:.1%}); the tail of the audio is unaccounted for",
            ))

        report.bucket_wps = [round(v, 3) for v in bucket_density(times, audio_s, buckets)]
        if len(report.bucket_wps) >= 4:
            median = statistics.median(report.bucket_wps)
            if median > 0:
                tail = report.bucket_wps[-LATE_BUCKETS:]
                report.late_density = statistics.fmean(tail) / median
                if report.late_density < LATE_DENSITY_FLOOR:
                    report.late_collapse = True
                    findings.append(Finding(
                        "late-collapse",
                        f"final {LATE_BUCKETS} of {buckets} time buckets average "
                        f"{report.late_density:.0%} of the median word density; "
                        f"quality degrades late in the file",
                    ))
                worst = min(range(len(report.bucket_wps)), key=lambda i: report.bucket_wps[i])
                report.worst_bucket = worst
                report.worst_bucket_density = report.bucket_wps[worst] / median
                if report.worst_bucket_density < EMPTY_DENSITY_FLOOR:
                    findings.append(Finding(
                        "empty-bucket",
                        f"bucket {worst + 1}/{buckets} is effectively empty "
                        f"({report.worst_bucket_density:.0%} of median word density); "
                        f"a whole stretch of audio produced no output",
                    ))
                elif report.worst_bucket_density < GAP_DENSITY_FLOOR:
                    findings.append(Finding(
                        "dropout",
                        f"bucket {worst + 1}/{buckets} holds only "
                        f"{report.worst_bucket_density:.0%} of the median word density; "
                        f"thin but not empty -- could be a quiet stretch of the recording",
                        severity="warn",
                    ))
    elif audio_s:
        findings.append(Finding(
            "no-timeline",
            "engine reported no word or segment timings, so late-collapse and dropout cannot be "
            "checked; only the word-count and repetition checks ran",
            severity="warn",
        ))

    report.findings = findings
    return report
