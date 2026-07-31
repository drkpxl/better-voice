# ASR pipeline bake-off

Originally answered one question — **is the most accurate dictation pipeline Apple+Apple,
Apple+Ollama, or a dedicated ASR on its own?** — and the answer settled the app's architecture: a
dedicated ASR on its own. Design: [`specs/2026-07-30-asr-pipeline-bakeoff-design.md`](../specs/2026-07-30-asr-pipeline-bakeoff-design.md).

> **The cleanup grid is retired.** The LLM cleanup stage it measured was deleted from the app: it was
> worth ~0 WER points on the backend that shipped while costing most of the wait. `run_cleanup` now
> fails with a pointer to the historical numbers in
> [`results/2026-07-30-results.json`](results/2026-07-30-results.json) rather than invoking an app
> flag that no longer exists. Everything below about `./run.py cleanup` and the `best` column is
> kept because the recorded results are still valid; the stage is not re-runnable.

It is also a **repeatable regression test**: when a new speech model ships, one command scores it on
two fixed recordings and ranks it against every engine measured before. Start at
[Evaluating a new model](#evaluating-a-new-model).

Nothing here is part of the shipping app. The app-side additions are all under `#if BENCH`, which
`Package.swift` defines for debug builds only.

## Evaluating a new model

```bash
cd bench
./run.py evaluate qwen3-asr-1.7b                          # a registered engine
./run.py evaluate whisper:mlx-community/whisper-large-v3   # any repo an existing runner can load
```

One command runs the engine on both fixtures, scores the dictation one against the frozen
references, measures throughput and long-form stability on the meeting one, and prints where it lands
among previously measured engines. Add `--update-baseline` to record the numbers.
(`--cleanup` refers to the retired grid — see the note above.)

Nothing is re-measured unnecessarily: an engine already present in a run dir is reused unless you
pass `--force`. Running `evaluate` on an engine that is already in the baseline doubles as a
regression check on it.

`evaluate` never regenerates the reference transcripts. That is deliberate — see
[Why the references are frozen](#why-the-references-are-frozen).

### The two fixtures

| Run | Audio | What it measures |
|---|---|---|
| `runs/current` | 116s, 197 words, one speaker, spontaneous disfluent dictation | **WER.** Has a reviewed `verbatim.txt`, a hand-written `intended.txt` and `terms.txt`, so accuracy is meaningful |
| `runs/pod` | 3450s (57.5 min), 4 speakers, real meeting | **Throughput, long-form stability, diarization.** No reference transcript exists, so never WER |

`runs/` is gitignored and the meeting recording is confidential business discussion. Fixtures and
transcripts stay there; only aggregate numbers ever leave.

A slow engine is handled automatically. `evaluate` projects the meeting wall clock from the dictation
RTFx it just measured, and if that exceeds `--meeting-budget` (default 15 min) it measures a
`--meeting-slice` (default 300s) instead and labels the result `slice:300`. Slice and full-file
numbers are never compared to each other. `--meeting-full` forces the whole file;
`--meeting-budget 0` disables the guard.

## The baseline

`results/baseline.json` is the tracked table of everything measured so far, so comparisons survive
`runs/` being wiped. Aggregate numbers only — no transcript text, no samples, nothing derived from
what was said in the meeting.

```bash
./run.py baseline show               # the standing table
./run.py baseline check              # re-derive from runs/ and fail if a known engine moved
./run.py baseline refresh            # dry run: what would change
./run.py baseline refresh --write    # commit those numbers
```

`refresh` reads recorded results and never runs an engine, so it cannot quietly re-measure over a
regression. It is a dry run by default for the same reason: refreshing over a real regression is how
a bad number becomes the new expectation.

### Regression detection

`baseline check` exits non-zero when a previously measured engine no longer reproduces its numbers.
The fixtures and references are fixed and ASR is deterministic, so a moved number is **environment
drift, not the model** — a changed normalizer, an upgraded dependency, a new OS speech model in a
macOS update. Thresholds:

| Metric | Material change | Fails the check |
|---|---|---|
| WER (verbatim, intended, best-cleanup) | > 2 points absolute | yes |
| Meeting word count | > 5% relative | yes |
| Long-form stability verdict | any flip | yes |
| RTFx (either fixture) | > 25% relative | no — `--strict` to opt in |

Timing is excluded by default because a slow run is usually thermals or background load, and a check
that cries wolf gets ignored. Improvements are flagged too: on fixed audio, "better" still means
something changed that was not the model.

## Adding an engine

**Most new models need no code change at all.** If the model runs on a runtime that already has a
runner, pass a `family:model` spec:

```bash
./run.py evaluate whisper:mlx-community/whisper-large-v3     # -> label whisper-large-v3
./run.py evaluate qwen3-asr:Qwen/Qwen3-ASR-3B                # -> label qwen3-asr-3b
./run.py evaluate fluidaudio:v4                              # -> label fluidaudio-v4
./run.py evaluate my-label=whisper:mlx-community/whisper-tiny # explicit label
```

Families are `whisper` and `qwen3-asr` (MLX runners) plus `fluidaudio` (any `--model-version`
`fluidaudiocli` accepts). The label is derived from the repo tail and keys everything downstream —
the per-engine ASR file, the results table, the baseline row — so the same spec always lands on the
same row.

**To promote a model to a permanent name**, add one line to `engines.py`:

```python
MLX_ENGINES = {
    "qwen3-asr-3b": ("mlx_qwen3_runner.py", "Qwen/Qwen3-ASR-3B"),   # <- this
}
```

It then appears in `ASR_ENGINES` and runs as part of a bare `./run.py asr`. `FLUIDAUDIO_VERSIONS`
works the same way for CoreML models.

**A genuinely new runtime** is the only case needing real work: write `runners/mlx_<name>_runner.py`
as a PEP-723 script (`uv` isolates its dependencies) and register the family in
`engines.RUNNER_FAMILIES`. The contract is one JSON object on stdout, everything else on stderr:

```json
{"engine": "...", "text": "...", "cold_s": 1.2, "warm_s": 0.9, "runs": [1.2, 0.9], "error": null}
```

Optional but valuable: `segments` as `[{"start", "end", "text"}]` (or `wordTimings` as
`[{"word", "startTime"}]`). Without timings the long-form checks fall back to word-count and
repetition only — late collapse and dropouts become undetectable for that engine. Report `error` as a
string rather than raising; a broken dependency should fail one column, not the run.

Then: `./run.py evaluate <spec>`, read the numbers, `--update-baseline` if they are real.

## Long-form stability

The meeting fixture has no reference, so instead of accuracy it checks that the engine survived 57
minutes. Every failure mode here produces output that looks fine if you only read the first paragraph.

- **truncation** — word count far below the healthy band (~10,520 words on this fixture, the mean
  across engines that completed it). Only stable engines contribute to that band, or one truncating
  engine would drag the expectation down toward itself.
- **n-gram collapse** — the primary loop signal. Healthy output is 99.7%+ distinct 5-grams; a model
  stuck in a repetition loop lands near 60%. Enormous margin, no tuning.
- **late collapse / dropout** — word density per decile of *audio time*, plus how far the last timed
  word sits from the end of the file. Sliced by time, not by word index: a transcript covering only
  the first 40 minutes looks perfectly uniform sliced by index and obviously broken sliced by time.

FAIL is reserved for unambiguous breakage. **Consecutive phrase repetition is only ever a WARN** —
real speech stutters, the healthy Whisper transcript repeats a two-word phrase four times in a row,
and that is something the cleanup stage removes rather than evidence of a broken model. Thresholds are
calibrated against four healthy engines and tuned for zero false alarms on healthy input.

## Prerequisites

```bash
cd client && swift build          # builds BetterVoice2 with the BENCH CLIs
brew install ffmpeg               # canonical audio decode
ollama serve                      # for the Ollama cleanup backends
```

`uv` handles MLX dependencies per-runner; nothing needs a global install.

## The recording

Talk for ~2 minutes into QuickTime, ~250 words. **Speak naturally — do not read a script.** The
cleanup stage only has work to do if there are disfluencies, false starts, and self-corrections. A
clean read makes every cleanup backend look identical and the experiment measures nothing.

## Stages

The full pipeline, for building a fixture from scratch or re-running the whole grid. Evaluating a
single new model against existing fixtures does not need any of this — use `evaluate` above.

```bash
cd bench
./run.py prepare ~/Desktop/dictation.m4a   # -> 16kHz mono WAV, identical bytes for every engine
./run.py asr                               # every ASR engine, raw
./run.py reference                         # consensus draft + the sites worth reviewing
./run.py review                            # TUI: pick from engine votes -> verbatim.txt
./run.py intended                          # write what you MEANT -> intended.txt
./run.py cleanup                           # RETIRED: fails with a pointer to historical results
./run.py score --terms vocabulary.txt      # results.json + ranked table
./run.py status                            # what exists so far
```

Stages are resumable and skip completed work; `--force` redoes it. `--run <id>` keeps separate runs
side by side.

First `./run.py asr` downloads 8–12GB of models. Run one engine at a time to spread it out:
`./run.py asr --engines whisper-large-v3-turbo`.

## Review TUI

`./run.py review` opens a curses TUI. Nearly always the correct word is already one of the engine
votes, so the primary action is selecting, not typing.

```
↑↓ / jk   move between vote options        ⏎     accept, advance
1-9       jump straight to an option       e     type a word no engine got
p / space play ~3.5s of audio at the word  ←→    skip without deciding
q / esc   save progress and quit
```

Each site shows its audio timestamp, mapped onto the consensus tokens from whichever engine reports
word-level timings (Parakeet does; Apple only has coarse segment boundaries). `p` plays that moment
via ffplay so you can settle a contested word by ear instead of guessing.

Decisions are keyed by original token index, so deleting a word never shifts the positions of sites
you have not reviewed yet. `q` saves what you have decided so far — the run is resumable.

`--plain` gives a line-based fallback for dumb terminals or piped input. `--min-support 0.6` reviews
only low-agreement sites, but read the warning it prints first: the sites where the majority is
*wrong* are disproportionately the jargon sites.

## Why the references are frozen

`evaluate` scores a new engine against the existing `verbatim.txt` and `intended.txt` and never
rebuilds them, even though a new engine's votes could in principle improve the consensus.

That is the trade that makes this a regression test. Rebuilding the reference would change every
previously measured engine's WER at the same moment, so the baseline numbers would no longer be
comparable to the new one and the whole table would need re-measuring on every addition. A slightly
imperfect but *fixed* reference gives comparable numbers; a moving one gives none.

The cost is real: if a new engine is the only one hearing a jargon term correctly, the reference may
have that word wrong and the engine is penalized for being right. `terms.txt` and the `jargon` column
exist partly to make that visible. If the reference ever needs correcting, edit it, then re-run
`./run.py score` and `./run.py baseline refresh --write` to re-derive every engine on the new
reference in one pass.

## Why two references

`verbatim.txt` is what you actually said. `intended.txt` is what you meant to end up with.

Scoring pipelines against the verbatim text **inverts the answer**: deleting "um" counts as a
deletion error, so good cleanup scores worse and the table declares no-cleanup the winner. The
`WER/verb` column measures the ASR stage alone; `WER/int` is the one that ranks pipelines. The table
labels which it sorted by.

Write `intended.txt` *before* looking at any pipeline output. Deriving it from one pipeline's result
hands that pipeline an unearned win.

## Reading the results

- **WER/int** — end-to-end pipeline quality. The answer.
- **WER/verb** — ASR stage only. Diagnostic: explains *why* a pipeline won or lost.
- **spread** — a cleanup backend's run-to-run variance. LLM cleanup is nondeterministic, so a gap
  smaller than the spread is not a real difference. The table names cells tied with the leader.
- **jargon** — domain terms surviving verbatim, median across repeats. Pass `--terms` with a file
  (one term per line) or a comma-separated list, or the column stays empty.

~250 words is a single sample. It separates pipelines that differ substantially; it does not resolve
sub-point gaps. Break near-ties with a blind preference ranking, not decimals.

## Tests

```bash
for t in test_*.py; do python3 "$t"; done

python3 test_score.py       # normalizer + WER/CER + jargon recall
python3 test_consensus.py   # consensus voting, pivot choice, refusal guards
python3 test_review.py      # timestamp mapping + TUI decision logic
python3 test_longform.py    # long-form stability checks and their calibration
python3 test_baseline.py    # record building, regression thresholds, ranking
python3 test_engines.py     # engine spec resolution and label stability
```

The normalizer decides whether any of this means anything — engines differ in how much punctuation
and casing they emit, so unnormalized scoring would rank them by formatting rather than by what they
heard. `test_formatting_is_free` pins that down.

## Layout

| File | Role |
|---|---|
| `run.py` | stage driver, state under `runs/<id>/` |
| `engines.py` | engine invocation + spec resolution; failures become records with `error`, never exceptions |
| `score.py` | normalizer, WER/CER, jargon recall |
| `consensus.py` | ROVER-style voting + disagreement sites |
| `timings.py` | maps engine word timings onto consensus tokens |
| `longform.py` | long-form stability: truncation, degeneracy, late collapse, diarization coverage |
| `baseline.py` | tracked baseline I/O, regression thresholds, ranking |
| `review_tui.py` | curses review UI; all decision logic in `ReviewState` (pure, tested) |
| `runners/mlx_*.py` | PEP-723 scripts; `uv` isolates their deps |
| `results/baseline.json` | **tracked**: measured numbers per engine, aggregates only |

### Two invariants worth knowing before editing

- **ASR results are one JSON file per engine** under `runs/<id>/asr/`, and evaluation reports one per
  engine under `runs/<id>/evaluations/`. A shared file lost data once: two concurrent runs each loaded
  it, added their engine and wrote back, and a Whisper run erased a completed Apple diarization pass.
  `baseline.merge_engine` merges per fixture for the same reason.
- **The ASR stage workspace has no `vocabulary.md`; the cleanup stage does.** The app applies
  `Vocabulary.apply()` unconditionally on transcript text, so a vocabulary in the ASR workspace would silently
  correct Apple's transcript while the FluidAudio and MLX engines — which never pass through the app —
  got no such help. The asymmetry is what keeps the ASR comparison fair.
