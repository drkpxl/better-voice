# WE Meeting Mode Field Evaluation Report

> Evaluation date: 2026-04-15
> Meeting recording: 2026-04-13, duration 1 hour 32 minutes 31 seconds, multi-person meeting
> Benchmark system: Tongyi Tingwu (Alibaba Cloud, commercial-grade ASR)
> Evaluation method: the same recording transcribed separately by WE and Tongyi Tingwu, then cross-compared

## I. Evaluation Method Description

### 1.1 Data Source

- **Recording file**: `meeting-2026-04-13T04-59-30Z.wav`, 169MB, 16kHz, mono
- **WE transcription**: WE Meeting Mode real-time transcription, SpeechAnalyzer streaming input + FluidAudio speaker diarization
- **Tongyi Tingwu**: uploaded via the web client, "Chinese + multi-person discussion" mode selected, original text exported as docx

### 1.2 Alignment Method

The two systems segment sentences at different granularities (Tongyi Tingwu uses longer paragraphs, WE's paragraphs are more fragmented), so direct paragraph-by-paragraph comparison isn't possible.

Two alignment methods were tried:

1. **Slicing by time window** (2-minute/5-minute windows) → **unreliable**. The two sides' timestamps were offset by 3-8 seconds, causing severe content misalignment at window boundaries and artificially inflating the CER. In some windows the two sides weren't even covering the same stretch of speech at all (e.g., the 62:00-64:00 window showed a CER of 46.6%, which was actually alignment drift rather than recognition error).
2. **Full-text concatenation + SequenceMatcher content alignment** → **reliable**. This removes the dependency on timestamps and uses Python's difflib.SequenceMatcher (Ratcliff/Obershelp algorithm) to align the full-text sequences. Manual spot-checking of 20 anchor points confirmed that both sides were referring to the same passage at every point, with no misalignment found.

Method 2 was ultimately adopted.

### 1.3 Evaluation Metrics

| Metric | Description | Limitations |
|------|------|--------|
| **CER (Character Error Rate)** | Edit distance / reference text character count, computed with the jiwer library | Only measures literal differences and doesn't distinguish the magnitude of semantic impact. Filler-word differences and semantic errors are scored equally |
| **SemDist (Semantic Distance)** | Chinese BERT embedding cosine similarity, shibing624/text2vec-base-chinese | Effective for long segments (>3 characters); unreliable for single-character substitutions (context dilution issue) |
| **Manual segment-by-segment comparison** | 10 time segments randomly sampled, both sides' text read manually | Highly subjective, but can surface issues that algorithmic metrics can't capture |

**Reflections on metric selection**:

- CER is the standard metric for ASR evaluation (still used by NIST sclite today), but its fatal flaw is treating "um → ah" the same as "progress → quarter." In a meeting context, the former is inconsequential while the latter can cause real misunderstanding.
- SemDist should, in theory, be able to distinguish semantic impact, but in practice it suffers from a context-dilution problem: once a difference segment is padded with the surrounding identical text, the BERT embedding gets pulled toward high similarity. Once the context is removed, single-character substitutions become too short for the BERT embedding to be stable.
- The final judgment still relies on manual segment-by-segment reading.

### 1.4 Important Statement

**Tongyi Tingwu is not ground truth.** Tongyi Tingwu itself also has recognition errors (e.g., "press conference" may actually have been "press briefing" or "newlywed gathering"; "WeChat vehicle" is clearly an error). The CER in this report is the **disagreement rate** between the two systems, not WE's absolute error rate. WE's true error rate can only be obtained after manually listening to the recording and annotating ground truth.

---

## II. CER (Character Error Rate)

### 2.1 Full-Text Statistics

| Metric | Value |
|------|------|
| Tongyi Tingwu total character count (punctuation removed) | 21,089 |
| WE total character count (punctuation removed) | 22,628 |
| Character count difference | WE has 7.3% more |
| **CER** | **19.09%** |

### 2.2 Error Type Breakdown

| Type | Count | % of baseline character count | Description |
|------|------|-----------|------|
| Correct match | 18,960 | 89.9% | Characters identical on both sides |
| Substitution (S) | 1,772 | 8.4% | WE recognized a different character |
| Insertion (I) | 1,896 | 9.0% | Extra characters in WE |
| Deletion (D) | 357 | 1.7% | Characters WE dropped |

**The 9% insertion rate is the largest source of difference** — WE retains filler words (um, ah, "like, like") and repetitions, while Tongyi Tingwu automatically cleans these up. This isn't necessarily an "error," but rather a difference in product strategy.

### 2.3 Limitations of CER (issues exposed during this evaluation)

1. `progress → quarter` (counted as 1 substitution by CER) and `um → ah` (also counted as 1 substitution by CER) are treated the same, but the former changes the meaning of the meeting content
2. The extra filler words WE retains are counted as "insertion errors," accounting for nearly half of the CER
3. The 19.09% figure mixes "genuine recognition errors" with "filler-word/punctuation differences," and shouldn't be interpreted directly as "1 error in every 5 characters"

---

## III. SemDist Semantic Distance Evaluation

### 3.1 Method

Of the 1,420 replace differences found after full-text alignment, two categories were processed:

- **Long segments (>3 characters)**: encoded the difference segment itself (without added context) using Chinese BERT (text2vec-base-chinese), and computed cosine similarity
- **Short segments (≤3 characters)**: BERT embeddings for single characters are unreliable, so these were flagged as "pending manual judgment"

### 3.2 Results

| Category | Count | Characters involved | % of total characters |
|------|------|---------|---------|
| Severe semantic change (sim < 0.5) | 140 instances | 777 characters | 3.38% |
| Moderate semantic difference (0.5 ≤ sim < 0.75) | 90 instances | 486 characters | 2.11% |
| Short-segment substitution (≤3 characters, algorithm cannot judge) | 1,109 instances | 1,892 characters | 8.22% |
| Surface-level change (sim ≥ 0.9) | 1 instance | 4 characters | — |

### 3.3 Limitations of SemDist (issues exposed during this evaluation)

1. **Context dilution**: the first implementation added 15 characters of surrounding context before and after each difference segment, causing nearly all differences to be judged as "surface-level changes" (99.92% semantic fidelity) — this result was wrong
2. **Single-character substitution blind spot**: 1,109 short-segment substitutions (78% of all differences) cannot be evaluated with SemDist. Yet these short segments contain a large number of genuine homophone-substitution errors (progress→quarter, hear→marriage, win→smooth)
3. **Conclusion**: SemDist can distinguish the semantic impact of long-segment differences, but it is powerless against Chinese single-character homophone substitution — the most common type of ASR error

---

## IV. Manual Segment-by-Segment Comparison (Key Findings)

10 two-minute segments were sampled evenly across the entire meeting, and both sides' text was read sentence by sentence.

### 4.1 Areas where Tongyi Tingwu clearly outperforms WE

#### English and technical terms (largest gap)

| Tongyi Tingwu | WE | Location |
|---------|-----|------|
| voice print | body text | 00:53 |
| copy paste to cloudy AI | cobematchase to clounin AI | 61:24 |
| deeper research | deacher research / deperasage | 61:00 |
| token fee | colken fee | 50:54 |
| cloud slash 1 USDK | cloudownpin yeah | 16:51 |
| VG / wiki | wieke / wike | 06:12 |
| andle capacity | Andricapassiy | 05:46 |
| high-score speed (token/s) | topen's speed | 10:16 |
| V100 | B 10 | 10:51 |

WE's terminology recognition in mixed Chinese-English scenarios is clearly weaker than Tongyi Tingwu's.

#### Name recognition

| Tongyi Tingwu | WE | Occurrences |
|---------|-----|---------|
| Bisheng | Bishun | multiple times |
| Lu Shumei | Luo Fumei | 1 time |
| Director Kai | Katong | 1 time |
| Wang Yonghui | Wang Yiwei | 1 time |
| Lu Fengwei | Lu Fengmei | 1 time |

WE got every name wrong, and even for the same person whose name appeared multiple times, the errors were inconsistent.

#### Sentence segmentation and readability

- Tongyi Tingwu: passages are complete and coherent, with reasonably placed punctuation
- WE: segments are cut too finely (average ~50 characters per segment vs. ~130 for Tongyi), punctuation is messy (commas and periods are placed inaccurately)

Example (around 01:30):
```
Tongyi: Take a look at my screen while I'm talking — there are three things. The first is the matter of the
        assessment. Let's go over the progress again. The second is the specific progress on what you're all
        working on right now. The third is the so-called training.

WE:     Oh, take a look — can I say — look look look three things the first is that house-negotiation matter.
        Go over over an progress item the second is the specific progress on what you're all working on right
        now the third is the so-called training.
```

#### Speaker differentiation

- Tongyi Tingwu: identified 6 speakers; switching between the main speaker (Speaker 2, 74.1%) and secondary speakers (Speaker 1/3/4/5/6) was largely accurate
- WE: identified 5 speakers + "Unknown"; the main speaker's share was consistent (Speaker 1, 74.4%), but accuracy in distinguishing secondary speakers was lower. In some multi-person overlapping segments (25:00-27:00), speaker labeling was chaotic

### 4.2 Areas where WE performs on par or acceptably

#### Core Chinese spoken content

In long sentences of pure spoken Chinese, both sides basically conveyed the core meaning:

```
Tongyi: The model itself has training, fine-tuning, and prompts — these injection points. But for each model
        itself, the mechanism by which these injection points take effect is a black box.

WE:     The model itself has training fine-tuning prompts these injection points. But for each model itself
        the mechanism by which these injection points take effect is is a black line uh, what are you gonna do about it
```

Although "black box → black line" is wrong, the overall meaning of the sentence is still understandable.

#### Completeness

WE didn't lose any large chunks of content. Tongyi Tingwu occasionally merges several sentences together or skips short filler words, while WE preserved almost all spoken content as-is.

### 4.3 Areas where WE performs clearly worse

#### Severe quality degradation in certain segments

In the two segments 16:00-17:00 and 85:00-87:00, WE's transcription was nearly unreadable:

```
WE (16:51): Good good OK is is isn't it use a use a cloudicloudu use a SDK that cloudg slash fart.
Tongyi (16:57): Use cloud slash 1 USDK and another cloud slash slash P, right.
```

Neither side is quite right, but WE is clearly worse.

#### Distortion of key information

| Likely original meaning | Tongyi Tingwu | WE |
|------------|---------|-----|
| assessment | assessment | house negotiation |
| performance management | performance management | school management |
| progress | progress | quarter |
| improve some skills | so as to improve some skills | Li Ji piano some skills |
| underlying code | underlying code | underlying what |

These errors would cause anyone reading the meeting minutes to misunderstand.

---

## V. Speaker Diarization Comparison

| Metric | Tongyi Tingwu | WE |
|------|---------|-----|
| Number of speakers identified | 6 | 5 + Unknown |
| Main speaker share | 74.1% | 74.4% |
| Main speaker consistency rate (30-second window) | — | 86.5% |
| Unidentified share | 0% | 0.4% |

Main speaker identification is consistent between both sides. Tongyi Tingwu is more accurate at distinguishing secondary speakers.

---

## VI. Summary

### 6.1 Positioning of WE Meeting Mode

WE uses Apple SpeechAnalyzer (on-device) for real-time transcription and FluidAudio for offline speaker diarization. This is a **lightweight, privacy-first, zero-cost** solution. Tongyi Tingwu is a **cloud-based, commercial-grade ASR** with dedicated optimization for meeting scenarios. The two are not in the same weight class.

### 6.2 Summary of Gaps

| Dimension | Gap Size | Description |
|------|---------|------|
| Chinese spoken language recognition | **Small** | The gap between the two sides is small for everyday spoken Chinese |
| English/terminology recognition | **Large** | WE's recognition of English vocabulary is far inferior to Tongyi's |
| Name recognition | **Large** | WE got almost every name wrong |
| Sentence segmentation/readability | **Medium** | WE's sentences are cut too finely, with inaccurate punctuation |
| Speaker differentiation | **Medium** | Main speaker is accurate, but the gap for secondary speakers is clear |
| Completeness | **No gap** | WE preserved more of the original spoken content |

### 6.3 Issues with the Evaluation Method Itself

The following methodological issues were exposed during this evaluation, recorded here for future improvement:

1. **No ground truth**: Tongyi Tingwu was used as the baseline, but it has its own errors too. The 19.09% CER is a disagreement rate, not WE's absolute error rate
2. **CER doesn't distinguish semantic impact**: it scores filler-word differences and keyword errors equally, which is unreasonable in a meeting context
3. **SemDist fails for Chinese single-character substitutions**: 78% of differences are short-segment substitutions, which BERT cannot reliably evaluate
4. **Time-window alignment is unreliable**: the two systems' timestamps are offset, so slicing by fixed windows causes content misalignment; the segment-by-segment CER data in the initial draft of the report was affected by this

### 6.4 Recommendations for Follow-up

1. **Obtain ground truth**: select a 10-15 minute recording, manually transcribe it word-for-word, and calculate the true CER for each side separately
2. **contextualStrings**: add meeting-related names and terminology to SpeechAnalyzer's contextualStrings, which could significantly improve proper-noun recognition
3. **Apply L2 correction to meeting mode**: the fine-tuned we-polish model could be used for post-processing meeting transcripts, especially for terminology correction
4. **Sentence segmentation optimization**: WE currently segments based on SpeechAnalyzer's isFinal boundaries; merging adjacent short segments could be considered to improve readability
