# Better Voice v1.0.0

The 1.0 release. On-device dictation and meeting transcription is stable, so this release trims the app down to that core and sharpens it: meeting speaker separation is meaningfully better, diarization no longer stalls a fresh meeting, and mid-meeting device switches (like unplugging AirPods) no longer break transcription.

## Removed

Three optional, less-used features are gone as of 1.0, to keep the app small and focused on dictation + meeting transcription:

- **Remote Voice** — the iOS Shortcut / Tailscale push-to-talk path for recording from another device.
- **Ambient mode** — always-listening background transcription.
- **Correction dictionary** — `~/.better-voice/correction-dictionary.json` is no longer read. Use `~/.better-voice/personal-context.md` instead: it's free-text, easier to maintain, and the model uses it to disambiguate names, acronyms, and jargon in both dictation and meetings.

These still work exactly as before, unaffected by this change: hotkeys, meeting mode, personal context, per-model selection, in-app updates.

All three removed features remain available in git history prior to 1.0 if you need them.

### Config

If your `~/.better-voice/config.json` has any of these keys, they're simply ignored now — no error, no migration needed:

- `remote.*`
- `ambient_enabled`
- `polish.context_dictionary_*`
- `meeting.diarization.*`
- `downloads.*`

## Improved

- **Better speaker separation** — the meeting diarization pipeline was re-tuned (offline clustering, retuned similarity threshold) and benchmarked at **29% lower frame error** than 0.9.2 on multi-speaker recordings. Fewer merged/misattributed speakers on calls with several participants.
- **No more stall at the end of a meeting** — the diarization model now downloads and warms up in the background while the meeting is recording, instead of blocking when you hit Stop on a fresh install.
- **Mid-meeting device switches just work** — switching audio devices during a meeting or dictation (e.g. AirPods to built-in mic) no longer breaks transcription for the rest of the session.
- **Smaller app** — internal benchmark/test CLI harnesses are no longer compiled into release builds.
- **More reproducible builds** — dependencies are now pinned to tested revisions, and GitHub Actions CI runs the build + test suite on every change.

## Requirements

- macOS 26+
- Apple Silicon (M-series)

## Installation

Better Voice is self-signed (not notarized). On first launch:

1. Drag `Better Voice.app` into Applications.
2. Right-click the app → **Open** → **Open** (bypasses the unsigned-app warning), or run `xattr -cr /Applications/Better\ Voice.app` in Terminal.
3. Grant permissions as prompted: Microphone, Speech Recognition, Accessibility, and (for meetings) System Audio Recording.

## Upgrade notes

- In-app update via Sparkle from 0.9.x.
- If you relied on Remote Voice, Ambient mode, or the correction dictionary, note that they're gone in 1.0 — see **Removed** above. Move any custom terms into `~/.better-voice/personal-context.md`.
