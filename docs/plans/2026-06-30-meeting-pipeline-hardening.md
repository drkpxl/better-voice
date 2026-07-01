# Meeting Pipeline Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the meeting transcription / speaker-identification pipeline so it separates speakers reliably with many voices and overlapping/interrupting speech, and is efficient — *before* fingerprinting is added on top.

**Architecture:** Decouple diarization from the mono transcription mix. Transcription keeps using a (fixed) mic+system mix; **diarization runs per-channel** — the mic channel is deterministically "me" via VAD, the system channel is diarized by FluidAudio with a persistent `SpeakerManager`, and the two are merged onto one speaker timeline. Phrase→speaker alignment becomes confidence-aware and retains each segment's embedding (the seam fingerprinting will consume). Diarization is chunked with a timeout; the mixer is made sample-accurate and moved off the main thread.

**Tech Stack:** Swift 6, AVFoundation, Core Audio, Apple SpeechAnalyzer, FluidAudio (DiarizerManager / SpeakerManager / TimedSpeakerSegment.embedding), XCTest (`BetterVoiceCoreTests`), the existing `MeetingSession.runFromFile` bench harness.

**Branch:** `meeting-pipeline-hardening` (many commits; keep off `main`).

**Guiding principles:** DRY, YAGNI (no fingerprinting persistence yet — only the seam), TDD for all pure logic in `BetterVoiceCore`, bench-harness + manual verification for audio-integration tasks, frequent commits.

**How we verify integration tasks:** `Sources/BetterVoiceCore` is Foundation-only and unit-tested; audio capture/diarization cannot be unit-tested without models/hardware. So: pure logic (alignment, VAD, merge, mixer math, centroid math, config parsing) is extracted into Core and TDD'd; the wired pipeline is verified with `BetterVoice --bench-meeting <wav>` on labeled multi-speaker/overlap fixtures (Task 0.1 adds a scorer) plus a manual "both" meeting. Each integration task states its bench expectation.

---

## Phase 0 — Measurement harness & seams

You cannot tell if speaker ID improved without a score. Build the ruler first, and carve the pure-logic seam out of `MeetingSession` so later phases change small tested functions instead of the 1200-line file.

### Task 0.1: Speaker-accuracy scorer in Core

**Files:**
- Create: `Sources/BetterVoiceCore/DiarizationScoring.swift`
- Test: `Tests/BetterVoiceCoreTests/DiarizationScoringTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import BetterVoiceCore

final class DiarizationScoringTests: XCTestCase {
    func test_perfectMatch_scoresZeroError() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let hyp = ref
        let s = scoreDiarization(reference: ref, hypothesis: hyp)
        XCTAssertEqual(s.speakerCountError, 0)
        XCTAssertEqual(s.frameErrorRate, 0, accuracy: 0.001)
    }

    func test_swappedSecondHalf_countsAsError() {
        let ref: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "B", start: 2, end: 4)]
        let hyp: [LabeledInterval] = [.init(speaker: "A", start: 0, end: 2),
                                      .init(speaker: "A", start: 2, end: 4)]
        let s = scoreDiarization(reference: ref, hypothesis: hyp, frameSec: 0.5)
        XCTAssertEqual(s.speakerCountError, 1)   // hyp found 1 speaker, ref has 2
        XCTAssertGreaterThan(s.frameErrorRate, 0.4)
    }
}
```

**Step 2: Run to verify it fails** — `swift test --filter DiarizationScoringTests` → FAIL (types not defined).

**Step 3: Minimal implementation**

```swift
import Foundation

public struct LabeledInterval: Sendable, Equatable {
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval
    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

public struct DiarizationScore: Sendable, Equatable {
    public let frameErrorRate: Double   // fraction of frames whose majority hyp speaker != ref (after optimal label mapping)
    public let speakerCountError: Int   // |distinct(hyp) - distinct(ref)|
}

/// Frame-based speaker error with greedy label mapping (a lightweight DER proxy — good enough
/// to compare pipeline changes on the same fixture; not a formal DER implementation).
public func scoreDiarization(reference: [LabeledInterval],
                             hypothesis: [LabeledInterval],
                             frameSec: TimeInterval = 0.1) -> DiarizationScore {
    let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
    guard end > 0 else { return .init(frameErrorRate: 0, speakerCountError: 0) }
    func speakerAt(_ t: TimeInterval, _ ivs: [LabeledInterval]) -> String? {
        ivs.first(where: { $0.start <= t && t < $0.end })?.speaker
    }
    // greedy map hyp labels -> ref labels by co-occurrence
    var pairCounts: [String: [String: Int]] = [:]
    var frames = 0, mappable = 0
    var t = frameSec / 2
    while t < end {
        if let r = speakerAt(t, reference) {
            frames += 1
            if let h = speakerAt(t, hypothesis) {
                pairCounts[h, default: [:]][r, default: 0] += 1
                mappable += 1
            }
        }
        t += frameSec
    }
    var map: [String: String] = [:]
    for (h, refs) in pairCounts { map[h] = refs.max(by: { $0.value < $1.value })?.key }
    var wrong = 0; t = frameSec / 2
    while t < end {
        if let r = speakerAt(t, reference) {
            let h = speakerAt(t, hypothesis).flatMap { map[$0] }
            if h != r { wrong += 1 }
        }
        t += frameSec
    }
    let fer = frames > 0 ? Double(wrong) / Double(frames) : 0
    let scErr = abs(Set(hypothesis.map(\.speaker)).count - Set(reference.map(\.speaker)).count)
    return .init(frameErrorRate: fer, speakerCountError: scErr)
}
```

**Step 4: Run to verify pass** — `swift test --filter DiarizationScoringTests` → PASS.

**Step 5: Commit** — `git add -A && git commit -m "test: add diarization scoring proxy for pipeline evaluation"`

**Step 6:** Wire the scorer into the bench output. In `MeetingSession.runFromFile` (`Sources/MeetingSession.swift:234`), when a sidecar `<wav>.speakers.json` (array of `{speaker,start,end}`) exists next to the input, compute `scoreDiarization(...)` on the produced segments and log `[Bench] DER-proxy: fer=… scErr=…`. Also emit it into the JSON in `MeetingBenchmark.formatResult` (`Sources/BetterVoiceApp.swift:197`). Commit.

**Verification:** `swift build && .build/debug/BetterVoice --bench-meeting <fixture>.wav` prints the score line.

---

### Task 0.2: Extract phrase→speaker alignment into Core (pure seam)

Move the alignment/grouping math out of `MeetingSession` so Phases 1–2 modify tested pure functions. Keep behavior identical for now (characterization).

**Files:**
- Create: `Sources/BetterVoiceCore/SpeakerAlignment.swift`
- Modify: `Sources/MeetingSession.swift:619-732` (delete the moved bodies, call Core)
- Test: `Tests/BetterVoiceCoreTests/SpeakerAlignmentTests.swift`

**Step 1: Define neutral types + failing tests**

```swift
// SpeakerAlignment.swift
import Foundation

public struct SpeakerInterval: Sendable, Equatable {
    public let speakerId: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let embedding: [Float]?      // retained for fingerprinting (Phase 2)
    public let quality: Float?          // TimedSpeakerSegment.qualityScore
    public let source: SpeakerSource
    public init(speakerId: String, start: TimeInterval, end: TimeInterval,
                embedding: [Float]? = nil, quality: Float? = nil, source: SpeakerSource = .system) {
        self.speakerId = speakerId; self.start = start; self.end = end
        self.embedding = embedding; self.quality = quality; self.source = source
    }
}
public enum SpeakerSource: Sendable, Equatable { case mic, system }

public struct PhraseSpan: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
}

public struct SpeakerAssignment: Sendable, Equatable {
    public let speakerId: String?
    public let embedding: [Float]?
    public let confidence: Double      // overlappedDuration / phraseDuration  (0…1)
    public let overlapped: Bool        // true when >1 distinct speaker overlaps this phrase (interruption)
}
```

Tests (characterize current behaviour, then the fixes we want):

```swift
func test_assignsMaxOverlapSpeaker() {
    let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 3),
               SpeakerInterval(speakerId: "2", start: 3, end: 6)]
    let a = assignSpeaker(to: PhraseSpan(start: 2.5, end: 3.2), among: ivs)
    XCTAssertEqual(a.speakerId, "1")            // 0.5 vs 0.2 overlap
    XCTAssertGreaterThan(a.confidence, 0.6)
}
func test_noOverlap_isLowConfidenceNotSnap() {
    let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 1)]
    let a = assignSpeaker(to: PhraseSpan(start: 5, end: 6), among: ivs)
    XCTAssertEqual(a.confidence, 0, accuracy: 0.001)   // was: snapped to nearest
}
func test_flagsOverlapWhenTwoSpeakersInPhrase() {
    let ivs = [SpeakerInterval(speakerId: "1", start: 0, end: 2),
               SpeakerInterval(speakerId: "2", start: 1.5, end: 3)]
    let a = assignSpeaker(to: PhraseSpan(start: 0, end: 3), among: ivs)
    XCTAssertTrue(a.overlapped)
}
```

**Step 2: Run → FAIL.**

**Step 3: Implement** `assignSpeaker(to:among:)` (max total overlap per speaker; confidence = bestOverlap/phraseDur; `overlapped` when ≥2 speakers each overlap ≥ some min) and `groupIntoTurns(phrases:assignments:)` (port of `buildSpeakerTurns` grouping, but split a turn when confidence drops below a threshold). Provide full implementations.

**Step 4: Run → PASS.**

**Step 5:** Replace `alignTranscriptionWithDiarization` / `speakerForTimeRange` / the grouping in `buildSpeakerTurns` (`MeetingSession.swift:619-732`) with calls into these Core functions. Convert `[TimedSpeakerSegment]` → `[SpeakerInterval]` at the call site (retain `.embedding`, `.qualityScore`). Keep the old nearest-snap behavior behind a flag OFF by default (we are intentionally replacing it). `swift build` + run the existing meeting flow to confirm no regressions.

**Step 6: Commit** — `git commit -m "refactor: extract speaker alignment into BetterVoiceCore (tested)"`

**⚠️ Behavior change:** brief interjections that used to snap to the nearest speaker now get `speakerId=nil` / low confidence. That is intended (finding #4) and is handled in Phase 1 by the mic channel and Phase 2 by embedding matching.

---

## Phase 1 — Per-channel diarization (findings #1, #4, #6)

Stop diarizing the mono mix. Mic = "me" via VAD; system = FluidAudio; merge onto one timeline.

### Task 1.1: Mic VAD → "me" intervals (pure, TDD)

**Files:**
- Create: `Sources/BetterVoiceCore/VoiceActivity.swift`
- Test: `Tests/BetterVoiceCoreTests/VoiceActivityTests.swift`

**Step 1: Failing tests** — over a `[Float]` mono 16 kHz buffer, `detectSpeechIntervals(samples:sampleRate:)` returns `[Range<TimeInterval>]` where RMS over a 30 ms frame exceeds an adaptive threshold, with hangover/merge of gaps < `minSilenceSec`. Tests: silence → `[]`; a 1 s tone at 0.5 amplitude in the middle of 3 s → one interval ≈ [1,2]; two bursts with a 100 ms gap → merged into one.

**Step 2–4:** Implement RMS-frame VAD with an adaptive noise floor (e.g. threshold = max(absoluteFloor, noiseFloor × k)), hangover, and gap-merge. Full code in Core. Run → PASS.

**Step 5: Commit** — `git commit -m "feat: mic VAD speech-interval detection (tested)"`

### Task 1.2: Split the diarization feed by channel

**Files:** Modify `Sources/MeetingSession.swift:45-53, 365-435` and `Sources/AudioMixer.swift`.

- Replace the single `diarizationBuffer: [Float]` + shared `onDiaSamples` with **two** accumulators: `micDiaBuffer` and `sysDiaBuffer`.
- The mixer currently owns diarization delivery for `both` mode (`AudioMixer.drainAndMix` → `onDiarizationSamples(mixed)`, `AudioMixer.swift:136`). Change `AudioMixer` to expose the *pre-mix* per-channel drained samples via two callbacks (`onMicSamples`, `onSysSamples`) in addition to the mixed stream it still yields to SpeechAnalyzer. In `mic`/`system` single-source modes, route that source's capturer samples to the matching buffer.
- Keep appends **off the main thread** (see Task 4.2) — for now append on a dedicated serial queue, not `DispatchQueue.main.async`.

**Verification (bench):** run `--bench-meeting` on a stereo fixture split into `.mic.wav`/`.system.wav`; log both buffer sizes. No scoring change yet (still one diarizer in 1.3). Commit.

### Task 1.3: System-channel diarization + "me" merge + new alignment

**Files:** Modify `Sources/MeetingSession.swift:563-703`; use Core from 0.2 + 1.1.

- In `performDiarization()`: run FluidAudio `performCompleteDiarization` on **`sysDiaBuffer` only**, producing `[SpeakerInterval(source: .system, embedding:, quality:)]`.
- Run `detectSpeechIntervals` on `micDiaBuffer` → `[SpeakerInterval(speakerId: "me", source: .mic)]`.
- Merge both into one `[SpeakerInterval]` timeline (sorted by start).
- Align phrases with `assignSpeaker(to:among:)` (Task 0.2). When mic and system overlap a phrase, `overlapped == true` → keep the higher-overlap source but mark the segment (used later for UI/interruption).
- `mic`-only meetings: everything is "me". `system`-only: no mic timeline; unchanged from today but via the new path.

**Verification (bench):** on a 2-speaker fixture where one speaker is the mic, `DER-proxy fer` should **drop materially** vs. Phase 0 baseline, and `speakerCountError` should be 0. Record before/after in the commit message. Manual: a real "both" meeting where you interrupt the video — you should be labelled "me" through the interruption. Commit.

**Note on `numClusters = -1`:** keep FluidAudio's auto speaker count (good for many voices). Do **not** switch to the streaming Sortformer backend here — it's capped at 4 speakers (`SortformerDiarizer.swift:8`) and would hurt the many-voices goal.

---

## Phase 2 — Retain embeddings + confidence (finding #2 seam, #4)

### Task 2.1: Add embedding + confidence to `MeetingSegment` (Core, TDD)

**Files:** Modify `Sources/BetterVoiceCore/MeetingTypes.swift:17-`; Test `Tests/BetterVoiceCoreTests/BetterVoiceCoreTests.swift`.

- Add `public let speakerEmbedding: [Float]?` and `public let speakerConfidence: Double?` (default nil in `init`, so all existing call sites compile). Keep `Sendable`.
- Test: a segment round-trips these fields; `applySpeakerNames` (SpeakerLabeling) preserves them (add fields to the reconstruction at `SpeakerLabeling.swift:22-31`).

**Step 5: Commit** — `git commit -m "feat: MeetingSegment carries speaker embedding + confidence"`

### Task 2.2: Thread embeddings through alignment → segments

**Files:** Modify `Sources/MeetingSession.swift:665-703` (`buildSpeakerTurns`).

- When building each turn's `MeetingSegment`, set `speakerEmbedding` to the mean of the turn's constituent `SpeakerInterval.embedding`s (skip mic "me" intervals — no model embedding) and `speakerConfidence` to the turn's min phrase confidence.
- Add a mean-of-embeddings helper in Core `SpeakerAlignment.swift` (`meanEmbedding([[Float]]) -> [Float]?`) with a TDD test (equal-length average; nil on empty/ragged).

**Verification:** bench logs `segments with embedding: N/M`. Commit.

### Task 2.3: `SpeakerRegistry` seam (in-memory only — NO persistence yet)

**Files:** Create `Sources/BetterVoiceCore/SpeakerRegistry.swift`; Test `Tests/BetterVoiceCoreTests/SpeakerRegistryTests.swift`.

- Define `protocol SpeakerRegistry { func match(_ embedding: [Float]) -> (id: String, distance: Float)?; mutating func upsert(id: String, embedding: [Float]) }` and a simple in-memory cosine-distance implementation with a threshold.
- TDD: enrolling A then matching a near-identical vector returns A under threshold; a far vector returns nil.
- **Do not** wire persistence or cross-meeting behavior — this is the documented hook the fingerprinting project implements next. YAGNI.

**Step 5: Commit** — `git commit -m "feat: SpeakerRegistry seam for fingerprinting (in-memory, tested)"`

---

## Phase 3 — Chunked diarization + timeout + memory (finding #3)

### Task 3.1: Timeout around diarization

**Files:** Modify `Sources/MeetingSession.swift:582-611`.

- Wrap `performCompleteDiarization` in the existing `withThrowingTimeout(seconds:)` helper (used at `:517`). On timeout: log, return segments with `speakerId=nil` rather than hang `stop()`. Commit.

### Task 3.2: Chunked system diarization with a persistent `SpeakerManager`

**Files:** Modify `Sources/MeetingSession.swift:563-611`.

- Process `sysDiaBuffer` in fixed windows (e.g. `DiarizerConfig.chunkDuration = 10s`), reusing **one** `DiarizerManager` across chunks so its `speakerManager` keeps stable IDs + accumulating embeddings within the meeting (`DiarizerManager.speakerManager`, `initializeKnownSpeakers`). Concatenate the per-chunk `TimedSpeakerSegment`s (offset times by chunk start).
- This caps per-pass work and gives stable within-meeting IDs (prereq for cross-meeting fingerprinting).

**Verification (bench):** on a long (>10 min) fixture, `stop()`→result latency is bounded and `speakerCountError` unchanged or better vs Phase 1. Commit.

### Task 3.3: Cap diarization-buffer memory

**Files:** Modify `Sources/MeetingSession.swift` accumulation.

- Once a 10 s chunk is diarized, **discard** its raw samples (keep only the `SpeakerInterval`s + embeddings). Peak RAM becomes ~one chunk, not the whole meeting. (WAV persistence is unaffected — it's written separately by the capturers.)
- Verification: log peak `sysDiaBuffer.count`; confirm it stays ~`chunkDuration × 16000`. Commit.

---

## Phase 4 — Mixer correctness + audio perf (findings #5, #6, #8)

### Task 4.1: Sample-accurate mixer alignment (pure math, TDD)

**Files:** Create `Sources/BetterVoiceCore/MixAlignment.swift`; Test `Tests/BetterVoiceCoreTests/MixAlignmentTests.swift`. Modify `Sources/AudioMixer.swift:111-137`.

- Extract the align+sum as a pure function over running per-stream sample counters: given `(micTotal, sysTotal, mic:[Float], sys:[Float])` and a shared output cursor, return the mixable prefix (min of available aligned samples) and carry the remainder, so streams that arrive at different rates stay phase-locked instead of index-zero-padding every 100 ms.
- TDD: equal-length streams sum elementwise; when sys lags by N samples, mic is held (carried) rather than mixed against zeros; long-run drift stays bounded.

**Step 5:** Wire into `AudioMixer` (replace `drainAndMix`'s zero-pad loop `:118-125`). Commit.

### Task 4.2: vDSP mix + off-main accumulation

**Files:** `Sources/AudioMixer.swift`, `Sources/MeetingSession.swift`.

**Status: off-main done; vDSP consciously declined.**

- **Off-main (finding #8): done.** There is no `DispatchQueue.main.async` anywhere on the audio
  path. Raw capture callbacks (the ~10 ms hot path) run off the main thread: single-source `mic`/
  `system` modes append from the capturer's own serial queue, and `both` mode feeds the mixer's
  `nonisolated` lock-protected `feedMic`/`feedSystem`. The only main-actor touch is `AudioMixer`'s
  coarse **100 ms** drain timer, which does lightweight buffering (append + VAD chunk boundary
  detection); the heavy diarization work is deferred to `performDiarization()` at `stop()`. This is
  an acceptable cadence, not the per-callback main-thread dispatch finding #8 warned about.
- **vDSP: declined.** The mix now lives in `BetterVoiceCore.alignAndMix`, which is deliberately
  Foundation-only (see `SpeakerRegistry.swift` — "no Accelerate") so the mixer math stays pure and
  unit-tested. The mix processes ~1600 samples per 100 ms window (10×/s); a scalar add there costs a
  few µs, so `vDSP_vadd`/`vDSP_vsmul` would save ~1 µs/window on an M4 — below noise. Importing
  Accelerate into Core (or restructuring Core to return unsummed slices just to SIMD the add in
  `AudioMixer`) trades the module's purity/testability for no measurable gain. YAGNI. If a future
  profile shows the mix on a real hot path, revisit by having Core return aligned prefixes and doing
  the vDSP add in `AudioMixer`.

### Task 4.3: Dedupe + batch the WAV/convert code

**Files:** Create `Sources/PCMWavWriter.swift` and `Sources/PCMConvert.swift`; Modify `Sources/SystemAudioCapturer.swift` + `Sources/MeetingSession.swift` (MeetingCaptureDelegate) to use them.

- The WAV header/writer and the block-based `convert(...)` are duplicated verbatim in `SystemAudioCapturer` and `MeetingCaptureDelegate`. Extract one `PCMWavWriter` (buffering writes, flushing every ~1 s instead of per-callback) and one `convert` helper.
- Where extractable, unit-test the WAV header bytes in Core. Verification: recorded WAVs still play and match sample counts. Commit.

### Task 4.4 (finding #6): echo guard note

- Add a one-line doc + Settings hint that `both` mode assumes headphones (open speakers double-count the remote voice into the mic). Full acoustic echo cancellation is out of scope; per-channel diarization (Phase 1) already prevents the *attribution* error. Commit.

---

## Phase 5 — Tuning & config (finding #7)

### Task 5.1: Expose `DiarizerConfig` in RuntimeConfig + Settings

**Files:** Modify `Sources/RuntimeConfig.swift` (add `meeting.diarization` defaults: `clustering_threshold=0.7`, `min_speech_sec=1.0`, `min_silence_sec=0.5`), `Sources/MeetingSession.swift:591` (build `DiarizerConfig` from config), `Sources/SettingsWindow.swift` (advanced disclosure in Meetings).

- TDD a small pure `parseDiarizationConfig([String:Any]) -> DiarizerConfigValues` mapper in Core (clamps `clustering_threshold` to 0.5…0.9). Commit.

### Task 5.2: Bench sweep + choose defaults

- Assemble 2–3 labeled fixtures (2-speaker, 4-speaker, and one with interruptions) under `client/.fixtures/` with `.speakers.json` sidecars.
- Sweep `clustering_threshold` ∈ {0.6, 0.65, 0.7, 0.75, 0.8} via `--bench-meeting`, record `fer`/`scErr`, pick the default that minimizes error across fixtures. Document results in this plan's "Results" appendix. Commit.

---

## Definition of done

- All new Core logic has passing XCTest cases; `swift test` green.
- On the labeled fixtures, `DER-proxy fer` and `speakerCountError` are **no worse than baseline and materially better on the interruption fixture** (record numbers).
- A manual "both" meeting with an interruption labels the mic speaker as "me" throughout and does not merge all remote speech under one label.
- `stop()` returns within the diarization timeout even on a long meeting; peak diarization RAM ≈ one chunk.
- No `DispatchQueue.main.async` on the audio hot path. (vDSP mix consciously declined — see Task 4.2.)
- `MeetingSegment` carries `speakerEmbedding`/`speakerConfidence`; `SpeakerRegistry` seam exists and is tested, with **no persistence** (that's the next project).

## Results

**Fixtures assembled so far:** only one — `client/.fixtures/videoplayback.wav` (309 s, mono multi-speaker
"system audio"). It exercises the system-channel diarizer but **not** the per-channel mic+system path or
interruption handling; the 2-speaker (mic+remote) and interruption fixtures still need real app recordings
(`both` mode). So Task 5.2's cross-fixture sweep is partial and the chosen 0.57 default is **interim**,
to be re-validated on real meetings.

Scoring is vs pyannote gold labels (a reference, not ground truth). Full methodology + raw sweep live in
`tools/pyannote/README.md`. Per-phase historical baselines were not captured on this clip; the numbers
below are the current pipeline swept over `clustering_threshold`.

### `videoplayback.wav` — human-verified 7 speakers, pyannote gold 6

| clustering_threshold | BetterVoice speakers | scErr vs pyannote | frame error (`fer`) |
|---|---|---|---|
| 0.55 | 9 | 3 | — |
| **0.56–0.57 (chosen)** | **8** | **2** | **0.289** (best) |
| 0.58–0.60 | 5 | 1 | 0.368 |
| 0.70 (old default) | 4 | 2 | — |

The clusterer jumps 8→5 between 0.57 and 0.58 (a count of 7 is unreachable by threshold alone on this
clip). 0.57 wins on frame agreement (~71%). Note `scErr` is lowest at 0.58–0.60 but `fer` is worse there
— we optimize `fer` (per-frame attribution) over exact count, since attribution is what the UI shows.

| Fixture | Status | scErr | fer | Chosen threshold |
|---------|--------|-------|-----|------------------|
| multi-speaker system (`videoplayback`) | ✅ scored | 2 (8 vs gold 6) | 0.289 | 0.57 (interim) |
| 2-speaker (mic+remote) | ⏳ needs a real `both` recording | — | — | — |
| interruptions | ⏳ needs a real `both` recording | — | — | — |

## Pre-release code review (2026-06-30, high-effort, workflow-backed)

A full `main...HEAD` review of the Swift pipeline ran before the 0.7.0 merge. 10 verified findings.

**Fixed before merge:**
- **[0] cross-gap turn merge** (`SpeakerAlignment.groupIntoTurns`) — consecutive same-speaker/`nil`
  phrases separated by a long silence collapsed into one turn spanning the gap with concatenated
  text. Now split on `maxTurnGapSec` (default 10s). Tests added.
- **[1] short-clip spurious labels** (`SystemDiarizationChunker`) — chunking dropped the old
  `audioDuration >= 2.0` whole-buffer guard, so a <2s meeting got zero-padded and diarized into a
  bogus speaker. Restored: skip diarization when the whole meeting is <2s (no full chunk).
- **[7] tie-break comment** (`SpeakerAlignment`) — comment said "higher id wins"; code + test
  intentionally pick the LOWER id on a tie. Comment corrected (behavior unchanged).
- **[8] stale settings text** (`SettingsWindow`) — help said "Default 0.55"; actual default is
  0.57. Fixed, and the stepper step 0.05→0.01 so the 0.57 default is actually reachable.

**Intentional (by design; kept, documented):**
- **[2] snap-to-nearest removal** — zero-overlap interjections now render "Unknown" instead of
  snapping to the nearest speaker. This is the deliberate Task 0.2 decision (finding #4): a wrong
  snap is worse than an honest "Unknown"; the mic channel + future embedding matching recover it.
- **[3] WAV ~1s buffered flush** — `PCMWavWriter` can lose up to ~1s on a crash. Accepted: the old
  per-buffer writer also left a broken placeholder header on crash (unplayable), and the `.wav` is
  a local debug artifact; the ~1s batching is the intended Task 4.3 syscall reduction.

**Deferred follow-ups (out of this project's scope — real-time audio alignment):**
- **[4]/[5]/[6] mixer phase-lock drift** (`AudioMixer`/`MixAlignment`) — under sustained capture-clock
  drift (>0.5s) the drift cap drops mix samples and the transcription vs diarization timelines can
  diverge; a window is suppressed if one channel is momentarily empty. PLAUSIBLE, timing-dependent.
  Proper fix = true host-time alignment, explicitly out of scope here (see Task 1.3 note).
- **[9] unbounded diarization stream on first-run download** (`SystemDiarizationChunker`) — the
  consumer `AsyncStream` is `.unbounded`, so if the first-run model download stalls, meeting audio
  piles up in memory, defeating the bounded-memory goal. First-run-only. Cleanest fix is to
  pre-download models before capture begins.
