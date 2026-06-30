# WE v0.2.0

First public release.

## New Features

- **Meeting Mode**: Menu bar → "Start Meeting", long-form recording → automatic segmentation → L2 model correction → export Markdown minutes
- **Custom Hotkeys**: Menu bar → "Set Hotkey...", supports a single modifier key (Right Option, etc.) or key combinations (⌘⇧R, etc.), with conflict detection
- **Dictionary Correction**: Automatically loads `~/.we/correction-dictionary.json`, injecting high-frequency terms into the speech recognition context
- **Full Data Trail**: The input/output of each L2 correction is written in real time to `~/.we/meeting-history.jsonl`
- **Remote Recording**: An iOS Shortcut pushes audio over HTTP to the Mac's :9800 port for transcription

## Installation (Read This First)

1. Download `WE-0.2.0.dmg` and double-click to mount it
2. Drag `WE.app` into "Applications"
3. Run in Terminal (to bypass the unsigned-app warning, **only needed once**):
   ```
   xattr -cr /Applications/WE.app
   ```
4. Launch WE and grant permissions as prompted: Microphone, Speech Recognition, Accessibility

See `INSTALL.txt` inside the DMG for details.

## Configuration

Menu bar → "Edit Config File...", key settings:

- `server.endpoint`: Defaults to `http://localhost:11434`; change it to your own ollama server address
- `polish.context_dictionary_enabled`: Enables dictionary correction (default: false)
- `meeting.audio_source`: `mic` / `system` / `both` (system audio / mixed audio captures the other meeting participants' voices)

## System Requirements

- macOS 26 (Tahoe)
- Apple Silicon (M-series)
- A remote or local ollama server running the `we-polish` model

## Known Limitations

- Self-signed build: After upgrading, TCC privacy permissions may need to be re-granted once
- L2 correction depends on an external ollama service; if the server is unreachable, it falls back to passing through the raw SA transcript (logged as `kind=failed`)

## Uninstall

```
killall WE 2>/dev/null
rm -rf /Applications/WE.app ~/Applications/WE.app
# Also clear history data:
rm -rf ~/.we/
```
