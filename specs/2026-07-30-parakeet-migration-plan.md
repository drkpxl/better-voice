# Parakeet Migration — Design

**Date:** 2026-07-30
**Status:** **Largely implemented — historical record, not a description of current code.**
**Branch:** `refactor/parakeet-phase1`

> **Read this as a plan, not as documentation.** Phases 1–5a are done: Parakeet is the only engine,
> the LLM cleanup stage and the Apple ASR stack are deleted, and the decision table below records why.
> Code references throughout (`meeting.l2_flush_on_pause_sec`, `MeetingSegment.rawText`, `l2Kind`,
> `--no-polish`, `run_apple`) describe the codebase **as it was when this was written** and were
> deliberately left intact so the reasoning stays legible. They no longer exist — the segmentation
> keys are `meeting.segment_*`, the vestigial fields are gone (decision 10), and the bench engine is
> `app-pipeline`. For current behaviour read the source; for *why*, read the decision table.
>
> Still open: Phase 5b (lowering the macOS floor) and decision 12's provider-seed fork.

## Problem

The bake-off (`specs/2026-07-30-asr-pipeline-bakeoff-design.md`, results in
`bench/results/2026-07-30-results.json`) answered the question it was built to answer, and the
answer invalidates the shipped architecture:

1. **The engine is the whole game.** Across the 35-cell grid, engine choice moves WER by 19.1
   points; cleanup-model choice moves it by 1.0–3.6. Apple `SpeechTranscriber` + Apple on-device
   cleanup — what ships today — is **38.14%** WER against the intended reference. Parakeet TDT v3
   raw is **25.26%**, and **24.23%** with cleanup. Swapping *only* the engine is a 12.9-point paired
   improvement; 13.9 with cleanup retained.

2. **Cleanup is ~90% of the wall clock for ~1 point.** Measured on the same ~116s / 207-word
   transcript (`bench/runs/current/cleanup.json`): Apple on-device 3.31–4.07s, `qwen3.5:4b-mlx`
   (the Ollama default seeded at `RuntimeConfig.swift:191`) 4.70–4.73s, `qwen3.5:9b-mlx`
   7.88–8.10s, `gemma4:12b-mlx` 9.88–10.00s. Parakeet's inference for the same audio: **0.4856s**
   (`bench/runs/current/parakeet-tdt-v3.json`, `processingTimeSeconds`).

3. **Cleanup frequently does nothing at all.** Re-verified against the artifacts with the harness's
   own normalizer: **9 of 28** cleanup cells produced output identical to their input after
   normalization, and Apple's on-device cleanup was a no-op on **4 of 7** transcripts.

4. **There is no seam to swap the engine through.** `VoiceSession.swift:87` and
   `ImportPipeline.swift:137` each construct `SpeechTranscriber` inline and each drive their own
   `SpeechAnalyzer`. Neither is behind an abstraction.

5. **The cost of the cleanup stage is not just latency, it is the architecture.** `LLMBackend.swift`
   (320 lines), `ModelServer.swift` (187), `PolishClient.swift`, the polling health check
   (`ModelServer.swift:70-119`), the menu-bar connection badge (`MenuBarScene.swift:70-72`), two
   Settings provider forms (`SettingsWindow.swift:310-343`, `:345-390`), an onboarding step
   (`WelcomeWindow.swift:479-489`), a config migration (`RuntimeConfig.swift:234-265`), and a
   `#if BENCH` override system (`RuntimeConfig.swift:22-40`) all exist substantially to serve a
   stage worth about a point.

## Decisions (from the user)

- **Parakeet becomes the primary ASR engine** for both the dictation and the meeting-import paths.
- **Dictation cleanup / polish is removed entirely** — not disabled, not defaulted off. Deleted.
- **Summarization keeps its LLM.** Cleanup and summarization are different features; summarization
  genuinely needs a model and is out of scope for removal.
- **Bundle id stays `com.drkpxl.bettervoice2`, Team `W7SHD73SB5`.** The immutable Sparkle/TCC
  identity. Nothing in this plan touches it.

## Corrections of record

Things believed during planning that the code and artifacts contradict. Recorded so they are not
re-litigated.

1. **Dictation is not streaming in any user-visible sense, so no streaming ASR model is needed.**
   `VoiceSession` uses the streaming `SpeechAnalyzer` API, but the user only ever receives text
   assembled at stop: `fullText = finalizedText + volatileText` (`VoiceSession.swift:226`), handed
   to `VoicePipeline.process()` and injected at `VoicePipeline.swift:56`. The live-preview hook
   `onPartialResult` appears exactly twice in the entire repository — its declaration
   (`VoiceSession.swift:52`) and its invocation (`:137`). **No caller ever assigns it.** Dropping
   streaming loses no shipped feature. Parakeet EOU, Nemotron streaming, `SlidingWindowAsrManager`
   and `StreamingUnifiedAsrManager` are therefore all out of scope — and none of them were measured
   in the bake-off, so adopting one would put the plan's central claim on unmeasured ground.

2. **Parakeet TDT v3 emits punctuation *and* capitalization.** This was the single biggest feared
   regression from deleting cleanup, and it is not real. Verified two ways:
   `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/parakeet_v3_vocab.json`
   contains 9 punctuation tokens (`. , ? ! : - '` and two space-prefixed variants) and 740 tokens
   carrying uppercase; and the actual bench output begins *"I don't know. Okay. Oh it's recording.
   Alright, summit past. Sitecore."* — sentence casing and terminal punctuation, model-side, no
   post-processing. This contradicts the bake-off spec's own §6 claim ("Parakeet TDT emits neither",
   line 176) and FluidAudio's `Documentation/Benchmarks.md:103` ("TDT v3 … no punctuation"). Both
   are wrong for the pinned revision. **The bake-off's WER numbers are punctuation- and
   case-blind by construction, so they neither credit nor penalize this — it is a free win the
   table could not show.**

3. **Parakeet is not the most accurate engine measured — it is the Pareto choice.**
   `qwen3-asr-1.7b` scored **18.56%** WER vs Parakeet v3's 24.23%, a 5.7-point lead. It runs at
   RTFx 5.0 (23.06s to transcribe 116s of audio) against Parakeet's 263.3. On the 57.5-minute
   meeting fixture it completed in 1183.5s wall (RTFx 2.9) — slow, not broken. Parakeet is chosen
   for the accuracy-per-second frontier, not for topping the accuracy column. Any claim that
   Parakeet is "the most accurate engine" is false and should not appear in release notes.

4. **`UnifiedAsrManager` cannot serve the meeting path.** Parakeet Unified is tempting — English,
   better batch WER than TDT v3 (2.15% vs 2.6% avg on test-clean per
   `FluidAudio/Documentation/Benchmarks.md:96-99`), higher RTFx, native punctuation. But
   `UnifiedAsrManager.transcribe` returns a bare `String`
   (`Unified/UnifiedAsrManager.swift:172`, `:207`) — **no token or word timings at all**. The
   meeting path's speaker attribution (`groupIntoTurns`, `SpeakerAlignment.swift:206`) is driven
   entirely by timestamps. Unified is structurally disqualified for meetings, and it was not
   measured in the bake-off. See Open Question 9.

5. **FluidAudio's own docs describe APIs that do not exist.**
   - `Documentation/ASR/CustomVocabulary.md:542-563` shows `AsrManager.shared` and
     `asrManager.transcribe(samples, customVocabulary:)`. Neither exists: `AsrManager` has no
     `shared` (only `init(config:models:)`, `AsrManager.swift:63`) and no `customVocabulary:`
     overload. The only working path is the CLI's manual three-step (spotter →
     `VocabularyRescorer.create` → `ctcTokenRescore`), `FluidAudioCLI/…/TranscribeCommand.swift:488-560`.
   - `Documentation/API.md:182-186` shows `transcribe(_:source:)`. The real signature requires
     `decoderState: inout TdtDecoderState` (`AsrManager.swift:353`, `:377`, `:478`).

   **Implication: budget for reading FluidAudio's source, not its docs.**

6. **`SlidingWindowAsrConfig.hypothesisChunkSeconds` is dead.** Declared
   (`SlidingWindowAsrManager.swift:714`, derived at `:825`) and never read by the window loop
   (`:347-383`). Anyone reaching for "quick hypothesis updates" will get one update per
   `chunkSeconds` instead. Irrelevant given Correction 1, but recorded so it isn't rediscovered.

7. **v3 dropped ~6 seconds of speech at the first chunk boundary in the bench fixture.** The v3
   word timings jump from `endTime 14.24` straight to `startTime 20.08`
   (`bench/runs/current/asr/parakeet-tdt-v3.json`), losing *"I'm gonna speak naturally, et cetera.
   Model cloud"* — which **both** v2 and TDT-CTC-110M transcribed. The 15s window boundary
   (`ASRConstants.maxModelSamples`) lands exactly there. This has the shape of FluidAudio issue
   #594, documented at length on `ASRConfig.melChunkContext` (`AsrTypes.swift:26-39`): the 80ms
   mel-context prepend can shift v3's first-frame distribution enough for the decoder to drift.
   **This is the most serious unquantified risk in the migration** and Phase 0 exists to measure it.

   **Independently re-verified 2026-07-30** by diffing word timings across all three Parakeet
   variants on the same fixture. v3 has a 5.84s hole at 14.24→20.08s; v2 covers the window with
   *"I'm sp gonnaeak naturally, etc. Model cloud"* (itself garbled — v2 has a different boundary
   artifact, word interleaving rather than loss); 110M covers it cleanly with *"I'm speak naturally,
   et cetera. Model cloud."* All three variants show boundary artifacts; **v3's is the only one that
   loses content outright.** Note the direction of the bias: the dropout counted as deletions
   *against* v3, so its 25.26% is a floor, not a flattered number. That makes the accuracy case
   stronger and the reliability case weaker — silent phrase loss in a dictation app is worse for a
   user than a garbled word, because nothing signals that anything went missing.

## Design

### 1. `Transcriber` — the seam (new, `client/Sources/Transcriber.swift`)

One protocol, batch-only, because after Correction 1 batch is all the product needs.

```
protocol Transcriber: Sendable            // conceptual shape, not final code
  func prepare(progress:) async throws     // load/download models; idempotent
  func transcribe(fileURL:locale:) async throws -> Transcript
  var isReady: Bool { get async }

struct Transcript                          // engine-neutral
  let text: String
  let words: [TimedWord]                   // text, start, end, confidence
  let audioDuration: TimeInterval
  let engineID: String                     // for history/logging provenance
```

Two conformances:

- **`ParakeetTranscriber`** — an `actor` owning one `AsrModels` + one `AsrManager`
  (`AsrManager.swift:6`) for the process lifetime, mirroring today's
  `modelRetention: .processLifetime` intent (`VoiceSession.swift:99`) and
  `OfflineDiarizerHost`'s single-instance discipline (`OfflineDiarizerHost.swift:11-41`) — that file
  is the pattern to copy, including its single-flight `preparing` task and the `@unchecked Sendable`
  box for the non-`Sendable` manager. Per call it creates a fresh
  `TdtDecoderState.make(decoderLayers:)` (`Decoder/TdtDecoderState.swift:52`) and calls
  `transcribe(url:decoderState:language:)` (`AsrManager.swift:377`), which auto-routes to the
  disk-backed chunked path above `config.streamingThreshold` (480,000 samples ≈ 30s,
  `AsrTypes.swift:72`). `ASRResult.tokenTimings` (`AsrTypes.swift:94`) is folded to words with the
  library's own `buildWordTimings(from:)` (`AsrTypes.swift:182`) rather than a hand-rolled
  SentencePiece splitter.
- **`AppleSpeechTranscriber`** — today's `SpeechAnalyzer` code, moved behind the protocol *unchanged*,
  for A/B and rollback. Deleted in Phase 5.

**Progress.** `AsrManager.transcriptionProgressStream` (`AsrManager.swift:103`) emits `Double` for
audio over 240,000 samples (~15s) and is documented single-session. `ParakeetTranscriber` must own
that stream and serialize calls; it must not be handed to two concurrent imports. `ImportSession`
already runs the two live-meeting passes strictly sequentially and says so
(`ImportSession.swift:263-266`) — preserve that invariant, and assert it rather than assume it.

**Phrase synthesis (the fiddly part).** `SegmentBuffer.Entry` (`SegmentBuffer.swift:14-18`) and
`groupIntoTurns` (`SpeakerAlignment.swift:206`) both consume *phrase*-level spans, which Apple's API
handed over for free as `result.isFinal` segments (`ImportPipeline.swift:151-166`). Parakeet emits
words. A pure, unit-tested helper in `BetterVoiceCore` (proposed
`BetterVoiceCore/PhraseSegmentation.swift`) must group `[TimedWord]` into phrases on:
sentence-final punctuation (available per Correction 2), and inter-word gaps above a threshold.
Two non-obvious requirements:

- `groupIntoTurns` joins phrase text with `group.map(\.text).joined()` — **no separator**
  (`SpeakerAlignment.swift:230`). Apple's segments carried leading spaces; Parakeet words do not.
  Phrase text must be built with explicit spacing or every turn boundary loses a space.
- The gap threshold interacts with `meeting.l2_flush_on_pause_sec` (default 1.5s,
  `ImportPipeline.swift:314`). Do not silently reuse that value for a different purpose; give
  phrase segmentation its own constant and document the relationship.

**Wiring.** `ImportPipeline.run` takes a `Transcriber` (default `ParakeetTranscriber.shared`), and
lines 136-182 collapse to one `await transcriber.transcribe(...)` plus phrase synthesis into the
existing `segmentBuffer.feed` / `allPhraseEntries` flow. `extractTimeRange`
(`ImportPipeline.swift:421-435`) and `import Speech` both go away.

### 2. Dictation becomes explicitly batch

**New flow:** hotkey down → `MicCapturer` writes a WAV → hotkey up → one Parakeet call → inject.

`MicCapturer.swift` is reused as-is, not reinvented. It already does exactly this job: capture via
`AVCaptureSession` (`:90-110`) — the path its doc comment calls out as the proven
Bluetooth/AirPods-compatible one, since `AVAudioEngine.installTap` never fires on Bluetooth inputs
(`:11-14`) — writing its own native-rate WAV *"instead of feeding a `SpeechAnalyzer`"* (`:12-14`).
It has the `stateLock` start/stop/close discipline (`:54-57`), orders `wavWriter.finalize()` strictly
after in-flight writes on the capture queue (`:126-133`), reports `onAudioLevel` already hopped to
main (`:99-102`) with the same `WaveformMath.rms` the HUD expects, and has an idempotent `close()`
for the quit path (`:140-151`). `VoiceModule.startRecording` (`:94-142`) swaps `VoiceSession` for
`MicCapturer` and keeps its Bluetooth start-cue lead (`:110-112`) and both mid-start abort guards
(`:116-119`, `:127-131`) unchanged.

**Latency: this is a net improvement of several seconds, not a cost to mitigate.** Parakeet's
measured 0.4856s inference on 116.1s of audio is 0.0042 s per audio-second (model resident,
inference only):

| Dictation length | Parakeet transcribe | Today: Apple finalize + Apple cleanup |
|---|---|---|
| 15s | **0.06s** | ≥0.5s + ~3.3–4.1s |
| 30s | **0.13s** | ≥0.5s + ~3.3–4.1s |
| 60s | **0.25s** | ≥0.5s + ~3.3–4.1s |
| 5 min | **1.25s** | ≥0.5s + cleanup, likely worse (longer prompt) |

Today's floor is not zero even before cleanup: `stop()` awaits
`finalizeAndFinishThroughEndOfInput()` under a 5s timeout (`VoiceSession.swift:206`) and then
*unconditionally* sleeps 500ms to let the result task drain (`:220`). So a typical dictation pays
≥0.5s of finalize plus 3.3–4.1s of Apple cleanup — about **4s** — where the new path pays ~0.1–0.3s.

**The one genuine regression, stated honestly:** today transcription overlaps with speaking, so at
release most of the work is already done. Batch does all of it after release, and the post-release
wait grows linearly with dictation length. At 0.0042 s/s that is 1.25s for a 5-minute monologue and
2.5s for ten minutes — still faster than today's cleanup, but no longer imperceptible. Mitigation:
`VoiceModule` already transitions to `.processing` and the HUD already hides on that transition
(`BetterVoice2App.swift:211-214`); add a "Transcribing…" affordance only when recorded duration
exceeds a threshold (~60s, i.e. ~0.25s of expected work). See Open Question 4.

**Model load is separate from inference and must not be conflated.** RTFx 263 is inference-only
(the harness takes it from the CLI's self-reported `processingTimeSeconds`,
`bench/engines.py:186-190`). Process-cold wall clock with `.mlmodelc` already compiled and the page
cache hot was 0.712s. First-ever load after download includes CoreML compilation and will stay
**unmeasured on this hardware** — FluidAudio's only figures are iPhone
(`Documentation/Benchmarks.md:73-80`: encoder 3.36s cold / 0.16s warm on iPhone 16 Pro Max).
Deliberately dropped (owner, 2026-07-30): the app warms the models at launch (§3) so the hotkey never
pays it, and that mitigation ships whatever the number is, so the measurement cannot change the
design.

**New concerns the file-based path introduces, none of which exist today** (`VoiceSession` returns
`audioPath: nil`, `VoiceSession.swift:242`, and dictation writes no audio):

- **Temp WAV lifecycle.** Write under `SupportDir.url/Dictation/` (sibling of
  `LiveMeetings/`, `MeetingCoordinator.swift:307`) and **delete after successful injection**. Note
  that `LiveMeetings/` is a known accumulating-WAV trade-off (`MeetingCoordinator.swift:300-305`) —
  do not repeat it for dictation, which is far higher frequency. See Open Question 5.
- **Silence guard.** Reuse `isRecordingEffectivelyEmpty(at:)` (`AudioFileSilence.swift:14`) before
  transcribing, so a muted mic short-circuits instead of paying model time and injecting "".
  `VoiceModule` already guards empty text (`:161-165`); this makes it cheaper and more explicit.
- **Minimum duration.** `ASRError.invalidAudioData` requires ≥300ms of audio
  (`AsrTypes.swift:236`). A hotkey tap shorter than that must be handled as a no-op, not surfaced
  as an error.

### 3. Model download, lifecycle, and first-run UX

**Measured, not estimated** — from this machine's cache:

| Repo | On disk | Needed for |
|---|---|---|
| `parakeet-tdt-0.6b-v3` | **470 MB** (Encoder 433 MB, Decoder 23 MB, JointDecisionv3 13 MB, Preprocessor 0.5 MB, 2 vocab files 148 KB each) | ASR — required |
| `speaker-diarization` | 21 MB | diarization — **already downloaded today** |
| `parakeet-ctc-110m-coreml` | 99 MB | CTC vocabulary boosting — optional, §5 |

So the marginal first-run cost is **~470 MB**, or ~570 MB with CTC vocabulary boosting. The "~600MB"
working figure is right.

**Location.** `~/Library/Application Support/FluidAudio/Models/<repo>/`, fixed by
`MLModelConfigurationUtils.defaultModelsDirectory` (`Shared/MLModelConfigurationUtils.swift:37-47`)
and reachable via `AsrModels.defaultCacheDirectory(for:)` (`AsrModels.swift:641`). **Do not
relocate it** — the diarizer already lives there and shares the cache root. It is outside
`SupportDir` (`SupportDir.swift:33`), so "Open Data Folder…" (`SettingsWindow.swift:464`) will not
show it; a separate "Reveal Models…" row is needed if the user should ever see it.

**Owner (new, `client/Sources/AsrModelStore.swift`).** An `@Observable @MainActor` store, modelled
on `PermissionStore` (the same "one observable source of truth so SwiftUI actually re-renders"
lesson from `docs/superpowers/specs/2026-07-14-permissions-onboarding-refactor-design.md` §1), with
states: `absent → downloading(fraction, phase) → compiling → ready` / `failed(Error)`. It wraps
`AsrModels.downloadAndLoad(version:progressHandler:)` (`AsrModels.swift:548`) and forwards
`DownloadUtils.DownloadProgress` (`DownloadUtils.swift:182`), whose `phase` distinguishes
`.listing` / `.downloading(completedFiles:totalFiles:)` / `.compiling(modelName:)`
(`:172-179`) — enough to say "Downloading 2 of 5…" then "Preparing…" rather than a stalled bar.
Byte-weighted, 0–0.5 for download and 0.5–1.0 for compile (`:615`, `:647`, `:403`). The handler is
documented as arriving on an unspecified queue (`:196-197`) — hop to main.

**Presence check without touching the network:** `AsrModels.modelsExist(at:version:)`
(`AsrModels.swift:576`).

**First run.** Add a **Transcription model** step to onboarding, placed immediately after
`permMic` and before `model` — it is a download the user should start early, and it can run in the
background while they walk the remaining steps. This bumps
`WelcomeViewModel.currentOnboardingVersion` from 4 (`WelcomeWindow.swift:53`), which by
`BetterVoice2App.swift:174` re-runs onboarding for every existing user. That is the desired
behaviour here (they need the model) but it must be a deliberate decision — see Open Question 6.

**Interrupted download — verified semantics.** `downloadRepo` downloads each file to a temp path
and `moveItem`s it into place (`DownloadUtils.swift:626-637`), and skips files that already exist
(`:578-582`). So a kill or network drop **resumes at whole-file granularity** and never leaves a
truncated file at a destination path. Practically: interrupting during the 433 MB encoder costs the
whole encoder again; interrupting after it costs nothing. There is **no byte-range resume**. After
all files land, required models are verified present (`:654-660`).

**Corrupt cache self-heals, and that is a hazard to know about.** `DownloadUtils.loadModels` catches
any load failure, **deletes the whole repo directory, and re-downloads**
(`DownloadUtils.swift:224-258`). Good for a truncated `.mlmodelc`; alarming if it fires on an
offline machine or mid-flight. Two consequences: (a) surface it — a silent 470 MB re-download must
appear in the UI, and (b) `DownloadUtils.enforceOffline` (`:25`) exists precisely to suppress it and
should be considered for a user-facing "don't use the network" preference.

**Offline / failure / retry.**
- Offline with models present: works completely. Nothing in the ASR path needs the network — and
  after §4 nothing in *dictation* needs it at all, which is a genuine product improvement worth
  saying out loud.
- Offline without models: `AsrModelStore` reports `.failed` with a retry affordance. Dictation and
  import must fail *loudly at the point of use* with "the transcription model isn't downloaded yet",
  never silently produce an empty transcript. `ImportError.transcriptionFailed`
  (`ImportPipeline.swift:41-43`) already renders errors properly in the wizard; dictation currently
  has no user-visible error channel and needs one (`Notify.warn`).
- Download timeout is 1800s (`DownloadUtils.DownloadConfig`, `:203`), with bounded per-file retry
  on transient failures (`:600-604`).

**Launch warm-up.** `applicationDidFinishLaunching` kicks off `AsrModelStore.prepareIfPresent()` —
load if already on disk, never download unprompted. This is the slot that
`ModelServer.startHealthCheck()` (`BetterVoice2App.swift:199`) vacates in §4, and it replaces the
`analyzer.prepareToAnalyze` warm-up (`VoiceSession.swift:110`) that made the first hotkey press fast.

**Uninstall / reclaim.** `DownloadUtils.clearModelCache(forRepo:directory:)` (`:261`) exists. A
Settings → Data row showing usage and offering removal is cheap and closes the "600 MB appeared on
my disk" complaint. See Open Question 5.

### 4. Removing Ollama / the external LLM — exactly what dies and what lives

**Dies:**

| Thing | Reference |
|---|---|
| `PolishClient` (whole file) | `PolishClient.swift` |
| `OllamaBackend` | `LLMBackend.swift:79-224` |
| `OpenAICompatibleBackend` | `LLMBackend.swift:231-320` |
| `fetchOK` / `fetchJSON` HTTP helpers | `LLMBackend.swift:51-73` |
| `LLMBackend` protocol + `LLMRequest` | `LLMBackend.swift:6-42` (collapses into the Apple backend) |
| `ModelServer` health-check loop + `Status` + `onStatusChange` | `ModelServer.swift:41-45`, `:63-119` |
| `ModelServer.availableModels` / "Load Models" | `ModelServer.swift:126-129`; `SettingsWindow.swift:338`, `:371` |
| Menu-bar connection badge | `MenuBarScene.swift:29`, `:70-72` |
| Settings → Connection section | `SettingsWindow.swift:293-308` |
| Settings → Dictation Polish section (all of it) | `SettingsWindow.swift:310-343` |
| Onboarding "Local model server" step | `WelcomeWindow.swift:479-489`, `WizardStep.model` `:273` |
| `Prompts.polishEN` / `Prompts.defaultPolish` | `Prompts.swift:8-26` |
| `--bench-polish` CLI + `PolishBenchmark` | `BetterVoice2App.swift:30-39`, `PolishBenchmark.swift` |
| `RuntimeConfig.benchPolishServerOverride` / `benchPolishEnabledOverride` | `RuntimeConfig.swift:30`, `:39` |
| `Vocabulary.promptBlock`'s polish call site | `PolishClient.swift:26-28` |
| `l2ElapsedMs` / L2 stats plumbing in the dictation path | `VoicePipeline.swift:23-48` |
| `WordInfo.alternatives` (always `[]`) and `PolishClient`'s dead `words:` param | `VoiceSession.swift:11`; bake-off spec §5 correction |

**Survives, unchanged:**

- `SummarizationClient` end to end (`SummarizationClient.swift`) — classify, summarize,
  `summarizeWithTitle`, the fallback-title call.
- `FoundationModelsBackend` (`FoundationModelsBackend.swift`) including map-reduce, which
  summarization depends on for long transcripts (`:170-232`).
- `PersonalContext` injection — summarization-only by deliberate design, and `PolishClient.swift:18-24`
  documents *why* it was never in dictation cleanup. That reasoning becomes moot but the file stays.
- `Prompts` summarization prompts, `meetingTypeClassificationPrompt`, title instructions.
- `meeting.summarization.*` config including `server`, `num_ctx`, `num_predict`, `timeout`.
- Settings → Summarization section (`SettingsWindow.swift:345-390`).
- `Vocabulary.promptBlock` — still used by summarization
  (`SummarizationClient.swift:118`, `:144`). It is only the *dictation* injection that dies.
- `MeetingSegment.rawText` / `l2Kind` (`BetterVoiceCore/MeetingTypes.swift:4-9`). Both are persisted
  in `meeting-history.jsonl` and read by tooling. Keep the enum; every new segment is `.skipped`.
  Removing it is a data-format change and does not belong in this refactor.

**Which LLM paths survive — the explicit answer.** Exactly one: **summarization**, on **any** of
its three providers. `ModelServer` does *not* disappear; it shrinks to a provider-dispatch facade
for summarization alone. Whether summarization keeps Ollama and OpenAI-compatible, or narrows to
Apple-only, is the single biggest scope question in this plan — see Open Question 1. Everything
above is written so that either answer costs the same.

**`ModelServer` after the cut:** `generate(server:prompt:systemPrompt:options:onToken:)` and
`backend(for:)`. The per-call fail-fast health probe (`ModelServer.swift:152-157`) stays if HTTP
providers stay — it is what keeps a black-holed endpoint from burning the 300s summarization
timeout. The *polling* loop and the global `status` go regardless: with cleanup gone, the only
consumer of "is the server up?" is a summarization call that already probes itself.

**Migration for existing users** (`RuntimeConfig`):

1. `polish.server` becomes unread. Do **not** delete it — the existing
   `migrateServerSectionIfNeeded` precedent explicitly leaves orphaned keys in place
   (`RuntimeConfig.swift:232-233`), and preserving it makes a revert lossless.
2. `polish.enabled` becomes unread. `polishConfig` and `polishServerConfig`
   (`RuntimeConfig.swift:43-49`, `:86-97`) are deleted.
3. **The real hazard is `WelcomeWindow.persistServer`** (`:174-201`): on a *first-ever* onboarding
   completion it mirrors the chosen provider into `meeting.summarization.server`. With the polish
   step deleted, that mirror must be rewritten to write summarization's config directly, or a
   fresh install ends up with summarization pointing at an endpoint the user never chose.
4. **Users whose summarization points at Ollama and who never notice it is down** get a silent
   `nil` summary today, surfaced as `.generationFailed` in the wizard
   (`ImportSession.swift:377-385`). If Open Question 1 lands on "Apple-only", they need a one-time
   migration + an explicit notice, not a silent switch that changes summary quality.
5. `RuntimeConfig.load`'s seeded default (`:189-191`) currently chooses Ollama when
   `SystemLanguageModel.default.isAvailable` is false. That is also the last `import FoundationModels`
   in `RuntimeConfig` and matters for §6.

### 5. Vocabulary

Today vocabulary reaches output through two channels:

1. **Prompt injection** — `Vocabulary.promptBlock` appended to the polish system prompt
   (`PolishClient.swift:26-28`), capped at ~600 chars (`Vocabulary.swift:53-74`).
2. **Deterministic find/replace** — `Vocabulary.apply(to:)` (`Vocabulary.swift:41-48`) over
   `VocabularyRules` (case-insensitive, word-boundary, longest-then-leftmost, no chaining), applied
   at `VoicePipeline.swift:52` and `ImportPipeline.swift:301`, `:306`, `:374`.

Channel 1 dies with the LLM. Channel 2 is untouched, already unit-tested
(`Tests/BetterVoiceCoreTests/VocabularyRulesTests.swift`), and explicitly designed to work when
polish is off (`Vocabulary.swift:15-18`). **So the deterministic channel alone is the Phase 2
answer** — no capability regression on `replacements`, which is where exact jargon fixes actually
live.

**What is genuinely lost:** the model's ability to *hear* a term it was told about. The bake-off
measured this, and it is small but real: Parakeet v3 raw recovered **2 of 5** jargon terms; with
`qwen3.5:4b` cleanup, **3 of 5**. Two caveats that make this weak evidence — the bench workspace
had only **2 vocabulary terms loaded** (`bench/runs/current/cleanup.json`, `vocabulary_terms: 2`),
so prompt injection was barely exercised; and 5 terms cannot separate signal from noise.

**Can FluidAudio's `--custom-vocab` replace it?** Investigated; the honest answer is *probably, but
not on faith*.

- **The API is real but undocumented-in-practice** (Correction 5). Batch usage is the CLI's manual
  three-step: `CustomVocabularyContext.loadWithCtcTokens(from:)`
  (`CustomVocabulary/CustomVocabularyContext.swift:273`) → `CtcKeywordSpotter.spotKeywordsWithLogProbs`
  → `VocabularyRescorer.create` → `ctcTokenRescore(transcript:tokenTimings:logProbs:…)`
  (`TranscribeCommand.swift:488-560`). It consumes `ASRResult.tokenTimings`, which
  `ParakeetTranscriber` already has.
- **Cost with TDT v3: a separate 99 MB CTC encoder** — approach 2 in
  `Documentation/ASR/CustomVocabulary.md:92-161`, because the 0.6B models have no built-in CTC head.
  Claimed RTFx 25.98 with 99.4% dictionary recall, ~130 MB peak RAM. At RTFx 26 a 60s dictation
  costs ~2.3s — **five times Parakeet's own inference**, which would give back most of the latency
  win. Loading the CTC encoder on demand and unloading after is explicitly suggested (`:207-210`).
- **The data model maps beautifully onto ours.** `CustomVocabularyTerm(text:aliases:)`
  (`CustomVocabularyContext.swift:44`) is exactly `vocabulary.md`: `terms` → `text`, and each
  `replacement` `{from,to}` → a term whose canonical `text` is `to` and whose `aliases` contain
  `from`. The doc's own examples are `macOS` with aliases `["Mac OS", "Mac O S", "Macos"]`
  (`CustomVocabulary.md:309-322`) — the same intent as our replacements list. No file-format change.
- **The failure mode is documented and matches our vocabulary's shape.** Short terms that collide
  acoustically with ordinary English over-fire — 12 false positives in the repro, and up to ~94 with
  the acoustic spotter-rescue on (`CustomVocabulary.md:480-538`). The mitigations are opt-in and
  off by default. Our vocabulary contains exactly such terms (`GLM`, and per the bench term list
  `Summit Pass`, `Sitecore`). Terms under ~4 chars are also skipped by `minTermLength`, and stopwords
  are dropped (`:628-632`).
- **Vocabulary-size-aware thresholds already exist** (`ContextBiasingConstants.rescorerConfig(forVocabSize:)`,
  `:369-401`), so we would not be tuning from scratch.

**Recommendation:** ship Phase 2 with the deterministic channel only; add CTC rescoring as a *bench
column* in Phase 4 (the harness already runs `fluidaudiocli`, and `--custom-vocab` is a flag it can
pass — `TranscribeCommand.swift:278`); adopt in-app only if measured jargon recall beats
deterministic-only on a vocabulary of real size, and then behind an off-by-default toggle with the
latency cost stated. See Open Question 7.

### 6. OS support floor — what it actually is

Every macOS-26-only API currently in use, and what happens to it:

| API | File | Fate |
|---|---|---|
| `SpeechTranscriber` / `SpeechAnalyzer` / `AnalyzerInput` / `AssetInventory` | `VoiceSession.swift:34-36`, `:87`, `:294`; `ImportPipeline.swift:137`, `:175`; `SpeechUtils.swift` | **Removed** in Phase 5 |
| `AttributeScopes.SpeechAttributes.{Confidence,TimeRange}Attribute` | `VoiceSession.swift:258-259`; `ImportPipeline.swift:422` | Removed with the above |
| `SystemLanguageModel`, `LanguageModelSession`, `GenerationOptions` | `FoundationModelsBackend.swift`; `RuntimeConfig.swift:2`, `:189` | **Only if summarization drops Apple** — see Open Question 1 |

With those gone, what still holds the floor up:

| Constraint | Minimum |
|---|---|
| FluidAudio package | **macOS 14 / iOS 17** (`FluidAudio/Package.swift:8-9`) |
| `OfflineDiarizerManager` | macOS 14 / iOS 17 (`FluidAudio/Documentation/API.md:47`) |
| Core Audio process taps — `CATapDescription`, `AudioHardwareCreateProcessTap` | **macOS 14.2** (SDK `AudioHardwareTapping.h`, `API_AVAILABLE(macos(14.2))`) — `SystemAudioCapturer.swift:92`, `:99` |
| `Scene.restorationBehavior` | **macOS 15.0** (SwiftUI `.swiftinterface`) — `BetterVoice2App.swift:83` etc. |
| `Scene.defaultLaunchBehavior` | **macOS 15.0** (SwiftUI `.swiftinterface`) — `BetterVoice2App.swift:82` etc. |
| `@Observable`, `MenuBarExtra`, `SettingsLink` | macOS 14 |
| `AXIsProcessTrusted`, `AEDeterminePermissionToAutomateTarget`, `AVCaptureDevice` | long-standing; `PermissionManager.swift` is entirely pre-26 |

**The real new floor is macOS 15.0**, set by two SwiftUI scene modifiers, not by anything hard.
Both are load-bearing behaviourally (they stop windows auto-opening in a menu-bar app,
`BetterVoice2App.swift:117-118`) but both are one-line `if #available` wraps or an
`NSWindow`-level equivalent. **With that work, the floor is macOS 14.2**, set by the meeting
system-audio tap.

**Apple Silicon remains required regardless.** `AsrModels.isModelValid` throws
`ASRError.unsupportedPlatform("Parakeet models require Apple Silicon")` when
`SystemInfo.isAppleSilicon` is false (`AsrModels.swift:604`), and the models are ANE-targeted
(`AsrModels.swift:452-455`). The README badge already says so. Lowering the OS floor does **not**
open Intel.

**Also required for the floor to mean anything:**
- `Package.swift:7` `platforms: [.macOS(.v26)]` → `.v15`.
- `Info.plist` has **no** `LSMinimumSystemVersion` key at all; the floor is enforced only by the
  linked deployment target. Add the key explicitly so Finder/Gatekeeper report it honestly.
- Sparkle appcast needs `sparkle:minimumSystemVersion` if older machines are ever offered a build
  they cannot run.
- `.github/workflows/ci.yml:15` pins `runs-on: macos-26`. Lowering the floor without adding an
  older runner means the lower floor is never actually compiled against — an untested claim.
- README badge and Requirements section (`README.md:5`, "macOS 26 or later").

**iOS — a possibility, not a promise.** In favour: FluidAudio supports iOS 17, the ASR and
diarization stacks are CoreML and used on iPhone (`Documentation/Benchmarks.md:73-80`), and
`BetterVoiceCore` is deliberately Foundation-only and iOS-clean by design (`Package.swift:14-19`).
Against, and this is most of the app: the Core Audio process tap has
`API_UNAVAILABLE(ios, …)` so meeting capture cannot exist on iOS at all; the global hotkey
(`CGEventTap`, `GlobalHotKey.swift`), text injection into other apps (`TextInjector`, AX API),
`AppIdentity`/`FocusTarget`, `NSWorkspace`, `NSAlert`, `MenuBarExtra`, `osascript`-driven Apple
Notes writing (`NotesScript.swift`), and Sparkle are all macOS-only. **Dictation-as-injection is
the product, and injection into arbitrary apps is impossible on iOS.** A realistic iOS target is a
different app — record/import → transcribe → diarize → summarize, sharing `BetterVoiceCore` and the
new `Transcriber` — not this app recompiled. Treat it as a reason to keep the seam clean, not as a
roadmap item.

### 7. Sequencing

Each phase compiles, ships, and leaves the app working.

**Phase 0 — Measure before committing (bench only, no app change).**
Answers the three things that could invalidate the plan:
(a) the v3 chunk-boundary dropout (Correction 7) — run v3 against the 57.5-min fixture and the
dictation fixture with default `melChunkContext`, then with `melChunkContext: false`, then with
`dualDecodeArbitration: true` (`--no-mel-context`, `--dual-decode-arbitration`,
`TranscribeCommand.swift:316-318`), and diff word coverage against v2;
(b) ~~first-ever CoreML compile + cold load time on this Mac after a `clearModelCache`~~ — **DROPPED**,
the launch warm-up ships regardless so the number cannot change the design;
(c) whether `--custom-vocab` beats deterministic-only on a real-size vocabulary;
(d) **Parakeet Unified as a dictation candidate** (decision 9) — English-only is now acceptable
(decision 3), and dictation needs no timings, so it is eligible. Score it on the dictation fixture
against TDT v3 and v2. It is *not* eligible for meetings (Correction 4);
(e) **v2 as the primary candidate, not just a fallback** — decision 3 removed v3's multilingual
advantage, and v2 did not exhibit the 5.84s dropout. The question is whether 2.6 WER points is worth
buying content integrity, which is a judgement the numbers inform but do not settle.
**Gate: if (a) shows systematic content loss, v2 becomes the default and §1 changes.**
**Note:** decision 7 (CTC boosting on import) and a Unified win on dictation are compatible only
because the paths differ — Unified has no timings, so boosting can never apply to dictation.

**Phase 1 — Introduce the seam on the import path. No behaviour change.**
Add `Transcript`/`TimedWord`/`Phrase` in Core, the `Transcriber` protocol, `AppleSpeechTranscriber`
(existing code, moved), and phrase synthesis in Core with unit tests. **`ImportPipeline` routes
through the protocol; `VoiceSession` does not.** Ships identical behaviour; every test still passes.

**Correction (2026-07-30): the original Phase 1 said `VoiceSession` also routes through the protocol
"with identical behaviour". That is not possible.** `ImportPipeline` transcribes a file
(`analyzer.start(inputAudioFile:finishAfterFile:)`, `ImportPipeline.swift:175`) and maps cleanly onto
`transcribe(fileURL:)`. `VoiceSession` does not: it streams live mic buffers into
`analyzer.start(inputSequence:)` through an `AsyncStream<AnalyzerInput>`
(`VoiceSession.swift:113-118`). Putting it behind a batch, file-based protocol means capturing to a
temp WAV and transcribing after the hotkey is released — added latency, a temp-file lifecycle, and a
new error channel. That *is* Phase 3, so it belongs there and nowhere else. Phase 1 is import-only.

**Related finding, in favour of Phase 3:** `VoiceSession.onPartialResult` (`:52`) is fired on every
volatile result (`:137`) but **is never assigned by any caller** — it is dead. So streaming currently
produces no live text anywhere in the UI; its only benefit is that transcription has already finished
when the hotkey is released. Going batch therefore costs latency at release (~0.0042 s/s → ~1.25 s on
a 5-minute dictation) and loses nothing visible, which removes the main objection to Phase 3. Delete
`onPartialResult` with the rest of the streaming machinery.

**Phase 1 inventory — what a full read of `ImportPipeline` turned up (2026-07-30).**

*Contract correction, already applied.* An earlier draft of `Transcript` made `words` the primary
unit. **Apple's import path has no per-word timings and no confidence at all** — `extractTimeRange`
(`ImportPipeline.swift:421-435`) reads the `.audioTimeRange` attribute once per `result.isFinal`, so
the unit Apple hands over is a *phrase*. Both downstream consumers (`SegmentBuffer.Entry`,
`groupIntoTurns`) want phrases too. So `phrases` is the seam's currency and `words` is optional;
Parakeet fills `words` and derives phrases, Apple fills only phrases. Making `words` required would
have forced the Apple conformance to fabricate timings to satisfy the shape.

*What batching cannot preserve.* `SegmentBuffer` itself is safe — every threshold is measured in
*audio* timestamps and buffered characters, with no wall clock or timer (`SegmentBuffer.swift:49-65`,
`:78-100`), so replaying entries in order after transcription yields bit-identical batches, trigger
reasons, `polishedSegments` and L2 counters. Four things still change, and only the first is fixable:

1. **`.transcribing` progress granularity** — emitted from inside the results loop
   (`ImportPipeline.swift:163`) and the sole source of intra-transcription progress. *Fixable:* the
   `Transcriber.transcribe` progress callback exists for exactly this, so the Apple conformance
   reports as it drains the stream and the pipeline maps it through unchanged.
2. `MeetingSegmentRecord.timestamp` is `Date()` at flush time (`:377`), so stamps cluster at the end.
3. **Crash durability is lost.** `:72` and `MeetingHistory.swift:11` both claim streaming-to-disk
   *while the run is in progress*; batched, a crash loses everything rather than everything-so-far.
4. **Wall clock increases.** Today each `PolishClient` await (`:349`) suspends the results consumer
   while the analyzer keeps producing, so L2 latency is partly hidden behind ASR. Serialized, the two
   costs add — visible in `ImportBenchmark`'s `total_processing_s` / `rtfx`.

**2–4 all vanish when the polish machinery is deleted, which raises a sequencing question.** Phase 1
as written ("no behaviour change") is not fully achievable while polish stays: batching serializes ASR
and polish. Either Phase 1 absorbs the polish deletion (bigger, but genuinely faster and the end state
anyway) or Phase 1 ships a measurably slower import for one phase. The plan already uses the first
argument to justify deleting polish in Phase 2 rather than Phase 4 — *"holding it back to a later phase
just means shipping a slower app in between."* **Owner decision needed before Phase 1 lands.**

*Pre-existing bugs found. None are caused by this migration; all are worth fixing while in the area.*

| # | Bug | Evidence |
|---|---|---|
| 1 | `polishedSegments` is built by an awaited LLM call per flush, then **discarded** on the labeled multi-speaker path — `performDiarization` rebuilds from raw `allPhraseEntries` and re-polishes per turn. Every batch-level L2 call on that path is paid for, written to disk, and thrown away | `:322` → `:203`, `:226`, `:278` |
| 2 | `logL2Summary()` reports only the **discarded** batch path — `polishTurnText` touches none of the counters — and is called at `:186`, *before* turn polishing even starts | `:298-308`, `:186`, `:416` |
| 3 | `meeting-history.jsonl` records only flush batches, so the bench/distillation consumer **never sees the text the user actually gets** on a multi-speaker import | `:376-390` |
| 4 | `reportingOptions: [.volatileResults]` is requested then discarded by `guard result.isFinal` — wasted compute on a file path with no partial consumer | `:140`, `:153` |
| 5 | `resultTask` is never cancelled. A throw at `:174` or `:175` leaves it awaiting a stream that will never finish, retaining the transcriber. No `defer`, no `cancel()` | `:149`, `:174-175` |
| 6 | Three **unmapped** error paths reach the user as raw engine strings rather than `ImportError`: `ensureModelInstalled` (`:143`), and both `AVAudioFile`/`analyzer.start` throws (`:174`, `:175`) — inconsistent with `:128`, which maps the *same* failure on the *same* URL | `:143`, `:174`, `:175` |
| 7 | `extractTimeRange` returns `(0, 0)` silently on a missing attribute, cascading into rewound progress, a pause-flush that can never fire, collapsed batch time ranges, and a zero-width `PhraseSpan` that always attributes to Unknown | `:433` → `:163`, `SegmentBuffer.swift:54`, `SpeakerAlignment.swift:119` |
| 8 | `polishedSegments.isEmpty` at `:204` is the "no phrases" gate only *by accident* — it holds because `flushFinal` flushes any non-empty buffer. Reorder the batch path and it silently starts returning `[]` for a good transcript. **Direct hazard for this refactor** | `:204`, `SegmentBuffer.swift:68-72` |
| 9 | Escaping un-awaited `Task { @MainActor … }` for diarizer progress can fire after the next `run` reassigned `progressHandler`, rewinding the bar. The live path runs two passes on the same instance | `:241-243`, `ImportSession.swift:263-286` |
| 10 | `.changed`/`.identity` is classified **before** vocabulary on the batch path and **after** it on the turn path, so the same input yields different `l2Kind` | `:356` vs `:304-305` |
| 11 | Progress at `:163` is neither monotonic nor lower-bounded — no `max(0, …)`, no ratchet | `:163` |
| 12 | The silence gate covers only the live path, so a silent *file* import returns a zero-segment, error-free `MeetingResult` — the exact "empty successful transcript" `:95-96` says it exists to prevent | `AudioFileSilence.swift:14`, `MeetingCoordinator.swift:252` |

*Also preserve:* there is **no analyzer teardown** — import relies on `finishAfterFile: true` plus ARC,
unlike `VoiceSession.swift:207`. And `modelRetention: .processLifetime` (`:144`) must survive the
move, or the live path's second `pipeline.run` pays a model load it does not pay today.

**Phase 2 — Parakeet on the import path, behind a hidden default.**
Add `ParakeetTranscriber`, `AsrModelStore`, download UI, launch warm-up. `ImportPipeline` defaults
to Parakeet; an undocumented config key selects Apple for A/B. Dictation is still Apple ASR.

~~Delete the dictation and import polish calls in this phase.~~ **Done in Phase 1** — batching behind
the seam serializes ASR and polish, so keeping polish would have shipped a slower import for a phase.

**Added to this phase by Phase 1's findings — the separator convention.** Both phrase consumers
concatenate with a bare `.joined()` and no separator (`SpeakerAlignment.swift:232`,
`SegmentBuffer.swift:84`), which works only because Apple's segments carry their own leading space;
the `SpeakerAlignmentTests` fixture encodes `"Hello "` with a trailing space to match.
`PhraseSegmentation.joinWords` returns trimmed text, so Parakeet's phrases fed straight in produce
`"One.Two."`. Silent space loss, no crash, nothing flags it — `PhraseSegmentationTests`
`testGroupIntoTurnsConcatenatesPhraseTextWithoutASeparator` pins the current behaviour. Resolving it
means picking one convention across the seam and both consumers, updating that fixture, and
**verifying against the real fixture rather than by inspection** — a naive `" "` separator breaks any
segment that legitimately begins with punctuation.

**Phase 3 — Dictation goes batch.**
`VoiceModule` switches `VoiceSession` → `MicCapturer` + `ParakeetTranscriber`. Temp-WAV lifecycle,
silence and minimum-duration guards, the >60s progress affordance, a real dictation error channel.
`VoiceSession` still exists (Phase 1 conformance) so a revert is one line.

**Phase 4 — Delete the cleanup machinery.**
Everything in §4's "dies" table. Config migration. Settings and onboarding surgery. Menu-bar badge
removal. `--bench-polish` removal. Optionally adopt CTC vocabulary boosting if Phase 0(c) earned it.

**Phase 5 — Delete Apple ASR and lower the floor.**
Remove `AppleSpeechTranscriber`, `SpeechUtils`, all `import Speech`. Drop `Package.swift` to
`.macOS(.v15)`, add `LSMinimumSystemVersion`, gate or replace the two macOS-15 scene modifiers if
going to 14.2, add an older CI runner, update README and appcast. **Deliberately last**, because
until it lands the previous engine is one config key away.

### 8. Testing

- **Unit (`BetterVoiceCoreTests`, no TCC / no models):** phrase synthesis from word timings —
  punctuation splits, gap splits, the joined-without-separator spacing hazard, empty and
  single-word inputs; the `vocabulary.md` → `CustomVocabularyContext` mapping if §5 is adopted;
  `AsrModelStore` state machine against a fake downloader.
- **Existing suites must stay green** — `SpeakerAlignmentTests` in particular, since it pins the
  contract phrase synthesis has to satisfy.
- **Bench, paired, same audio:** `--bench-meeting` gains `--engine {apple,parakeet}` so
  `bench/run.py` can score both through the *app's own pipeline* rather than through
  `fluidaudiocli`. That is what makes the A/B measure the shipped path, including phrase synthesis
  and diarization alignment, not just the model.
- **Diarization regression:** the DER-proxy sidecar path already exists
  (`ImportBenchmark.swift:177-185`, `BetterVoiceCore/DiarizationScoring.swift`). Diarization runs on
  audio and is engine-independent, but *alignment* consumes ASR timings — so this is the check that
  phrase synthesis did not degrade attribution. **This is the most likely place for a silent
  regression.**

  **Correction (2026-07-30, from the Phase 2 A/B): `speaker_coverage` cannot compare engines.** It is
  `labeled_time / audio_duration`, which conflates two independent things — how much of the audio the
  engine's spans blanket, and how much of those spans got a speaker. Measured on the 57-min fixture:

  | | labeled/audio (`speaker_coverage`) | labeled/segtime (*attribution*) | segtime/audio (*span tightness*) |
  |---|---:|---:|---:|
  | Apple | 0.9692 | **0.9957** | 0.9733 |
  | Parakeet v3 | 0.9411 | **0.9912** | 0.9495 |

  Parakeet looks 2.8 points worse and is actually 0.45 points worse. Its word-derived spans hug real
  speech; Apple's phrase ranges include surrounding silence, so Apple's segments blanket 97.3% of the
  audio against Parakeet's 95.0%. **Use `labeled/segtime` for attribution across an engine change**,
  and treat `speaker_coverage` as valid only within one engine. `der_proxy_fer` needs a
  `<audio>.speakers.json` ground-truth sidecar, which the meeting fixture does not have — so it was
  not available for this comparison and the decomposition above stood in for it.
- **Long-form:** the 57.5-min 4-speaker fixture, asserting 4 speakers / ~179 turns / ~97%
  attribution and no boundary dropout.
- **Manual:** first-run download on a cleared cache; download killed mid-encoder then resumed;
  airplane mode with and without models; dictation at 3s / 60s / 5min; Bluetooth (AirPods) capture,
  including that the start cue is still audible (`VoiceModule.swift:110-112`); quit mid-dictation
  and mid-download.

### 9. Risks and rollback

| Risk | Evidence | Mitigation |
|---|---|---|
| **v3 drops content at 15s chunk boundaries** | ~6s lost in the bench fixture (Correction 7, independently re-verified); FluidAudio issue #594 documented on `AsrTypes.swift:26-39` | Phase 0(a) gate; fall back to `melChunkContext: false`, `dualDecodeArbitration: true`, or v2 |
| Phrase synthesis degrades speaker attribution | `groupIntoTurns` is timestamp-driven; Apple gave phrases for free | `der_proxy_fer` before/after on fixtures; unit-test the segmentation |
| First-run 470 MB download abandonment | new cost, no precedent in this app | Start it in onboarding; byte-weighted progress; whole-file resume; app fully usable for meetings-from-file… only after it completes — no graceful degradation exists |
| Silent 470 MB re-download on a corrupt cache | `DownloadUtils.swift:224-258` | Surface it in `AsrModelStore`; consider `enforceOffline` |
| Jargon recall drops without prompt injection | 3/5 → 2/5 measured, on 5 terms and a 2-term vocabulary | Deterministic channel unchanged; Phase 0(c) evaluates CTC |
| Post-release wait on very long dictations | 0.0042 s/s → 1.25s at 5 min | Stated openly; progress affordance >60s |
| Cold-load stall on first hotkey | unmeasured on Mac, and staying that way | Launch warm-up, unconditionally (Phase 0(b) dropped) |
| Summarization quality changes if providers narrow | Measured: `bench/results/2026-07-30-summarization-bakeoff.md` | Settled — `qwen3.5:9b-mlx` is the default, all three providers stay selectable |
| **Ollama default means a fresh install cannot summarize** | Apple was the zero-setup path; Ollama is a separate app plus a 5.6 GB pull | **Open — Phase 4.** See decision row 12 |
| Onboarding version bump re-onboards everyone | `WelcomeWindow.swift:53`, `BetterVoice2App.swift:174` | Open Question 6 |
| Lowered floor never compiled against | `ci.yml:15` pins `macos-26` | Add an older runner in Phase 5 or do not claim the floor |

**Rollback.** Phases 1–3 are revertible by config: the `Transcriber` protocol keeps
`AppleSpeechTranscriber` alive and selectable through Phase 4. After Phase 4 (polish deleted) the
LLM path is gone but the *engine* can still be flipped. Only Phase 5 is one-way, which is why it is
last and why it is separated from the floor-lowering it enables.

**A/B with the existing harness.** `bench/run.py` already treats each ASR as a column
(`bench/engines.py:245`) and each stage as resumable. Adding `--engine` to `--bench-meeting` makes
"the app with Apple" and "the app with Parakeet" two columns scored against the same `verbatim.txt`
and `intended.txt` — a paired comparison on the shipped code path. `--no-polish`
(`ImportBenchmark.swift:43-45`) already isolates raw ASR, so the four cells (Apple/Parakeet ×
with/without cleanup) are reachable today with one flag added.

## Out of scope

- Any streaming ASR engine (Parakeet EOU, Nemotron, `SlidingWindowAsrManager`,
  `StreamingUnifiedAsrManager`) — unmeasured, and unnecessary per Correction 1.
- A user-facing engine/model picker. The bake-off's own §"Out of scope" declined this and nothing
  has changed; one measured default is the product.
- Multilingual work beyond keeping v3's coverage. `SpeechUtils.bestLocale()` becomes a language
  *hint* (`AsrManager.transcribe(…language:)`, v3-only script filtering) rather than a model
  selector; the Settings language picker offers only "Follow system" and "English" today
  (`SettingsWindow.swift:406-413`).
- Diarization changes. Engine-independent, already has its own scorer and threshold rationale
  (`OfflineDiarizerHost.swift:14-24`).
- `MeetingSegment.rawText` / `L2Kind` removal — a persisted-format change.
- iOS. See §6.
- Any bundle-id, Team, or `.app`-name change.

---

## Decisions — resolved with the owner, 2026-07-30

All eleven open questions are answered. Where a decision departs from the recommendation, the
reasoning is the owner's and is recorded as such.

| # | Decision | Note |
|---|---|---|
| 1 | **Summarization keeps all three providers** (Apple + Ollama + OpenAI-compatible) | Conditional on Apple's context window. Measured on macOS 26.5.2: `SystemLanguageModel.default.contextSize` = **4096**; WWDC26 shows `8192`, so OS 27 roughly doubles it. A 57-minute meeting is ~14,000 tokens, so **even 8192 is ~1.7x short** and map-reduce stays mandatory. `PrivateCloudComputeLanguageModel` (32K) would fit but needs network, is usage-capped behind iCloud+, and requires macOS 27 — which *raises* the floor. Ruled out. |
| 2 | **Parakeet TDT v3 with default settings** — decided by Phase 0(a), see `bench/results/2026-07-30-phase0-findings.md` | The dropout is real but costs ~0.5% of content (58 words on the 57-min meeting). `--no-mel-context` closes it but garbles the seam, costing 2.0 WER points, and is **dominated by v2** (27.3% vs 27.8% is a tie, while being 24% slower and needing a non-default flag). `--dual-decode-arbitration` does nothing for this failure mode — byte-identical to default. Owner chose v3 default: best accuracy (25.3%), accepting silent boundary loss. Preserves multilingual in reserve. |
| 3 | **English-only** — reversed from an initial "keep multilingual" | Drops the language picker, `SpeechUtils` locale selection and the zh-Hans/zh-CN fallbacks. **Interacts with #2:** v3's chief advantage was multilingual coverage, so English-only removes the main reason to prefer it over v2 — and v2 is the variant that did *not* drop the 5.84s passage. v2 costs 2.6 WER points for content integrity. Phase 0 must weigh that trade explicitly. |
| 4 | **Keep the HUD visible with a distinct "transcribing" state** | No threshold constant. `BetterVoice2App.swift:211-214` currently hides the HUD on `.processing`; that changes. |
| 5 | ~~**Delete the dictation WAV on success, keep it on failure**~~ → **SUPERSEDED: dictation writes no audio file at all** | The decision assumed batch transcription requires a file. It does not — `AsrManager` has `[Float]` and `AVAudioPCMBuffer` overloads alongside the URL one, so dictation transcribes straight from memory. Owner's call once that was established: no file, anywhere. Dictation speech never touches disk, which is a genuine privacy improvement for a local-first app, and the entire temp-file lifecycle disappears — no retention cap, no pruning, nothing to leak. **Cost, accepted knowingly:** a failed dictation leaves no audio to inspect; only the text in `VoiceHistory`. Settings → Data rows for model disk usage and removal still apply, and `Transcriber.unload()` exists so removing them also drops the loaded engine. Meetings keep their file: diarization needs it, and `transcribe(url:)` routes to disk-backed chunking above ~30s where the in-memory path has no such fallback. |
| 6 | **Bump `currentOnboardingVersion`, but skip already-satisfied steps** | Returning users see the model download and the Done screen, little else. |
| 7 | **REVERSED by Phase 0(c) — do not adopt CTC vocabulary boosting on either path** | It doubles jargon recall (2/5 → 4/5) and throughput is a non-issue (RTFx 256, so the docs' ~26 warning was wrong). But it over-fires, substituting vocabulary terms for common words: *'megabytes a Sitecore'*, *'takes some Kimi GLM out'*, *'for me to Sitecore in'*. Dropping sub-6-char terms cuts the penalty from 4.6 to 2.0 WER points but visible nonsense survives. Owner's call: **the false substitutions are disqualifying.** Jargon stays on the deterministic `Vocabulary.apply()` channel, which does exact word-boundary replacement and therefore carries **zero** false-substitution risk. The actionable path to better jargon is expanding `vocabulary.md` (decision row 'Now'), not acoustic boosting. |
| 8 | **Floor to macOS 15**, and add a `macos-15` CI job | Follows from #1: Apple Foundation Models stays optional, so nothing requires macOS 26. Without the CI job the lower floor is an uncompiled claim. |
| 9 | **REVERSED by Phase 0(d) — Unified rejected** | Wins the intended reference by 1.1 points but only by recovering v3's boundary dropout; loses the verbatim comparison by 3.9 points, mangling 'summit pass sitecore' into 'I kind passed FIC core'. **3.25x slower** on our audio (75x vs 244x RTFx), contradicting FluidAudio's own docs. Identical jargon recall at 2/5. TDT v3 serves both paths. Side effect: Unified was the main reason English-only mattered, so decision 3 is now a pure scope choice and cheaply revisitable. |
| 10 | **DONE — `MeetingSegment.rawText` and `l2Kind` removed** | Decided as a **persisted-format change** needing reader migration, and budgeted accordingly. On implementation that premise was **false**: `JSONLWriter.append` takes an `Encodable`, and nothing in the app or in `bench/` decodes `meeting-history.jsonl` or `voice-history.jsonl`. With no reader there was nothing to migrate — old lines simply carry keys nobody looks for. The cost was a type cleanup after all. Also removed in the same pass, having turned out to be the same kind of vestige: `MeetingSegmentRecord`'s `rawText`/`polishedText`/`l2Kind`/`l2ElapsedMs`, `VoiceHistoryEntry`'s `l1Text` (a *duplicate* of `rawSA`, not merely vestigial — both were assigned `transcription.fullText`), `polishedText`, `words` and `audioPath`, the `WordInfo` type, and the `L2Kind` enum. Lesson for the next row like this: check for a decoder before budgeting a format migration. |
| 11 | **`Notify.warn` on real faults only** | Model-not-ready and transcription-failed notify; sub-300ms audio and silent capture are silent no-ops. |
| 12 | **REVISED — `ornith:9b` is the summarization default**, all three providers stay user-selectable | Supersedes the `qwen3.5:9b-mlx` decision recorded here on 2026-07-30. That one rested on a bake-off run which, on audit, was **not measuring the shipping pipeline**: it fed the models `summary_input_raw.txt` (anonymous `S1`–`S4` speaker labels, uncorrected jargon) and passed `--no-context`, which in `bench/summarize.py` suppressed the **vocabulary** block as well as personal context. The app always sends vocabulary and runs `Vocabulary.shared.apply` on transcript text, so the benchmarked models produced `iSummit` and `SiteCore` where the app produces `Summit Pass` and `Sitecore`. Re-run in the shipping configuration (named speakers, vocabulary sent, current prompt), thread recall is a **three-way tie at 72.7%** — ornith:9b, gemma4:12b and qwen3.5:9b-mlx — with qwen3.5:4b-mlx at 56.8%. Since the metric no longer discriminates, the owner chose by **reading the four summaries** (`bench/summary_compare.py` renders them). Secondary support: ornith:9b is the smallest of the three at **5.6 GB** vs qwen 8.9 GB and gemma 6.8 GB, which is a fresh install's download on top of Parakeet's 470 MB; it is publicly pullable from the Ollama library; and it is thinking-capable but `makeOllamaRequestBody` sends `think: false`. **Two caveats on the record:** the earlier blind judged ranking (`bench/runs/pod/judge/verdict.md`), which placed ornith:9b second on quality and flagged an attribution failure, scored the degraded input and is **void** — it has not been re-run against these summaries. And ornith:9b is a *coding-assistant*-tuned build, an unusual choice for meeting notes, accepted on read quality rather than on fit. **Consequence still unresolved (Phase 4):** `RuntimeConfig.swift` seeds Apple whenever Apple Intelligence is available, so shipping an Ollama default means a fresh install needs Ollama plus a 5.6 GB pull before it can summarize, where Apple needed nothing — while Apple remains unfit for long meetings (row 1). Choose: (a) seed Ollama and make onboarding install-and-pull; (b) seed Apple, accept degraded first-run summaries, prompt to upgrade; or (c) seed nothing and ship diarized transcripts until a provider is configured. Not decided here. |

**Download budget, settled by Phase 0:** all models fetched during onboarding, no lazy fetching.
With Unified rejected (row 9) and CTC boosting rejected (row 7), the first-run cost is **470 MB** —
Parakeet TDT v3 alone, plus the 21 MB diarization models already present. Down from the ~1.13 GB the
plan originally budgeted. There is still no partial-capability mode while downloading, so the gate is
real, but it is now a single model.

## Original open questions — resolved above, retained for the reasoning

*(Each entry's analysis and trade-offs still stand; the recommendations were superseded where the
decisions table says so.)*

**1. Does summarization keep Ollama and OpenAI-compatible, or narrow to Apple-only?**
This is the largest scope fork in the plan. Keeping them means `ModelServer`, `LLMBackend`,
`OllamaBackend`, `OpenAICompatibleBackend`, the per-call health probe, the Settings provider form,
and the model-discovery dropdown **all survive** — about 500 of the ~700 lines listed as "dies"
come back. Narrowing to Apple-only deletes all of it, but caps summarization at Apple's small
context window, which is exactly why `FoundationModelsBackend.mapReduce` exists
(`FoundationModelsBackend.swift:170-232`) and which the code itself warns degrades long meetings
(`SummarizationClient.swift:88-96`). **Recommendation: keep all three providers for summarization.**
The 57.5-minute meeting is a real use case, map-reduce is a workaround not a solution, and the
maintenance burden of an HTTP client is trivial next to a wrong summary. Deleting the *polish*
plumbing already gets ~80% of the complexity win.

**2. Which Parakeet variant, if Phase 0 shows v3 dropping content at chunk boundaries?**
Options: (a) v3 with `melChunkContext: false` — the documented fix for issue #594, but it changes
the decode path the bake-off measured; (b) v3 with `dualDecodeArbitration: true` — better quality
per `AsrTypes.swift:41-62` but 1.1–1.5× slower and off by default; (c) v2 — measured at 27.84% vs
v3's 25.26% (2.6 points worse) but English-only and it did *not* drop the passage v3 lost;
(d) Parakeet Unified — best English WER and RTFx but **no timings**, so meetings are impossible
(Correction 4). **Recommendation: (a) first, verified on the long fixture, falling back to (b).**
Do not choose blind — this is why Phase 0 is a gate rather than a task.

**3. English-only, or keep multilingual?**
v3 is multilingual (25 languages, `Documentation/Benchmarks.md:14-38`) and is the slower, slightly
less accurate English option. If English is the only language that matters, v2 or Unified are both
better on English. But `RuntimeConfig.language` exists, `SpeechUtils` has zh-Hans/zh-CN fallbacks
(`SpeechUtils.swift:40`), and the codebase carries Chinese comments and a `Localization.swift`.
**Recommendation: keep v3 for multilingual coverage** unless you confirm English-only, in which case
Unified-for-dictation + v2-for-meetings becomes worth measuring. **Are non-English users real?**

**4. Progress indicator threshold for batch dictation — 60s, or never?**
At 0.0042 s/s, 60s of speech costs ~0.25s. Arguably nothing needs saying below several seconds
(~20 minutes of speech). But the HUD currently *hides* on the `.processing` transition
(`BetterVoice2App.swift:211-214`), so long dictations would show nothing at all while working.
**Recommendation: keep the HUD visible in `.processing` with a distinct "transcribing" state instead
of adding a threshold** — simpler, always honest, and no magic number. Do you want any visible
transcribing state, or is silence-then-text preferable?

**5. Dictation WAV retention, and should the 470 MB be user-manageable?**
Two sub-questions. (a) Delete the dictation WAV after injection, or keep it? `VoiceHistory` already
persists text and its comment refers to WAVs "to help debug transcription issues"
(`VoicePipeline.swift:59`), though dictation writes none today. Keeping them mirrors
`LiveMeetings/`, which the code already flags as an accumulating-disk trade-off
(`MeetingCoordinator.swift:300-305`). **Recommendation: delete on success, keep on failure, with a
capped debug retention behind a hidden key.** (b) Add Settings → Data rows for model disk usage and
"Remove downloaded models" (`DownloadUtils.clearModelCache`, `:261`)? **Recommendation: yes** — 470 MB
appearing invisibly under `Application Support` is a support ticket waiting to happen.

**6. Bumping `currentOnboardingVersion` re-runs onboarding for every existing user. Acceptable?**
`WelcomeWindow.swift:53` is 4; `BetterVoice2App.swift:174` gates the Welcome window on
`onboardingVersion < current`. Existing users genuinely need the new model download, so a forced
walkthrough has a real justification — but they will also re-see the permission, personal-context,
vocabulary, and Notes steps. Alternatives: bump and let them walk it; or leave the version alone and
trigger download lazily at first use, which risks a 470 MB surprise mid-dictation.
**Recommendation: bump it, but make the wizard skip already-satisfied steps** so a returning user
sees the model step and the Done screen and little else.

**7. CTC vocabulary boosting — evaluate now, or defer entirely?**
Costs 99 MB extra, drops RTFx from 263 to ~26 when active (~2.3s on a 60s dictation, giving back
most of the latency win), and its documented failure mode — short acoustically-colliding terms
over-firing — matches terms already in your vocabulary (`GLM`). Against that, the only thing prompt
injection measurably bought was 3/5 vs 2/5 jargon recall on a 5-term list with a 2-term vocabulary
loaded. **Recommendation: measure it in Phase 0(c) but plan to ship without it**, adopting later
only if a real-size vocabulary shows a clear win, and then off by default on the dictation path
(where latency matters) and on by default for imports (where 2.3s of a multi-minute job is free).
**Is jargon accuracy worth 2s per dictation to you?** You are the only user who can answer that.

**8. How low should the OS floor actually go, and will you test it?**
macOS 15 is nearly free (delete `import Speech`, drop the deployment target). macOS 14.2 additionally
requires gating or replacing `defaultLaunchBehavior` and `restorationBehavior`. Either way,
`ci.yml:15` pins `macos-26`, so **without an older CI runner the lower floor is a claim nobody has
compiled, let alone run.** **Recommendation: go to macOS 15 in Phase 5, add a `macos-15` CI job, and
stop there** unless you know of real macOS 14 users — 14.2 buys one OS version for a real
compatibility-shim burden. Do you have telemetry or user reports on OS versions? (None found in
the repo.)

**9. Parakeet Unified for the dictation path only — worth a measurement?**
It is the best English batch engine in FluidAudio (2.15% vs TDT v3's 2.6% avg on test-clean, higher
RTFx, native punctuation) and dictation needs **no timings**, so Correction 4 does not disqualify it
there. Cost: a second model family. The int8 encoder is ~565 MB per encoder by the library's own
note (`UnifiedConfig.swift:5-8`), so Unified-for-dictation + TDT-for-meetings is roughly **1 GB**
of downloads instead of 470 MB, and it was never in the bake-off.
**Recommendation: no for this migration** — one engine, one download, measured numbers. Log it as a
follow-up experiment. **Unless you would accept 1 GB, in which case Phase 0 should add it as a
column.**

**10. `MeetingSegment.rawText` and `L2Kind` — keep the fields as inert, or clean them up?**
With cleanup gone, `text == rawText` always and `l2Kind` is always `.skipped`. They are persisted in
`meeting-history.jsonl` (`ImportPipeline.swift:376-390`) and consumed by bench tooling.
**Recommendation: keep them, always `.skipped`**, and revisit in a separate data-format change. It
costs nothing and keeps `meeting-history.jsonl` readable by existing scripts.

**11. Does dictation need a user-visible error channel, and what should it say?**
Today a failed dictation just logs and returns to idle (`VoiceModule.swift:133-141`,
`:161-165`) — the user sees nothing. Post-migration there are new failure modes worth naming: models
not downloaded, audio too short (<300ms, `AsrTypes.swift:236`), silent capture, transcription threw.
**Recommendation: `Notify.warn` for "model not ready" and "transcription failed", silent no-op for
too-short and silent-audio.** Do you want any notification at all on a failed dictation, or is
silence preferable for something triggered dozens of times a day?
