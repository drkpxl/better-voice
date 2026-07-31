#!/usr/bin/env python3
"""Driver for the ASR + cleanup pipeline bake-off.

Stages are separate subcommands with state persisted under `bench/runs/<id>/`, because the middle of
the pipeline needs a human: the verbatim reference is reviewed and the intended reference is written
by hand. Each stage can be re-run without redoing the expensive ones.

    ./run.py prepare <recording>   # -> audio.wav (canonical 16k mono, identical bytes for all engines)
    ./run.py asr                   # -> asr.json  (every ASR engine, raw/unpolished)
    ./run.py reference             # -> verbatim_draft.txt + sites.json (consensus + what to review)
    ./run.py review                # interactive: resolve sites -> verbatim.txt
    ./run.py intended              # opens verbatim.txt to edit into intended.txt
    ./run.py cleanup               # -> cleanup.json (the cleanup grid over each ASR transcript)
    ./run.py score                 # -> results.json + printed table
    ./run.py status                # what exists so far

Stdlib only.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import statistics
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

import baseline
import longform
from consensus import ABSENT, build_consensus
from engines import (
    ASR_ENGINES,
    CLEANUP_BACKENDS,
    AsrResult,
    resolve_engine,
    run_asr,
    run_cleanup,
)
from score import cer, jargon_recall, normalize, strip_fillers, wer, word_errors
from timings import clock, map_timestamps

RUNS = Path(__file__).resolve().parent / "runs"
DEFAULT_RUN = "current"
# The long-form fixture lives in its own run dir because it needs different treatment throughout: no
# reference transcript is possible, diarization is on, and one pass takes minutes rather than seconds.
MEETING_RUN = "pod"



REAL_VOCABULARY = Path.home() / "Library" / "Application Support" / "BetterVoice2" / "vocabulary.md"



def _asr_dir(d: Path) -> Path:
    ad = d / "asr"; ad.mkdir(parents=True, exist_ok=True); return ad


def _load_asr(d: Path) -> dict:
    """Merge per-engine result files, falling back to a legacy single asr.json.

    Results are stored one file per engine because cmd_asr used to read-modify-write a shared
    asr.json: two concurrent runs against the same run-id would each load the file, add their own
    engine, and write back -- silently discarding the other's work. That actually happened here, with
    a Whisper run erasing a completed Apple diarization pass.
    """
    merged: dict = {}
    legacy = d / "asr.json"
    if legacy.exists():
        merged.update(load_json(legacy, {}) or {})
    ad = d / "asr"
    if ad.exists():
        for f in sorted(ad.glob("*.json")):
            rec = load_json(f)
            if isinstance(rec, dict) and rec.get("engine"):
                merged[rec["engine"]] = rec
    return merged


def _save_asr(d: Path, result_dict: dict) -> None:
    """One file per engine -- an atomic unit that no other engine's run can overwrite."""
    (_asr_dir(d) / f"{result_dict['engine']}.json").write_text(json.dumps(result_dict, indent=2))


def _ws_asr(d: Path) -> Path:
    """Workspace for the ASR stage: deliberately WITHOUT a vocabulary file.

    `ImportPipeline.polishTurnText` applies `Vocabulary.apply()` even when polish is disabled, so a
    vocabulary here would silently correct Apple's transcript ("Summit Past" -> "Summit Pass") while the
    FluidAudio and MLX engines -- which never pass through the app -- got no such help. That would
    bias the ASR comparison toward Apple.
    """
    ws = d / "ws_asr"
    ws.mkdir(parents=True, exist_ok=True)
    (ws / "vocabulary.md").unlink(missing_ok=True)
    return ws


def _ws_cleanup(d: Path, vocabulary: str | None) -> Path:
    """Workspace for the cleanup stage: WITH the real vocabulary.

    Here it is fair -- every engine's transcript goes through the same CLI, so all cells get the same
    terms -- and it matches the shipping workflow, which is what the comparison is about.
    """
    ws = d / "ws_cleanup"
    ws.mkdir(parents=True, exist_ok=True)
    src = Path(vocabulary).expanduser() if vocabulary else REAL_VOCABULARY
    if src.exists():
        shutil.copyfile(src, ws / "vocabulary.md")
    return ws


def run_dir(name: str) -> Path:
    d = RUNS / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def load_json(path: Path, default=None):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:  # noqa: BLE001
        return default


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# prepare
# ---------------------------------------------------------------------------

def cmd_prepare(args) -> None:
    d = run_dir(args.run)
    src = Path(args.recording).expanduser()
    if not src.exists():
        die(f"recording not found: {src}")
    if shutil.which("ffmpeg") is None:
        die("ffmpeg not on PATH (brew install ffmpeg)")

    out = d / "audio.wav"
    # One canonical decode, then every engine gets byte-identical input. Letting each engine decode
    # the source itself would fold their resampler differences into the accuracy comparison.
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(out),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        die(f"ffmpeg failed: {proc.stderr.strip()[:500]}")

    duration = _probe_duration(out)
    (d / "meta.json").write_text(json.dumps({
        "source": str(src), "audio": str(out), "audio_s": duration,
    }, indent=2))
    print(f"prepared {out}  ({duration:.1f}s, 16kHz mono)")
    if duration and duration < 60:
        print(f"  note: {duration:.0f}s is short for a stable comparison; the design assumes ~2 minutes")


def _probe_duration(path: Path) -> float | None:
    if shutil.which("ffprobe") is None:
        return None
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=False,
    )
    try:
        return float(proc.stdout.strip())
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# asr
# ---------------------------------------------------------------------------

def cmd_asr(args) -> None:
    d = run_dir(args.run)
    audio = d / "audio.wav"
    if not audio.exists():
        die(f"no audio.wav in {d} — run `prepare` first")
    meta = load_json(d / "meta.json", {}) or {}
    audio_s = meta.get("audio_s")

    specs = []
    for raw_spec in (args.engines or ASR_ENGINES):
        try:
            specs.append(resolve_engine(raw_spec))
        except ValueError as exc:
            die(str(exc))
    existing = _load_asr(d)

    for spec in specs:
        engine = spec.name
        if engine in existing and not args.force:
            print(f"[skip] {engine} (already present; --force to redo)")
            continue
        print(f"[run ] {engine} ...", flush=True)
        result = run_asr(spec, audio, _ws_asr(d), audio_s, repeats=args.repeats,
                         multi_speaker=args.multi)
        existing[engine] = asdict(result)
        _save_asr(d, existing[engine])
        if result.error:
            print(f"       FAILED: {result.error}")
        else:
            rtfx = f"RTFx={result.rtfx}" if result.rtfx else ""
            spk = f" speakers={result.n_speakers} segs={result.n_segments}" if result.n_speakers else ""
            print(f"       ok  warm={result.warm_s}s cold={result.cold_s}s {rtfx}{spk}")
            print(f"       {result.text[:110]}{'...' if len(result.text) > 110 else ''}")

    ok = [e for e, r in existing.items() if not r.get("error") and (r.get("text") or "").strip()]
    print(f"\n{len(ok)}/{len(existing)} engines produced text: {', '.join(sorted(ok))}")
    failed = sorted(set(existing) - set(ok))
    if failed:
        print(f"failed: {', '.join(failed)}")


# ---------------------------------------------------------------------------
# reference
# ---------------------------------------------------------------------------

def cmd_reference(args) -> None:
    d = run_dir(args.run)
    asr = _load_asr(d)
    if not asr:
        die("no ASR results — run `asr` first")

    transcripts = {
        engine: rec.get("text", "")
        for engine, rec in asr.items()
        if not rec.get("error") and (rec.get("text") or "").strip()
    }
    try:
        result = build_consensus(transcripts)
    except ValueError as exc:
        die(str(exc))

    # Timestamps ride across the alignment from whichever engine reports word-level timings
    # (Parakeet does); the consensus itself has no timing of its own. Approximate but scrubbable.
    timings_source, word_timings = _pick_word_timings(asr)
    timestamps = map_timestamps(result.tokens, word_timings)

    (d / "verbatim_draft.txt").write_text(result.text + "\n", encoding="utf-8")
    (d / "sites.json").write_text(json.dumps({
        "pivot": result.pivot,
        "timings_source": timings_source,
        "timestamps": timestamps,
        "sites": [
            {
                "index": s.index, "options": s.options, "chosen": s.chosen,
                "context_before": s.context_before, "context_after": s.context_after,
            }
            for s in result.sites
        ],
    }, indent=2))

    print(f"consensus from {len(transcripts)} engines, pivot={result.pivot}")
    print(f"  {len(result.tokens)} tokens, {len(result.sites)} need review "
          f"({result.unanimous_fraction:.0%} unanimous)")
    print("\nper-engine agreement with consensus (WER):")
    for engine, value in sorted(result.per_engine_wer_to_consensus.items(), key=lambda kv: kv[1]):
        print(f"  {value:6.1%}  {engine}")
    if timings_source:
        print(f"\ntimestamps mapped from {timings_source} "
              f"({sum(1 for t in timestamps if t is not None)}/{len(timestamps)} tokens)")
    else:
        print("\nno engine reported word timings; review will show --:-- and playback is unavailable")
    print(f"draft: {d / 'verbatim_draft.txt'}")
    print(f"next:  ./run.py review --run {args.run}")


# ---------------------------------------------------------------------------
# review
# ---------------------------------------------------------------------------


def _pick_word_timings(asr: dict) -> tuple[str | None, list[dict]]:
    """First engine that reported word-level timings. Parakeet does; Apple only has coarse segments."""
    for engine, rec in sorted(asr.items()):
        timings = (rec.get("raw") or {}).get("wordTimings") or []
        if timings:
            return engine, timings
    return None, []


def cmd_review(args) -> None:
    d = run_dir(args.run)
    draft_path = d / "verbatim_draft.txt"
    sites_data = load_json(d / "sites.json")
    if not draft_path.exists() or sites_data is None:
        die("no draft/sites — run `reference` first")

    tokens = draft_path.read_text().split()
    sites = sites_data["sites"]
    timestamps = sites_data.get("timestamps") or [None] * len(tokens)

    # Edits are persisted keyed by DRAFT token index, and verbatim.txt is always regenerated from
    # draft+edits. Resuming from verbatim.txt instead would be wrong: deletions change the token
    # count, so sites.json indices would no longer line up -- and a second pass would silently throw
    # away the first pass's work.
    edits_path = d / "review_edits.json"
    prior = load_json(edits_path, {}) or {}
    prior_edits = {int(k): v for k, v in (prior.get("edits") or {}).items()}
    prior_decided = set(prior.get("decided") or [])
    if prior_edits or prior_decided:
        print(f"resuming: {len(prior_decided)} site(s) already decided, {len(prior_edits)} edit(s) kept")

    # Support filtering is opt-in and defaults to reviewing everything, because the sites where the
    # majority is WRONG are disproportionately the jargon sites: a term only one engine hears
    # correctly ("Hugging Face" heard by 1 of 7) becomes a high-support site for the wrong reading,
    # and skipping it bakes the error into the reference -- then penalizes the one engine that got it
    # right. Filtering trades reference quality for review time in exactly the wrong direction.
    if args.contains:
        wanted = {t.strip().lower() for t in args.contains.split(",") if t.strip()}
        before_n = len(sites)
        sites = [s_ for s_ in sites if wanted & {o.lower() for o in s_["options"]}]
        print(f"targeted pass: {len(sites)} of {before_n} sites mention {sorted(wanted)}")

    if args.undecided:
        keyed = {s_["index"] for s_ in sites}
        sites = [s_ for s_ in sites if s_["index"] not in prior_decided]
        print(f"skipping already-decided sites: {len(sites)} remain")

    if args.min_support > 0:
        total_before = len(sites)
        sites = [
            s_ for s_ in sites
            if s_["options"].get(s_["chosen"], 0) / max(sum(s_["options"].values()), 1) < args.min_support
        ]
        print(f"reviewing {len(sites)} of {total_before} sites (--min-support {args.min_support:.0%}).")
        print("Skipped sites keep the majority reading, including where the majority is wrong about")
        print("a jargon term. This affects the WER/verb diagnostic column, not the headline ranking.\n")

    if not sites:
        (d / "verbatim.txt").write_text(" ".join(tokens) + "\n", encoding="utf-8")
        print("nothing to review; verbatim.txt written unchanged")
        return

    if args.plain:
        edits = _review_plain(tokens, sites, timestamps, dict(prior_edits))
        decided = set(prior_decided)
    else:
        from review_tui import ReviewState, run_tui
        state = ReviewState(tokens=tokens, sites=sites, timestamps=timestamps,
                            edits=dict(prior_edits))
        state = run_tui(state, str(d / "audio.wav"))
        print(f"decided {len(state.decided)}/{len(sites)} this pass, {len(state.edits)} edit(s) total")
        edits = state.edits
        decided = set(prior_decided) | {sites[i]["index"] for i in state.decided if i < len(sites)}

    edits_path.write_text(json.dumps(
        {"edits": {str(k): v for k, v in sorted(edits.items())}, "decided": sorted(decided)}, indent=2))
    final = [tok for i, tok in enumerate(tokens)
             if i not in edits or edits[i] is not None
             for tok in [edits.get(i, tok) if i in edits else tok]]
    (d / "verbatim.txt").write_text(" ".join(final) + "\n", encoding="utf-8")
    print(f"wrote {d / 'verbatim.txt'}")
    print(f"next: ./run.py intended --run {args.run}")


def _review_plain(tokens: list[str], sites: list[dict], timestamps: list,
                  edits: dict[int, str | None]) -> dict[int, str | None]:
    """Line-based fallback for when curses is unavailable (piped stdin, dumb terminal)."""
    print(f"{len(sites)} site(s). Enter = keep, a number = pick that vote, text = custom,")
    print("'-' = delete, 'q' = save and stop.\n")
    for n, site in enumerate(sites, 1):
        idx = site["index"]
        before = " ".join(tokens[max(0, idx - 5):idx])
        after = " ".join(tokens[idx + 1:idx + 6])
        current = tokens[idx] if idx < len(tokens) else "(end)"
        stamp = clock(timestamps[idx]) if idx < len(timestamps) else "--:--"
        ranked = sorted(site["options"].items(), key=lambda kv: -kv[1])
        print(f"[{n}/{len(sites)}] {stamp}  …{before} >>{current}<< {after}…")
        for i, (tok, votes) in enumerate(ranked, 1):
            shown = "(nothing)" if tok == ABSENT else tok
            print(f"         {i}. {shown}  ×{votes}")
        try:
            answer = input("         > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nstopping early")
            break
        if answer == "q":
            break
        if answer == "-":
            edits[idx] = None
        elif answer.isdigit() and 1 <= int(answer) <= len(ranked):
            picked = ranked[int(answer) - 1][0]
            edits[idx] = None if picked == ABSENT else picked
        elif answer:
            edits[idx] = answer

    return edits


# ---------------------------------------------------------------------------
# intended
# ---------------------------------------------------------------------------

def cmd_intended(args) -> None:
    d = run_dir(args.run)
    verbatim = d / "verbatim.txt"
    if not verbatim.exists():
        die("no verbatim.txt — run `review` first")
    intended = d / "intended.txt"
    if not intended.exists():
        intended.write_text(verbatim.read_text(), encoding="utf-8")

    print("The intended reference is what you MEANT to end up with: disfluencies removed,")
    print("false starts resolved, jargon spelled correctly. Scoring pipelines against the")
    print("verbatim text instead would penalize cleanup for removing 'um', and rank no-cleanup first.")
    print()
    print("Write it now, BEFORE looking at any pipeline output — deriving it from one pipeline's")
    print("result would hand that pipeline an unearned win.")
    print()
    print(f"  {intended}")
    editor = os.environ.get("EDITOR")
    if editor and not args.no_edit:
        subprocess.run([editor, str(intended)], check=False)
        print(f"\nsaved. next: ./run.py cleanup --run {args.run}")
    else:
        print(f"\nedit it, then: ./run.py cleanup --run {args.run}")


# ---------------------------------------------------------------------------
# cleanup grid
# ---------------------------------------------------------------------------

def cmd_cleanup(args) -> None:
    d = run_dir(args.run)
    asr = _load_asr(d)
    if not asr:
        die("no ASR results — run `asr` first")

    transcripts = {
        engine: rec.get("text", "")
        for engine, rec in asr.items()
        if not rec.get("error") and (rec.get("text") or "").strip()
    }
    backends = args.backends or list(CLEANUP_BACKENDS)
    existing = load_json(d / "cleanup.json", {}) or {}

    for engine, text in sorted(transcripts.items()):
        for backend in backends:
            key = f"{engine}+{backend}"
            if key in existing and not args.force:
                print(f"[skip] {key}")
                continue
            print(f"[run ] {key} ...", flush=True)
            result = run_cleanup(text, backend, _ws_cleanup(d, args.vocabulary), repeats=args.repeats)
            existing[key] = asdict(result)
            (d / "cleanup.json").write_text(json.dumps(existing, indent=2))
            if result.error:
                print(f"       FAILED: {result.error}")
            else:
                distinct = len(set(result.outputs))
                print(f"       ok  median={result.median_s}s  {distinct} distinct output(s) "
                      f"of {len(result.outputs)}  vocab={result.vocabulary_terms}")
    print(f"\n{len(existing)} cleanup cell(s) recorded")


# ---------------------------------------------------------------------------
# score
# ---------------------------------------------------------------------------

def _references(d: Path) -> tuple:
    """The three reference variants for a run: verbatim, intended, intended-with-fillers-stripped.

    Shared by `score` and `evaluate` so a newly evaluated engine is scored against byte-identical
    references to every engine already in the baseline. Recomputing them differently in two places is
    exactly how a comparison silently stops being a comparison.
    """
    verbatim_path = d / "verbatim.txt"
    intended_path = d / "intended.txt"
    verbatim = verbatim_path.read_text().strip() if verbatim_path.exists() else ""
    intended = intended_path.read_text().strip() if intended_path.exists() else ""
    intended_nf, removed = strip_fillers(intended) if intended else ("", [])
    return verbatim, intended, intended_nf, removed


def _spoken_terms(spec: str | None, reference: str, quiet: bool = False) -> tuple:
    """Jargon terms actually present in the reference, plus the ones dropped for being absent.

    Only score terms that were actually spoken. A term absent from the reference is "missed" by every
    engine, which does not bias the ranking but makes the absolute recall meaningless (a vocabulary of
    20 terms of which 3 were spoken would report 3/20 for a perfect transcript).
    """
    all_terms = _load_terms(spec)
    terms = [t for t in all_terms if jargon_recall(reference, [t])[0] == 1]
    unspoken = [t for t in all_terms if t not in terms]
    if unspoken and not quiet:
        print(f"note: {len(unspoken)} vocabulary term(s) not present in the reference, excluded "
              f"from jargon scoring: {', '.join(unspoken)}\n")
    return terms, unspoken


def _default_terms(d: Path, spec: str | None) -> str | None:
    """Fall back to the run's own terms.txt, so the jargon column is not silently empty.

    The column measures the metric that annoys the user most in daily use, and it stays blank unless
    --terms is passed; defaulting to the file the run already keeps means the common invocation
    reports it.
    """
    if spec:
        return spec
    local = d / "terms.txt"
    return str(local) if local.exists() else None


def _build_cells(asr: dict, cleanup: dict, verbatim: str, intended: str, intended_nf: str,
                 terms: list, engines: list | None = None) -> list:
    """Score every ASR cell and cleanup cell into the results-table shape.

    `engines` restricts to a subset, which is what lets `evaluate` score one new model without
    rescoring (or needing the cleanup grid of) every engine already measured.
    """
    cells: list = []
    wanted = set(engines) if engines else None

    # Raw ASR cells (cleanup = none).
    for engine, rec in sorted(asr.items()):
        if wanted is not None and engine not in wanted:
            continue
        if rec.get("error") or not (rec.get("text") or "").strip():
            continue
        cells.append(_cell(engine, "none", rec["text"], verbatim, intended, intended_nf, terms,
                           asr_rec=rec, cleanup_s=0.0, variants=1))

    # Cleanup cells. Each repeat is scored; the median is reported and the spread retained, because
    # a gap smaller than a backend's own run-to-run spread is not a real difference.
    for key, rec in sorted(cleanup.items()):
        if rec.get("error"):
            continue
        engine, _, backend = key.partition("+")
        if wanted is not None and engine not in wanted:
            continue
        outputs = [o for o in rec.get("outputs", []) if o.strip()]
        if not outputs:
            continue
        cells.append(_cell(engine, backend, outputs, verbatim, intended, intended_nf, terms,
                           asr_rec=asr.get(engine, {}),
                           # Recomputed from the raw seconds list: median_s is a @property and
                           # asdict() does not serialize properties, so rec["median_s"] is absent and
                           # every total_s silently omitted the cleanup stage.
                           cleanup_s=(_median(rec["seconds"]) if rec.get("seconds") else None),
                           variants=len(set(outputs))))
    return cells


def cmd_score(args) -> None:
    d = run_dir(args.run)
    asr = _load_asr(d)
    cleanup = load_json(d / "cleanup.json", {}) or {}
    if not asr:
        die("no ASR results — run `asr` first")
    if not (d / "verbatim.txt").exists():
        die("no verbatim.txt — run `reference` then `review` first")

    # Second reference variant with discourse fillers removed, derived mechanically so it costs no
    # extra hand-writing. Scoring against both answers whether the recommendation is an artifact of
    # whether the reference keeps "okay"/"yeah"/"like" -- a cleanup stage is penalized for removing
    # them under the first reference and rewarded under the second.
    verbatim, intended, intended_nf, removed_fillers = _references(d)
    if intended_nf:
        (d / "intended_nofiller.txt").write_text(intended_nf + "\n", encoding="utf-8")
        print(f"derived intended_nofiller.txt: removed {len(removed_fillers)} filler(s) "
              f"({len(normalize(intended).split())} -> {len(normalize(intended_nf).split())} words)")
        if removed_fillers:
            print(f"  {', '.join(repr(f) for f in removed_fillers[:14])}"
                  f"{' …' if len(removed_fillers) > 14 else ''}\n")
    if not intended:
        print("warning: no intended.txt — end-to-end scores will be omitted "
              "(run `intended`). ASR-stage scores below are still valid.\n")

    terms_spec = _default_terms(d, args.terms)
    if terms_spec and not args.terms:
        print(f"using jargon terms from {terms_spec} (override with --terms)\n")
    terms, unspoken = _spoken_terms(terms_spec, intended or verbatim)

    cells = _build_cells(asr, cleanup, verbatim, intended, intended_nf, terms)

    payload = {
        "verbatim_words": len(normalize(verbatim).split()),
        "intended_words": len(normalize(intended).split()) if intended else 0,
        "jargon_terms": terms,
        "intended_nofiller": intended_nf,
        "fillers_removed": removed_fillers,
        "jargon_terms_excluded_unspoken": unspoken,
        "cells": cells,
    }
    (d / "results.json").write_text(json.dumps(payload, indent=2))
    _print_table(cells, bool(intended), bool(intended_nf), terms)
    print(f"\nwrote {d / 'results.json'}")


def _median(values: list[float]) -> float:
    import statistics
    return statistics.median(values)


def _cell(engine, backend, text_or_texts, verbatim, intended, intended_nf, terms, asr_rec, cleanup_s, variants):
    texts = [text_or_texts] if isinstance(text_or_texts, str) else text_or_texts
    verbatim_wers = [wer(verbatim, t) for t in texts]
    intended_wers = [wer(intended, t) for t in texts] if intended else []
    nofiller_wers = [wer(intended_nf, t) for t in texts] if intended_nf else []
    recalls = [jargon_recall(t, terms)[0] for t in texts] if terms else []
    counts = word_errors(intended or verbatim, texts[0])

    asr_warm = asr_rec.get("warm_s") or 0.0
    return {
        "engine": engine,
        "cleanup": backend,
        "wer_verbatim": round(_median(verbatim_wers), 4),
        "wer_intended": round(_median(intended_wers), 4) if intended_wers else None,
        "wer_intended_spread": round(max(intended_wers) - min(intended_wers), 4) if len(intended_wers) > 1 else 0.0,
        "wer_nofiller": round(_median(nofiller_wers), 4) if nofiller_wers else None,
        "wer_nofiller_spread": round(max(nofiller_wers) - min(nofiller_wers), 4) if len(nofiller_wers) > 1 else 0.0,
        "cer_intended": round(cer(intended, texts[0]), 4) if intended else None,
        # Median, not max: reporting the best of N nondeterministic outputs would overstate how
        # reliably a pipeline preserves your vocabulary.
        "jargon_found": int(_median(recalls)) if recalls else None,
        "jargon_total": len(terms) or None,
        "asr_warm_s": asr_warm,
        "asr_cold_s": asr_rec.get("cold_s"),
        "cleanup_s": cleanup_s,
        "total_s": round(asr_warm + (cleanup_s or 0.0), 3),
        "rtfx": (round(asr_rec["audio_s"] / asr_warm, 1)
                 if asr_rec.get("audio_s") and asr_warm else None),
        "distinct_outputs": variants,
        "substitutions": counts.substitutions,
        "deletions": counts.deletions,
        "insertions": counts.insertions,
        "sample": texts[0][:200],
    }


def _load_terms(spec: str | None) -> list[str]:
    """Jargon terms from a file (one per line) or a comma-separated string."""
    if not spec:
        return []
    path = Path(spec).expanduser()
    if path.exists():
        return [ln.strip() for ln in path.read_text().splitlines() if ln.strip() and not ln.startswith("#")]
    return [t.strip() for t in spec.split(",") if t.strip()]


def _print_table(cells: list[dict], has_intended: bool, has_nofiller: bool, terms: list[str]) -> None:
    primary = "wer_intended" if has_intended else "wer_verbatim"
    ranked = sorted(cells, key=lambda c: (c[primary] is None, c[primary]))

    head = (f"{'ASR engine':<23} {'cleanup':<16} {'verb':>7} {'int':>7} {'int-nf':>7} "
            f"{'spread':>7} {'jargon':>7} {'tot s':>7}")
    print(head)
    print("-" * len(head))
    for c in ranked:
        wi = f"{c['wer_intended']:.1%}" if c["wer_intended"] is not None else "-"
        nf = f"{c['wer_nofiller']:.1%}" if c.get("wer_nofiller") is not None else "-"
        sp = f"{c['wer_intended_spread']:.1%}" if c["wer_intended_spread"] else "-"
        jg = f"{c['jargon_found']}/{c['jargon_total']}" if c["jargon_found"] is not None else "-"
        print(f"{c['engine']:<23} {c['cleanup']:<16} {c['wer_verbatim']:>6.1%} "
              f"{wi:>7} {nf:>7} {sp:>7} {jg:>7} {c['total_s']:>7.2f}")

    print("\n  verb   = vs verbatim (ASR stage only; penalizes cleanup for removing disfluencies)")
    print("  int    = vs your intended reference, fillers KEPT")
    print("  int-nf = vs the same reference with discourse fillers stripped")

    if not has_intended:
        print("\nRanked by WER against the VERBATIM reference — ASR stage only, not a pipeline ranking.")
        return

    print(f"\nRanked by 'int'. Leader: {_name(ranked[0])} at {ranked[0]['wer_intended']:.1%}")
    _tie_note(ranked, "wer_intended", "wer_intended_spread")

    if has_nofiller:
        _sensitivity(cells)

    if not terms:
        print("\nNo jargon terms supplied (--terms); that column is the metric most likely to match")
        print("what annoys you day to day.")


def _name(cell: dict) -> str:
    return f"{cell['engine']}+{cell['cleanup']}"


def _tie_note(ranked: list[dict], key: str, spread_key: str) -> None:
    """Cells indistinguishable from the leader given their own run-to-run variance."""
    best = ranked[0]
    close = [
        c for c in ranked[1:]
        if c[key] is not None
        and c[key] - best[key] <= max(best.get(spread_key, 0.0), c.get(spread_key, 0.0), 0.01)
    ]
    if close:
        print(f"  tied with it (within run-to-run spread): {', '.join(_name(c) for c in close)}")
        print("  Break these with a blind preference ranking, not the decimals.")


def _sensitivity(cells: list[dict]) -> None:
    """Does the recommendation survive the choice of reference?

    This is the whole point of scoring twice. If the leader flips when fillers are stripped, the
    'winner' is an artifact of how the reference was written rather than a property of the pipeline,
    and the honest answer is that the two are not separated by this experiment.
    """
    usable = [c for c in cells if c["wer_intended"] is not None and c.get("wer_nofiller") is not None]
    if not usable:
        return
    by_int = sorted(usable, key=lambda c: c["wer_intended"])
    by_nf = sorted(usable, key=lambda c: c["wer_nofiller"])

    print(f"\nSensitivity to the reference:")
    print(f"  fillers kept     -> {_name(by_int[0])} ({by_int[0]['wer_intended']:.1%})")
    print(f"  fillers stripped -> {_name(by_nf[0])} ({by_nf[0]['wer_nofiller']:.1%})")

    if _name(by_int[0]) == _name(by_nf[0]):
        print("  SAME winner under both references — the recommendation is robust to this choice.")
    else:
        print("  DIFFERENT winner — the recommendation depends on whether the reference keeps")
        print("  fillers, so it is not a property of the pipelines alone. Treat both as candidates.")

    top3_int = [_name(c) for c in by_int[:3]]
    top3_nf = [_name(c) for c in by_nf[:3]]
    print(f"  top 3 kept:     {', '.join(top3_int)}")
    print(f"  top 3 stripped: {', '.join(top3_nf)}")
    if set(top3_int) == set(top3_nf):
        print("  Same three cells lead either way (order may differ).")

    # Which factor moves more: does stripping fillers help cleanup cells specifically?
    def mean_delta(pred) -> float | None:
        vals = [c["wer_intended"] - c["wer_nofiller"] for c in usable if pred(c)]
        return sum(vals) / len(vals) if vals else None

    raw_d = mean_delta(lambda c: c["cleanup"] == "none")
    clean_d = mean_delta(lambda c: c["cleanup"] != "none")
    if raw_d is not None and clean_d is not None:
        print(f"  stripping fillers changes WER by {raw_d:+.1%} for raw-ASR cells "
              f"and {clean_d:+.1%} for cleanup cells")
        print("  (positive = that cell scores better against the stripped reference)")


# ---------------------------------------------------------------------------
# evaluate — the one-command "is this new model any good" flow
# ---------------------------------------------------------------------------

def _fixture(base: dict, key: str) -> dict:
    return ((base.get("fixtures") or {}).get(key)) or {}


def _expected_words(base: dict, audio_s: float | None) -> int | None:
    """Healthy word count for `audio_s` of the meeting fixture, scaled from the baseline band.

    Scaled from words-per-second rather than compared against a fixed count, so a slice or a replaced
    fixture recording still gets a meaningful truncation check instead of failing every engine.
    """
    meeting = _fixture(base, "meeting")
    words = meeting.get("expected_words")
    ref_audio = meeting.get("audio_s")
    if not words or not ref_audio or not audio_s:
        return None
    return int(round(words * (audio_s / ref_audio)))


def _slice_run(source: Path, seconds: int, name: str) -> Path:
    """A shorter copy of a fixture, for engines too slow to run the full file.

    Derived with ffmpeg from the canonical 16k mono WAV rather than re-decoding the original, so the
    slice is byte-identical to the first N seconds every other engine saw.
    """
    d = run_dir(name)
    out = d / "audio.wav"
    if not out.exists():
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(source), "-t", str(seconds),
               "-c", "copy", str(out)]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            die(f"ffmpeg slice failed: {proc.stderr.strip()[:400]}")
    duration = _probe_duration(out)
    (d / "meta.json").write_text(json.dumps(
        {"source": str(source), "audio": str(out), "audio_s": duration, "slice_of": str(source)},
        indent=2))
    return d


def _run_one_asr(d: Path, spec, audio_s: float | None, repeats: int, force: bool,
                 multi_speaker: bool = False) -> dict:
    """Run (or reuse) one engine's ASR in a run dir, returning its record."""
    existing = _load_asr(d)
    if spec.name in existing and not force:
        rec = existing[spec.name]
        if not rec.get("error"):
            print(f"  [reuse] {spec.name} already measured here (--force to redo)")
            return rec
    print(f"  [run  ] {spec.name} on {d.name} ...", flush=True)
    result = run_asr(spec, d / "audio.wav", _ws_asr(d), audio_s, repeats=repeats,
                     multi_speaker=multi_speaker)
    rec = asdict(result)
    _save_asr(d, rec)
    return rec


def cmd_evaluate(args) -> None:
    """Measure one engine on both fixtures and rank it against everything measured before."""
    try:
        spec = resolve_engine(args.engine)
    except ValueError as exc:
        die(str(exc))

    base = baseline.load(Path(args.baseline) if args.baseline else baseline.BASELINE_PATH)
    known = (base.get("engines") or {}).get(spec.name)
    record: dict = {}

    print(f"evaluating {spec.name}"
          f"{'' if spec.registered else f'  (ad-hoc spec: {args.engine})'}")
    if known:
        print(f"  already in the baseline — this run doubles as a regression check")
    print()

    # --- fixture 1: dictation, where WER is meaningful --------------------
    d = run_dir(args.run)
    dict_cells: list = []
    dict_rec: dict = {}
    if not (d / "audio.wav").exists():
        die(f"no audio.wav in {d} — the dictation fixture must exist (see README)")
    if not (d / "verbatim.txt").exists():
        die(f"no verbatim.txt in {d} — references must be reviewed before an engine can be scored")

    print("fixture 1/2: dictation (WER vs the reviewed references)")
    meta = load_json(d / "meta.json", {}) or {}
    dict_asr = _run_one_asr(d, spec, meta.get("audio_s"), args.repeats, args.force)
    if dict_asr.get("error"):
        print(f"  FAILED: {dict_asr['error']}")
    else:
        verbatim, intended, intended_nf, _ = _references(d)
        terms, _ = _spoken_terms(_default_terms(d, args.terms), intended or verbatim, quiet=True)

        if args.cleanup:
            _cleanup_for_engine(d, spec.name, dict_asr.get("text", ""), args)

        cleanup = load_json(d / "cleanup.json", {}) or {}
        dict_cells = _build_cells({spec.name: dict_asr}, cleanup, verbatim, intended, intended_nf,
                                 terms, engines=[spec.name])
        dict_rec = baseline.dictation_record(dict_cells, dict_asr)
        record["dictation"] = dict_rec
        _print_dictation_card(dict_cells, dict_rec, bool(intended))

    # --- fixture 2: meeting, where throughput and stability are the point -
    print("\nfixture 2/2: meeting (throughput + long-form stability; no reference exists)")
    m = run_dir(args.meeting_run)
    meet_rec: dict = {}
    report = None
    if not (m / "audio.wav").exists():
        print(f"  skipped: no audio.wav in {m}")
    elif args.no_meeting:
        print("  skipped: --no-meeting")
    else:
        m_meta = load_json(m / "meta.json", {}) or {}
        m_audio_s = m_meta.get("audio_s")
        measured_on = "full"
        target = m

        # Guard against a 40-minute surprise: project the meeting wall clock from the dictation RTFx
        # we just measured, and fall back to a slice when it exceeds the budget. A slow engine still
        # gets a throughput number instead of the command appearing to hang.
        rtfx = (dict_rec or {}).get("rtfx")
        projected = (m_audio_s / rtfx) if (rtfx and m_audio_s) else None
        if (projected and args.meeting_budget and projected > args.meeting_budget
                and not args.meeting_full):
            print(f"  projected {projected / 60:.0f} min for the full file at RTFx {rtfx:g}, over the "
                  f"{args.meeting_budget / 60:.0f} min budget")
            print(f"  measuring a {args.meeting_slice}s slice instead "
                  f"(--meeting-full to run the whole file, --meeting-budget 0 to disable)")
            target = _slice_run(m / "audio.wav", args.meeting_slice,
                               f"{args.meeting_run}-slice{args.meeting_slice}")
            m_audio_s = (load_json(target / "meta.json", {}) or {}).get("audio_s")
            measured_on = f"slice:{args.meeting_slice}"

        # Diarization on by default here: the meeting has four speakers, and Apple's measured cost on
        # this fixture includes attributing them. Engines that cannot diarize ignore the flag.
        meet_asr = _run_one_asr(target, spec, m_audio_s, args.meeting_repeats, args.force,
                                multi_speaker=not args.no_diarize)
        if meet_asr.get("error"):
            print(f"  FAILED: {meet_asr['error']}")
        else:
            report = longform.analyze(
                meet_asr.get("text", ""), audio_s=m_audio_s,
                expected_words=_expected_words(base, m_audio_s), raw=meet_asr.get("raw"),
            )
            meet_rec = baseline.meeting_record(meet_asr, report, measured_on=measured_on)
            record["meeting"] = meet_rec
            _print_meeting_card(meet_rec, report, measured_on, m_audio_s)

    # --- ranking against previously measured engines ----------------------
    print()
    if dict_rec:
        value = dict_rec.get("wer_intended_best") or dict_rec.get("wer_intended")
        if value is not None and (base.get("engines") or {}):
            for line in baseline.format_ranking(base, spec.name, value):
                print(line)
            if not dict_rec.get("wer_intended_best"):
                print("  (ranked on the raw-ASR number; pass --cleanup to measure the "
                      "best-pipeline number the table's other entries use)")
        elif value is not None:
            print(f"no baselined engines to compare against; {spec.name} is the first.")

    # --- regression check when this engine was measured before ------------
    if known:
        print()
        deltas = baseline.compare_engine(known, record)
        _print_regression(spec.name, deltas)

    # One file per engine, mirroring the ASR stage: a second evaluation running concurrently cannot
    # clobber this one.
    out_dir = d / "evaluations"
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {"engine": spec.name, "spec": args.engine, "record": record,
               "cells": dict_cells,
               "stability": report.to_dict() if report is not None else None}
    (out_dir / f"{spec.name}.json").write_text(json.dumps(payload, indent=2))
    print(f"\nwrote {out_dir / f'{spec.name}.json'}")

    if args.update_baseline:
        if not record:
            print("nothing measured; baseline unchanged")
        else:
            path = Path(args.baseline) if args.baseline else baseline.BASELINE_PATH
            baseline.merge_engine(base, spec.name, record)
            baseline.save(base, path)
            print(f"updated {path} with {spec.name} ({', '.join(sorted(record))})")
    elif record:
        print(f"to record these numbers: ./run.py evaluate {args.engine} --update-baseline")


def _cleanup_for_engine(d: Path, engine: str, text: str, args) -> None:
    """Run the cleanup grid for one engine only."""
    if not text.strip():
        return
    backends = args.backends or list(CLEANUP_BACKENDS)
    existing = load_json(d / "cleanup.json", {}) or {}
    for backend in backends:
        key = f"{engine}+{backend}"
        if key in existing and not args.force:
            print(f"  [reuse] {key}")
            continue
        print(f"  [run  ] {key} ...", flush=True)
        result = run_cleanup(text, backend, _ws_cleanup(d, args.vocabulary), repeats=args.repeats)
        existing[key] = asdict(result)
        (d / "cleanup.json").write_text(json.dumps(existing, indent=2))
        if result.error:
            print(f"          FAILED: {result.error}")


def _print_dictation_card(cells: list, record: dict, has_intended: bool) -> None:
    primary = "wer_intended" if has_intended else "wer_verbatim"
    ranked = sorted(cells, key=lambda c: (c[primary] is None, c[primary]))
    print(f"  {'cleanup':<16} {'verb':>7} {'int':>7} {'int-nf':>7} {'jargon':>7} {'tot s':>7}")
    for c in ranked:
        wi = f"{c['wer_intended']:.1%}" if c["wer_intended"] is not None else "-"
        nf = f"{c['wer_nofiller']:.1%}" if c.get("wer_nofiller") is not None else "-"
        jg = f"{c['jargon_found']}/{c['jargon_total']}" if c["jargon_found"] is not None else "-"
        print(f"  {c['cleanup']:<16} {c['wer_verbatim']:>6.1%} {wi:>7} {nf:>7} {jg:>7} "
              f"{c['total_s']:>7.2f}")
    rtfx = record.get("rtfx")
    print(f"  warm {record.get('asr_warm_s')}s"
          f"{f', RTFx {rtfx:g}' if rtfx else ''}")


def _print_meeting_card(record: dict, report, measured_on: str, audio_s: float | None) -> None:
    rtfx = record.get("rtfx")
    span = f"{audio_s / 60:.1f} min" if audio_s else "?"
    print(f"  {span} of audio in {record.get('warm_s')}s"
          f"{f' (RTFx {rtfx:g})' if rtfx else ''}"
          f"{'' if measured_on == 'full' else f'  [{measured_on}]'}")
    if record.get("n_speakers"):
        print(f"  diarization: {record['n_speakers']} speakers, {record.get('n_segments')} segments")
    print(f"  stability: {report.summary()}")
    for f in report.findings:
        print(f"    {f.render()}")
    if measured_on != "full":
        print("    note: measured on a slice, so this is not a long-form stability verdict")


def _print_regression(engine: str, deltas: list) -> None:
    print(f"regression check against the baseline entry for {engine}:")
    if not deltas:
        print("  nothing comparable recorded")
        return
    for delta in deltas:
        print(delta.render())
    bad = baseline.material(deltas)
    if bad:
        print(f"\n  {len(bad)} material change(s): "
              f"{', '.join(d.metric for d in bad)}")
        print("  Same audio, same references — so this is environment drift, not the model:")
        print("  a changed normalizer, an upgraded dependency, or a new OS speech model. Investigate")
        print("  before trusting any comparison made against the older numbers.")
    else:
        timing = [d for d in deltas if d.material and d.kind == "timing"]
        if timing:
            print(f"\n  accuracy reproduced; {len(timing)} timing metric(s) moved "
                  f"({', '.join(d.metric for d in timing)}) — usually the machine, not the model")
        else:
            print("\n  reproduced within tolerance")


# ---------------------------------------------------------------------------
# baseline
# ---------------------------------------------------------------------------

def cmd_baseline_show(args) -> None:
    base = baseline.load(Path(args.baseline) if args.baseline else baseline.BASELINE_PATH)
    engines = base.get("engines") or {}
    if not engines:
        die("baseline is empty — run `baseline refresh --write`")

    dictation = _fixture(base, "dictation")
    meeting = _fixture(base, "meeting")
    print(f"baseline schema {base.get('schema')}  generated {base.get('generated', '?')}")
    if dictation:
        print(f"  dictation fixture: {dictation.get('audio_s')}s, "
              f"{dictation.get('intended_words')} intended words")
    if meeting:
        print(f"  meeting fixture:   {meeting.get('audio_s')}s, "
              f"~{meeting.get('expected_words')} words expected, "
              f"{meeting.get('speakers')} speakers")
    print()

    head = (f"{'engine':<23} {'verb':>7} {'int':>7} {'best':>7} {'cleanup':<16} "
            f"{'RTFx':>7} | {'meet s':>8} {'RTFx':>6} {'words':>7} {'stable':>7}")
    print(head)
    print("-" * len(head))
    for name, _ in baseline.ranking(base):
        rec = engines[name]
        d = rec.get("dictation") or {}
        m = rec.get("meeting") or {}
        stable = m.get("stability") or {}
        print(f"{name:<23} "
              f"{_pct(d.get('wer_verbatim')):>7} {_pct(d.get('wer_intended')):>7} "
              f"{_pct(d.get('wer_intended_best')):>7} {(d.get('best_cleanup') or '-'):<16} "
              f"{_num(d.get('rtfx')):>7} | {_num(m.get('warm_s')):>8} {_num(m.get('rtfx')):>6} "
              f"{_num(m.get('words')):>7} "
              f"{('yes' if stable.get('ok') else 'NO') if stable else '-':>7}")
    print("\n  int  = WER vs the intended reference, raw ASR (no cleanup)")
    print("  best = the best cleanup option for that engine")
    print("  meet = the 57-minute meeting fixture: wall clock, throughput, word count, stability")


def _pct(value) -> str:
    return f"{value:.1%}" if isinstance(value, (int, float)) else "-"


def _num(value) -> str:
    if value is None:
        return "-"
    return f"{value:g}" if isinstance(value, float) else str(value)


def _measure_all(args, base: dict) -> dict:
    """Records for every engine that both fixtures' run dirs already hold results for.

    Reads recorded state only -- it never runs an engine. Refreshing the baseline must not be able to
    quietly re-measure anything, or "refresh" would become a way to overwrite a regression with the
    numbers that caused it.
    """
    d = run_dir(args.run)
    m = run_dir(args.meeting_run)
    dict_asr = _load_asr(d)
    meet_asr = _load_asr(m)

    verbatim, intended, intended_nf, _ = _references(d)
    measured: dict = {}
    if verbatim:
        terms, _ = _spoken_terms(_default_terms(d, args.terms), intended or verbatim, quiet=True)
        cleanup = load_json(d / "cleanup.json", {}) or {}
        cells = _build_cells(dict_asr, cleanup, verbatim, intended, intended_nf, terms)
        by_engine: dict = {}
        for cell in cells:
            by_engine.setdefault(cell["engine"], []).append(cell)
        for engine, engine_cells in by_engine.items():
            rec = baseline.dictation_record(engine_cells, dict_asr.get(engine, {}))
            if rec:
                measured.setdefault(engine, {})["dictation"] = rec

    expected = _expected_words(base, (load_json(m / "meta.json", {}) or {}).get("audio_s"))
    if expected is None:
        # Bootstrap: the very first refresh has no recorded band yet, and the band is derived from
        # exactly these results. Falling back to the local mean makes that first pass self-consistent
        # instead of writing null word ratios. Only ever a fallback -- `check` must use the RECORDED
        # band, or a truncated engine would shift the expectation and hide its own truncation.
        counts = [len((r.get("text") or "").split()) for r in meet_asr.values()
                  if not r.get("error") and (r.get("text") or "").strip()]
        expected = int(round(statistics.fmean(counts))) if counts else None
    for engine, rec in meet_asr.items():
        if rec.get("error") or not (rec.get("text") or "").strip():
            continue
        report = longform.analyze(rec.get("text", ""), audio_s=rec.get("audio_s"),
                                  expected_words=expected, raw=rec.get("raw"))
        measured.setdefault(engine, {})["meeting"] = baseline.meeting_record(rec, report)
    return measured


def cmd_baseline_refresh(args) -> None:
    path = Path(args.baseline) if args.baseline else baseline.BASELINE_PATH
    base = baseline.load(path)
    measured = _measure_all(args, base)
    if not measured:
        die("no measurable results in the run dirs")

    result = baseline.compare(base, measured)
    print(f"{len(measured)} engine(s) measurable from the run dirs\n")
    for engine in result["new"]:
        print(f"  [new] {engine}")
    for engine, deltas in sorted(result["engines"].items()):
        moved = [d_ for d_ in deltas if d_.material]
        if moved:
            print(f"  [changed] {engine}: {', '.join(d_.metric for d_ in moved)}")
        else:
            print(f"  [same]    {engine}")
    if result["unmeasured"]:
        print(f"\n  kept unchanged (no local results): {', '.join(result['unmeasured'])}")

    if not args.write:
        print("\ndry run — nothing written. Add --write to commit these to the baseline file.")
        print("Read the [changed] lines first: refreshing over a real regression is how a bad")
        print("number becomes the new expectation.")
        return

    for engine, rec in measured.items():
        baseline.merge_engine(base, engine, rec)
    base["generated"] = datetime.date.today().isoformat()
    _refresh_fixtures(base, args, measured)
    baseline.save(base, path)
    print(f"\nwrote {path} ({len(base.get('engines') or {})} engines)")


def _refresh_fixtures(base: dict, args, measured: dict) -> None:
    """Fixture metadata: durations, reference sizes, and the healthy long-form word band.

    The expected word count is the MEAN across engines that completed the full file, not any single
    engine's output -- picking one engine would make it the de facto reference for a fixture that
    deliberately has none. Mean rather than median only because it moves smoothly as engines are
    added; with a truncation threshold of 80% the difference between the two is immaterial.

    Only STABLE engines contribute. Otherwise the band is self-poisoning: evaluate an engine that
    truncates at half the file, refresh, and the expectation drops toward the broken value -- which
    both lets that engine off the hook and starts flagging the healthy engines as overrunning.
    """
    d = run_dir(args.run)
    m = run_dir(args.meeting_run)
    verbatim, intended, _, _ = _references(d)
    fixtures = base.setdefault("fixtures", {})
    dict_meta = load_json(d / "meta.json", {}) or {}
    if verbatim:
        fixtures["dictation"] = {
            "run": args.run,
            "audio_s": dict_meta.get("audio_s"),
            "verbatim_words": len(normalize(verbatim).split()),
            "intended_words": len(normalize(intended).split()) if intended else 0,
            "note": "single speaker, spontaneous disfluent dictation; full ground truth, WER valid",
        }
    meet_meta = load_json(m / "meta.json", {}) or {}
    counts = []
    excluded = []
    for engine, rec in sorted(measured.items()):
        meeting = rec.get("meeting") or {}
        if meeting.get("measured_on") != "full" or not meeting.get("words"):
            continue
        if (meeting.get("stability") or {}).get("ok") is False:
            excluded.append(engine)
            continue
        counts.append(meeting["words"])
    if excluded:
        print(f"\n  excluded from the healthy word band (unstable): {', '.join(excluded)}")
    if counts:
        existing = fixtures.get("meeting") or {}
        fixtures["meeting"] = {
            "run": args.meeting_run,
            "audio_s": meet_meta.get("audio_s"),
            "speakers": existing.get("speakers", 4),
            "expected_words": int(round(statistics.fmean(counts))),
            "expected_words_from": len(counts),
            "note": "multi-speaker meeting; NO reference transcript — throughput, long-form "
                    "stability and diarization only, never WER",
        }


def cmd_baseline_check(args) -> None:
    """Re-derive numbers from the run dirs and fail if a known engine moved materially."""
    path = Path(args.baseline) if args.baseline else baseline.BASELINE_PATH
    base = baseline.load(path)
    if not (base.get("engines") or {}):
        die("baseline is empty — run `baseline refresh --write`")
    measured = _measure_all(args, base)
    if args.engines:
        measured = {k: v for k, v in measured.items() if k in set(args.engines)}
    if not measured:
        die("no results in the run dirs to check")

    result = baseline.compare(base, measured)
    failed: list = []
    kinds = ("accuracy", "stability", "timing") if args.strict else baseline.FAILING_KINDS
    for engine, deltas in sorted(result["engines"].items()):
        bad = baseline.material(deltas, kinds)
        # Timing-only movement gets its own label rather than a bare "ok": it is not a failure, but
        # printing "[ok]" directly above a MOVED line reads like a bug in the checker.
        timing_only = [d_ for d_ in deltas if d_.material and d_ not in bad]
        status = "DRIFT" if bad else ("warn" if timing_only else "ok")
        print(f"[{status:>5}] {engine}")
        for delta in deltas:
            if delta.material or args.verbose:
                print(delta.render())
        if bad:
            failed.append(engine)
    for engine in result["new"]:
        print(f"[new ] {engine} — measured here but not in the baseline "
              f"(record it with `evaluate {engine} --update-baseline`)")
    if result["unmeasured"]:
        print(f"[skip] not measured locally: {', '.join(result['unmeasured'])}")

    print()
    if failed:
        print(f"FAIL — {len(failed)} engine(s) moved materially: {', '.join(failed)}")
        print("Fixtures and references are fixed, so a moved number means the environment changed.")
        raise SystemExit(1)
    print(f"PASS — {len(result['engines'])} engine(s) reproduced their baseline numbers")


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

def cmd_status(args) -> None:
    d = run_dir(args.run)
    print(f"run: {d}")
    stages = [
        ("audio.wav", "prepare"), ("asr", "asr"), ("verbatim_draft.txt", "reference"),
        ("verbatim.txt", "review"), ("intended.txt", "intended"),
        ("cleanup.json", "cleanup"), ("results.json", "score"),
    ]
    for filename, stage in stages:
        path = d / filename
        mark = "✓" if path.exists() else "·"
        detail = ""
        if path.exists() and filename == "asr":
            detail = f"({len(_load_asr(d))} engines)"
        elif path.exists() and filename.endswith(".json"):
            data = load_json(path, {})
            if isinstance(data, dict):
                detail = f"({len(data.get('cells', data))} entries)"
        print(f"  {mark} {stage:<10} {filename:<20} {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", default=DEFAULT_RUN, help="run id under bench/runs/")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("prepare"); p.add_argument("recording"); p.set_defaults(fn=cmd_prepare)
    p = sub.add_parser("asr")
    # No `choices=`: an ad-hoc `family:model` spec must be accepted so a newly released model can be
    # run without editing this file. resolve_engine() validates and lists the known names on a typo.
    p.add_argument("--engines", nargs="*",
                   help=f"registered ({', '.join(ASR_ENGINES)}) or family:model, "
                        f"e.g. whisper:mlx-community/whisper-large-v3")
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--force", action="store_true")
    p.add_argument("--multi", action="store_true",
                   help="Apple runs with diarization (meeting audio) instead of --single")
    p.set_defaults(fn=cmd_asr)
    p = sub.add_parser("reference"); p.set_defaults(fn=cmd_reference)
    p = sub.add_parser("review")
    p.add_argument("--plain", action="store_true", help="line-based review instead of the TUI")
    p.add_argument("--contains", default=None,
                   help="only review sites where a vote matches one of these comma-separated words")
    p.add_argument("--undecided", action="store_true", help="skip sites already decided in a prior pass")
    p.add_argument("--min-support", type=float, default=0.0,
                   help="only review sites whose winning vote is below this fraction "
                        "(default 0.0 = review all; see the note in cmd_review)")
    p.set_defaults(fn=cmd_review)
    p = sub.add_parser("intended"); p.add_argument("--no-edit", action="store_true"); p.set_defaults(fn=cmd_intended)
    p = sub.add_parser("cleanup")
    p.add_argument("--backends", nargs="*", choices=list(CLEANUP_BACKENDS))
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--force", action="store_true")
    p.add_argument("--vocabulary", default=None, help="vocabulary.md to seed the cleanup workspace (default: the app's real one)")
    p.set_defaults(fn=cmd_cleanup)
    p = sub.add_parser("score")
    p.add_argument("--terms", default=None,
                   help="jargon term file or comma-separated list (default: <run>/terms.txt)")
    p.set_defaults(fn=cmd_score)

    p = sub.add_parser("evaluate", help="run one engine on both fixtures and rank it")
    p.add_argument("engine", help="registered name, or family:model (see --help-engines)")
    p.add_argument("--meeting-run", default=MEETING_RUN, help="run id of the long-form fixture")
    p.add_argument("--repeats", type=int, default=3, help="dictation-fixture repeats")
    p.add_argument("--meeting-repeats", type=int, default=1,
                   help="meeting-fixture repeats (1: a 57-minute file is its own sample)")
    p.add_argument("--cleanup", action="store_true",
                   help="also run the cleanup grid, for the best-pipeline number")
    p.add_argument("--backends", nargs="*", choices=list(CLEANUP_BACKENDS))
    p.add_argument("--vocabulary", default=None)
    p.add_argument("--terms", default=None)
    p.add_argument("--force", action="store_true", help="re-run even if results already exist")
    p.add_argument("--no-meeting", action="store_true", help="dictation fixture only")
    p.add_argument("--no-diarize", action="store_true",
                   help="skip diarization on the meeting fixture (Apple only)")
    p.add_argument("--meeting-budget", type=float, default=900.0,
                   help="seconds; above this projected wall clock, measure a slice instead (0=off)")
    p.add_argument("--meeting-slice", type=int, default=300, help="slice length in seconds")
    p.add_argument("--meeting-full", action="store_true", help="always run the full meeting file")
    p.add_argument("--update-baseline", action="store_true", help="record the numbers measured")
    p.add_argument("--baseline", default=None, help="baseline file (default: results/baseline.json)")
    p.set_defaults(fn=cmd_evaluate)

    p = sub.add_parser("baseline", help="the tracked table of previously measured engines")
    bsub = p.add_subparsers(dest="baseline_cmd", required=True)
    b = bsub.add_parser("show", help="print the baseline table")
    b.add_argument("--baseline", default=None)
    b.set_defaults(fn=cmd_baseline_show)
    b = bsub.add_parser("refresh", help="recompute the baseline from the run dirs")
    b.add_argument("--write", action="store_true", help="actually write (default: dry run)")
    b.add_argument("--meeting-run", default=MEETING_RUN)
    b.add_argument("--terms", default=None)
    b.add_argument("--baseline", default=None)
    b.set_defaults(fn=cmd_baseline_refresh)
    b = bsub.add_parser("check", help="fail if a baselined engine's numbers moved")
    b.add_argument("--engines", nargs="*", default=None)
    b.add_argument("--meeting-run", default=MEETING_RUN)
    b.add_argument("--terms", default=None)
    b.add_argument("--baseline", default=None)
    b.add_argument("--strict", action="store_true", help="fail on timing drift too")
    b.add_argument("--verbose", action="store_true", help="show metrics that did not move")
    b.set_defaults(fn=cmd_baseline_check)

    p = sub.add_parser("status"); p.set_defaults(fn=cmd_status)

    args = parser.parse_args()
    args.fn(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
