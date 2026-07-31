"""Render summarization runs side by side as one self-contained local HTML page.

Exists because a ranking table is the wrong instrument for judging a summary. The numbers say
`ornith:9b` has the best thread recall on the POD fixture; reading the summaries says it is close to
unusable, and the only way to see that is to read them. This builds the page for reading.

It also prints the configuration of every run it renders. That is not decoration -- a bake-off whose
runs differ in input file or context blocks is comparing pipelines, not models, and the first version
of this comparison silently did exactly that (anonymous speaker labels and no vocabulary block, so
the models produced "iSummit" where the app produces "Summit Pass"). The badges make a mismatched
comparison visible instead of leaving it in the JSON.

CONFIDENTIAL: writes under bench/runs/ (gitignored) and inlines transcript-derived text. The output
is a local file; it is deliberately not uploaded anywhere.

Run:
  python3 bench/summary_compare.py --key bench/runs/pod/gold/key.json \
      --transcript bench/runs/pod/summary_input_clean.txt \
      --reference bench/runs/pod/gold/reference-summary.md \
      --out bench/runs/pod/judge/comparison.html \
      bench/runs/pod/summaries/app__*.json
"""

from __future__ import annotations

import argparse
import html
import json
import re
from pathlib import Path

from summary_score import score_one


def render_markdown(md: str) -> str:
    """Minimal GFM subset: headings, bullets (two levels), bold, inline code, paragraphs.

    Deliberately hand-rolled rather than pulling a dependency: the bench runs on the stdlib (no
    pytest, no markdown package), and the models only ever emit this subset.
    """
    out: list[str] = []
    list_depth = 0

    def close_lists(to: int = 0) -> None:
        nonlocal list_depth
        while list_depth > to:
            out.append("</ul>")
            list_depth -= 1

    def inline(text: str) -> str:
        text = html.escape(text)
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
        return text

    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            close_lists()
            continue
        heading = re.match(r"^(#{1,4})\s+(.*)$", line)
        if heading:
            close_lists()
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            continue
        bullet = re.match(r"^(\s*)[-*+]\s+(.*)$", line)
        if bullet:
            want = 2 if len(bullet.group(1)) >= 2 else 1
            while list_depth < want:
                out.append("<ul>")
                list_depth += 1
            close_lists(want)
            out.append(f"<li>{inline(bullet.group(2))}</li>")
            continue
        close_lists()
        out.append(f"<p>{inline(line)}</p>")
    close_lists()
    return "\n".join(out)


def badges(rec: dict) -> str:
    """Configuration badges. A mismatch between cards is the thing worth seeing."""
    items: list[tuple[str, str]] = []
    if rec.get("audio_direct"):
        # An audio-direct run has no transcript and no diarizer, so the two things the text runs are
        # judged on -- input quality and speaker labels -- do not apply. Say so rather than leaving
        # the reader to assume it got the same input as the cards above it.
        items.append(("heard the audio — no ASR", "ok"))
        items.append(("no diarizer: speakers inferred", "warn"))
        if rec.get("chunks"):
            items.append((f"{rec['chunks']} audio chunks, map-reduce", "warn"))
    else:
        src = Path(rec.get("transcript") or "-").name
        named = "clean" in src
        items.append(("named speakers" if named else "S1–S4 labels", "ok" if named else "warn"))
    items += [
        ("vocabulary" if rec.get("with_vocabulary") else "no vocabulary",
         "ok" if rec.get("with_vocabulary") else "warn"),
        ("personal context" if rec.get("with_personal_context") else "no personal context", "neutral"),
        (f"num_ctx {rec.get('num_ctx'):,}" if rec.get("num_ctx") else "num_ctx ?", "neutral"),
    ]
    if rec.get("seconds"):
        items.append((f"{rec['seconds']:.0f}s", "neutral"))
    return "".join(f'<span class="badge {cls}">{html.escape(text)}</span>' for text, cls in items)


CSS = """
:root { --bg:#fbfaf8; --fg:#1a1a19; --muted:#6b6b66; --line:#e2e0db; --card:#fff;
        --ok:#1f7a4d; --warn:#a8500f; --accent:#2f5d8a; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#16171a; --fg:#e8e6e1; --muted:#9a9993; --line:#2c2e33; --card:#1d1f23;
          --ok:#4dbd83; --warn:#d98a45; --accent:#7aa8d4; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
  font:16px/1.6 ui-sans-serif,-apple-system,"Segoe UI",system-ui,sans-serif; }
.wrap { max-width:62rem; margin:0 auto; padding:2.5rem 1.25rem 5rem; }
h1 { font-size:1.7rem; margin:0 0 .4rem; letter-spacing:-.01em; }
.sub { color:var(--muted); margin:0 0 1.5rem; }
.notice { border:1px solid var(--line); border-left:3px solid var(--warn);
  background:var(--card); padding:.85rem 1rem; border-radius:6px; margin:0 0 2rem;
  font-size:.9rem; color:var(--muted); }
.notice strong { color:var(--fg); }
table.lead { width:100%; border-collapse:collapse; margin:0 0 2.5rem; font-size:.92rem; }
table.lead th, table.lead td { text-align:left; padding:.5rem .6rem; border-bottom:1px solid var(--line); }
table.lead th { color:var(--muted); font-weight:600; font-size:.8rem;
  text-transform:uppercase; letter-spacing:.04em; }
table.lead td.num { font-variant-numeric:tabular-nums; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px;
  padding:1.4rem 1.5rem; margin:0 0 1.6rem; }
.card.ref { border-left:3px solid var(--accent); }
.card h2 { font-size:1.15rem; margin:0 0 .1rem; }
.rank { color:var(--muted); font-size:.85rem; font-variant-numeric:tabular-nums; }
.badges { margin:.7rem 0 0; display:flex; flex-wrap:wrap; gap:.4rem; }
.badge { font-size:.74rem; padding:.16rem .5rem; border-radius:999px;
  border:1px solid var(--line); color:var(--muted); white-space:nowrap; }
.badge.ok { color:var(--ok); border-color:color-mix(in srgb, var(--ok) 40%, transparent); }
.badge.warn { color:var(--warn); border-color:color-mix(in srgb, var(--warn) 45%, transparent); }
.body { margin-top:1.1rem; padding-top:1.1rem; border-top:1px solid var(--line); }
.body h2 { font-size:1rem; margin:1.3rem 0 .4rem; color:var(--accent); }
.body h3 { font-size:.94rem; margin:1rem 0 .3rem; }
.body ul { margin:.3rem 0 .7rem; padding-left:1.3rem; }
.body li { margin:.22rem 0; }
.body p { margin:.5rem 0; }
.body code { background:color-mix(in srgb, var(--fg) 8%, transparent);
  padding:.08em .35em; border-radius:4px; font-size:.88em; }
.missed { font-size:.84rem; color:var(--muted); margin:.6rem 0 0; }
.missed code { font-size:.95em; }
footer { color:var(--muted); font-size:.84rem; border-top:1px solid var(--line);
  margin-top:2.5rem; padding-top:1rem; }
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("summaries", nargs="+", type=Path)
    ap.add_argument("--key", required=True, type=Path)
    ap.add_argument("--transcript", required=True, type=Path)
    ap.add_argument("--reference", type=Path, default=None)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--title", default="Summarization comparison")
    ap.add_argument("--note", default="", help="one-line context line under the title")
    args = ap.parse_args()

    key = json.loads(args.key.read_text())
    transcript = args.transcript.read_text()

    cards = []
    for path in args.summaries:
        rec = json.loads(path.read_text())
        if rec.get("error") or not rec.get("summary"):
            print(f"!! skipped {path.name}: {rec.get('error') or 'no summary'}")
            continue
        sc = score_one(rec["summary"], key, transcript, rec.get("meeting_type", "general"))
        cards.append({"rec": rec, "sc": sc, "file": path.name})

    cards.sort(key=lambda c: -c["sc"]["thread_recall_weighted"])

    ref_card = None
    if args.reference and args.reference.exists():
        ref_md = args.reference.read_text()
        ref_card = {
            "md": ref_md,
            "sc": score_one(ref_md, key, transcript, "general"),
        }

    rows = "".join(
        f"<tr><td class='num'>{i}</td><td>{html.escape(c['rec']['label'])}</td>"
        f"<td class='num'>{c['sc']['thread_recall_weighted'] * 100:.1f}%</td>"
        f"<td class='num'>{c['sc']['decision_recall'] * 100:.0f}%</td>"
        f"<td class='num'>{c['sc']['action_items_with_owner']}/{c['sc']['action_items']}</td>"
        f"<td class='num'>{len(c['sc']['invented_names'])}</td>"
        f"<td class='num'>{c['rec'].get('seconds') or 0:.0f}s</td>"
        f"<td class='num'>{len(c['rec']['summary']):,}</td></tr>"
        for i, c in enumerate(cards, 1)
    )
    if ref_card:
        rows += (
            f"<tr><td>—</td><td>Opus reference</td>"
            f"<td class='num'>{ref_card['sc']['thread_recall_weighted'] * 100:.1f}%</td>"
            f"<td class='num'>{ref_card['sc']['decision_recall'] * 100:.0f}%</td>"
            f"<td class='num'>{ref_card['sc']['action_items_with_owner']}"
            f"/{ref_card['sc']['action_items']}</td>"
            f"<td class='num'>{len(ref_card['sc']['invented_names'])}</td>"
            f"<td class='num'>—</td><td class='num'>{len(ref_card['md']):,}</td></tr>"
        )

    body = [
        f"<title>{html.escape(args.title)}</title>",
        f"<style>{CSS}</style>",
        "<div class='wrap'>",
        f"<h1>{html.escape(args.title)}</h1>",
        f"<p class='sub'>{html.escape(args.note)}</p>" if args.note else "",
        "<div class='notice'><strong>Confidential — local file.</strong> This page quotes a real "
        "internal meeting. It lives in a gitignored directory on this Mac and has not been uploaded "
        "anywhere. Do not share it without scrubbing names first.</div>",
        "<table class='lead'><thead><tr><th>#</th><th>Model</th><th>Thread recall</th>"
        "<th>Decisions</th><th>Owned actions</th><th>Invented names</th><th>Time</th>"
        "<th>Chars</th></tr></thead>"
        f"<tbody>{rows}</tbody></table>",
    ]

    for i, c in enumerate(cards, 1):
        missed = c["sc"].get("missed_threads") or []
        missed_html = (
            "<p class='missed'>Missed: "
            + ", ".join(f"<code>{html.escape(m)}</code>" for m in missed)
            + "</p>"
        ) if missed else ""
        # The "invented names" and "not in transcript" checks compare a summary against the ASR
        # transcript. That is the right reference for a model that READ the transcript and the wrong
        # one for a model that heard the audio: a name the ASR garbled and the audio model got right
        # scores as an invention. Say so on the card rather than let the column read as a defect.
        if c["rec"].get("audio_direct"):
            missed_html += (
                "<p class='missed'><strong>Scoring caveat:</strong> the invented-name and "
                "not-in-transcript checks are measured against the ASR transcript, which this run "
                "never saw. A name it heard correctly but the transcript garbled counts against it "
                "here. Judge its faithfulness by reading, not by those columns.</p>"
            )
        body.append(
            f"<div class='card'><span class='rank'>#{i} · thread recall "
            f"{c['sc']['thread_recall_weighted'] * 100:.1f}%</span>"
            f"<h2>{html.escape(c['rec']['label'])}</h2>"
            f"<div class='badges'>{badges(c['rec'])}</div>"
            f"{missed_html}"
            f"<div class='body'>{render_markdown(c['rec']['summary'])}</div></div>"
        )

    if ref_card:
        body.append(
            "<div class='card ref'><span class='rank'>reference · thread recall "
            f"{ref_card['sc']['thread_recall_weighted'] * 100:.1f}%</span>"
            "<h2>Opus reference</h2>"
            "<div class='badges'><span class='badge neutral'>full transcript read</span>"
            "<span class='badge warn'>not a blind run</span></div>"
            "<p class='missed'>Known flaws: it resolves one genuinely ambiguous exchange with more "
            "confidence than the transcript supports, and one action item is incomplete. It also had "
            "both transcripts available where the models had one — treat the gap to it as an "
            "upper bound, not a fair margin.</p>"
            f"<div class='body'>{render_markdown(ref_card['md'])}</div></div>"
        )

    body.append(
        "<footer>Thread recall is a deterministic keyword measure — it rewards touching a topic, "
        "not getting it right. Read the summaries; the ranking is a starting point, not a verdict."
        "</footer></div>"
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(p for p in body if p))
    print(f"-> {args.out}  ({len(args.out.read_text()):,} bytes, {len(cards)} summaries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
