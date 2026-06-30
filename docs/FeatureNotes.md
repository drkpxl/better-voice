# Call Transcription Tool — Feature Notes

## Near-term

### 1. Live waveform indicator
- Small waveform UI sits below the camera bar, in the "eyebrow" area.
- Animates when audio is detected — either your voice (mic) or system audio (other participants).
- Flat/idle when no one is speaking.
- Reference: FreeFlow and similar Whisper-based apps for visual style.
- Needs basic noise-floor awareness so ambient room noise doesn't trigger the "speaking" animation — only real speech/audio above a threshold should animate it.

### 2. Transcript summarization via Ollama
- Currently the app outputs a raw markdown transcript with no summarization step.
- Add a post-processing step that sends the full transcript to a local Ollama endpoint for summarization.
- Output gets appended to (or saved alongside) the markdown file.

### 3. Speaker labeling UI (stepping stone to voice fingerprinting)
- Between transcription and summarization, add a UI step to assign names to detected speakers.
- App detects N speakers (e.g., "5 speakers") → user labels each once per session ("Speaker 1 = Steven," "Speaker 2 = Erin," etc.).
- Labels carry through into the summarization step so the summary references people by name, not speaker number.

### 4. Meeting-type-aware summarization prompts
- Maintain a set of prompt templates keyed to meeting type (e.g., 1:1, status meeting, other types TBD).
- User selects (or app infers) meeting type, which determines which summarization prompt is used — so a 1:1 summary looks different from a status-meeting summary.

## Future / later

### 5. Voice fingerprinting
- Build persistent voice fingerprints per person (yourself + recurring call participants).
- Goal: auto-recognize and label speakers across sessions without manual assignment.
- Speaker-labeling UI (#3) is the interim solution until this is built.

### 6. Other later-stage ideas
- Live markdown editor (edit transcript/notes in real time during or after the call).
- Folder structure / organization system for saved transcripts and summaries.
