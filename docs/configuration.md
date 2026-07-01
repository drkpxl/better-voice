# Configuration Reference

## Overview

Better Voice reads its configuration from `~/.better-voice/config.json`. On first launch, the app creates this file with sensible defaults. The file is monitored for changes at runtime -- edits are picked up automatically without restarting the app (hot-reload via `DispatchSource` file watcher).

All sections are optional. Missing keys fall back to their defaults.

---

## Server Settings

The `server` object controls how Better Voice connects to the model inference backend for L2 polish (text refinement). Two API protocols are supported: Ollama (default) and OpenAI-compatible.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.endpoint` | string | `"http://localhost:11434"` | Base URL of the model server. For Ollama this is typically `http://host:11434`. For OpenAI-compatible APIs, use the full base URL (the client appends `/v1/chat/completions` if no `/v1/` path is present). |
| `server.api` | string | `"ollama"` | API protocol. `"ollama"` uses the `/api/generate` endpoint; `"openai"` uses the `/v1/chat/completions` endpoint. |
| `server.model` | string | `"qwen3.5:4b-mlx"` | Model name passed to the inference server. Must match an available model on the server (`ollama list`). A general ~4B model gives good cleanup out of the box; smaller models trade quality for speed. |
| `server.summarization_model` | string | `""` | Optional separate model for meeting summaries — point this at a larger, longer-context model while keeping a fast one for dictation polish. Empty falls back to `server.model`. |
| `server.timeout` | number | `10` | Request timeout in seconds for inference calls. |
| `server.health_interval` | number | `30` | Interval in seconds between automatic health checks. The app polls the server periodically and updates its status (connected / disconnected) shown in the menu bar. |
| `server.api_key` | string | `""` | API key for OpenAI-compatible endpoints. Sent as `Bearer` token in the `Authorization` header. Not needed for Ollama. |

**Examples:**

Local Ollama (default):
```json
"server": {
    "endpoint": "http://localhost:11434",
    "api": "ollama",
    "model": "qwen3.5:4b-mlx",
    "timeout": 10,
    "health_interval": 30
}
```

Remote Ollama over LAN:
```json
"server": {
    "endpoint": "http://192.168.1.100:11434",
    "api": "ollama",
    "model": "qwen3.5:0.8b",
    "timeout": 15,
    "health_interval": 60
}
```

OpenAI-compatible API:
```json
"server": {
    "endpoint": "https://api.example.com/v1/chat/completions",
    "api": "openai",
    "model": "gpt-4o-mini",
    "api_key": "sk-...",
    "timeout": 15,
    "health_interval": 60
}
```

---

## Polish Settings

The `polish` object controls the L2 semantic polish stage, which refines raw speech recognition output into cleaner written text.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `polish.enabled` | bool | `true` | Master switch for the polish pipeline. When `false`, raw transcription is used as-is (L1 only). |
| `polish.model` | string | `""` | Optional model override for dictation polish (can be a smaller/faster model than `server.model`). Empty falls back to `server.model`. |
| `polish.system_prompt` | string | (locale-aware default from `Prompts.swift`) | System prompt sent to the model. Controls the style of text refinement. |
| `polish.personal_context_enabled` | bool | `true` | When `true`, the contents of `~/.better-voice/personal-context.md` (if present and non-empty) are appended to the system prompt for disambiguation. See **Personal Context** below. |

---

## Personal Context

`~/.better-voice/personal-context.md` is a free-text Markdown file you edit by hand. Its
contents are appended to both the L2 polish system prompt and the meeting
summarization prompt, so the model can disambiguate names, jargon, acronyms, and
references using your real-world background. This replaces the old fine-tuning
approach to personalization: it carries meaning (not just word spellings), is
editable in seconds, and needs no retraining.

There is no schema -- write whatever helps. Example:

```markdown
I'm a product manager at Acme Robotics. I work mostly on the Atlas platform.

People I meet with often:
- Erin (design lead)
- Sam (staff engineer)
- Priya (my manager)

Recurring topics: Q3 roadmap, latency SLOs, the warehouse pilot.
```

The model is instructed to use this only for disambiguation and never to output
or act on it. Set `polish.personal_context_enabled` to `false` to disable
injection without deleting the file. Changes are picked up on the next polish call.

---

## Top-level Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `language` | string | `"en"` | Transcription & UI language (BCP-47 or a language code, e.g. `"en"`, `"zh-Hans"`). Empty/omitted follows the system language. |
| `onboarding_version` | number | `0` | Highest onboarding version the user has completed. The app shows the first-launch welcome screen while this is below the current code constant; you normally don't edit it by hand. |

---

## Meeting Settings

The `meeting` object controls meeting capture, live note-taking, diarization, and summaries.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `meeting.audio_source` | string | `"both"` | What to capture: `"mic"` (your voice only), `"system"` (the call's audio only), or `"both"` (mixed). Use headphones for `"both"` so the remote voices don't leak back into your microphone. |
| `meeting.save_folder` | string | `~/.better-voice/meetings` | Where meeting `transcript.md` + `-summary.md` files are written (supports `~` expansion). |
| `meeting.auto_delete_audio` | bool | `false` | Delete the recorded `.wav` after transcription finishes. |
| `meeting.default_type` | string | `"general"` | Default meeting type in the wrap-up panel: `general` / `one_on_one` / `standup`. |
| `meeting.l2_flush_on_pause_sec` | number | `1.5` | Flush live notes to the polish model after this many seconds of pause. |
| `meeting.l2_flush_on_chars` | number | `200` | Flush live notes once this many characters have accrued. |
| `meeting.l2_min_chars` | number | `30` | Minimum characters before a live-note flush is attempted. |

### `meeting.summarization`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Generate an AI summary when the meeting stops. |
| `num_ctx` | number | `32768` | Context window passed to the model. Better Voice sizes the request to the transcript (capped at 256K) at runtime; this is the floor. A sub-128K model warns once when it can't hold a long meeting. |
| `num_predict` | number | `2048` | Max tokens generated for the summary. |
| `timeout` | number | `300` | Summarization request timeout in seconds. |
| `classify_enabled` | bool | `true` | Run a quick classification pass to pre-select the meeting type. |
| `prompts` | object | `{}` | Per-type prompt overrides (`general` / `one_on_one` / `standup`). Empty uses the built-in templates. |

### Diarization

The system channel is always diarized offline with FluidAudio's VBx pipeline over the recorded WAV (global clustering, more accurate on a finished recording than a live chunker). The clustering threshold is a tuned internal constant (`MeetingSession.offlineClusteringThreshold`), not a user-configurable setting — there is no `meeting.diarization` config section.

---

## Hotkey Settings

The `hotkey` object defines the global dictation hotkey. It's normally set from the Settings window rather than by hand.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hotkey.keyCode` | number | `61` | Virtual key code (61 = Right Option). |
| `hotkey.modifierFlags` | number | `0` | Modifier bitmask for combos (e.g. ⌘⇧). `0` for a modifier-only key. |
| `hotkey.isModifierOnly` | bool | `true` | Whether the hotkey is a bare modifier key (like Right Option) rather than a key + modifiers. |
| `hotkey.displayName` | string | `"Right Option"` | Human-readable label shown in the UI. |

---

## Full Example

Below is the shape Better Voice writes on first launch.

```json
{
    "language": "en",
    "onboarding_version": 0,

    "server": {
        "endpoint": "http://localhost:11434",
        "api": "ollama",
        "model": "qwen3.5:4b-mlx",
        "summarization_model": "",
        "timeout": 10,
        "health_interval": 30
    },

    "polish": {
        "enabled": true,
        "personal_context_enabled": true
    },

    "meeting": {
        "audio_source": "both",
        "auto_delete_audio": false,
        "default_type": "general",
        "summarization": { "enabled": true, "num_ctx": 32768, "num_predict": 2048, "classify_enabled": true }
    },

    "hotkey": { "keyCode": 61, "modifierFlags": 0, "isModifierOnly": true, "displayName": "Right Option" }
}
```

---

## macOS Permissions

Better Voice requires the following macOS permissions to function. The system will prompt on first use; they can also be granted in **System Settings > Privacy & Security**.

### Accessibility

**Required.** Better Voice uses a `CGEventTap` to listen for the Right Option key (hotkey for push-to-talk) and to inject transcribed text into the active application via synthetic key events (`TextInjector`). Without Accessibility access, hotkey detection and text injection will not work.

Grant in: **Privacy & Security > Accessibility**

### Input Monitoring

**Required.** Needed for `CGEventTap` to observe keyboard events globally. On macOS 26, this may be consolidated under the Accessibility permission depending on system version.

Grant in: **Privacy & Security > Input Monitoring**

### Microphone

**Required.** Better Voice captures audio via `AVCaptureSession` for speech recognition. The app's `Info.plist` includes `NSMicrophoneUsageDescription`. Without microphone access, no audio can be captured.

Grant in: **Privacy & Security > Microphone**

### System Audio Recording

**Meetings only.** Used by Meeting mode to capture the other side of a call. Better Voice uses a **Core Audio process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap` in `SystemAudioCapturer.swift`) — **not ScreenCaptureKit** — so it needs only the narrow *System Audio Recording* consent (the purple dot), never full Screen Recording. Not needed for dictation-only use. If not granted, meetings still record microphone audio but not the system/remote-participant audio.

Grant in: **Privacy & Security > System Audio Recording** (macOS prompts on first meeting).
