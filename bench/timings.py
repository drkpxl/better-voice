"""Map audio timestamps onto consensus tokens, so manual review can jump to the audio.

The consensus reference is built by voting across engines and has no timing of its own. But one
engine (Parakeet, via fluidaudiocli) reports word-level timings, so its words are aligned to the
consensus tokens with the same Levenshtein alignment used for scoring, and timestamps ride across
the alignment. Gaps -- consensus tokens with no aligned source word -- are filled by interpolating
between the nearest known anchors.

Timings are approximate by construction: they come from a different engine's segmentation than the
consensus text. Good enough to scrub to, which is the entire purpose.

Stdlib only.
"""

from __future__ import annotations

from score import alignment_ops, normalize


def expand_source_words(word_timings: list[dict]) -> list[tuple[str, float]]:
    """Flatten engine word timings into (normalized_token, start_seconds) pairs.

    One source word can normalize into several tokens ("25" -> "twenty five"), and all of them
    inherit that word's start time -- the alternative, dropping them, would desynchronize the
    alignment against the consensus tokens.
    """
    out: list[tuple[str, float]] = []
    for entry in word_timings:
        raw = entry.get("word") or ""
        start = entry.get("startTime")
        if start is None:
            continue
        for token in normalize(raw).split():
            out.append((token, float(start)))
    return out


def map_timestamps(tokens: list[str], word_timings: list[dict]) -> list[float | None]:
    """Return a start-time per consensus token, or all None when no timings are usable."""
    source = expand_source_words(word_timings)
    if not tokens or not source:
        return [None] * len(tokens)

    src_tokens = [t for t, _ in source]
    stamps: list[float | None] = [None] * len(tokens)
    for kind, ref_i, hyp_j in alignment_ops(tokens, src_tokens):
        if kind in ("match", "sub") and ref_i is not None and hyp_j is not None:
            stamps[ref_i] = source[hyp_j][1]

    return _fill_gaps(stamps)


def _fill_gaps(stamps: list[float | None]) -> list[float | None]:
    """Linear interpolation between anchors; edges extend the nearest anchor."""
    known = [i for i, s in enumerate(stamps) if s is not None]
    if not known:
        return stamps
    out = list(stamps)

    for i in range(known[0]):
        out[i] = stamps[known[0]]
    for i in range(known[-1] + 1, len(out)):
        out[i] = stamps[known[-1]]

    for left, right in zip(known, known[1:]):
        span = right - left
        if span <= 1:
            continue
        start, end = stamps[left], stamps[right]
        assert start is not None and end is not None
        step = (end - start) / span
        for offset in range(1, span):
            out[left + offset] = round(start + step * offset, 2)
    return out


def clock(seconds: float | None) -> str:
    """m:ss for review display."""
    if seconds is None:
        return "--:--"
    total = int(seconds)
    return f"{total // 60}:{total % 60:02d}"
