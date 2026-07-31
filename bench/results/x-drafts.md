# X drafts — ASR pipeline bake-off

Images are in `x-cards/`. Nothing here is posted; these are drafts for you to edit.

**Before posting, read the accuracy note at the bottom.** Two of these make claims about named
third-party models from a single 116-second sample, which is the kind of thing that gets
quote-tweeted by the model's authors.

---

## Thread (recommended — the caveat lives inside it)

Attach `1-cleanup-does-nothing.png` to post 1, `2-engine-dominates.png` to post 3,
`3-speed-vs-accuracy.png` to post 4.

**1/**
> I ship a macOS dictation app. Apple's speech engine, then a local LLM to clean up the
> transcript.
>
> I finally measured it properly: 7 speech engines × 5 cleanup LLMs, 35 pipelines, one recording
> of me actually talking.
>
> The cleanup LLM was doing close to nothing.

**2/**
> Swapping the speech engine moved word error rate 19.1 points.
>
> Swapping the cleanup LLM moved it 1–3.6 points.
>
> And 9 of 28 cleanup runs came back identical after normalization. They'd only changed the
> punctuation.

**3/**
> Here's the whole argument in one chart.
>
> Each row is a speech engine. Each dot is one of the 5 cleanup LLMs applied to it.
>
> The clusters barely move. No cleanup model rescues a weak engine, and a good engine doesn't
> need one.

**4/**
> Worse for me specifically: the engine I ship is beaten on *both* axes.
>
> Parakeet TDT v3 is 13.9 points more accurate than Apple's engine AND 2.6× faster.
>
> That's not a tradeoff. That's just me having picked wrong.

**5/**
> Caveat that matters: n=1. One 116-second recording, 197 words, one speaker, one mic.
>
> Enough to see a 14-point gap. Not enough to rank things half a point apart.
>
> Scored against a reference I hand-wrote of what I *meant* to say, not what I literally said —
> otherwise cleanup gets punished for deleting "um".

**6/**
> The thing I'd tell anyone building on-device voice:
>
> measure the engine before you tune the prompt. I spent months on cleanup prompts. The 14-point
> win was a model swap I never tried.

---

## Single post — the self-deprecating version

> I spent months tuning the cleanup LLM in my dictation app.
>
> Then I measured it: swapping the speech engine moves accuracy 19.1 points. Swapping the cleanup
> LLM moves it 1–3.6.
>
> 9 of 28 cleanup runs returned text identical after normalization.
>
> I optimized the wrong stage.
>
> (n=1 recording, 197 words — enough for a 14pt gap, not for fine ranking)

Attach: `1-cleanup-does-nothing.png`

---

## Single post — the finding-first version

> Measured 35 on-device dictation pipelines on Apple Silicon: 7 speech engines × 5 local cleanup
> LLMs.
>
> Engine choice: 19.1 points of word error rate.
> Cleanup LLM choice: 1–3.6 points.
>
> Parakeet TDT v3 beat Apple's SpeechTranscriber on accuracy AND speed simultaneously.
>
> n=1 recording, so directional not definitive.

Attach: `3-speed-vs-accuracy.png`

---

## Accuracy notes — please don't skip

- **Say n=1.** Every draft above includes it. One 116-second recording of one speaker on one mic.
  Cutting the caveat is what turns this from an honest observation into a benchmark claim you'd
  have to defend.
- **"19.1 points" is a range across engines**, from Qwen3-ASR-1.7B at 18.6% to Apple at 37.6% — not
  a paired improvement you'd get from one swap. The paired Apple→Parakeet-v3 number is 13.9 points.
  Both appear above; don't merge them.
- **These are absolute WER on hard audio**, deliberately disfluent and jargon-heavy. They are not
  comparable to LibriSpeech numbers, where the same models score in the low single digits. If
  someone replies "Parakeet gets 6% WER," they're right and it isn't a contradiction.
- **"9 of 28 identical after normalization"** means identical *after* case-folding, punctuation
  stripping, and number canonicalization. The models did emit different punctuation. Say
  "normalization" or the claim is wrong.
- **Apple's engine was run raw**, with polish disabled, to isolate the stage. The shipping app also
  applies vocabulary replacement, which fixes some errors this measurement counts against it.
  Real-world Apple is somewhat better than 38.1%.
- **Streaming is untested.** All timings are batch. Parakeet has streaming variants; Apple's engine
  is designed for streaming. Anyone asking "but what about latency to first word?" has a fair point
  that this data doesn't answer.
- **Nothing here is about model quality in general** — it's one app's pipeline on one recording.
  Framing it as "X beats Y" invites a fight you don't need. "I picked wrong for my use case" is both
  truer and more interesting.
