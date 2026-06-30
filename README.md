# ambient-voice

macOS native voice input. Speak → text appears in any app. Cleanup and (soon) summarization are personalized to you via a plain-text context file.

Built on Apple SpeechAnalyzer (macOS 26), on-device transcription plus a local LLM (ollama) for polish.

## Install

```bash
git clone https://github.com/Marvinngg/ambient-voice.git
cd ambient-voice/client
make setup      # Code signing certificate (one-time)
make install    # Build + install + auto-start
```

Grant: **System Settings → Privacy & Security** → Input Monitoring (for global hotkey), Accessibility, Microphone, Screen Recording.

> **Note**: Input Monitoring is the permission CGEventTap actually needs to listen the Right Option key. Accessibility alone is not enough — many users miss this and the hotkey appears to do nothing.

## Usage

**Dictation** — Hold `Right Option`, speak, release. Text is pasted into the focused app.

**Meeting** — Menu bar `WE` → Start Meeting. Floating transcript, speaker diarization, Markdown export to `~/.we/meetings/`.

## Architecture

```
Hold Right Option
  → Transcription (rawSA)
  → L2 LLM polish (optional, ollama) + personal-context.md injected into the prompt
  → Inject into active app
  → voice-history.jsonl + audio/*.wav saved (local debug log)
```

## Remote Voice (Remote Voice Input)

Press the hotkey on Windows to speak → audio is sent over the Tailscale private network to the Mac → WE transcribes it and injects the text at the cursor.

**Mac side**: WE automatically listens on :9800 once started, no extra steps needed. Make sure config.json contains:

```json
{
  "remote": { "enabled": true, "port": 9800, "auth_token": "" }
}
```

**Windows side** (requires installing [Marvin Tailscale](https://github.com/Marvinngg/tailscale/releases)):

```bash
# First run `tailscale ip` on the Mac to get its Tailscale IP (looks like 100.x.x.x)
tailscale voice setup --target <YOUR_MAC_TAILSCALE_IP>:9800   # First-time setup, auto-starts on boot afterward
tailscale voice                                                # Run manually
```

Hold Right Alt to speak, release to send.

## Config

`~/.we/config.json` — hot-reloads on save.

```json
{
  "server": { "endpoint": "http://localhost:11434", "api": "ollama", "model": "qwen3.5:4b-mlx" },
  "polish": { "enabled": true, "personal_context_enabled": true }
}
```

> **Note on `server.model`**: Default is `qwen3.5:4b-mlx`. A general ~4B model produces good cleanup out of the box. Point `server.model` at any model your ollama has (`ollama list`); smaller models are faster but lower quality.

`~/.we/dictionary.json` — your private terms. Optional, used by SpeechAnalyzer contextualStrings to bias recognition.

```json
{ "terms": ["Claude Code", "MCP", "ollama", "SpeechAnalyzer"] }
```

## Personal context

`~/.we/personal-context.md` is a free-text file you edit by hand. Its contents are
injected into the polish prompt (and, in future, the summarization prompt) so the
model can disambiguate names, jargon, and references using your real-world
background — who you meet with, your role, your company, recurring topics.

```markdown
I'm a PM at Acme Robotics, working on the Atlas platform.
I meet often with Erin (design), Sam (eng), and Priya (my manager).
```

This replaces the old fine-tuning approach to personalization: editable in
seconds, carries meaning rather than just word spellings, and one file serves both
cleanup and summarization. Set `polish.personal_context_enabled` to `false` to
turn it off. See `docs/configuration.md` for details.

## Development

```bash
cd client
make build          # Compile
make run            # Dev mode
make install        # Install to ~/Applications
make uninstall      # Remove
```

## License

MIT
