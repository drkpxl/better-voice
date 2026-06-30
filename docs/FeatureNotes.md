# Call Transcription Tool — Feature List


### 0. New Settings UI  — DONE
- From menu bar a settings option should be created, initial selections are up to you further details are listed below

### 1. Live waveform indicator  — DONE
- Small waveform UI sits below the camera bar, in the "eyebrow" area.
- Animates when audio is detected — either your voice (mic) or system audio (other participants).
- Flat/idle when no one is speaking.
- Reference: FreeFlow and similar Whisper-based apps for visual style.
- Needs basic noise-floor awareness so ambient room noise doesn't trigger the "speaking" animation — only real speech/audio above a threshold should animate it.

### 2. Transcript summarization via Ollama  — DONE
- Currently the app outputs a raw markdown transcript with no summarization step.
- Add a post-processing step that sends the full transcript to a local Ollama endpoint for summarization.
- Output gets appended to (or saved alongside) the markdown file.
- User gets to in the UI choose save location for both files
- User gets option to auto-delete audio files after transcription
- Defaults to our current model, but they can put in a different ollama model id
- Need to make sure context is upped on model args

### 3. Speaker labeling UI (stepping stone to voice fingerprinting) — DONE
- Between transcription and summarization, add a UI step to assign names to detected speakers.
- App detects N speakers (e.g., "5 speakers") → user labels each once per session ("Speaker 1 = Steven," "Speaker 2 = Erin," etc.).
- Labels carry through into the summarization step so the summary references people by name, not speaker number.

### 4. Meeting-type-aware summarization prompts — DONE
- Maintain a set of prompt templates keyed to meeting type (e.g., 1:1, status meeting, other types TBD).
- User selects (or app infers) meeting type, which determines which summarization prompt is used — so a 1:1 summary looks different from a status-meeting summary.


### 5. Voice fingerprinting  — DONE
- Build persistent voice fingerprints per person (yourself + recurring call participants).
- Goal: auto-recognize and label speakers across sessions without manual assignment.
- Speaker-labeling UI (#3) is the interim solution until this is built.

### 6. Personalization via personal context (replaces self-training) — DONE
- **Decision:** rather than fine-tune a tiny model, run a general ~4B model in ollama and add personal context up front (people I meet with, where I work, what I do) so cleanup — and later summarization — produce better output. Editable in seconds, carries meaning, and one file serves both stages.
- **Removed:** the entire self-training / fine-tuning pipeline (server/ distillation → QLoRA on Qwen3-0.6B → GGUF deploy, client→server sync, KPI m7 milestones).
- **Added:** free-text `~/.we/personal-context.md` injected into the polish prompt via `PersonalContext.appended(to:)`, gated by `polish.personal_context_enabled`. Default model bumped to `qwen3:4b`.
- **Next:** reuse the same `PersonalContext.appended(to:)` in the summarization prompt (#2–#4).

### Update check and update button in UI
- Add a feature that on app launch or every 14 days checks for update code and notifies in menu system for the user to update. Include notes of what changed, and update button that lets the app update in place and restart. Following convention, not introducing a non-best practice, something like “restart to update"

### Overall UI Pass
- We should have some onboarding on first start, encouraging them to fill out the personal context and why it’s helpful. We should also introduce the app as a whole. Hotkeys, set file folder, permissions, etc. Your standard new app onboarding.
- We should use as much as swift ui conventions as possible or whatever UI is standard and modern no need to reinvent the wheel for something that is meant to be out of the way

### Voice fingerprinting
- Build persistent voice fingerprints per person (yourself + recurring call participants).
- Goal: auto-recognize and label speakers across sessions without manual assignment.
- Speaker-labeling UI (#3) is the interim solution until this is built.


###  Other not defined ideas
- Live markdown editor (edit transcript/notes in real time during or after the call).
- Edit personal context in side app
- Folder structure / organization system for saved transcripts and summaries.
- How to get in apple app store or at least notarized?
