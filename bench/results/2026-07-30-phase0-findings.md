# Phase 0 findings — measurements that decided the migration variant

Gates the plan in `specs/2026-07-30-parakeet-migration-plan.md`. Run 2026-07-30 on this Mac
(macOS 26.5.2, Apple Silicon), against the two committed fixtures.

## (a) The v3 chunk-boundary dropout — RESOLVED

**The defect is real.** On the dictation fixture (116s), Parakeet TDT v3 with default settings has a
5.84s hole in its word timings (14.24s → 20.08s) and silently loses *"I'm gonna speak naturally, et
cetera. Model cloud"* — content that **both** v2 and TDT-CTC-110M transcribed. Independently verified
by diffing word timings across all three variants.

### The documented fix works, but costs accuracy

| config | words | proc s | WER/verbatim | WER/intended | 15s hole |
|---|---:|---:|---:|---:|---|
| v3 default | 191 | 0.512 | 19.3% | **25.3%** | **YES — 5.84s** |
| v3 `--no-mel-context` | 195 | 0.508 | 21.7% | 27.3% | closed |
| v3 `--dual-decode-arbitration` | 191 | 0.477 | 19.3% | 25.3% | YES — 5.84s |

`--no-mel-context` closes the hole and recovers the content, but **garbles the seam while doing it** —
the recovered text reads *"two words., It into's quick time. I'm speak naturally, etc."* That is why
WER gets 2.0 points worse rather than better: it trades a clean omission for a messy join.

**`--dual-decode-arbitration` does nothing for this failure mode** — byte-identical output to default.
Worth recording, because the plan listed it as the fallback if the mel fix failed. It is not a
fallback for this.

### Scale check on the 57-minute meeting

The dictation fixture has ~8 chunk boundaries; the meeting has ~230. If the dropout recurred at every
boundary it would be disqualifying.

| config | words | proc s | gaps >2s | boundary-aligned gaps |
|---|---:|---:|---:|---|
| v3 default | 10,511 | 11.71 | 43 (188s total) | 11 (51s) |
| v3 `--no-mel-context` | **10,569** | 14.30 | 34 (148s) | 9 (38s) |
| v2 | 10,498 | **10.91** | **33 (123s)** | 9 (33s) |

**Read this carefully — two of these columns are weak evidence.** Most gaps >2s in a 57-minute
four-person discussion are genuine silence between speakers (43 gaps totalling 188s is ~5% of
runtime, entirely plausible), and the boundary-alignment heuristic is unreliable when 43 gaps are
scattered across 230 boundaries — coincidental alignment is likely.

The trustworthy signal is the word count: **`--no-mel-context` recovered 58 words that v3 default
missed**, consistent in direction with the dictation finding. So the dropout is real at scale but
costs roughly **0.5% of content**, not a catastrophe.

### What this eliminated

**`v3 --no-mel-context` is dominated and should not be considered further.** At 27.3% it is
statistically tied with v2's 27.8% (inside the sub-1-point tie band this project established), while
being **24% slower** than v2 on the meeting (14.30s vs 10.91s) and requiring a non-default flag.
There is no dimension on which it wins.

That reduced the variant question to a genuine two-way trade:

- **v3 default** — 25.3% WER, 11.71s, loses ~0.5% of content silently at boundaries
- **v2** — 27.8% WER, 10.91s, keeps the content, English-only, no flags

### Decision: v3 default

The owner chose v3 default — best accuracy, accepting the ~0.5% silent content loss for 2.5 WER
points. Noted as a real trade rather than a free win: **silent phrase loss is the failure mode a user
cannot detect**, unlike a garbled word. The choice also preserves multilingual capability in reserve,
which partially hedges the separate English-only decision.

## (b) Cold CoreML compile + first load — DROPPED, will not be measured

Owner's call, 2026-07-30: not worth the cost. The measurement is destructive (`clearModelCache` plus
a 470 MB re-download) and would invalidate every warm timing above, while the mitigation — a launch
warm-up — is going in regardless of what the number turns out to be. Measuring it could not change
the design.

Known bound if it ever matters: process-cold wall clock with `.mlmodelc` already compiled and the
page cache warm is 0.712s. FluidAudio's only published cold figures are iPhone
(`Documentation/Benchmarks.md:73-80`: encoder 3.36s cold / 0.16s warm on iPhone 16 Pro Max).

## (c) CTC vocabulary boosting — RUN. Real gain, real cost, needs tuning before adoption

Vocabulary built from the app's own `vocabulary.md` plus the jargon the recording actually contains
(`vocab.txt`, 9 terms). CLI path: `transcribe --custom-vocab <file>`, which pulls the 99MB
`parakeet-ctc-110m-coreml` encoder.

| config | WER/intended | jargon recall |
|---|---:|---|
| v3 default | **25.3%** | 2/5 |
| + boosting, 9 terms | 29.9% | **4/5** |
| + boosting, 5 "safe" terms (`vocab2.txt`) | 27.3% | **4/5** |

**It doubles jargon recall — 2 of 5 to 4 of 5.** That is the metric the owner cares most about, and
the gain is unambiguous.

**It also over-fires badly**, substituting vocabulary terms for ordinary words. With all 9 terms:
*"I don't **QuickTime Emmie**"* for "I don't know. Okay.", *"for me to **Sitecore** in"* for "to
record in", *"each pod's **GLM** is"* for "capacity is", *"megabytes a **Sitecore**"* for "a second",
*"takes some **Kimi GLM** out"* for "takes some time it turns out". This is the documented failure
mode — short terms colliding acoustically with common English — at greater severity than the docs'
"12 false positives".

**Vocabulary hygiene recovers most of it.** Dropping the three short terms (`GLM`, `Kimi`, `Emmie`)
keeps jargon at 4/5 while cutting the WER penalty from 4.6 points to 2.0. Some false positives
survive even then (*"I don't QuickTime it's recording"*, *"for me to Sitecore in"*).

**Throughput is a non-issue.** RTFx 256 with boosting active, against 244–263 without. The docs'
warning of ~26 RTFx (2.3s on a 60s dictation) did not materialise on this hardware, which removes the
latency objection entirely and changes the shape of the decision.

**Assessment.** The trade at best is +2 jargon terms for −2.0 WER points, with residual visible
nonsense. That is not obviously worth shipping as-is on either path. What it does establish is that
the *mechanism works* — the terms genuinely get recovered — so the remaining problem is threshold
tuning, not capability. `ContextBiasingConstants.rescorerConfig(forVocabSize:)`, `minTermLength`, and
disabling the acoustic spotter rescue are all documented knobs, **none exposed as CLI flags**, so
tuning requires calling the API directly.

**Recommendation:** do not adopt on either path yet. Revisit only with threshold tuning through the
API and a vocabulary that excludes sub-6-character terms. Note this partially reverses the owner's
Q7 decision (adopt split-by-path): the latency objection is gone, but the false-positive cost is
worse than the plan assumed.

## (d) Parakeet Unified as a dictation candidate — RUN. Rejected.

| engine | WER/verbatim | WER/intended | jargon | RTFx | words |
|---|---:|---:|---|---:|---:|
| Unified int8 | 23.2% | **24.2%** | 2/5 | 75 | 189 |
| Parakeet TDT v3 | **19.3%** | 25.3% | 2/5 | **244** | 191 |

**The two references disagree, and that is the finding.** Unified wins the headline metric by 1.1
points *because it recovers the content v3 drops* — its output covers the 15s region v3 loses. It
loses the verbatim comparison by 3.9 points because it mangles jargon badly: **"I kind passed FIC
core"** where v3 gives "summit past. Sitecore" against a reference of "summit pass sitecore". So the win
is bought entirely by fixing the boundary defect, not by hearing better.

**Unified is 3.25x SLOWER on this audio** — 75x RTFx against v3's 244x. This directly contradicts
FluidAudio's `Documentation/Benchmarks.md:96-99`, which claims Unified has the higher RTFx. Another
instance of Correction 5: measure, do not trust the docs.

It also carries 3 mid-sentence capitalization seams (v3 has 0), needs 565MB, is English-only, and —
permanently — cannot support CTC jargon boosting because it emits no timings.

**Decisive: jargon recall is identical at 2/5.** It buys nothing on the metric that matters most.

**Decision: rejected.** The owner reversed the earlier Q9 "adopt for dictation" call. TDT v3 serves
both paths; first-run download falls from ~1.13GB to 569MB (470MB if CTC boosting is also dropped per
(c) above). Side effect worth noting: Unified was the main reason English-only mattered, so with it
gone, English-only becomes a pure scope choice rather than an engine-forced one, and Q3 is cheaply
revisitable.

**Toolchain note.** `fluidaudiocli transcribe` cannot reach Unified — `--parakeet-variant` takes
`StreamingModelVariant` values (EOU chunk sizes), and `unified-benchmark`'s main path downloads
LibriSpeech. The way in is `unified-benchmark --input <file>`, a seam-comparison mode that transcribes
with both Unified and TDT and writes both transcripts.

## (d-old) notes

**Toolchain note for whoever picks this up:** `fluidaudiocli transcribe` **cannot** reach Unified.
`--parakeet-variant` takes `StreamingModelVariant` values (the EOU chunk sizes), not Unified, and
the main `unified-benchmark` path downloads LibriSpeech rather than accepting a file.

The way in is `unified-benchmark --input <file>`, which routes to a seam-comparison mode that
transcribes the given file with **both** Unified and TDT and writes both transcripts out. That is
usable for a fixture comparison even though it was not built for it.

## (e) v2 vs v3 head-to-head on English — DONE, folded into (a)

Both tables above are English-only comparisons, so this is answered: v3 default leads v2 by 2.5
points on the dictation fixture (25.3% vs 27.8%) and v2 is 7% faster on the meeting. English-only
removed v3's multilingual advantage but not its accuracy advantage.
