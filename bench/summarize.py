"""Summarization bake-off runner: one model, one transcript, one summary.

Mirrors what the shipping app actually sends, because a bench that uses a different prompt or a
different context size measures a pipeline nobody runs. Specifically it reproduces:

  - `Prompts.summarizeGeneralEN` / `summarizeOneOnOneEN` / `summarizeStandupEN` verbatim
  - `PersonalContext.appended(to:)` + `Vocabulary.promptBlock` appended to the system prompt
  - `OllamaBackend.fittedNumCtx` -- num_ctx grown to fit the prompt, floor 32768, cap 262144,
    clamped to the model's own maximum from /api/show
  - `makeOllamaRequestBody` -- temperature 0, think false, stream false, num_predict 2048

The Apple on-device provider is deliberately NOT here: it needs `FoundationModelsBackend`'s
map-reduce, which only exists in Swift. That path needs a `--bench-summary` harness in the client
and is tracked separately -- pretending a single-shot Python call represents it would be worse than
leaving it out.

Run: python3 bench/summarize.py --model qwen3.5:9b-mlx --transcript <file> --out <file.json>
"""

from __future__ import annotations

import argparse
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

OLLAMA = "http://localhost:11434"

# Verbatim from client/Sources/Prompts.swift. Kept as literal strings rather than parsed out of the
# Swift source: a parser would silently drift into "close enough" on a refactor, and the whole point
# is that the bench and the app send byte-identical instructions. When Prompts.swift changes, this
# must be updated in the same commit -- test_summarize.py asserts the two stay in sync.
COMMON_RULES = """The input is a meeting transcript. Each line is "Speaker: text" (speakers may be named or labelled "Speaker N"). The transcript came from speech-to-text and may contain small errors — use judgement.

Rules:
- Refer to people by the names/labels used in the transcript. Never invent names or facts.
- Be factual and complete. Do not include anything that was not said, but do not leave out anything that was.
- Output GitHub-flavoured Markdown only — no preamble, no code fences around the whole answer.
- Write in the language the meeting was conducted in."""

PROMPTS = {
    "general": f"""You are a meeting-notes assistant. Summarize the meeting for someone who missed it.

{COMMON_RULES}

Structure the summary as:
## Summary
A paragraph of what the meeting was about and any outcome.
## Key points
Bullet points covering EVERY distinct topic and decision discussed, including ones raised in the middle of the meeting. Do not omit a topic because the meeting moved on from it.
## Action items
Bullet points as "- [owner] action" for every commitment or follow-up. Omit the section only if there were genuinely none.""",
    "one_on_one": f"""You are a notes assistant for a 1:1 conversation between two people. Capture it so both participants remember what was discussed and agreed.

{COMMON_RULES}

Structure the summary as:
## Summary
A short paragraph of the overall conversation and tone.
## Topics discussed
Bullet points grouped by topic, attributing views to the right person where it matters.
## Feedback & growth
Any feedback, concerns, or development/career points raised (omit if none).
## Action items
"- [owner] action" for every commitment made by either person (omit if none).""",
    "standup": f"""You are a notes assistant for a status/standup meeting. Produce a crisp status digest.

{COMMON_RULES}

Structure the summary as:
## Status by person
For each participant who reported: "### Name" then bullets for what they did, are doing next, and anything notable.
## Blockers
Bullet points of blockers/risks raised, with who is affected (omit if none).
## Action items
"- [owner] action" for every follow-up agreed (omit if none).""",
}

TITLE_INSTRUCTION = """Additionally: before the summary, output exactly one line "TITLE: <short title>" — a short, plain-text title (6 words or fewer, no trailing punctuation, no markdown) naming what the meeting was about — then a blank line, then the summary itself as described above."""

SUPPORT_DIR = Path.home() / "Library/Application Support/BetterVoice2"


def vocabulary_prompt_block(vocab_md: Path) -> str:
    """Reproduce `Vocabulary.promptBlock`: the ## Terms list, capped at 600 chars of terms.

    Only the Terms section feeds the prompt. Replacements are deliberately withheld from the model
    (`vocabulary.md`'s own note: "never shown to the model, so it can't learn the misspelling"), so
    including them here would make the bench more informed than the app.
    """
    if not vocab_md.exists():
        return ""
    terms: list[str] = []
    in_terms = False
    for line in vocab_md.read_text().splitlines():
        if line.startswith("## "):
            in_terms = line.strip() == "## Terms"
            continue
        if in_terms and line.startswith("- "):
            terms.append(line[2:].strip())
    included, chars = [], 0
    for term in terms:
        chars += len(term) + 2
        if chars > 600:
            break
        included.append(term)
    if not included:
        return ""
    return (
        "\n\n\n## Vocabulary\nThe speaker uses these exact spellings. When a word in the text "
        "plausibly matches one of them, use the exact spelling as written here: "
        f"{', '.join(included)}."
    )


def personal_context_block(ctx_md: Path) -> str:
    """Reproduce `PersonalContext.appended(to:)`. Absent file -> no block, same as the app."""
    if not ctx_md.exists():
        return ""
    body = ctx_md.read_text().strip()
    if not body:
        return ""
    return f"\n\n## Personal context\n{body}"


def model_max_ctx(model: str) -> int | None:
    """Model's own context ceiling via /api/show, as `ollamaModelContextLength` does."""
    try:
        req = urllib.request.Request(
            f"{OLLAMA}/api/show",
            data=json.dumps({"name": model}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            info = (json.load(resp).get("model_info") or {})
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None
    for key, value in info.items():
        if key.endswith(".context_length") and isinstance(value, int):
            return value
    return None


def fitted_num_ctx(prompt: str, system: str, num_predict: int, floor: int, model: str) -> int:
    """`OllamaBackend.fittedNumCtx`: grow the window to fit, floor 32768, cap 262144, clamp to model."""
    needed = (len(prompt) + len(system)) // 4 + num_predict + 1024
    ctx = min(max(floor, needed), 262_144)
    max_ctx = model_max_ctx(model)
    if max_ctx is not None:
        ctx = min(ctx, max_ctx)
    return ctx


def generate(model: str, system: str, prompt: str, num_ctx: int, num_predict: int, timeout: float) -> tuple[str, dict]:
    """One /api/generate call. Returns (response_text, ollama_timing_fields)."""
    body = {
        "model": model,
        "prompt": prompt,
        "system": system,
        "stream": False,
        "think": False,
        "options": {"temperature": 0, "num_predict": num_predict, "num_ctx": num_ctx},
    }
    req = urllib.request.Request(
        f"{OLLAMA}/api/generate",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.load(resp)
    timings = {
        k: payload.get(k)
        for k in ("total_duration", "load_duration", "prompt_eval_count", "eval_count", "eval_duration")
    }
    return (payload.get("response") or "").strip(), timings


def parse_title(text: str) -> tuple[str | None, str]:
    """Split a leading title line off, mirroring `parseSummaryTitle` in `SummarizationLogic.swift`.

    Ported line-for-line after the previous version diverged from the app in three ways that all
    made the bench *less* capable: it required a bare uppercase `TITLE:`, so a model answering
    `## TITLE: X` or `**TITLE:** X` -- which the app tolerates by design -- was scored with the title
    line still sitting in its summary body; and it scanned the first five lines rather than only the
    first non-empty one, so a `TITLE:` further down could be lifted out where the app would leave it.
    Voxtral emits the heading form, so this was not hypothetical.

    Only the first non-empty line is a candidate. Leading `#`/`*` markers are stripped, the marker
    match is case-insensitive, and `*` is trimmed off the title text (for `**TITLE: X**`). At most
    one blank line after the title is consumed as the separator. Anything malformed returns
    `(None, text)` with the response byte-identical -- a bad title must never fail a summary.
    """
    lines = text.split("\n")
    title_index = next((i for i, line in enumerate(lines) if line.strip()), None)
    if title_index is None:
        return None, text

    candidate = lines[title_index].strip()
    while candidate[:1] in ("#", "*"):
        candidate = candidate[1:]
    candidate = candidate.strip()

    if not candidate.lower().startswith("title:"):
        return None, text
    # ONE pass over a combined set, matching Swift's
    # `trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*")))`. Chaining
    # `.strip().strip("*").strip()` is not equivalent: each pass sees only its own characters, so
    # `**X** *` trims to `X**` instead of `X`. Deliberately space+tab rather than Python's default
    # whitespace class -- Swift's `.whitespaces` excludes `\r`, and matching it is the point here.
    title_text = candidate[len("title:"):].strip(" \t*")
    if not title_text:
        return None, text

    remaining = lines[title_index + 1:]
    if remaining and not remaining[0].strip():
        remaining.pop(0)
    return title_text, "\n".join(remaining)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--transcript", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--type", default="general", choices=sorted(PROMPTS))
    ap.add_argument("--num-predict", type=int, default=2048)
    ap.add_argument("--num-ctx-floor", type=int, default=32768)
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--title", action="store_true", help="request the inline TITLE: line")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--label", default=None, help="tag for the output record (defaults to model)")
    # The app appends these two blocks independently: vocabulary whenever there are terms, personal
    # context only when the file is non-empty. `--no-context` suppressing BOTH made every no-context
    # run *less* informed than the app, which always sends vocabulary -- the reason a judged run
    # produced "iSummit" where the app produces "Summit Pass". Kept as a shorthand for both, but the
    # two are now separately controllable so a run can match the shipping configuration exactly.
    ap.add_argument("--no-context", action="store_true",
                    help="shorthand for --no-personal-context --no-vocabulary")
    ap.add_argument("--no-personal-context", action="store_true",
                    help="omit the personal-context block only (vocabulary still sent, as the app does)")
    ap.add_argument("--no-vocabulary", action="store_true",
                    help="omit the vocabulary block only")
    args = ap.parse_args()

    skip_personal = args.no_context or args.no_personal_context
    skip_vocabulary = args.no_context or args.no_vocabulary

    transcript = args.transcript.read_text().strip()
    system = PROMPTS[args.type]
    if args.title:
        system += "\n\n" + TITLE_INSTRUCTION
    if not skip_personal:
        system += personal_context_block(SUPPORT_DIR / "personal-context.md")
    if not skip_vocabulary:
        system += vocabulary_prompt_block(SUPPORT_DIR / "vocabulary.md")

    num_ctx = fitted_num_ctx(transcript, system, args.num_predict, args.num_ctx_floor, args.model)

    record: dict = {
        "label": args.label or args.model,
        "model": args.model,
        "transcript": str(args.transcript),
        "transcript_chars": len(transcript),
        "meeting_type": args.type,
        "num_ctx": num_ctx,
        "num_predict": args.num_predict,
        "with_personal_context": not skip_personal,
        "with_vocabulary": not skip_vocabulary,
        "system_chars": len(system),
        "requested_title": args.title,
        "error": None,
    }

    runs = []
    try:
        for i in range(max(1, args.repeats)):
            t0 = time.perf_counter()
            text, timings = generate(
                args.model, system, transcript, num_ctx, args.num_predict, args.timeout
            )
            elapsed = time.perf_counter() - t0
            title, body = parse_title(text) if args.title else (None, text)
            runs.append({"seconds": round(elapsed, 2), "title": title, "summary": body, "ollama": timings})
            print(f"  run {i + 1}/{args.repeats}: {elapsed:.1f}s, {len(body)} chars", flush=True)
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"{type(exc).__name__}: {exc}"

    record["runs"] = runs
    if runs:
        record["seconds"] = runs[0]["seconds"]
        record["summary"] = runs[0]["summary"]
        record["title"] = runs[0]["title"]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(record, indent=1))
    print(f"-> {args.out}")
    return 1 if record["error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
