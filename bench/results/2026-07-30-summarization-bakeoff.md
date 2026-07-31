# Summarization bake-off — which local model should be the default

Run 2026-07-30 on this Mac against the 57.5-minute four-speaker meeting fixture (`bench/runs/pod`,
gitignored). Scoring is deterministic against a hand-authored key; no judge model was used, because a
local model cannot credibly rank its own family and the fixture cannot go to a cloud judge.

> ### ⚠️ SUPERSEDED 2026-07-31 — this run did not measure the shipping pipeline
>
> Every number below comes from runs against `summary_input_raw.txt` (anonymous `S1`–`S4` speaker
> labels, uncorrected jargon), and the `--no-context` runs additionally suppressed the **vocabulary**
> block, because `bench/summarize.py` coupled it to personal context behind one flag. The app always
> sends vocabulary and runs `Vocabulary.shared.apply` on transcript text, so the models here produced
> `iSummit` and `SiteCore` where the app produces `Summit Pass` and `Sitecore`. **The bake-off
> benchmarked a pipeline worse than the one that ships**, and the ranking below is an artifact of
> that.
>
> The harness is fixed (`--no-personal-context` and `--no-vocabulary` are now separate). Re-run in the
> shipping configuration — named speakers, vocabulary sent, current prompt — thread recall is a
> **three-way tie at 72.7%** between `ornith:9b`, `gemma4:12b-mlx` and `qwen3.5:9b-mlx`, with
> `qwen3.5:4b-mlx` at 56.8%. Recall no longer discriminates; the default was chosen by reading the
> summaries. **`ornith:9b` is the default** — see decision row 12 in
> `specs/2026-07-30-parakeet-migration-plan.md`.
>
> Also void: `bench/runs/pod/judge/verdict.md`, the blind judged ranking, which scored these same
> degraded summaries. Its findings — including that `qwen3.5:9b-mlx` fabricated an agreement — have
> not been reproduced against the corrected runs and should not be cited.
>
> What survives the correction: the personal-context template bug (real, and the fix stands), the
> scoring-key over-crediting audit, the `num_ctx`/`num_predict` finding, and the observation that
> recall rewards verbosity. Regenerate the comparison with `bench/summary_compare.py`.

**Original verdict (retained for the record, no longer accurate): `gemma4:12b-mlx` leads on clean
input and post-fix, but `qwen3.5:9b-mlx` closes to within 7 points and is 1.6x faster. Keeping the 9b
as the default is a defensible trade — but only after the personal-context fix below; as the app
shipped before it, the 9b was 25 points behind. `ornith:9b` wins on the raw pre-fix input and is worth
watching, with caveats. `qwen3.5:4b-mlx` is not a contender.**

Four models scored: `gemma4:12b-mlx`, `qwen3.5:9b-mlx`, `qwen3.5:4b-mlx`, `ornith:9b`. Apple
on-device is deliberately out of scope — its 4,096-token window forces map-reduce on any real meeting,
which the owner ruled out rather than benchmark.

## Results

Thread recall against `gold/key.json` (18 weighted threads). `1st/mid/fin` are recall within each
third of the meeting timeline. `s` is wall clock.

| input | model | recall | 1st | mid | fin | decisions | act | unassigned | invented | s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| — | **Opus reference** | **95.5%** | 82% | 100% | 100% | 88.9% | 12 | 0 | 0 | — |
| clean | **gemma4:12b-mlx** | **75.0%** | 82% | 72% | 73% | 66.7% | 5 | 2 | 0 | 77.7 |
| clean | **qwen3.5:9b-mlx** | **68.2%** | 82% | 56% | 73% | 66.7% | 5 | 0 | 0 | 43.2 |
| raw (shipping) | ornith:9b | 68.2% | 82% | 56% | 73% | **100%** | 8 | **5** | 0 | 53.1 |
| raw, no ctx | gemma4:12b-mlx | 68.2% | 82% | 56% | 73% | 66.7% | 5 | 0 | 0 | 78.5 |
| raw (shipping) | gemma4:12b-mlx | 65.9% | 55% | 56% | 87% | 77.8% | 5 | 1 | 0 | 81.8 |
| clean | ornith:9b | 63.6% | 82% | 72% | 40% | 88.9% | 8 | 1 | 0 | 52.5 |
| raw, no ctx | qwen3.5:9b-mlx | 61.4% | 82% | 56% | 53% | 77.8% | 7 | 0 | 0 | 48.1 |
| raw, no ctx | ornith:9b | 56.8% | 82% | 56% | 40% | 66.7% | 7 | 2 | 0 | 50.4 |
| clean | qwen3.5:4b-mlx | 45.5% | 55% | 33% | 53% | 33.3% | 5 | 0 | 0 | 25.5 |
| raw (shipping) | qwen3.5:4b-mlx | 40.9% | 55% | 22% | 53% | 55.6% | 4 | 0 | 0 | 25.8 |
| raw (shipping) | qwen3.5:9b-mlx | 40.9% | 55% | 22% | 53% | 66.7% | 4 | 0 | 0 | 44.9 |
| raw, no ctx | qwen3.5:4b-mlx | 22.7% | 27% | 11% | 33% | 33.3% | 4 | 0 | 0 | 24.7 |

`unassigned` counts action items whose owner is `[unassigned]`, `[Team]` or similar. It is broken out
because the owner-format check counts those as compliant, which flatters a model that declines to
attribute — 5 of ornith's 8 items carry no real owner.

### Post-fix ranking is the one that matters

With the personal-context bug fixed (the `no ctx` rows, now the shipping behaviour):

| rank | model | recall | s | disk |
|---:|---|---:|---:|---:|
| 1 | gemma4:12b-mlx | 68.2% | 78.5 | 6.8 GB |
| 2 | **qwen3.5:9b-mlx** | **61.4%** | 48.1 | 8.9 GB |
| 3 | ornith:9b | 56.8% | 50.4 | 5.6 GB |
| 4 | qwen3.5:4b-mlx | 22.7% | 24.7 | 4.0 GB |

Keeping `qwen3.5:9b-mlx` as the default costs 6.8 points against gemma and saves 30 s per meeting.
That is a reasonable trade and it is the owner's call. `qwen3.5:4b-mlx` should not be a default under
any configuration.

### ornith:9b — best on bad input, and the reason to distrust recall alone

`ornith:9b` is a qwen3.5-architecture 9B at Q4_K_M, against `qwen3.5:9b-mlx`'s nvfp4 MLX build — same
family and parameter count, different quantisation and runtime. It is the **only model that scores
best on the raw, as-shipped input** (68.2%) and it degrades when the input improves, which is the
opposite of every other model here. It also caught the two-phase propose-then-workshop thread that
*every* other model missed, and hit 9 of 9 decisions.

Three reasons not to read that as a win:

1. **Its recall is partly verbosity.** At 2,973 characters it has the *lowest* recall-per-1,000-chars
   in the leading group (22.9 against `qwen3.5:9b-mlx` clean at 30.5). The scorer measures recall
   only, so length is rewarded. (Density is a verbosity check, not a quality metric — the Opus
   reference scores worst on it at 12.6, because it is deliberately exhaustive.)
2. **5 of its 8 action items have no owner.**
3. **It conflated two people, and no metric caught it.** It rendered the more-senior stakeholder's
   name as the 2-occurrence spelling rather than the 11-occurrence one, and attributed a
   next-week absence to that person where the transcript attributes it to a separately named
   individual. Both names occur in the transcript, so the invented-name guard passes cleanly.

**The scorer has no precision metric.** That is its main known weakness: it cannot see a
confidently-worded misattribution, and it rewards a summary that gestures at everything. Recall is
the right primary signal for "did the summary cover the meeting", but it should not be the only one,
and the ranking above should be read with that limit in mind.

`raw` = the diarized Parakeet transcript with `S1`–`S4` labels, exactly what the app builds today.
`no ctx` = same, with the personal-context and vocabulary blocks withheld. `clean` = jargon corrected
and real speaker names substituted (`gold/corrections.json`).

## Input hygiene is worth as much as the model upgrade

The single most useful number here is not the ranking. It is that for `qwen3.5:9b-mlx`:

| change | recall | delta |
|---|---:|---:|
| as shipped | 40.9% | — |
| fix the personal-context bug | 61.4% | **+20.5** |
| clean jargon + real speaker names | 68.2% | **+27.3** |
| *(for comparison)* swap the model to gemma4:12b, inputs untouched | 65.9% | +25.0 |

Fixing the inputs buys more than replacing the model. That reframes the question the bake-off was
asked to answer: the default model matters less than what the app feeds it.

## Bug: an unedited `personal-context.md` is injected as if it were real context

`PersonalContext.load()` (`client/Sources/PersonalContext.swift:58-62`) returns the file whenever
`trimmed.isEmpty` is false. A freshly created `personal-context.md` is the 500-char starter template —
not empty. So `appended(to:)` wraps it in *"The following background describes the speaker and their
world"* and ships the model a blank form complete with its own instructions (*"Edit freely. Useful
things to include: - Your name and how it's spelled."*), on **every dictation polish and every meeting
summary**, for any user who never filled it in. This box is one of them: all three sections are empty.

Measured effect of removing it, same model, same transcript:

| model | with template | without | delta |
|---|---:|---:|---:|
| qwen3.5:9b-mlx | 40.9% | 61.4% | **+20.5** |
| gemma4:12b-mlx | 65.9% | 68.2% | +2.3 |
| qwen3.5:4b-mlx | 40.9% | 22.7% | **−18.2** |

Note the sign flips. This is not "removing it helps" — it is a large uncontrolled perturbation whose
direction depends on the model. That is the argument for fixing it: the app should not be sending a
blank form to the model at all, and the measured cost of doing so is up to 20 points in either
direction.

Fix: compare against `PersonalContext.template`, or require content under at least one heading.

## Every model collapses in the middle of the meeting

Recall by position, best result per model across all configurations:

| model | first third | middle third | final third |
|---|---:|---:|---:|
| Opus reference | 82% | **100%** | 100% |
| gemma4:12b-mlx | 82% | **72%** | 87% |
| qwen3.5:9b-mlx | 82% | **56%** | 73% |
| qwen3.5:4b-mlx | 55% | **33%** | 53% |

The middle is the worst bin for all three, by 15–30 points. On the shipping configuration both qwen
models scored 22% there. Three of the meeting's substantive threads sit in that bin — including one
that ran for roughly a fifth of the meeting — and they are the ones that vanish.

This is why the key bins by position. Prose quality, length, structure compliance and hallucination
checks were all *identical* between models that differed by 25 points of recall. Only position-binned
recall separated them.

## What did not go wrong

Worth recording, because these were the risks the design worried about:

- **Zero invented names, all nine runs.** The prompt's *"Never invent names or facts"* rule held on
  every local model. The soft flag list caught only ordinary sentence-initial words.
- **Zero invented numbers.**
- **100% structure compliance.** Every run emitted `## Summary`, `## Key points` and `## Action
  items`, and every action item carried an explicit `[owner]`. The format contract is reliable.
- **Every run produced a usable inline `TITLE:` line.** The documented title failure is specific to
  Apple's map-reduce path, not to single-shot providers.

## Methodology notes

**The first version of the key over-credited by ~30% and was rebuilt.** Schema 1 scored a thread as
covered if *any* one keyword appeared. Generic words did most of the damage: `phase` matched an
unrelated use of "transition phase", `Express` matched a passing mention rather than the blocker being
described, and `transparen` matched generic prose rather than the specific thread it was keyed to.
Under that key `qwen3.5:4b-mlx` appeared to *beat* gemma (68.2% vs 65.9%), which contradicted hand
reading. Schema 2 requires one hit from every group in `all_of` — a conjunction of disjunctions. After
the rebuild all hits survive hand adjudication and the ranking matches hand reading.

**Thread recall is robust to run-to-run variation; decision recall is not.** Three consecutive
identical-prompt runs of `qwen3.5:9b-mlx` at temperature 0 produced *different text* (1,928 vs 2,260
chars — runs 2 and 3 identical to each other, run 1 different). Thread recall was **40.9% in all
three**. Decision recall moved 66.7% → 77.8%, and action-item count 4 → 5. So the headline metric is
stable and gemma's lead is well outside the noise band; treat decision recall as ±11 points.

**Temperature 0 is not reproducible here, and the cause is prompt caching.** `load_duration` was
~20 ms on all three runs and `prompt_eval_count` was identically 13,291, so the 42.6 s → 12.8 s drop
is not model loading — it is the cached prompt prefix. The numerics of the cached path differ enough
to flip a token and diverge the output. **For a one-shot meeting summary the prefix is never cached,
so 43–48 s is the honest latency for the 9b, not 13 s.**

## Not covered

- **Apple on-device is out of scope by decision, not omission.** Owner's call, 2026-07-30: the context
  window is disqualifying, so measuring it cannot change the outcome. For the record, its usable
  budget on this transcript is 1,792 tokens (`contextSize` 4096 − `numPredict` 2048 − 256 framing),
  implying ~11 chunks plus two reduce rounds, ~15 calls. **This leaves a live gap:** Apple is still the
  *default* summarization provider on a fresh install with Apple Intelligence enabled
  (`RuntimeConfig.swift:189-191`), so the shipping default is a provider now judged unfit for long
  meetings. Changing that default is a separate decision.
- **One fixture, one meeting type.** All runs are `general` on a single 57-minute meeting. No 1:1 or
  standup, and no second meeting to check that the ranking generalises.
- **Speaker names are inferred, not confirmed.** Two of the four are addressed by name inside the
  transcript and are high-confidence; a third is medium-confidence; the fourth is never named across
  168 turns and stays a bare label. The mapping and its evidence live in `gold/key.json`, which is
  gitignored along with the rest of the fixture — real names do not enter this repo.

## Reproducing

```
python3 bench/summarize.py --model <ollama-model> \
  --transcript bench/runs/pod/summary_input_raw.txt \
  --out bench/runs/pod/summaries/raw__<model>.json --title

python3 bench/summary_score.py --key bench/runs/pod/gold/key.json \
  --transcript bench/runs/pod/summary_input_raw.txt \
  bench/runs/pod/summaries/*.json
```

`summarize.py` reproduces the shipping prompt, the `fittedNumCtx` sizing and the request body
verbatim, so a new model drops straight in.
