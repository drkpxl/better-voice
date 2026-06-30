# Configuration Reference

## Overview

WE reads its configuration from `~/.we/config.json`. On first launch, the app creates this file with sensible defaults. The file is monitored for changes at runtime -- edits are picked up automatically without restarting the app (hot-reload via `DispatchSource` file watcher).

All sections are optional. Missing keys fall back to their defaults.

---

## Server Settings

The `server` object controls how WE connects to the model inference backend for L2 polish (text refinement). Two API protocols are supported: Ollama (default) and OpenAI-compatible.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.endpoint` | string | `"http://localhost:11434"` | Base URL of the model server. For Ollama this is typically `http://host:11434`. For OpenAI-compatible APIs, use the full base URL (the client appends `/v1/chat/completions` if no `/v1/` path is present). |
| `server.api` | string | `"ollama"` | API protocol. `"ollama"` uses the `/api/generate` endpoint; `"openai"` uses the `/v1/chat/completions` endpoint. |
| `server.model` | string | `"qwen3.5:4b-mlx"` | Model name passed to the inference server. Must match an available model on the server (`ollama list`). A general ~4B model gives good cleanup out of the box; smaller models trade quality for speed. |
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
| `polish.system_prompt` | string | (locale-aware default from `Prompts.swift`) | System prompt sent to the model. Controls the style of text refinement. |
| `polish.personal_context_enabled` | bool | `true` | When `true`, the contents of `~/.we/personal-context.md` (if present and non-empty) are appended to the system prompt for disambiguation. See **Personal Context** below. |
| `polish.context_dictionary_enabled` | bool | `false` | When `true`, terms from the dictionary at `context_dictionary_path` are fed to SpeechAnalyzer as contextual hints to bias recognition (a transcription-layer aid, separate from the polish prompt). |
| `polish.context_dictionary_path` | string | `~/.we/correction-dictionary.json` | Path to the dictionary used for SpeechAnalyzer biasing. |

---

## Personal Context

`~/.we/personal-context.md` is a free-text Markdown file you edit by hand. Its
contents are appended to the L2 polish system prompt (and, in future, the
summarization prompt) so the model can disambiguate names, jargon, acronyms, and
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

## Feature Toggles

Top-level boolean flags that enable or disable major features.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `correction_enabled` | bool | `false` | Enable correction capture. When `true`, the app monitors the active text field after text injection and records any manual edits the user makes to `~/.we/corrections.jsonl` (a local log). |
| `ambient_enabled` | bool | `false` | Enable ambient (always-listening) mode. When `true`, the app continuously captures audio and segments speech automatically, rather than requiring the hotkey to be held. Intended for meeting transcription scenarios. |

---


## Full Example

```json
{
    "correction_enabled": false,
    "ambient_enabled": false,

    "server": {
        "endpoint": "http://localhost:11434",
        "api": "ollama",
        "model": "qwen3.5:4b-mlx",
        "timeout": 10,
        "health_interval": 30
    },

    "polish": {
        "enabled": true,
        "personal_context_enabled": true,
        "context_dictionary_enabled": false
    }
}
```

---

## macOS Permissions

WE requires the following macOS permissions to function. The system will prompt on first use; they can also be granted in **System Settings > Privacy & Security**.

### Accessibility

**Required.** WE uses a `CGEventTap` to listen for the Right Option key (hotkey for push-to-talk) and to inject transcribed text into the active application via synthetic key events (`TextInjector`). Without Accessibility access, hotkey detection and text injection will not work.

Grant in: **Privacy & Security > Accessibility**

### Input Monitoring

**Required.** Needed for `CGEventTap` to observe keyboard events globally. On macOS 26, this may be consolidated under the Accessibility permission depending on system version.

Grant in: **Privacy & Security > Input Monitoring**

### Microphone

**Required.** WE captures audio via `AVCaptureSession` for speech recognition. The app's `Info.plist` includes `NSMicrophoneUsageDescription`. Without microphone access, no audio can be captured.

Grant in: **Privacy & Security > Microphone**

### Screen Recording

**Optional.** Used by Meeting mode to capture system audio via ScreenCaptureKit (see `SystemAudioCapturer.swift`). Not needed for dictation-only use. If not granted, meetings still record microphone audio but not system/remote-participant audio.

Grant in: **Privacy & Security > Screen Recording**
