# Better Voice Technical Architecture

## System Overview

Better Voice is a macOS menu bar application that provides two core capabilities: **dictation mode** (ambient or hotkey-triggered voice-to-text input into any application) and **meeting mode** (long-form meeting recording with real-time transcription, speaker diarization, and Markdown export). The client is built in Swift 6.2 targeting macOS 26 (Tahoe), using Apple's SpeechAnalyzer framework for on-device speech recognition and AVCaptureSession for audio capture. Post-processing (L2 polish) is handled by a local LLM served via ollama, personalized through a free-text `~/.better-voice/personal-context.md` injected into the prompt.

## Dictation Mode Flow

### Voice Gate via CoreAudio HAL VAD (G1)

When ambient mode is enabled (`ambient_enabled` in config), `AmbientController` activates the hardware-level Voice Activity Detection built into CoreAudio HAL. It sets `kAudioDevicePropertyVoiceActivityDetectionEnable` on the default input device and listens for `kAudioDevicePropertyVoiceActivityDetectionState` changes via `AudioObjectAddPropertyListenerBlock`. When speech is detected, it fires `onSpeechStart`; when speech ends (after a configurable 0.8s settle delay to avoid sentence-gap false positives), it fires `onSpeechEnd`. A minimum duration threshold (0.5s) filters out coughs and transient noise. These callbacks are wired to `VoiceModule.onHotKeyDown()`, reusing the same recording pipeline as manual hotkey activation. Ambient mode and hotkey mode coexist -- the hotkey can still manually override at any time.

### Streaming Transcription via SpeechAnalyzer (G2)

`VoiceSession` manages the audio capture and transcription pipeline:

1. **Locale discovery** -- Queries `SpeechTranscriber.supportedLocales` for Chinese locales (zh-Hans, zh-CN, zh-Hant), downloads the speech model via `AssetInventory` if not already installed.
2. **SpeechTranscriber configuration** -- Created with `reportingOptions: [.volatileResults, .alternativeTranscriptions]` and `attributeOptions: [.audioTimeRange, .transcriptionConfidence]` to get partial results, alternative candidates, timestamps, and per-word confidence scores.
3. **SpeechAnalyzer** -- Wraps the transcriber; receives audio via an `AsyncStream<AnalyzerInput>` fed from the capture delegate.
4. **Result processing** -- A background `Task` iterates `transcriber.results`. Final segments are accumulated into `finalizedText` with word-level `WordInfo` (text, confidence, alternatives, timing). Volatile (partial) results are forwarded via `onPartialResult` for live UI feedback.
5. **Stop and finalize** -- On stop, capture halts, `inputBuilder.finish()` signals end-of-audio, then `analyzer.finalizeAndFinishThroughEndOfInput()` is awaited with a 5-second timeout. The accumulated text and word info are returned as a `TranscriptionResult`.

### Deterministic Correction via AlternativeSwap (L1)

`AlternativeSwap.apply()` performs rule-based corrections on the raw transcription:

1. Builds a replacement dictionary from recent human corrections stored in `CorrectionStore` (up to 200 entries retained in memory).
2. For each word with confidence below 0.8: first checks the correction dictionary for a known fix; then checks if the word's first SA alternative appears in any correction entry's corrected text, and substitutes if so.
3. Returns the corrected text, which may be identical to the input if no low-confidence words matched.

### Remote LLM Polish (L2)

`PolishClient` delegates to `ModelServer`, which supports both Ollama and OpenAI-compatible API backends:

- **Health monitoring** -- `ModelServer` runs periodic health checks (default every 30s) against `/api/tags` (Ollama) or `/v1/models` (OpenAI). Status is reflected in the menu bar icon.
- **Generation** -- Sends the L1 output as the user prompt with a system prompt (default: "Convert spoken language to written form. Output only the result."). Uses temperature=0 and max 256 tokens. Returns `nil` (skipping polish) if the server is disconnected or the polish feature is disabled.
- **Graceful degradation** -- If the server is unreachable, the pipeline continues with the L1 output.

### Text Injection

`TextInjector` uses a clipboard-based approach: saves the current pasteboard content, writes the final text to the pasteboard, synthesizes a Cmd+V keystroke via `CGEvent`, then restores the original clipboard after a 0.5s delay. The target application is identified by `AppIdentity` (bundle ID, process ID) captured at recording start.

### User Correction Capture

When `correction_enabled` is true, `CorrectionCapture` opens a 30-second monitoring window after text injection:

1. **Trigger** -- Listens for Enter key via `GlobalHotKey.onEnterKey`, or waits for the 30s timeout.
2. **Text reading** -- Uses the Accessibility API (`AXUIElementCopyAttributeValue` with `kAXValueAttribute`) to read the focused text element in the target application.
3. **Correction extraction** -- For short text (editor-like apps), directly compares. For long text (terminal buffers), searches the last 100 lines using LCS similarity, stripping common shell prompt prefixes.
4. **Storage** -- Corrections are saved to `~/.better-voice/corrections.jsonl` and `~/.better-voice/semantic-diffs.jsonl` via `CorrectionStore`. These entries feed back into L1 AlternativeSwap.

### Voice History Persistence

Every dictation session is recorded to `~/.better-voice/voice-history.jsonl` by `VoiceHistory`, regardless of correction capture settings. Each entry contains the raw SA output, L1 text, polished text, final text, word-level info with confidence and timing, audio file path, and target application identity. This file (paired with the saved `audio/*.wav`) is a local debugging log for inspecting transcription/polish behavior.

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

### Post-Recording Speaker Diarization

When recording stops, `MeetingSession.performDiarization()` runs batch speaker diarization on the accumulated audio buffer:

1. Downloads diarization models via `FluidAudio.DiarizerModels.downloadIfNeeded()` if not cached.
2. Creates a `DiarizerManager` with default `DiarizerConfig` and runs `performCompleteDiarization()` on the full buffer.
3. Returns `TimedSpeakerSegment` results with speaker IDs and time ranges.

Audio shorter than 2 seconds skips diarization entirely.

### Transcription-Diarization Alignment

`alignTranscriptionWithDiarization()` assigns a speaker ID to each transcription segment using time-overlap matching:

- For each transcription segment (with `audioTimeRange` from SpeechAnalyzer), compute the overlap duration with every diarization segment.
- The diarization segment with the maximum overlap determines the speaker assignment.
- If diarization fails, transcription segments are returned without speaker labels.

### Markdown Export

`MeetingExporter.exportMarkdown()` writes a structured Markdown file to `~/.better-voice/meetings/`:

- Header with date, duration, and total word count
- Segments grouped by speaker, each prefixed with a `MM:SS` timestamp
- Speaker changes are marked with `### Speaker X` headings

### Benchmark Mode

The application supports a `--bench-meeting` CLI mode for offline evaluation. `MeetingSession.runFromFile()` reads a WAV file, feeds it to SpeechAnalyzer via the file-based input API (`analyzer.start(inputAudioFile:finishAfterFile:)`), runs diarization, and outputs a JSON result with segments, timings, hypothesis text, and RTFx (real-time factor).

## Key Components

| Source File | Role |
|---|---|
| `BetterVoiceApp.swift` | Application entry point, `AppDelegate` initialization, benchmark CLI mode |
| `BetterVoiceModule.swift` | Module protocol (`onHotKeyDown`/`onHotKeyUp`) for extensible input modes |
| `ModuleManager.swift` | Module registry and hotkey event routing |
| `VoiceModule.swift` | Dictation mode state machine (idle/recording/processing) |
| `VoiceSession.swift` | Audio capture (AVCaptureSession) + SpeechAnalyzer streaming transcription |
| `VoicePipeline.swift` | Post-processing orchestrator: L1 -> L2 -> inject -> correction -> history |
| `AmbientController.swift` | CoreAudio HAL VAD for hands-free voice activation |
| `GlobalHotKey.swift` | CGEventTap-based global hotkey (Right Option toggle, Enter key detection) |
| `AlternativeSwap.swift` | Deterministic word replacement using SA alternatives + correction history |
| `PolishClient.swift` | LLM polish client, delegates to ModelServer |
| `ModelServer.swift` | Ollama/OpenAI-compatible API client with health monitoring |
| `ModelManager.swift` | Model file download and hash verification |
| `TextInjector.swift` | Clipboard + CGEvent Cmd+V text injection |
| `CorrectionCapture.swift` | Post-injection user correction monitoring via Accessibility API |
| `CorrectionStore.swift` | Correction data persistence (corrections.jsonl, semantic-diffs.jsonl) |
| `TranscriptionAccumulator.swift` | Data types: `WordInfo`, `TranscriptionResult`; legacy SFSpeechRecognitionResult aggregator |
| `VoiceHistory.swift` | Voice session history writer (voice-history.jsonl) |
| `MeetingSession.swift` | Meeting recording: dual-path capture, transcription, diarization, alignment |
| `MeetingTypes.swift` | `MeetingSegment`, `MeetingResult` data types |
| `MeetingExporter.swift` | Markdown export for meeting transcripts |
| `TranscriptPanel.swift` | Floating NSPanel + SwiftUI view for real-time meeting transcript |
| `StatusBarController.swift` | Menu bar UI, meeting mode controls, server status display |
| `RecordingIndicator.swift` | Floating HUD panel with pulsing mic icon during recording |
| `RuntimeConfig.swift` | JSON config loader (~/.better-voice/config.json) with file-watch hot reload |
| `PermissionManager.swift` | Accessibility, microphone, and screen-recording (meeting audio) permission checks |
| `AppIdentity.swift` | Frontmost application identification (bundle ID, PID, name) |
| `Logger.swift` | File + console logger with 5MB auto-trim |
| `JSONLWriter.swift` | Thread-safe JSONL append writer (local debug logs) |
| `BetterVoiceDataDir.swift` | ~/.better-voice/ directory structure management |
| `PersonalContext.swift` | Loads `~/.better-voice/personal-context.md` and appends it to the polish (and future summarization) system prompt |

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

 Right Option Key ──┐
                    ├──> VoiceModule (state machine)
 HAL VAD (G1) ─────┘    idle -> recording -> processing -> idle
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
                                     ┌─── AlternativeSwap (L1)
                                     |    (confidence < 0.8?
                                     |     check corrections
                                     |     + SA alternatives)
                                     v
                                PolishClient (L2)
                                     |
                              ModelServer ──> Ollama / OpenAI API
                                     |
                                     v
                              TextInjector
                              (clipboard + Cmd+V)
                                     |
                                     v
                            CorrectionCapture
                            (AX API read-back,
                             30s window or Enter)
                                     |
                          ┌──────────┴──────────┐
                          v                     v
                   CorrectionStore       VoiceHistory
                   corrections.jsonl     voice-history.jsonl
                   semantic-diffs.jsonl


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
                          FluidAudio Diarization
                          (batch, full buffer)
                                    |
                                    v
                          TimedSpeakerSegments
                                    |
                                    v
                          Alignment (max time overlap)
                          transcript segment <-> speaker segment
                                    |
                                    v
                          MeetingSegment[] (text + time + speakerId)
                                    |
                          ┌─────────┴─────────┐
                          v                   v
                   TranscriptPanel      MeetingExporter
                   (updated with        -> ~/.better-voice/meetings/
                    speaker labels)        YYYY-MM-DD_HH-mm.md
```
