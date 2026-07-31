# ASR + Cleanup Pipeline Bake-off — Design

**Date:** 2026-07-30
**Status:** Approved, not yet implemented
**Branch:** `asr-pipeline-bakeoff`

## Problem

The app ships a two-stage dictation pipeline — Apple `SpeechTranscriber` for ASR, then a
configurable LLM for cleanup — and **there is no evidence the shipped default is the best
configuration.** Specifically, we cannot currently answer:

1. **Is the cleanup stage earning its keep?** `RuntimeConfig.swift:163` flips the polish backend
   between `{"api": "apple"}` (on-device `FoundationModelsBackend`) and
   `{"api": "ollama", "model": "qwen3.5:4b-mlx"}`. Nobody has measured which is more accurate, or
   whether either beats no cleanup at all.
2. **Is Apple `SpeechTranscriber` the right ASR?** `ImportPipeline.swift:136` and
   `VoiceSession.swift:87` both hardcode it. Dedicated ASR models (Parakeet, Qwen3-ASR, Whisper)
   may hear better — or may be accurate enough alone that the cleanup stage becomes unnecessary.
3. **Does jargon survive?** Resort names, lift names, and Summit Pass terminology are the errors that
   actually annoy the user in daily use, and no metric tracks them.

The question is a **pipeline** comparison — `ASR × cleanup` — not an engine bake-off.

## Decisions (from the user)

- **Compare pipelines, not engines.** The three candidate shapes named were Apple+Apple,
  Apple+Ollama (e.g. Gemma), and direct-ASR-alone. The design runs the full grid so a winning
  combination none of us named (e.g. Parakeet + Gemma) cannot be structurally missed.
- **Gemma is the cleanup stage, not an ASR.** `gemma4:12b-mlx` receives *text* from
  `PolishClient`. Gemma 4's 30-second audio cap is therefore irrelevant to this experiment.
- **One recording, ~250 words, spoken once.** Recorded in QuickTime. No scripted passages, no
  per-clip recording session.
- **Ground truth is not hand-transcribed.** Derived by consensus across engines, user reviews only
  the disagreements.

### Corrections of record

Assumptions that were wrong during design, recorded so they are not re-litigated:

- **Qwen3-ASR is 0.6B and 1.7B**, not 0.8B/4B. Apache-2.0 open weights; the official repo is
  transformers/vLLM only, but community MLX runtimes exist (`qwen3-asr-mlx`, `mlx-qwen3-asr`).
- **No ASR engine refactor is required.** FluidAudio ships `fluidaudiocli`
  (`FluidAudio/Package.swift:16`) with `transcribe <wav> --model-version {v2,v3,tdtCtc110m}`
  (`AsrModelVersion`, `AsrModels.swift:5-11`). The Parakeet side costs zero changes to the app.
- **`qwen3.5:4b-mlx` and `9b-mlx` are text-only.** They have no audio encoder and cannot appear in
  the ASR column; they are cleanup candidates only.
- **No ASR models are currently downloaded.** `~/Library/Application Support/FluidAudio/Models/`
  holds only `speaker-diarization`. Expect 8–12GB of first-run downloads.

## Design

### 1. Recording protocol

One continuous take, ~250 words (~2 minutes), recorded in QuickTime.

**The user must speak naturally, not read.** This is load-bearing: the cleanup stage only has work
to do if there are disfluencies, false starts, and self-corrections. A clean read would make
Apple+Apple and Apple+Gemma produce near-identical output and the experiment would measure nothing.
The recording should be a real project update or meeting recap from memory, with the user's normal
jargon and normal verbal mess.

No chunking or splitting is needed anywhere — every engine in the grid accepts 2 minutes of audio,
and the cleanup stage receives text.

### 2. Two references from one recording

WER against a **verbatim** reference would punish good cleanup: deleting "um" scores as a deletion
error, so verbatim scoring ranks *no cleanup* as the winner and inverts the real conclusion. The
experiment therefore needs two references:

| Reference | Derived from | Scores |
|---|---|---|
| **Verbatim** | ROVER-style consensus across all ASR outputs; user reviews only words where engines disagree (~20–40 of 250) | The ASR stage alone — which engine *hears* best |
| **Intended** | User edits the verbatim text once into what they meant to say | Each pipeline end-to-end — the question being asked |

**Anchoring guard:** the intended reference is edited from the *verbatim* text (engine-neutral) and
must be written **before** the user sees any pipeline's output. Deriving it from a pipeline result
would hand that pipeline an unearned win.

**Alignment guard:** consensus voting requires all ASR outputs to align to the same utterance. The
scorer asserts that every engine produced a non-empty transcript and that pairwise alignment
coverage exceeds a floor before voting; it refuses to emit a reference on failure rather than
silently voting on a garbage alignment.

### 3. The grid — 7 ASR × 5 cleanup

**ASR:** Apple `SpeechTranscriber` · Parakeet TDT v3 · Parakeet TDT v2 · Parakeet TDT-CTC-110M ·
Qwen3-ASR 0.6B · Qwen3-ASR 1.7B · Whisper large-v3-turbo

**Cleanup:** none · Apple `FoundationModelsBackend` · `gemma4:12b-mlx` · `qwen3.5:4b-mlx` (current
default) · `qwen3.5:9b-mlx`

The full 35-cell grid (28 cleanup cells + 7 raw-ASR cells) is affordable because **each ASR runs
exactly once** and its transcript is reused across all five cleanup options: 7 ASR inferences plus
84 local LLM calls on ~250 words each (28 cells × 3 repeats, per §6). Estimated 30–45 minutes of
compute after downloads.

### 4. Harness architecture — `bench/` (new, standalone)

A directory outside the app target. One JSON contract: a runner takes a WAV path and emits one
JSON line, `{"engine", "text", "load_s", "transcribe_s"}`. Runners are independent processes, so a
broken MLX dependency fails one column instead of the whole run.

| Stage | Engine | Invocation |
|---|---|---|
| ASR | Apple | app's `--bench-meeting <wav> --single --output <tmp>` |
| ASR | Parakeet v3 / v2 / 110M | `swift run fluidaudiocli transcribe <wav> --model-version <v>` |
| ASR | Qwen3-ASR 0.6B / 1.7B | `uv run` + `qwen3-asr-mlx` (PEP-723 inline deps) |
| ASR | Whisper large-v3-turbo | `uv run` + `mlx-whisper` |
| Cleanup | all five | app's `--bench-polish` (see §5) |

`uv` and `ffmpeg` are already installed; MLX is not and will be fetched per-runner by `uv`.

### 5. `--bench-polish` extensions (the only app-side change)

Three gaps make the current CLI unfit for the grid, all inside the existing `#if BENCH` block
(`BetterVoice2App.swift:28-43`), so there is no product risk:

1. **Hardcoded scratch root** (line 34) — `SupportDir.configure(root:)` is pinned to
   `NSTemporaryDirectory()/bettervoice2-bench`, so backend selection would mean mutating one fixed
   `config.json` and concurrent runs would race. Add `--workspace <dir>`, matching
   `--bench-meeting`'s existing flag.
2. **Prose output** — prints `INPUT:`/`OUTPUT:` lines. Parsing an `OUTPUT: ` prefix breaks on
   multi-line cleanup results. Add `--json`.
3. **Vocabulary silently empty** — vocabulary reaches the prompt via
   `Vocabulary.shared.promptBlock` (`PolishClient.swift:26`), which reads
   `<SupportDir>/vocabulary.md`. Because the CLI pins `SupportDir` at an empty scratch dir the
   prompt gets no terms, and jargon recall would understate the real app. Fixed by `--workspace`
   pointing at a dir containing `vocabulary.md`; the CLI reports `vocabulary_terms` so the harness
   can assert the terms loaded rather than trusting that they did.
4. **No safe backend selection** — the backend comes from `RuntimeConfig`, and `updateSection` /
   `updateTopLevel` both call `save()` → `UserDefaults.standard.set`. Switching backends through the
   normal API would therefore *permanently rewrite the user's real polish settings* as a side effect
   of running a benchmark. Added `RuntimeConfig.benchPolishServerOverride`, a read-through in-memory
   override under `#if BENCH`, driven by `--api` / `--model` / `--endpoint`.
5. **Cold-load timing** — measured on this box: a cold Ollama call paging `gemma4:12b-mlx` into
   memory took **7.00s**, where the next identical call took **0.73s**. Reporting the first number as
   the model's speed would be a 10x error. Added `--warmup N` (discarded) alongside `--repeats N`.

**Correction to an earlier draft of this spec:** it claimed `words: []` bypassed vocabulary
injection. That was wrong. `PolishClient`'s `words:` parameter is never referenced in the function
body, and *all three* callers (`BetterVoice2App.swift`, `ImportPipeline.swift:303`, `:349`) pass
`[]` — it is dead parameter surface app-wide, unrelated to vocabulary.

### 6. Scoring

All metrics computed in the harness, not the app.

- **WER / CER vs verbatim** — ASR stage quality.
- **WER / CER vs intended** — end-to-end pipeline quality.
- **Jargon recall** — of the domain terms present in the intended reference, how many survive
  verbatim. Term list is drawn from the app's existing `Vocabulary` store, plus any additional
  terms the user marks while writing the intended reference; it is fixed before scoring so the
  metric cannot be tuned to a result. The metric the user actually cares about day to day.
- **Latency** — `load_s` and `transcribe_s` reported separately per ASR (cold load is a real UX
  cost but is not throughput), plus cleanup latency. One warmup pass discarded, 3 repeats, median
  reported. Peak RSS captured, since a 12B resident model is a different product decision than a
  110M one.
- **Blind preference ranking** — the user ranks a **shortlist** with labels hidden: the top cell per
  cleanup backend by end-to-end WER, plus the best raw-ASR cell, so ~6 outputs rather than 35.
  Ranking 35 near-identical paragraphs is not a task a human does reliably. For a rewriting stage
  this ranking is more authoritative than any string metric, and it is the tiebreak of record.

**Cleanup is nondeterministic.** The ASR stage is deterministic per engine, but LLM cleanup varies
run to run. Comparing four cleanup backends on one sample each could easily produce a ranking that
is sampling noise. Each cleanup cell therefore runs **3 times**, all three are scored, and the
spread is reported alongside the median. A backend whose spread exceeds its gap to a rival is
reported as tied with it. Cleanup runs at whatever temperature the shipping path uses — the goal is
to measure the app's real behavior, not an artificially greedy variant of it.

**Shared normalizer, applied identically to every hypothesis and every reference:** case-fold,
strip punctuation, canonicalize numerals (`25` ↔ `twenty-five`), expand contractions, collapse
whitespace. Without it the comparison is actively misleading — Whisper and Apple emit punctuation
and casing, Parakeet TDT emits neither, so raw scoring would penalize models *for being more
featureful*. This is the most common failure mode in homemade ASR benchmarks, so **the normalizer
gets its own unit tests** and is the one piece of harness code written test-first.

### 7. Deliverable

A published chart: WER on one axis, RTFx on the other, one point per pipeline cell, encoded so the
ASR and cleanup factors are separably visible — the Pareto view that makes dominated combinations
obvious. Plus the raw 35-cell table and per-metric breakdown so a surprising cell can be traced
back to a specific output.

## Statistical honesty

~250 words is a **single sample**. It is enough to separate pipelines whose accuracy differs
substantially, and the comparison is *paired* — every pipeline sees the same audio, so
passage difficulty cancels and per-cell deltas are far more precise than absolute WER would be.

It is **not** enough to trust small gaps. Two cells within roughly a point of each other should be
reported as tied, and the blind preference ranking should decide. If separating near-ties matters
later, the fix is more recordings, which is cheap once the harness exists.

## What this will not tell you

- **Nothing about meeting audio.** One speaker, one mic, no crosstalk, no phone-mic compression.
  This measures the dictation path.
- **Nothing about diarization.** Untouched; it already has its own scorer
  (`BetterVoiceCore/DiarizationScoring.swift`) and ground-truth sidecar convention.
- **Nothing about streaming latency-to-first-word**, which is what actually governs how dictation
  *feels*. All ASR here runs in batch mode. Parakeet EOU and the Nemotron streaming variants exist
  in FluidAudio and are a separate follow-up.
- **Nothing about first-run UX cost.** An 8–12GB download and a resident 12B model are real product
  objections that a WER chart does not capture.

## Out of scope

- Shipping a user-facing model picker. The transcriber abstraction stays out of the app entirely;
  the point of this experiment is to learn whether such a feature is worth building.
- SenseVoice and Paraformer-zh (need a separate `SenseVoiceManager` adapter, not exposed by
  `fluidaudiocli`).
- Long-form and multi-speaker evaluation.
