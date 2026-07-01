# Better Voice v0.7.0

Meeting pipeline hardening — the speaker separation is substantially more reliable, especially with many voices and interruptions, and it's leaner on memory and time.

## What changed

### 🎙️ Per-channel speaker diarization
- Diarization no longer runs on the mono mic+system mix. Your own voice (the microphone) is detected directly and labeled **"You"**; the other participants (system audio) are separated by [FluidAudio](https://github.com/FluidInference/FluidAudio) and merged onto a single speaker timeline.
- Result: your speech stays attributed to **"You"** even when you talk over the remote side, instead of being merged into one of the remote speakers.
- The clusterer keeps an automatic speaker count (no fixed cap), so a many-person call separates into many speakers.

### 🎯 Confidence-aware attribution
- Each phrase is attributed to the speaker who actually overlaps it, with a confidence score. Brief interjections that overlap no one are left honestly **unlabeled** rather than snapped to the nearest speaker (which used to mislabel them).
- A long silence now ends a speaker turn, so utterances minutes apart are no longer concatenated into one run-on line.
- Each turn carries a voice embedding + confidence — the groundwork for cross-meeting speaker recognition in a future release.

### ⚡ Bounded memory & no hangs
- The system channel is diarized in fixed chunks with a reused speaker model, so peak memory stays around one chunk instead of the whole meeting, and stable speaker IDs accumulate within a meeting.
- Diarization runs under a timeout, so stopping a long meeting always returns promptly.
- Short clips (under ~2s) skip diarization instead of emitting a spurious speaker.

### ⚙️ Tunable diarization (Settings → Meetings)
- New advanced control: **speaker clustering threshold** (default **0.57**, validated against pyannote gold labels — lower = more speakers), plus min-speech / min-silence knobs via config.

### 🎧 Meetings note
- The mic+system ("both") mode assumes **headphones** — with open speakers the remote voices leak back into your mic. Per-channel diarization already keeps attribution correct; a Settings hint now calls this out.

## Under the hood
- Sample-accurate, phase-locked audio mixer for the transcription stream.
- Deduplicated WAV writer + PCM converter shared across capture paths.
- `make run` / `make install` now embed Sparkle and sign with the stable certificate so permissions survive rebuilds.

## Upgrade notes
- In-app update via Sparkle (from 0.6.0). First-time installs: download the DMG, drag to Applications, grant Microphone / Speech Recognition / Accessibility / System Audio Recording when prompted.
- No config migration needed. Existing `~/.better-voice/config.json` gains `meeting.diarization` defaults automatically.
