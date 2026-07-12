# Better Voice

[![CI](https://github.com/drkpxl/better-voice/actions/workflows/ci.yml/badge.svg)](https://github.com/drkpxl/better-voice/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-black?logo=apple&logoColor=white)

A macOS menu-bar app with two halves: on-device dictation, and meeting notes that land in Apple Notes. Everything — transcription, speaker recognition, summarization — is processed locally on your Mac; your audio never leaves the machine.

> **Official builds are notarized.** The `.dmg` from [voice.baselinemakes.com](https://voice.baselinemakes.com/#download) is signed with a Developer ID and notarized by Apple, so it installs by drag-and-drop with no Gatekeeper workaround. In-app updates via Sparkle. Builds you compile yourself are **not** notarized — see [Building from source](#building-from-source).

## What it does

**Dictation** (menu bar): hold your hotkey, speak, release — the text is cleaned up and inserted at your cursor in any app. Transcription uses Apple's on-device `SpeechAnalyzer`; an optional local LLM pass fixes recognition errors and removes filler words.

**Meetings** (drag in a recording, or ⌘N/⌘O, or paste a transcript): a guided flow transcribes it and tells speakers apart locally, you confirm the speaker names, and a local LLM writes a summary with a human title (e.g. "Jun 18th - Q3 Roadmap Sync"). Better Voice then creates two notes in **Apple Notes** — a transcript note and a summary note, in folders you pick once during setup — and opens the summary. There's no in-app library or editor; everything after that lives in Apple Notes, so search, editing, and iCloud sync all happen there. Voice enrollment carries across meetings: name a voice once and Better Voice suggests that name next time.

## Models

Dictation cleanup and meeting summarization are configured **independently** — mix and match per section:

| Provider | Notes |
|----------|-------|
| **Apple on-device** | Zero setup; requires Apple Intelligence enabled. The default. |
| **Ollama** | Point at a local (or LAN) Ollama server. |
| **OpenAI-compatible** | LM Studio, llama.cpp, mlx-lm, Jan, or any `/v1/chat/completions` server. |

Transcription is always Apple's on-device speech model; speaker diarization runs locally via [FluidAudio](https://github.com/FluidInference/FluidAudio).

## Requirements

- macOS 26 or later (Apple Intelligence recommended for the zero-setup default).
- Apple silicon.

## Permissions

- **Microphone** — for dictation.
- **Input Monitoring / Accessibility** — to detect the dictation hotkey and type at your cursor.
- **Automation (Apple Notes)** — so Better Voice can create the transcript and summary notes and open them for you. It only ever writes and opens notes; it never reads your existing notes.

## Privacy

Transcription, speaker recognition, and summarization all run locally on your Mac — your audio never leaves the machine. Meeting notes are then saved to Apple Notes like anything else you write, so they sync through **your own** iCloud account, under Apple's encryption. Nothing passes through our servers — we don't run any.

## Install

1. Download the `.dmg` from [voice.baselinemakes.com](https://voice.baselinemakes.com/#download).
2. Drag **BetterVoice2.app** to `/Applications`.
3. Launch it and grant the permissions it asks for (Microphone, Input Monitoring, Accessibility, Automation for Notes).
4. On first run, pick the Apple Notes folders for summaries and transcripts.

The build is notarized, so no `xattr` / Gatekeeper workaround is needed. After the first install, updates arrive in-app via Sparkle (menu bar → **Check for Updates…**).

## Building from source

Requires Xcode 26.5. From `client/`:

```
make run      # build, sign with a local dev cert, launch, tail the log
swift build   # compile only
```

**A note on signing.** Only the official builds distributed from [voice.baselinemakes.com](https://voice.baselinemakes.com/#download) are Developer-ID-signed and Apple-notarized. A build you compile yourself is signed with a local self-signed certificate — fine for running on your own machine via `make run`, but if you copy that app to another Mac, macOS Gatekeeper will flag it as coming from an unidentified developer (right-click → **Open** to bypass, or clear the quarantine flag with `xattr -cr /path/to/BetterVoice2.app`). `make run` (dev channel) also strips the Sparkle feed URL, so dev builds don't self-update.

## Acknowledgements

Better Voice stands on:

- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** — on-device speaker diarization (Apache-2.0).
- **[Sparkle](https://sparkle-project.org)** — in-app updates for the official builds (MIT).

Transcription and the zero-setup on-device model both use Apple's frameworks (`SpeechAnalyzer` and Foundation Models).

## License

[MIT](LICENSE). Dependency licenses (Apache-2.0 for FluidAudio, MIT for Sparkle) apply to their respective code.
