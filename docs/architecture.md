# Better Voice Technical Architecture

## System Overview

Better Voice is a macOS menu bar application that provides two core capabilities: **dictation mode** (hotkey-triggered voice-to-text input into any application) and **meeting mode** (long-form meeting recording with real-time transcription, speaker diarization, and Markdown export). The client is built in Swift 6.2 targeting macOS 26 (Tahoe), using Apple's SpeechAnalyzer framework for on-device speech recognition and AVCaptureSession for audio capture. Post-processing (L2 polish) is handled by a local LLM served via ollama, personalized through a free-text `~/.better-voice/personal-context.md` injected into the prompt.

## Dictation Mode Flow

### Streaming Transcription via SpeechAnalyzer

`VoiceSession` manages the audio capture and transcription pipeline:

1. **Locale discovery** -- Resolves the transcription locale from the `language` config key (English by default; falls back to the system language when unset), and downloads the speech model via `AssetInventory` if not already installed.
2. **SpeechTranscriber configuration** -- Created with `reportingOptions: [.volatileResults, .alternativeTranscriptions]` and `attributeOptions: [.audioTimeRange, .transcriptionConfidence]` to get partial results, alternative candidates, timestamps, and per-word confidence scores.
3. **SpeechAnalyzer** -- Wraps the transcriber; receives audio via an `AsyncStream<AnalyzerInput>` fed from the capture delegate.
4. **Result processing** -- A background `Task` iterates `transcriber.results`. Final segments are accumulated into `finalizedText` with word-level `WordInfo` (text, confidence, alternatives, timing). Volatile (partial) results are forwarded via `onPartialResult` for live UI feedback.
5. **Stop and finalize** -- On stop, capture halts, `inputBuilder.finish()` signals end-of-audio, then `analyzer.finalizeAndFinishThroughEndOfInput()` is awaited with a 5-second timeout. The accumulated text and word info are returned as a `TranscriptionResult`.

### Raw transcription (L1)

Better Voice trusts Apple SpeechAnalyzer's own best transcription ordering with no rule-based rewriting — the earlier `AlternativeSwap`/correction-dictionary stage was removed in favor of prompt-based cleanup (L2) and `personal-context.md`. `VoicePipeline` records the raw text as `l1Text` and passes it straight to L2.

### Remote LLM Polish (L2)

`PolishClient` delegates to `ModelServer`, which supports both Ollama and OpenAI-compatible API backends:

- **Health monitoring** -- `ModelServer` runs periodic health checks (default every 30s) against `/api/tags` (Ollama) or `/v1/models` (OpenAI). Status is reflected in the menu bar icon.
- **Generation** -- Sends the raw transcription as the user prompt with a system prompt (default: "Convert spoken language to written form. Output only the result."), plus `personal-context.md` when enabled. Output length is sized to the input so OpenAI-compatible backends don't truncate. Returns `nil` (skipping polish) if the server is disconnected or the polish feature is disabled.
- **Graceful degradation** -- If the server is unreachable, the pipeline continues with the raw transcription.

### Text Injection

`TextInjector` uses a clipboard-based approach: saves the current pasteboard content, writes the final text to the pasteboard, synthesizes a Cmd+V keystroke via `CGEvent`, then restores the original clipboard after a 0.5s delay. The target application is identified by `AppIdentity` (bundle ID, process ID) captured at recording start.

### Voice History Persistence

Every dictation session is recorded to `~/.better-voice/voice-history.jsonl` by `VoiceHistory`. Each entry contains the raw SpeechAnalyzer output, polished text, final text, word-level info with confidence and timing, audio file path, and target application identity. This file (paired with the saved `audio/*.wav`) is a local debugging log for inspecting transcription/polish behavior, and can be auto-deleted.

## Meeting Mode Flow

### Audio Capture and Dual-Path Processing

Meeting mode is initiated from the status bar menu. `StatusBarController` creates a `MeetingSession` and wires up real-time callbacks.

`MeetingSession.start()` sets up an `AVCaptureSession` with a `MeetingCaptureDelegate` that forks each audio buffer into three paths:

1. **SpeechAnalyzer path** -- Audio is format-converted if needed (to match `SpeechAnalyzer.bestAvailableAudioFormat`, typically 16kHz Int16 mono) and fed via `AsyncStream<AnalyzerInput>` for real-time streaming transcription.
2. **Diarization buffer** -- Audio is separately converted to 16kHz Float32 mono and accumulated in an in-memory `[Float]` array for post-recording batch speaker diarization.
3. **WAV file** -- The analyzer-format audio is written to disk using manual WAV file construction (44-byte header + raw PCM data, finalized on stop). This avoids `AVAudioFile`'s internal AudioConverter which can abort-crash in certain format combinations.

### Real-Time Transcript Panel

`TranscriptPanelController` manages a floating `NSPanel` (non-activating, always-on-top, joins all Spaces) with a SwiftUI `TranscriptContentView` driven by an `@Observable TranscriptViewModel`. The panel shows:

- Timestamped transcript segments with auto-scroll to bottom
- Speaker labels (populated after diarization completes)
- A status bar with recording indicator, elapsed time, and word count

Real-time transcript updates come through `MeetingSession.onTranscriptUpdate`, which fires for both volatile (partial) and final segments. Duration updates come through `MeetingSession.onDurationUpdate` (1-second timer).

### Per-Channel Speaker Diarization

Diarization no longer runs on the mono mic+system mix. The mic and the call are kept as **separate channels**, which lets Better Voice attribute your own speech deterministically:

1. **You (the mic).** `performDiarization()` returns your own speech intervals directly from the microphone channel and labels them **"You"** — never merged into a remote speaker, even when you talk over the other side.
2. **The room (system audio).** The system channel is separated by [FluidAudio](https://github.com/FluidInference/FluidAudio) with a single **offline VBx pass over the on-disk system WAV** — global clustering is more accurate than a live chunker on a finished recording. Diarization models pre-warm at meeting start so the offline pass at stop doesn't pay a cold-load penalty. The clusterer keeps an automatic speaker count (no fixed cap), tuned by `MeetingSession.offlineClusteringThreshold` — a hand-tuned internal constant, not a user config key.
3. Remote speakers are merged onto a single speaker timeline and each turn carries a **voice embedding + confidence** — the groundwork for cross-meeting recognition.

Audio shorter than ~2 seconds skips diarization. The whole pass runs off the main thread under a timeout so stopping a long meeting always returns promptly.

### Transcription-Diarization Alignment

Each transcription segment (with `audioTimeRange` from SpeechAnalyzer) is attributed to the speaker whose diarized turn it most overlaps, with a confidence score. Brief interjections that overlap no one are left honestly **unlabeled** rather than snapped to the nearest speaker, and a long silence ends a speaker turn so utterances minutes apart aren't concatenated. If diarization fails, segments are returned without speaker labels.

### Summarization

When recording stops, `SummarizationClient` generates a summary (unless `meeting.summarization.enabled` is `false`):

1. **Meeting-type classification** -- a quick pass (when `classify_enabled`) picks `general` / `one_on_one` / `standup`; the wrap-up panel lets you override it.
2. **Type-aware prompt** -- the matching built-in template (or a `meeting.summarization.prompts` override) is filled in, with `personal-context.md` injected for disambiguation.
3. **Context sizing** -- `num_ctx` is sized to the transcript at runtime (capped at 256K); a sub-128K model warns once when it can't hold a long meeting, which otherwise causes silent front-truncation.

The `transcript.md` is written the instant recording stops (durable across a crash) and re-exported with speaker names after the wrap-up; the `-summary.md` is written alongside it. Meeting audio is kept when a summary was expected but failed.

### Markdown Export

`MeetingExporter.exportMarkdown()` writes a structured Markdown file to `~/.better-voice/meetings/`:

- Header with date, duration, and total word count
- Segments grouped by speaker, each prefixed with a `MM:SS` timestamp
- Speaker changes are marked with `### Speaker X` headings

### Benchmark Mode

The application supports a `--bench-meeting` CLI mode for offline evaluation, compiled only into `#if BENCH` debug builds (not shipped in release). `MeetingSession.runFromFile()` reads a WAV file, feeds it to SpeechAnalyzer via the file-based input API (`analyzer.start(inputAudioFile:finishAfterFile:)`), runs diarization, and outputs a JSON result with segments, timings, hypothesis text, and RTFx (real-time factor).

## Key Components

| Source File | Role |
|---|---|
| `BetterVoiceApp.swift` | Application entry point, `AppDelegate` initialization, benchmark CLI mode |
| `BetterVoiceModule.swift` | Module protocol (`onHotKeyDown`/`onHotKeyUp`) for extensible input modes |
| `ModuleManager.swift` | Module registry and hotkey event routing |
| `VoiceModule.swift` | Dictation mode state machine (idle/recording/processing) |
| `VoiceSession.swift` | Audio capture (AVCaptureSession) + SpeechAnalyzer streaming transcription |
| `VoicePipeline.swift` | Post-processing orchestrator: raw transcription -> L2 polish -> inject -> history |
| `GlobalHotKey.swift` | CGEventTap-based global hotkey (Right Option toggle) |
| `PolishClient.swift` | LLM polish client, delegates to ModelServer |
| `ModelServer.swift` | Ollama/OpenAI-compatible API client with health monitoring |
| `SummarizationClient.swift` | Meeting-type classification + type-aware summary generation |
| `ModelManager.swift` | Model file download and hash verification |
| `TextInjector.swift` | Clipboard + CGEvent Cmd+V text injection |
| `TranscriptionAccumulator.swift` | Data types: `WordInfo`, `TranscriptionResult`; legacy SFSpeechRecognitionResult aggregator |
| `VoiceHistory.swift` | Voice session history writer (voice-history.jsonl) |
| `MeetingSession.swift` | Meeting recording: dual-path capture, transcription, diarization, alignment |
| `MeetingTypes.swift` | `MeetingSegment`, `MeetingResult` data types |
| `MeetingExporter.swift` | Markdown export for meeting transcripts |
| `TranscriptPanel.swift` | Floating NSPanel + SwiftUI view for real-time meeting transcript |
| `StatusBarController.swift` | Menu bar UI, meeting mode controls, server status display |
| `RecordingIndicator.swift` | Floating HUD panel with pulsing mic icon during recording |
| `RuntimeConfig.swift` | JSON config loader (~/.better-voice/config.json) with file-watch hot reload |
| `PermissionManager.swift` | Accessibility, microphone, and System Audio Recording (Core Audio tap, meeting audio) permission checks |
| `AppIdentity.swift` | Frontmost application identification (bundle ID, PID, name) |
| `Logger.swift` | File + console logger with 5MB auto-trim |
| `JSONLWriter.swift` | Thread-safe JSONL append writer (local debug logs) |
| `BetterVoiceDataDir.swift` | ~/.better-voice/ directory structure management |
| `PersonalContext.swift` | Loads `~/.better-voice/personal-context.md` and appends it to both the polish and the meeting summarization system prompts |

## Audio Pipeline

### Why AVCaptureSession Instead of AVAudioEngine

`AVAudioEngine.installTap(onBus:)` does not work reliably with Bluetooth audio devices (e.g., vivo TWS 4 Hi-Fi). The tap callback simply never fires, with no error reported. This is a known limitation of the Audio Unit rendering pipeline when the Bluetooth device negotiates a non-standard sample rate or uses the HFP/SCO profile.

`AVCaptureSession` with `AVCaptureAudioDataOutput` works universally across all audio input devices -- built-in microphones, USB interfaces, and Bluetooth. The delegate receives `CMSampleBuffer` objects on a dedicated dispatch queue, which are then converted to `AVAudioPCMBuffer` for downstream processing.

### Format Conversion

The audio pipeline handles format mismatches between the capture device and SpeechAnalyzer:

1. **CMSampleBuffer to AVAudioPCMBuffer** -- `CMSampleBufferCopyPCMDataIntoAudioBufferList` copies PCM data from the CoreMedia buffer into an AVFoundation buffer, preserving the device's native format (commonly 16kHz Float32 for Bluetooth, 48kHz Float32 for built-in mic).
2. **Sample rate and format conversion** -- When the capture format differs from `SpeechAnalyzer.bestAvailableAudioFormat` (typically 16kHz Int16 mono), an `AVAudioConverter` is lazily created. The block-based `convert(to:error:)` API is used because the simple `convert(to:from:)` method does not support sample rate conversion.
3. **Meeting mode dual conversion** -- `MeetingCaptureDelegate` maintains two separate converters: one for the SpeechAnalyzer format and one for the diarization format (16kHz Float32 mono). Each audio buffer is independently converted and dispatched to its respective consumer.

### WAV File Writing

Audio files are written using manual WAV construction rather than `AVAudioFile`. A 44-byte placeholder header is written at file creation, raw PCM data is appended during recording, and the header is back-patched with correct RIFF/data chunk sizes on finalization. This approach avoids an `AVAudioFile` bug where its internal `AudioConverter` can `abort()` when handling certain format combinations.

### CGEventTap for Global Hotkey

macOS 26 introduced a Swift actor runtime issue where `NSEvent.addGlobalMonitorForEvents` callback triggers a Bus error crash in `GlobalObserverHandler`. The workaround uses `CGEvent.tapCreate` with a pure C-style callback function. Since CGEventTap callbacks execute in a `CFRunLoop` context that Swift's runtime does not recognize as MainActor, all `@MainActor` code is dispatched through `DispatchQueue.main.async` to bridge the concurrency boundary.

## Data Flow Diagram

```
                              DICTATION MODE
                              ==============

 Right Option Key ───> VoiceModule (state machine)
                       idle -> recording -> processing -> idle
                              |                    |
                              v                    v
                     ┌── VoiceSession ──┐    VoicePipeline
                     |                  |         |
          AVCaptureSession    SpeechAnalyzer      |
          (mic audio)         (streaming ASR)     |
                |                  |              |
                v                  v              |
           WAV file         TranscriptionResult   |
           (~/.better-voice/audio/)    (text + words +      |
                              confidence)         |
                                                  |
                                                  v
                                     v
                                PolishClient (L2)
                                (raw transcription +
                                 personal-context.md)
                                     |
                              ModelServer ──> Ollama / OpenAI API
                                     |
                                     v
                              TextInjector
                              (clipboard + Cmd+V)
                                     |
                                     v
                               VoiceHistory
                               voice-history.jsonl


                              MEETING MODE
                              ============

 Menu Bar "Start Meeting"
          |
          v
    MeetingSession.start()
          |
    AVCaptureSession
          |
    MeetingCaptureDelegate ──────────────────────────────┐
          |                     |                        |
          v                     v                        v
    SpeechAnalyzer        Diarization Buffer          WAV File
    (streaming ASR)       (16kHz Float32 mono         (~/.better-voice/audio/
     via AsyncStream)      in-memory accumulation)     meeting-*.wav)
          |
          v
    Real-time transcriber.results
          |
          ├── onTranscriptUpdate ──> TranscriptPanel (NSPanel + SwiftUI)
          |                          [timestamp] Speaker: text...
          v
    FinalizedSegments (text + audioTimeRange)
                                    |
                                    |  (on stop)
                                    v
                     Per-channel diarization (on stop)
              mic ──> "You"      system ──> FluidAudio (offline VBx)
                                    |
                                    v
                       TimedSpeakerSegments + confidence
                                    |
                                    v
                    Alignment (max overlap; no overlap = unlabeled)
                                    |
                                    v
                       MeetingSegment[] (text + time + speakerId)
                                    |
              ┌─────────────────────┼─────────────────────┐
              v                     v                      v
       TranscriptPanel       MeetingExporter        SummarizationClient
       (speaker labels)      transcript.md          (type-aware) -summary.md
                             ~/.better-voice/meetings/
```
