# WE Issues Deep Analysis

## Architectural Premise

WE has two independent voice processing modes that share the underlying capture solution (AVCaptureSession) and transcription engine (SpeechAnalyzer + SpeechTranscriber), but the upper-level flows are completely different:

**Everyday Transcription Mode** (VoiceModule → VoiceSession → VoicePipeline)
- Trigger: hotkey / Ambient VAD
- Duration: a few seconds to a few dozen seconds
- Pipeline: SA transcription → L1 (alternatives logging) → L2 (PolishClient correction) → TextInjector injection → VoiceHistory persisted to disk
- Has contextualStrings (via ScreenContextProvider OCR)
- Has L2 correction (via ModelServer → ollama)

**Meeting Mode** (MeetingSession, triggered from the StatusBarController menu)
- Trigger: menu bar click
- Duration: tens of minutes to a few hours
- Pipeline: SA transcription → TranscriptPanel live display → after stop, FluidAudio batch diarization → alignment → MeetingExporter exports MD
- **Does not have** contextualStrings
- **Does not have** L2 correction
- **Does not have** TextInjector injection
- **Does not** write to voice-history

---

## Issue 1: Everyday Transcription Mode — Trailing Content Loss

### Symptom
User feedback: spoke for about 1 minute, and the last ~20 seconds of transcribed content was lost.

### Code Trace

Execution order of VoiceSession.stop() (lines 204-252):

```
① captureSession?.stopRunning()      // synchronous, immediately stops hardware capture
② captureSession = nil
③ captureDelegate?.close()            // closes the WAV file
④ captureDelegate = nil               // delegate is released
⑤ inputBuilder?.finish()              // tells SA the input stream has ended
⑥ finalizeAndFinishThroughEndOfInput()  // waits for SA to finish processing, 5 second timeout
⑦ sleep(500ms)
⑧ resultTask?.cancel()                // forcibly cancels the result-receiving loop
⑨ fullText = finalizedText + volatileText
```

### Root Cause Analysis (Three Layers)

**Layer 1: Audio buffers discarded**

Step ① `stopRunning()` is synchronous — once called, hardware capture stops immediately. But the `captureOutput` callback runs on the background DispatchQueue `com.antigravity.we.audio-capture`. When capture stops, there may still be CMSampleBuffers in the queue that have already been captured but not yet processed by the callback.

Step ④ immediately sets `captureDelegate` to nil. But the delegate is the delegate of `AVCaptureAudioDataOutput`, held by the background queue. After setting it to nil, the delegate's `inputBuilder.yield()` may still be executing in a subsequent callback (a race condition), or it may no longer be called at all.

The key problem: there is no waiting mechanism between `stopRunning()` and `inputBuilder.finish()` to ensure the background queue is drained. If there are still buffers in the queue, the audio corresponding to those buffers never reaches SA.

**Layer 2: SA finalize timeout**

Step ⑥ gives `finalizeAndFinishThroughEndOfInput()` a 5 second timeout. The semantics of this method are "wait for SA to finish processing all received audio and produce all final results." For a short utterance of a few seconds this is enough, but if the user spoke for a longer duration (tens of seconds), SA may internally have a larger unprocessed buffer, and 5 seconds may not be enough.

After the timeout, execution continues without crashing, but SA may not yet have produced the last few final segments.

**Layer 3: resultTask forcibly cancelled**

Step ⑧ forcibly calls `resultTask?.cancel()` after sleep(500ms). `resultTask` is the `for try await result in transcriber.results` loop. After cancellation, even if SA subsequently produces a final result, there is no longer a consumer to receive it.

Step ⑨ uses `finalizedText + volatileText` to build the final text. `volatileText` holds the content from the last volatile update. But during the finalize phase SA converts volatile into final — if this conversion happens after the resultTask is cancelled, the final result is lost, and volatileText may be an earlier version of the volatile text (not the latest).

### Conclusion

The loss is not a single-point issue — it is three compounding defects:
1. No waiting for the background queue to drain between capture stop and input stream closure
2. The finalize timeout is too short (5 seconds)
3. resultTask is forcibly cancelled too early, discarding the final result produced during the finalize phase

---

## Issue 2: Meeting Mode — Poor Recognition of Jargon/Terminology

### Symptom
Industry jargon and product names in meetings (Claude Code, Tailscale, contextualStrings, etc.) are misrecognized by SA.

### Root Cause

**MeetingSession does not use contextualStrings at all.** Searching the code for `contextualStrings`, `AnalysisContext`, `setContext` — there are no related calls anywhere in MeetingSession.swift.

Compare with VoiceSession: VoiceSession.updateContext() (lines 189-201) obtains on-screen contextual vocabulary via ScreenContextProvider OCR and injects it into `analyzer.setContext(context)`. MeetingSession has no such logic.

**MeetingSession is not connected to the L2 correction pipeline.** The data flow in meeting mode is:

```
SA final segment → finalizedSegments array → after stop(), batch diarization → MeetingExporter exports MD
```

VoicePipeline (which includes PolishClient L2 correction) is not involved at all. The text produced by MeetingSession is SA's raw output, written directly into the MD file.

### Full Path Analysis for Adding L2 Correction to Meeting Mode

**Option A: Real-time correction (call L2 for every final segment)**

In MeetingSession's resultTask loop (lines 272-299), whenever a `result.isFinal` is received, call `PolishClient.polish()` to correct the text before appending it to `finalizedSegments`.

Issues:
- PolishClient calls ModelServer, and ModelServer makes a network request to ollama. Each request has a latency of about 100-500ms
- A 1-hour meeting may have 400+ final segments, accumulating an extra 40-200 seconds of latency
- resultTask runs inside a Task and serially consumes `transcriber.results`. If consumption can't keep up with SA's production rate (because the L2 call blocks), the results AsyncSequence may experience backpressure
- However, this doesn't affect the live display — the raw SA text can be shown first, then updated once the L2 result comes back

Implementation complexity: medium. Requires introducing PolishClient into MeetingSession and managing an asynchronous correction queue.

**Option B: Batch correction after the fact (process all segments at once after stop)**

In `stop()`, after diarization is complete and before exporting the MD, iterate over all segments and call L2 correction.

Issues:
- Serially correcting 400 segments takes 40-200 seconds. After the user clicks "End Meeting," they would have to wait a long time to get the result
- This could be parallelized, but ollama inference is single-threaded, so parallelizing wouldn't speed it up
- Advantage: simple logic, doesn't affect real-time transcription

**Option C: contextualStrings injection (at the SA level, zero latency)**

In MeetingSession.start(), load all correct terms (55 of them) from correction-dictionary.json and inject them as contextualStrings via `analyzer.setContext()`. SA will then be biased toward outputting the correct spelling during recognition.

Issues:
- The contextualStrings API is `AnalysisContext`, confirmed to exist. It has already been used in VoiceSession and verified to work
- However, contextualStrings is only a "hint" — it doesn't guarantee SA will always choose the correct word
- 55 words probably doesn't exceed Apple's limit (the exact limit isn't confirmed in official documentation, but the code comment in VoiceSession states 100)
- Zero latency, doesn't affect any existing flow

**My judgment: do C first (lowest cost, lowest risk), then A or B.**

C only requires adding a few lines of code in MeetingSession.start() to load vocabulary from the dictionary file and inject it into SA. It doesn't change the data flow and doesn't introduce a network dependency. The effect may not be perfect (SA won't always listen), but it at least gives SA a chance to correct itself.

A or B would require introducing a ModelServer dependency into meeting mode, and would need to handle network unavailability, latency, queue management, etc. — a larger change. Also, the premise is that the fine-tuned model's correction quality is already stable — currently the model is still in the parameter-tuning stage, so it's not suitable for immediate integration.

---

## Issue 3: Poor Recognition for Continuous Multi-Speaker Conversation

### Symptom
When multiple people speak in turn, SA's transcription quality degrades.

### Root Cause

SpeechTranscriber is designed for **single-speaker continuous speech**. Apple's official documentation describes it as suited to "clear speech" scenarios. When multiple speakers alternate:

1. **Language model context is broken**: SA's language model predicts the next word based on preceding text. When the speaker changes, the context shifts abruptly and the language model's predictions become inaccurate
2. **Acoustic model doesn't adapt**: different speakers have different timbres, speaking rates, and accents. SA does not perform speaker-aware processing — it treats all voices as the same person
3. **FluidAudio diarization happens after the fact** and does not participate in real-time transcription. The audio stream SA receives has multiple people's voices mixed together

### Possible Directions for Improvement

**Would DictationTranscriber be better?**

DictationTranscriber is confirmed to exist in Apple's documentation (developer.apple.com/documentation/speech/dictationtranscriber), as a subclass of SpeechModule. But its positioning is as "a replacement for the system dictation feature," with its main advantage being output that includes punctuation and sentence structure — **it is not optimized for multi-speaker scenarios**.

Whether DictationTranscriber supports contextualStrings, and whether it performs better in multi-speaker scenarios — **this is not confirmed by official documentation**. My earlier statement that "DictationTranscriber is more suitable for meeting scenarios" was speculation, not fact.

**Does Apple have native multi-speaker support?**

No. The Apple Speech framework has no speaker-diarization API and no speaker-identification API. SpeechAnalyzer is designed as "one audio stream → one text stream," without distinguishing speakers. FluidAudio is a third-party solution.

**Practically feasible improvements:**

This problem cannot be fundamentally solved at the SA level. Feasible directions include:
- L2 correction can partially compensate (fixing misrecognized words caused by context breaks)
- Injecting team-common terminology via contextualStrings can reduce terminology errors
- But the recognition quality degradation caused by overlapping/alternating multi-speaker dialogue is an inherent limitation of SA

---

## Issue 4: Poor Recognition at Fast Speech Rates

### Root Cause

Same as Issue 3 — this is an inherent characteristic of SA's Chinese-language model. SA's acoustic model has a certain tolerance range for speech rate; beyond that range, recognition accuracy drops.

### Feasible Improvements

- L2 correction can partially compensate
- But **dropped words** caused by fast speech (where SA directly skips over portions of the audio content) cannot be recovered through post-processing

---

## Issue 5: Diversity of Audio Sources

### Scenarios Raised by the User

1. **Local microphone capturing the physical environment** (current solution)
2. **Meeting audio played through a large display/another person's computer** — captured secondarily via microphone, with distance attenuation and ambient noise
3. **Online meetings running locally on the Mac** (Zoom/Teams/Feishu running on the Mac) — requires capturing system audio
4. **Remote meeting audio coming in through headphones**

### Current Code

Both VoiceSession and MeetingSession use `AVCaptureDevice.default(for: .audio)` to get the default audio input device. This picks up whatever input device is selected in the system preferences, typically the microphone or a Bluetooth headset's microphone.

It cannot capture system audio (sound played by other apps).

### Solutions Apple Provides

**ScreenCaptureKit (confirmed):**
- `SCStreamConfiguration.capturesAudio`: captures system audio
- `SCStreamConfiguration.captureMicrophone`: simultaneously captures the microphone (confirmed to exist on macOS 15+)
- Both can be enabled at the same time
- `SCContentFilter` can be used to filter audio from specific windows/applications

This means:
- Scenario 3 (online meeting running locally on the Mac): use ScreenCaptureKit to capture Zoom/Teams' system audio and feed it directly to SA
- Scenario 4 (remote audio coming through headphones): if the remote audio is played through the system, it can likewise be captured with ScreenCaptureKit
- Scenario 2 (physical sound from a large display): can still only be captured secondarily via microphone — ScreenCaptureKit cannot help here (the sound isn't being played on this Mac)

**Core Audio AudioHardwareCreateProcessTap (confirmed, macOS 14.4+):**
- Can tap the audio output of a specific process
- Lower-level than ScreenCaptureKit, with finer-grained control
- But the API is more complex

**Scope of changes involved:**

The current AVCaptureSession capture solution would need to coexist with a ScreenCaptureKit solution:
- Physical microphone scenario: continue using AVCaptureSession (already verified as stable, Bluetooth-compatible)
- System audio scenario: add a new ScreenCaptureKit capture path
- Both paths need to output AVAudioPCMBuffer to feed SA's inputBuilder

This is not a simple one-line code change. It would require:
1. Adding a new audio source abstraction layer (AudioSource protocol)
2. Implementing two sources: MicrophoneSource (existing AVCaptureSession) and SystemAudioSource (ScreenCaptureKit)
3. A configuration option to choose which source to use (config.json or a UI toggle)
4. Ensuring ScreenCaptureKit's audio format is compatible with SA's bestAvailableAudioFormat

---

## Issue 6: Bluetooth Headset Switching Causes Recording Interruption

### Symptom
During recording, the Bluetooth headset disconnects/switches, recording silently stops, and all subsequent content is lost.

### Root Cause

There is no device-change monitoring anywhere in the code. Searching for `wasInterrupted`, `routeChange`, `deviceDisconnect` — neither VoiceSession nor MeetingSession has any of these.

AVCaptureSession's behavior after the input device disconnects:
- `AVCaptureSession.wasInterruptedNotification` (confirmed to exist) is sent
- But nothing listens for it, so the app doesn't know
- The session stops producing CMSampleBuffer, but doesn't crash
- `inputBuilder` stops receiving data, and SA also stops producing results
- Recording silently dies this way

### Fix Direction

1. Listen for `AVCaptureSession.wasInterruptedNotification`
2. Upon receiving the notification:
   a. Record the breakpoint position (already-transcribed content is not lost)
   b. Attempt to get the new default audio device `AVCaptureDevice.default(for: .audio)`
   c. If there is a new device, rebuild AVCaptureDeviceInput and replace the session's input
   d. If there is no device, show a UI prompt to the user
3. No need to rebuild the SA session — `inputBuilder` is still around, it just temporarily has no data input. After the device is restored, simply resume yielding

Key risk: the audio gap during device switching (a few seconds) will be lost. This is unavoidable, but at least the rest of the content won't be entirely lost.

---

## Summary of Apple Framework Research (Verified vs. Unverified)

| Information | Status | Source |
|------|------|------|
| DictationTranscriber exists | Confirmed | developer.apple.com/documentation/speech/dictationtranscriber |
| DictationTranscriber supports contextualStrings | **Unconfirmed** | Not explicitly stated in official documentation |
| DictationTranscriber is suited to multi-speaker scenarios | **Unconfirmed, was speculation on my part earlier** | No basis |
| AnalysisContext.contextualStrings API | Confirmed | developer.apple.com/documentation/speech/analysiscontext |
| contextualStrings limit of 100 words | **Unconfirmed** | Code comment states 100, but this limit was not found in official documentation |
| SCStreamConfiguration.captureMicrophone | Confirmed | developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone |
| SCStreamConfiguration.capturesAudio | Confirmed | developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio |
| Simultaneous system audio + microphone capture | Configurable, but with reported reliability issues | Developer community feedback |
| AVCaptureSession.wasInterruptedNotification | Confirmed | developer.apple.com/documentation/avfoundation/avcapturesession/wasinterruptednotification |
| AudioHardwareCreateProcessTap (macOS 14.4+) | Confirmed | developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap |
| Apple native speaker-diarization API | **Does not exist** | Search confirmed no such API |
