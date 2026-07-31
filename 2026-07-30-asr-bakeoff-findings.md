# ASR Pipeline Bake-off — Findings

Measured 30 July 2026. Seven on-device speech engines × five cleanup options = 35 pipelines, all
scored on the same audio. The result reorganised the app's architecture: the cleanup stage was
deleted, Parakeet TDT v3 became the only engine, and the macOS floor dropped from 26 to 15.

This file is the permanent record. The harness, runners, results, and design specs that produced
these numbers have been removed from the repo — they served their purpose and are not coming back.

## The setup

**Recording:** 116 seconds, 197 words, one speaker, one mic. Unscripted, disfluent, jargon-heavy
— a real project update from memory, not a script read aloud. This is load-bearing: a clean read
gives every cleanup backend identical output and the experiment measures nothing.

**Two references:**
- **Verbatim** — what was actually said, derived by ROVER-style consensus across all seven engines.
  The user reviewed only the words engines disagreed on (~20–40 of 197).
- **Intended** — what the user meant to say, edited from the verbatim text *before* looking at any
  pipeline's output. Scoring against the intended reference is what makes the ranking meaningful:
  deleting "um" is a feature, not a deletion error.

**Normalizer:** case-fold, strip punctuation, canonicalise numerals, expand contractions, collapse
whitespace. Applied identically to every hypothesis and every reference. Without it, engines that
emit punctuation (Whisper, Apple) are penalised relative to those that don't (Parakeet TDT) — the
most common failure mode in homemade ASR benchmarks.

**Timings:** warm — one pass discarded, median of three, models already resident. Cleanup is
nondeterministic, so every cleanup cell ran three times and the spread is reported alongside the
median.

## The grid

| ASR engines | Cleanup options |
|---|---|
| Apple `SpeechTranscriber` | none |
| Parakeet TDT v3 | Apple on-device Foundation Models |
| Parakeet TDT v2 | `qwen3.5:4b-mlx` (the shipped default) |
| Parakeet TDT-CTC-110M | `qwen3.5:9b-mlx` |
| Qwen3-ASR 0.6B | `gemma4:12b-mlx` |
| Qwen3-ASR 1.7B | |
| Whisper large-v3-turbo | |

Each ASR ran once; its transcript was fed to all five cleanup options. 7 ASR inferences + 28
cleanup cells, one afternoon of compute.

## Findings

### 1. The engine is the whole game

Across the seven engines, word error rate (WER) against the intended reference spans **19.1
points**. Within any single engine, swapping between all five cleanup options moves it by **1.0–3.6
points** — and usually about one.

The stage the user had spent months tuning was worth roughly a point. The stage they had never
touched was worth nearly twenty.

### 2. Cleanup frequently did nothing

**9 of 28** cleanup runs returned text identical to their input after normalisation. Apple's
on-device cleanup — the zero-setup default — was a no-op on **4 of 7** transcripts.

Cleanup cost **4–9 seconds** and bought about **1.1 points**. Parakeet transcribes the same 116
seconds in **0.44 seconds**. On that pipeline, cleanup was ~90% of the wall clock for about a
point.

### 3. The shipped pipeline lost on both axes

| Pipeline | WER/intended | RTFx |
|---|---|---|
| Apple `SpeechTranscriber` + Apple cleanup (shipped) | 38.1% | 101× |
| Parakeet TDT v3, raw | 25.3% | 263× |
| Parakeet TDT v3 + `qwen3.5:4b-mlx` | **24.2%** | 263× |

The paired improvement from swapping Apple's engine for Parakeet TDT v3 is **13.9 points** and
**2.6× faster** — both axes at once. Parakeet was also better on names and proper nouns (2 of 5
jargon terms recovered vs 1 of 5).

### 4. The most accurate engine was unusable for meetings

Qwen3-ASR 1.7B posted the best short-audio accuracy: **18.6%** WER, roughly half the shipped
error rate. On the 57.5-minute four-speaker meeting fixture it took ~38 minutes to process 57
minutes of audio — about 1.5× real time. Disqualified for the meeting feature.

### 5. Parakeet dominated on long audio

Same 57.5-minute, four-speaker recording:

| Engine | Wall clock | RTFx |
|---|---|---|
| Parakeet TDT v3 | **11.7 s** | 295× |
| Whisper large-v3-turbo | 84 s | 41× |
| Apple + diarization | 109 s | 32× |

Parakeet showed no quality drift across the hour. Local diarisation found exactly four speakers
across 179 turns, attributing 97% of the audio.

## Phase 0 findings (variant selection)

Before committing to the migration, three risks were measured:

### v3 chunk-boundary dropout — real, accepted

Parakeet TDT v3 with default settings has a 5.84s hole in its word timings at the first 15s chunk
boundary, silently losing ~6 words. On the 57-minute meeting this cost ~0.5% of content (58 words
of 10,511). `--no-mel-context` closes the hole but garbles the seam, costing 2.0 WER points and
24% more time — dominated by v2. `--dual-decode-arbitration` does nothing for this failure mode.

**Decision: v3 default.** Best accuracy (25.3%), accepting ~0.5% silent content loss for 2.5 WER
points over v2. Silent phrase loss is the failure mode a user cannot detect, unlike a garbled
word.

### CTC vocabulary boosting — works, over-fires, not adopted

Adding `--custom-vocab` with the app's vocabulary terms doubled jargon recall (2/5 → 4/5) with no
throughput cost (RTFx 256). But it substituted vocabulary terms for ordinary words: *"megabytes a
Sitecore"*, *"takes some Kimi GLM out"*. Dropping sub-6-char terms cut the WER penalty from 4.6 to
2.0 points, but visible nonsense survived.

**Decision: not adopted.** Jargon stays on the deterministic `Vocabulary.apply()` channel (exact
word-boundary replacement, zero false-substitution risk).

### Parakeet Unified — rejected

Unified won the intended-reference metric by 1.1 points (24.2% vs 25.3%) but only by recovering
v3's boundary dropout. It lost the verbatim comparison by 3.9 points, mangling *"summit pass
sitecore"* into *"I kind passed FIC core"*. It was 3.25× slower (75× vs 244× RTFx), had identical
jargon recall (2/5), and cannot support CTC boosting because it emits no timings.

**Decision: rejected.** TDT v3 serves both paths; first-run download falls from ~1.13 GB to 470 MB.

## What changed in the app

- Parakeet TDT v3 is the only ASR engine (Apple `SpeechTranscriber` deleted)
- The LLM cleanup/polish stage for dictation is deleted entirely
- Dictation is batch (MicCapturer → Parakeet → inject), not streaming
- Summarisation keeps all three providers (Apple on-device, Ollama, OpenAI-compatible)
- macOS floor dropped from 26 to 15
- First-run download: ~470 MB (Parakeet TDT v3 model)

## Methodology worth preserving

These design decisions are the part of the bake-off most likely to be useful again:

- **Two references** (verbatim + intended) so cleanup isn't penalised for removing disfluencies
- **Shared normaliser** applied identically to every hypothesis and reference, so engines aren't
  ranked by formatting
- **Paired comparison** — every pipeline sees the same audio, so passage difficulty cancels and
  per-cell deltas are far more precise than absolute WER
- **Position-binned recall** for long-form evaluation — the middle third of the meeting is where
  every model collapsed, invisible in aggregate scores
- **Blind preference ranking** as the tiebreaker for near-ties, not decimals
- **Cleanup nondeterminism accounted for** — three repeats per cell, spread reported alongside
  median
