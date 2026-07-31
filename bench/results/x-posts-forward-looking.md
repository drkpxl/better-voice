# X posts — forward-looking, brand voice

Companion to `x-drafts.md`, not a replacement. Those drafts announce the **finding**
("I measured it and the cleanup LLM was doing nothing"). These are for what comes
**after** the finding: what I'm changing, what the long-audio run showed, and the honest
pitch for a free app with two users.

Nothing here is posted. Cards live in `x-cards/`.

**Voice rules for this account:** plain declarative sentences. Numbers do the work, not
adjectives. Self-deprecating before self-promoting. No emoji, no "🚀", no "excited to
share". Never a claim without its caveat in the same thread.

**Three things that must not slip, in any post, ever:**

1. **Parakeet is not shipped.** The app runs Apple's engine today. Every Parakeet number is
   a measurement. Present tense about Parakeet is a false claim about the product.
2. **n=1.** One 116-second dictation recording, one 57.5-minute meeting.
3. **No product comparisons.** No competing dictation or notetaker app was tested. If
   someone brings one up, say you haven't measured it.

No handles are filled in below — I don't want to guess at usernames. Add your own.

---

## Thread A — the forward-looking one (lead with this)

The point of this thread is: *the interesting part isn't the number, it's that I'm changing
the product because of it.* Attach `3-speed-vs-accuracy.png` to post 4.

**1/**
> I benchmarked my own app and it lost.
>
> 35 on-device dictation pipelines, 7 speech engines × 5 cleanup models, all scored on one
> recording of me talking normally. The pipeline I actually ship landed near the bottom.
>
> Here's what I'm doing about it.

**2/**
> The pipeline is two stages: a speech engine, then a small local LLM to clean the text up.
>
> I had spent months on stage two.
>
> Engine choice moves word error rate 19.1 points. Cleanup model choice moves it about one.
>
> I was sanding the wrong end of the board.

**3/**
> Worse: 9 of 28 cleanup runs came back identical after normalization. They had only
> re-punctuated.
>
> The stage costs 4-9 seconds and buys about a point. The engine transcribes the whole clip
> in 0.44s.
>
> Cleanup was ~90% of my wall clock.

**4/**
> Parakeet TDT v3 came in 13.9 points more accurate than the engine I ship AND 2.6x faster.
> Both at once.
>
> Normally a benchmark hands you a tradeoff to negotiate. This one didn't. I just picked
> wrong and never checked.

**5/**
> So the roadmap changed:
>
> 1. put the missing jargon terms in the vocabulary file (a text edit, fixes the errors I
>    actually notice)
> 2. build the transcriber seam the app doesn't have
> 3. ship Parakeet for dictation
> 4. make cleanup a choice instead of a default

**6/**
> To be exact about what exists: Better Voice ships Apple's engine today, at 38.1% on this
> recording. Parakeet is a measurement, not a feature.
>
> I'd rather publish the gap than quietly close it and act like it was never there.

**7/**
> Caveats, because they matter: n=1. One 116-second recording, 197 words, one mic.
>
> And these are absolute WER on deliberately disfluent, jargon-heavy audio, scored against
> what I *meant* to say. The same models post low single digits on clean read-aloud
> benchmarks. Different test.

**8/**
> The app is free, on-device, MIT-licensed, and has about two users — one of them me.
>
> voice.baselinemakes.com

---

## Thread B — the long-audio result (new material; nothing in `x-drafts.md` covers this)

Two-minute clips prove nothing about an hour of audio, and the hour is where the ranking
actually changed. No card exists for this one yet — either ship it text-only or make a
fourth card.

**1/**
> Everyone benchmarks ASR on short clips. My app also has to handle a full meeting, so I ran
> the same engines over 57.5 minutes of audio with four speakers.
>
> The ranking changed completely.

**2/**
> The most accurate engine on short audio — Qwen3-ASR 1.7B at 18.6% WER, roughly half my
> current error rate — took about 38 minutes to process 57.
>
> Best number in the table. Disqualified for the feature.

**3/**
> Parakeet did the same hour in 11.7 seconds. 295x real time, no drop in quality at minute
> 45.
>
> Whisper large-v3-turbo: 84 seconds. Apple's engine with diarization: 109.

**4/**
> Diarization ran locally and held up: exactly four speakers found, 179 turns, 97% of the
> audio attributed.
>
> Getting the speaker count right without being told it is what makes the resulting note
> readable instead of a wall of "Speaker 3".

**5/**
> I was in that meeting, so I could check the names against my own memory rather than
> against a metric. Parakeet was clearly better on proper nouns — which is the error I'd
> otherwise be fixing by hand.

**6/**
> Same caveat as always: one recording. Directional, not definitive. And none of this is
> shipped yet — the app still runs Apple's engine.
>
> But a single-axis accuracy leaderboard would have pointed me at exactly the wrong model.

---

## Single posts

### The honest-positioning one

> Better Voice has about two users. One of them is me.
>
> So instead of testimonials the landing page has a benchmark: 35 on-device dictation
> pipelines measured on my own voice, including the part where the pipeline I ship came out
> near the bottom.
>
> Free, on-device, MIT. voice.baselinemakes.com

### The lesson one (most likely to travel outside my bubble)

> Lesson from measuring my own app properly:
>
> Measure across your stage boundaries before you optimise inside one of them.
>
> I tuned prompts for months because the prompt was the part I wrote. The engine felt like a
> given because it came from a framework.
>
> It wasn't a given. It was 19 points.

### The one-liner about no-ops

> My dictation app ran a local LLM after every transcription to clean the text up.
>
> On 4 of 7 transcripts it changed nothing at all. Identical after normalization.
>
> It had been costing 4-9 seconds per dictation to re-punctuate.
>
> (n=1 recording, so: directional)

Attach `1-cleanup-does-nothing.png`.

### The build-in-public one, for when the seam lands

> The benchmark said swapping my speech engine was worth 13.9 points and 2.6x the speed.
>
> Problem: both code paths constructed Apple's transcriber directly. Nowhere to swap
> anything in.
>
> Today that's a protocol and one adapter. Boring work. Highest-payoff thing on the list.

### The one to post the day Parakeet actually ships

Hold this. Do not post it early — it's the only post here that claims present tense.

> Three weeks ago I published a benchmark showing the speech engine in my own app was 13.9
> points behind a model I wasn't using.
>
> That model is now what Better Voice runs.
>
> Same recording, measured again: [number]. Free, on-device, no subscription.

---

## Replies to have ready

You will get these. Answering well is worth more than the original post.

**"Parakeet gets ~6% WER, your numbers are way off."**
> Both true. Mine is absolute WER on unscripted, disfluent, jargon-heavy audio scored
> against what I meant to say, not read-aloud benchmark audio. Same model, much harder test.
> The gap between engines is the part that transfers, not the absolute number.

**"n=1 is worthless."**
> For fine ranking, agreed — I treat anything under about a point as a tie. The comparison is
> paired, though: every pipeline gets the identical audio, so passage difficulty cancels. A
> 14-point gap survives that. A 0.5-point one doesn't, and I don't claim it does.

**"So does the app use Parakeet?"**
> Not yet. It ships Apple's engine. The benchmark is what convinced me to build the seam to
> swap it, and that's in progress. I'll post the number when it lands.

**"How does it compare to [other dictation app]?"**
> No idea — I didn't test any. This is a comparison of speech engines inside my own
> pipeline, not a product review.

**"What about latency to first word?"**
> Fair, and my data doesn't answer it. Every timing is batch. Streaming is the thing that
> actually governs how dictation feels, and Apple's engine is designed for it, so this
> benchmark may be measuring it in its worst mode. Separate experiment.

**"Why is Apple's on-device cleanup so bad?"**
> Careful — I measured a no-op, not badness. It returned identical text after normalization
> on 4 of 7 transcripts. That's a small model correctly deciding not to touch something. The
> finding is that the stage was worth less than I assumed, not that the model is bad.

**"Can I see the data?"**
> Whole harness and the 35-cell table are in the repo under bench/. Scoring included, so you
> can disagree with it.

---

## Do not post

- Anything about the content of the 57.5-minute meeting. It's internal business discussion.
  It exists publicly as a duration and a speaker count. Not the topic, not the participants,
  not a sample line of transcript.
- The 19.1-point figure described as an improvement. It's the range across seven engines. The
  paired Apple to Parakeet improvement is 13.9. Merging them is the one error here that a
  hostile reader can prove.
- Any present-tense claim about Parakeet in the app until it is actually in a release.
- A screenshot of the results table without the caveat visible. The table is very screenshot-
  able and travels without its footnotes.
