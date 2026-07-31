"""Score meeting summaries against a hand-authored key. No judge model involved.

Every metric here is deterministic and reproducible, which is the point: a local model cannot be
trusted to rank its own family, and the confidential fixture cannot go to a cloud judge. So the
ranking signal is thread recall against `gold/key.json`, and everything else is a guard.

The metric that does the real work is POSITIONAL coverage. A summarizer that reads the whole
transcript and one that reads only the ends can produce equally plausible prose, and equally
plausible prose scores the same on length, structure and hallucination checks. Only binning recall
by where the content sits in the meeting separates them.

Run: python3 bench/summary_score.py --key bench/runs/pod/gold/key.json \
        --transcript bench/runs/pod/summary_input_raw.txt bench/runs/pod/summaries/*.json
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REQUIRED_SECTIONS = {
    "general": ["## Summary", "## Key points", "## Action items"],
    "one_on_one": ["## Summary", "## Topics discussed", "## Action items"],
    "standup": ["## Status by person", "## Action items"],
}

# Capitalized tokens that are not proper nouns and would otherwise flood the invented-name report.
_NOT_NAMES = {
    "The", "This", "That", "There", "They", "Their", "These", "Those", "Then", "Team", "Topics",
    "Summary", "Key", "Action", "Items", "Status", "Blockers", "Feedback", "Growth", "Discussed",
    "Person", "Title", "A", "An", "I", "It", "Its", "If", "In", "Is", "As", "At", "And", "But",
    "Or", "For", "To", "By", "Of", "On", "We", "Will", "Was", "Were", "Would", "Should", "Could",
    "Discussion", "Decision", "Decisions", "Next", "Steps", "Current", "Future", "Additionally",
    "Both", "All", "Each", "Some", "Other", "Others", "One", "Two", "Three", "Four", "Five",
    "No", "Not", "Now", "Note", "However", "While", "When", "Where", "What", "Who", "How", "Why",
    "Pod", "Pods", "Digital", "Physical", "Technical", "Product", "Design", "Roadmap", "Owner",
    "Leadership", "Meeting", "Notes", "Overall", "Given", "Ensure", "Schedule", "Move", "Hold",
    "Complete", "Communicate", "Prepare", "Review", "Investigate", "Coordinate", "Identify",
    "Lead", "Define", "Confirm", "Follow", "Draft", "Share", "Set", "Plan", "Focus", "Phase",
    "Do", "Does", "Did", "Be", "Been", "Being", "Have", "Has", "Had", "Can", "May", "Might",
    "Must", "Shall", "Also", "Only", "Just", "Even", "Still", "Yet", "Because", "Since", "So",
}


def normalize(text: str) -> str:
    """Lowercase, collapse punctuation to spaces, squeeze whitespace. Keeps `/` inside A/B."""
    text = text.lower()
    text = re.sub(r"[^\w\s/&.-]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def covered(summary_norm: str, spec: dict) -> list[str] | None:
    """Match a thread/decision spec against a normalized summary.

    `all_of` is a list of groups; a hit needs one keyword from EVERY group, and the returned list is
    the specific keyword that satisfied each. Schema 1's flat `any` is still accepted so an older key
    keeps working, but it is deliberately not used by the current key -- single-keyword disjunction
    over-credited by ~30% relative to hand adjudication (see the key's `matching` note).
    """
    if "all_of" in spec:
        matched: list[str] = []
        for group in spec["all_of"]:
            hit = next((kw for kw in group if normalize(kw) in summary_norm), None)
            if hit is None:
                return None
            matched.append(hit)
        return matched
    hit = next((kw for kw in spec.get("any", []) if normalize(kw) in summary_norm), None)
    return [hit] if hit else None


def score_one(summary: str, key: dict, transcript: str, meeting_type: str = "general") -> dict:
    snorm = normalize(summary)

    threads, hits, weight_total, weight_hit = [], 0, 0, 0
    for th in key["threads"]:
        w = th.get("weight", 1)
        weight_total += w
        kw = covered(snorm, th)
        if kw:
            hits += 1
            weight_hit += w
        threads.append({"id": th["id"], "lines": th["lines"], "weight": w,
                        "covered": bool(kw), "matched": kw, "label": th["label"]})

    decisions = []
    dec_hit = 0
    for d in key["decisions"]:
        kw = covered(snorm, d)
        if kw:
            dec_hit += 1
        decisions.append({"id": d["id"], "covered": bool(kw), "matched": kw, "label": d["label"]})

    # Positional coverage: bin threads by the midpoint of their line range into thirds of the
    # meeting. A thread spanning a boundary is attributed to where its midpoint falls -- crude, but
    # the alternative (splitting weight across bins) would blur exactly the signal being measured.
    total = key["total_turns"]
    bins: dict[str, dict[str, int]] = {b: {"threads": 0, "covered": 0, "weight": 0, "weight_covered": 0}
                                       for b in ("first_third", "middle_third", "final_third")}
    for th, scored in zip(key["threads"], threads):
        mid = sum(th["lines"]) / 2
        frac = mid / total
        b = "first_third" if frac < 1 / 3 else ("middle_third" if frac < 2 / 3 else "final_third")
        bins[b]["threads"] += 1
        bins[b]["weight"] += scored["weight"]
        if scored["covered"]:
            bins[b]["covered"] += 1
            bins[b]["weight_covered"] += scored["weight"]
    for b in bins.values():
        b["recall"] = round(b["weight_covered"] / b["weight"], 3) if b["weight"] else None

    # Structure
    required = REQUIRED_SECTIONS.get(meeting_type, REQUIRED_SECTIONS["general"])
    sections_present = [s for s in required if s.lower() in summary.lower()]

    # Action items: lines shaped as a bullet, and how many carry an explicit [owner].
    action_block = ""
    m = re.search(r"##\s*Action items(.*?)(?=\n##\s|\Z)", summary, re.S | re.I)
    if m:
        action_block = m.group(1)
    action_lines = [ln.strip() for ln in action_block.splitlines()
                    if re.match(r"^\s*[-*]\s+\S", ln)]
    with_owner = [ln for ln in action_lines if re.match(r"^\s*[-*]\s*\[[^\]]+\]", ln)]

    # Invented people: the hard check is the forbidden list (zero false positives by construction).
    tnorm = normalize(transcript)
    forbidden = [n for n in key["hallucination_guard"]["forbidden_names"]
                 if re.search(rf"\b{re.escape(n.lower())}\b", tnorm) is None
                 and re.search(rf"\b{re.escape(n.lower())}\b", snorm) is not None]

    # Softer flag list for human review: capitalized tokens absent from the transcript.
    caps = set(re.findall(r"\b[A-Z][a-zA-Z]{2,}\b", summary)) - _NOT_NAMES
    unseen_caps = sorted(c for c in caps
                         if re.search(rf"\b{re.escape(c.lower())}\b", tnorm) is None)

    # Numbers asserted that do not appear in the transcript.
    nums = set(re.findall(r"\b\d[\d,.]*\b", summary))
    unseen_nums = sorted(n for n in nums if n not in transcript)

    return {
        "thread_recall": round(hits / len(key["threads"]), 3),
        "thread_recall_weighted": round(weight_hit / weight_total, 3),
        "threads_hit": hits,
        "threads_total": len(key["threads"]),
        "decision_recall": round(dec_hit / len(key["decisions"]), 3),
        "decisions_hit": dec_hit,
        "decisions_total": len(key["decisions"]),
        "positional": bins,
        "sections_present": sections_present,
        "sections_missing": [s for s in required if s not in sections_present],
        "structure_ok": len(sections_present) == len(required),
        "action_items": len(action_lines),
        "action_items_with_owner": len(with_owner),
        "invented_names": forbidden,
        "unseen_capitalized": unseen_caps,
        "unseen_numbers": unseen_nums,
        "chars": len(summary),
        "compression": round(len(transcript) / len(summary), 1) if summary else None,
        "missed_threads": [t["id"] for t in threads if not t["covered"]],
        "thread_detail": threads,
        "decision_detail": decisions,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True, type=Path)
    ap.add_argument("--transcript", required=True, type=Path)
    ap.add_argument("summaries", nargs="+", type=Path)
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    key = json.loads(args.key.read_text())
    transcript = args.transcript.read_text()

    rows = []
    for path in args.summaries:
        rec = json.loads(path.read_text())
        if rec.get("error") or not rec.get("summary"):
            print(f"!! {path.name}: {rec.get('error') or 'no summary'}")
            continue
        sc = score_one(rec["summary"], key, transcript, rec.get("meeting_type", "general"))
        sc.update(label=rec["label"], file=path.name, seconds=rec.get("seconds"),
                  num_ctx=rec.get("num_ctx"),
                  # Older records carry a single `with_context` covering both blocks; newer ones
                  # split it (see summarize.py). Read either so mixed-vintage runs still tabulate.
                  with_personal_context=rec.get("with_personal_context", rec.get("with_context")),
                  with_vocabulary=rec.get("with_vocabulary", rec.get("with_context")),
                  title=rec.get("title"))
        rows.append(sc)

    rows.sort(key=lambda r: -r["thread_recall_weighted"])

    hdr = (f"{'model':22} {'recall':>7} {'1st':>5} {'mid':>5} {'fin':>5} {'dec':>6} "
           f"{'act':>4} {'own':>4} {'inv':>4} {'sec':>4} {'s':>7}")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        p = r["positional"]
        print(f"{r['label'][:22]:22} "
              f"{r['thread_recall_weighted'] * 100:6.1f}% "
              f"{(p['first_third']['recall'] or 0) * 100:4.0f}% "
              f"{(p['middle_third']['recall'] or 0) * 100:4.0f}% "
              f"{(p['final_third']['recall'] or 0) * 100:4.0f}% "
              f"{r['decision_recall'] * 100:5.1f}% "
              f"{r['action_items']:4} {r['action_items_with_owner']:4} "
              f"{len(r['invented_names']):4} "
              f"{'ok' if r['structure_ok'] else 'FAIL':>4} "
              f"{r['seconds'] or 0:7.1f}")

    print()
    for r in rows:
        if r["missed_threads"]:
            print(f"{r['label']}: missed {', '.join(r['missed_threads'])}")
        if r["invented_names"]:
            print(f"{r['label']}: INVENTED NAMES {r['invented_names']}")
        if r["unseen_capitalized"]:
            print(f"{r['label']}: capitalized-not-in-transcript {r['unseen_capitalized']}")
        if r["unseen_numbers"]:
            print(f"{r['label']}: numbers-not-in-transcript {r['unseen_numbers']}")

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(rows, indent=1))
        print(f"\n-> {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
