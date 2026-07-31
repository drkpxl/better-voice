<!--
  EDITORIAL NOTE — not for publication.

  This post is written for drkpxl.com. There is no drkpxl.com repository or content
  directory on this machine, so it is parked here next to the research it describes
  rather than dropped into an invented publishing path. Move it into the real site repo
  and adjust the frontmatter keys to whatever that generator expects.

  Everything numeric in here comes from bench/results/2026-07-30-results.json and
  bench/results/2026-07-30-chart.html. Do not "tidy" the numbers.

  Deliberately absent: any content, topic, or participant from the 57.5-minute meeting
  recording. It is internal business discussion. It appears in this post only as
  "a 57.5-minute recording with four speakers", and it must stay that way.
-->

---
title: "I spent months tuning the wrong half of my dictation app"
date: 2026-07-30
description: >-
  I measured 35 on-device speech pipelines on my own voice — 7 engines against 5
  cleanup models. Choosing the engine moved word error rate 19.1 points. Choosing
  the cleanup LLM moved it about one. I had been tuning the cleanup LLM.
tags: [asr, on-device, macos, benchmarks, better-voice]
---

I make a free macOS app called [Better Voice](https://voice.baselinemakes.com/). You hold a
key, talk, let go, and the text appears wherever your cursor is. It also turns meeting
recordings into Apple Notes. Everything runs on the machine; nothing gets uploaded.

Dictation in it is two stages:

1. A **speech engine** turns audio into words. That's Apple's on-device `SpeechTranscriber`.
2. A **cleanup model** — a small local LLM — takes those words and fixes recognition errors,
   drops the "um"s, and adds punctuation.

For months, when dictation came out wrong, I worked on stage two. I rewrote the cleanup
prompt. I swapped cleanup models. I added a vocabulary file so my work jargon would survive.
Stage two was where I had built things, so stage two was where I looked.

Then I built a benchmark harness and measured both stages at once, and it turned out I had
been sanding the wrong end of the board.

## The setup

Seven on-device speech engines, five cleanup options, every combination: 35 pipelines.

**Engines:** Apple `SpeechTranscriber` · Parakeet TDT v3 · Parakeet TDT v2 ·
Parakeet TDT-CTC-110M · Qwen3-ASR 0.6B · Qwen3-ASR 1.7B · Whisper large-v3-turbo

**Cleanup:** none · Apple's on-device Foundation Models · `qwen3.5:4b-mlx` (what I ship) ·
`qwen3.5:9b-mlx` · `gemma4:12b-mlx`

Each engine transcribes the audio once; that transcript is then fed to all five cleanup
options. Seven speech inferences, 28 cleanup cells, one afternoon of compute.

Three decisions in the design did more work than anything else:

**The recording had to be me talking, not me reading.** One continuous take, 116 seconds,
197 words, recorded in QuickTime — a project update from memory, with all the false starts
and self-corrections that come with it. This is load-bearing. If you read a clean script
aloud, the cleanup stage has nothing to do, every pipeline converges, and the experiment
measures nothing. Natural speech is the only condition under which stage two can prove it
earns its keep.

**Accuracy is scored against what I meant to say.** Word error rate against a *verbatim*
transcript would punish good cleanup: deleting "um" scores as a deletion error, so verbatim
scoring crowns "no cleanup at all" and inverts the answer. So there are two references. The
verbatim one is derived by consensus across all seven engines, with me reviewing only the
words they disagreed on. The intended one is me editing that verbatim text into what I
actually meant — written *before* I looked at any pipeline's output, so no pipeline gets an
unearned win. The headline numbers below are against the intended reference.

**Everything gets the same normalizer.** Case-folded, punctuation stripped, numerals
canonicalised, contractions expanded. Whisper and Apple emit punctuation and casing;
Parakeet TDT emits neither. Without a shared normalizer you penalise models for being more
featureful, which is the single most common way a homemade ASR benchmark ends up
backwards. It's the one piece of the harness I wrote test-first.

Timings are warm: one pass discarded, median of three, models already resident. Cleanup is
nondeterministic, so every cleanup cell ran three times and the spread is reported next to
the median.

## Finding 1: the engine is the lever

Across the seven engines, word error rate spans **19.1 points**.

Within any single engine, swapping between all five cleanup options moves it by
**1.0 to 3.6 points** — and usually about one.

That ratio is the whole post. The stage I had been tuning is worth roughly a point. The
stage I had never touched is worth nearly twenty.

## Finding 2: the cleanup stage frequently did nothing at all

Not "helped a little". Nothing.

**Nine of the 28 cleanup runs returned text that was identical after normalization.** The
model had changed the punctuation and nothing else. Apple's on-device cleanup — the
zero-setup default I ship — was a no-op on **four of the seven** transcripts I gave it.

And the stage isn't free. Cleanup costs **4 to 9 seconds** and buys about **1.1 points**.
For context, Parakeet transcribes the entire 116-second recording in **0.44 seconds**. On
that pipeline the cleanup stage is roughly **90% of the wall clock** for about a point of
accuracy.

That's not automatically a bad trade — punctuation and filler removal are things you can
*see*, and users notice them more than a point of WER. But it should be a deliberate product
decision, and until I measured it, mine wasn't a decision at all. It was an assumption.

## Finding 3: what I ship lost, on both axes at once

Here is the part that stung.

| | Word error rate | Speed (RTFx) |
|---|---|---|
| **What I ship** — Apple engine + Apple on-device cleanup | 38.1% | 101× |
| Parakeet TDT v3, raw | 25.3% | 263× |
| Parakeet TDT v3 + `qwen3.5:4b-mlx` | **24.2%** | 263× |

RTFx is seconds of audio processed per second of compute, so higher is faster. My shipping
pipeline also recovered only 1 of the 5 jargon terms in the recording.

The paired improvement from swapping Apple's engine for Parakeet TDT v3 is **13.9 points**.
(Careful with the two numbers: 19.1 is the full range across all seven engines; 13.9 is what
one specific swap buys. They're often conflated and they aren't the same claim.)

Usually a benchmark hands you a tradeoff to negotiate — more accurate but slower, faster but
worse. This one didn't. Parakeet is **more accurate and 2.6× faster**, at once. There's no
argument to have with it. I just picked wrong, and never checked.

Parakeet was better on names and proper nouns too, which matters more to me than the
aggregate. My daily errors aren't a scattering of small words; they're a colleague's name or
a product name coming out as nonsense.

## Finding 4: the most accurate engine is unusable for my second feature

Qwen3-ASR 1.7B posted the best short-audio accuracy in the grid: **18.6%**, roughly half
today's error rate.

Then I ran the same engines over a **57.5-minute recording with four speakers**, because
Better Voice also does meeting notes and a two-minute clip proves nothing about an hour of
audio. Qwen3-ASR collapsed: about **1.5× real time**, meaning roughly **38 minutes to
process 57**. As a background import job that's survivable. As anything a person waits on,
it's disqualifying.

This is why a single-axis leaderboard is dangerous. The most accurate model in the table is
the wrong choice for half of my app, and you cannot see that from the accuracy column.

## Finding 5: long audio was where Parakeet stopped being a nice option and became the answer

Same hour-long, four-speaker recording:

- **Parakeet: 11.7 seconds** for the full transcript — **294.6× real time** — with no drift
  in quality across the hour. It didn't degrade at minute 45.
- **Whisper large-v3-turbo: 84 seconds.**
- **Apple's engine with diarization: 109 seconds.**

And speaker diarization, which runs locally and separately, held up: it found **exactly four
speakers** across **179 turns**, attributing **97% of the audio**. Getting the speaker count
right without being told it is the thing that makes the resulting note readable.

I was in that meeting, so I could check the transcript against my own memory rather than
against a metric. Parakeet was clearly better on the names — the thing I'd actually be
correcting by hand.

I'm not going to say more about the recording than that. It's internal business discussion.
It's in this post as a duration and a speaker count.

## How much to trust any of it

I'd rather state the limits than have them pointed out to me.

**It's one recording of each kind.** 116 seconds of dictation, one speaker, one mic, plus one
meeting. Enough to see a 14-point gap. Not enough to separate two pipelines half a point
apart — the 0.5-point difference between Parakeet TDT v3 and Whisper large-v3-turbo is not
real, and I don't treat it as real. Directional, not definitive. The ranking did survive being scored against two
different reference variants, which is some comfort but not the same as more data.

**These absolute numbers are high on purpose.** The audio is unscripted, disfluent, and
jargon-heavy, and it's scored against what I meant rather than what I said. The same models
post low single digits on clean read-aloud benchmarks like LibriSpeech. If you're about to
reply "Parakeet gets 6% WER" — you're right, and it isn't a contradiction. Different test.
Never move an absolute WER between benchmarks.

**Nothing here measures streaming latency.** Time-to-first-word is what actually governs how
dictation *feels*, and every timing above is batch processing of a finished file. Parakeet
has streaming variants I haven't touched. Apple's engine is *designed* for streaming, which
means this benchmark may be measuring it in the mode it's least suited to.

**I gave my own pipeline a slightly unfair run.** Apple's engine was measured raw, with
polish disabled, to isolate the stage. The shipping app also applies vocabulary replacement,
which fixes some errors this scoring counts against it. Real-world Apple is somewhat better
than 38.1%.

**I tested no other products.** This is a comparison of speech engines inside my own app. It
says nothing about anyone else's dictation app, and I'm not going to pretend otherwise.

**And the important one: Parakeet is not in the app yet.** Everything above is a
measurement, not a feature. Better Voice ships Apple's engine today, at 38.1% on this
recording. I'd rather publish the gap than quietly close it and claim it was never there.

## What I'm actually doing about it

Roughly in order of payoff per unit of work:

**The free fix first.** Today's pipeline recovered 1 of 5 jargon terms, and part of that is
embarrassingly mundane: most of the terms in the recording were never in my vocabulary file.
The replacement mechanism already exists and applies even when cleanup is off. That's a text
edit, no build, and it fixes the errors I actually notice.

**Then a seam.** Both code paths construct Apple's `SpeechTranscriber` directly, so there is
nowhere to swap an engine in. A protocol and one adapter unlocks the entire 19-point range.
That's the real work, and it's the work I would never have prioritised without measuring —
"add an abstraction" doesn't feel like a feature until you know it's worth 14 points.

**Then Parakeet**, first for dictation, where 0.44 seconds means the cleanup stage becomes
genuinely optional rather than the default. It costs a ~600MB download on first run, which is
a real product objection a WER chart doesn't capture.

**Then possibly two engines**, because the two halves of the app have completely different
latency budgets. Dictation must feel instant. A file import is an offline batch job where
nobody is watching a cursor, and there the accuracy ceiling is worth minutes of waiting.

**And cleanup becomes a choice, not a default.** Something that costs 4–9 seconds and buys a
point, that does literally nothing 9 times out of 28, does not get to be on automatically.

## The transferable bit

If you're building anything on-device with multiple stages: **measure across the stage
boundaries before you optimise inside one of them.**

I spent months on prompts because the prompt was the part I had written, and the engine was
the part that came from a framework and therefore felt like a given. It wasn't a given. It
was a one-line constructor call sitting on top of a 19-point range.

The harness that found this took an afternoon. I could have run it a year ago.

---

*Better Voice is free, on-device, MIT-licensed, and currently has about two users, one of
whom is me. The benchmark harness is in the repo under `bench/` if you'd like to disagree
with my scoring.*
