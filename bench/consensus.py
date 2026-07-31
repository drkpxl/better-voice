"""ROVER-style consensus across ASR outputs, to build the verbatim reference without hand-transcribing.

The user should not have to transcribe 250 words by hand. Instead all ASR engines transcribe the
same recording, their outputs are aligned, and each position is decided by majority vote. Where the
engines agree the consensus is almost certainly right; where they disagree the user is asked, and
that is typically only a few dozen words.

The disagreement sites are the real product of this module. The draft consensus is a convenience;
the sites are what make the reference trustworthy.

Stdlib only.
"""

from __future__ import annotations

import statistics
from collections import Counter
from dataclasses import dataclass, field

from score import alignment_ops, normalize, wer

# Sentinel for "this engine heard nothing at this position".
ABSENT = "\x00absent"


@dataclass
class Site:
    """One position where the engines did not fully agree."""

    index: int                      # index into the consensus token list
    options: dict[str, int]         # token (or ABSENT) -> vote count
    chosen: str                     # what the vote selected
    context_before: list[str] = field(default_factory=list)
    context_after: list[str] = field(default_factory=list)

    @property
    def support(self) -> float:
        total = sum(self.options.values())
        return self.options.get(self.chosen, 0) / total if total else 0.0

    def render(self) -> str:
        before = " ".join(self.context_before)
        after = " ".join(self.context_after)
        shown = "(nothing)" if self.chosen == ABSENT else self.chosen
        alts = ", ".join(
            f"{'(nothing)' if tok == ABSENT else tok}×{n}"
            for tok, n in sorted(self.options.items(), key=lambda kv: -kv[1])
        )
        return f"...{before} [{shown}] {after}...\n    votes: {alts}  (support {self.support:.0%})"


@dataclass
class ConsensusResult:
    text: str
    tokens: list[str]
    pivot: str                      # engine name used as the alignment backbone
    sites: list[Site]
    per_engine_wer_to_consensus: dict[str, float]

    @property
    def unanimous_fraction(self) -> float:
        if not self.tokens:
            return 0.0
        return 1.0 - (len(self.sites) / len(self.tokens))


def _pick_pivot(normalized: dict[str, list[str]]) -> str:
    """Use the most central transcript as the alignment backbone.

    Aligning everything to an outlier would manufacture disagreements that are really artifacts of a
    bad backbone, so the pivot is the transcript with the lowest mean distance to all others.
    """
    names = sorted(normalized)
    if len(names) == 1:
        return names[0]
    scores: dict[str, float] = {}
    for name in names:
        others = [
            wer(" ".join(normalized[name]), " ".join(normalized[other]))
            for other in names
            if other != name
        ]
        scores[name] = statistics.fmean(others)
    # Sorted name as the tiebreak keeps pivot selection deterministic across runs.
    return min(names, key=lambda n: (scores[n], n))


def build_consensus(
    transcripts: dict[str, str],
    min_engines: int = 3,
    pivot: str | None = None,
) -> ConsensusResult:
    """Majority-vote a verbatim reference from several ASR transcripts.

    Raises ValueError when there is too little to vote on -- refusing is the point. A silently
    computed reference from one or two engines would look like ground truth while being one engine's
    opinion, and every downstream WER number would inherit that error invisibly.

    `pivot` forces the alignment backbone instead of choosing the most central transcript. Mainly a
    test seam: with an automatically chosen pivot, a word held by the majority is almost always in
    the pivot too, so the insertion-recovery path is rare and needs a deliberately bad backbone to
    exercise.
    """
    usable = {name: text for name, text in transcripts.items() if text and text.strip()}
    if len(usable) < min_engines:
        raise ValueError(
            f"consensus needs at least {min_engines} non-empty transcripts, got {len(usable)}: "
            f"{sorted(usable) or 'none'}. Refusing to emit a reference."
        )

    normalized = {name: normalize(text).split() for name, text in usable.items()}
    normalized = {name: toks for name, toks in normalized.items() if toks}
    if len(normalized) < min_engines:
        raise ValueError(f"consensus needs {min_engines} transcripts with content after normalization")

    if pivot is not None and pivot not in normalized:
        raise ValueError(f"pivot {pivot!r} is not among the usable transcripts: {sorted(normalized)}")
    pivot = pivot or _pick_pivot(normalized)
    pivot_tokens = normalized[pivot]
    voters = sorted(normalized)

    # position -> token votes; gap -> insertion votes. A "gap" g sits immediately before pivot
    # index g, so g ranges over 0..len(pivot_tokens).
    position_votes: list[Counter[str]] = [Counter() for _ in pivot_tokens]
    gap_votes: list[Counter[str]] = [Counter() for _ in range(len(pivot_tokens) + 1)]

    for name in voters:
        if name == pivot:
            for i, token in enumerate(pivot_tokens):
                position_votes[i][token] += 1
            continue
        seen_positions: set[int] = set()
        for kind, ref_i, hyp_j in alignment_ops(pivot_tokens, normalized[name]):
            if kind in ("match", "sub"):
                assert ref_i is not None and hyp_j is not None
                position_votes[ref_i][normalized[name][hyp_j]] += 1
                seen_positions.add(ref_i)
            elif kind == "del":
                assert ref_i is not None
                position_votes[ref_i][ABSENT] += 1
                seen_positions.add(ref_i)
            else:  # insertion: a word this engine heard that the pivot does not have
                assert hyp_j is not None
                # Attribute the insertion to the gap before the next pivot position consumed.
                gap = min(max(seen_positions) + 1 if seen_positions else 0, len(pivot_tokens))
                gap_votes[gap][normalized[name][hyp_j]] += 1

    total_voters = len(voters)
    majority = total_voters // 2 + 1

    tokens: list[str] = []
    sites: list[Site] = []

    def emit_gap_insertions(gap: int) -> None:
        """Recover a word the pivot missed, but only on a real majority.

        This only recovers single-word omissions; a phrase the pivot dropped entirely stays dropped.
        That is a known limit of aligning to one backbone instead of building a full word-transition
        network, and it is why the user reviews the sites.
        """
        if not gap_votes[gap]:
            return
        token, count = gap_votes[gap].most_common(1)[0]
        if count >= majority:
            options = dict(gap_votes[gap])
            options[ABSENT] = total_voters - sum(gap_votes[gap].values())
            index = len(tokens)
            tokens.append(token)
            if count < total_voters:
                sites.append(Site(index=index, options=options, chosen=token))

    for i, pivot_token in enumerate(pivot_tokens):
        emit_gap_insertions(i)
        votes = position_votes[i]
        if not votes:
            continue
        top = max(votes.values())
        # Tie broken toward the pivot's own reading, so the result is deterministic.
        candidates = [tok for tok, n in votes.items() if n == top]
        chosen = pivot_token if pivot_token in candidates else sorted(candidates)[0]
        index = len(tokens)
        if chosen != ABSENT:
            tokens.append(chosen)
        if len(candidates) > 1 or top < total_voters:
            sites.append(Site(index=index, options=dict(votes), chosen=chosen))
    emit_gap_insertions(len(pivot_tokens))

    # Fill review context now that the token list is final.
    for site in sites:
        site.context_before = tokens[max(0, site.index - 4) : site.index]
        site.context_after = tokens[site.index + 1 : site.index + 5]

    text = " ".join(tokens)
    return ConsensusResult(
        text=text,
        tokens=tokens,
        pivot=pivot,
        sites=sites,
        per_engine_wer_to_consensus={
            name: wer(text, " ".join(toks)) for name, toks in sorted(normalized.items())
        },
    )
