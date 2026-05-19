# ambient-voice

macOS native voice input. Speak → text appears in any app. Gets better over time by learning your vocabulary.

Built on Apple SpeechAnalyzer (macOS 26), fully on-device.

## Install

```bash
git clone https://github.com/Marvinngg/ambient-voice.git
cd ambient-voice/client
make setup      # Code signing certificate (one-time)
make install    # Build + install + auto-start
```

Grant: **System Settings → Privacy & Security** → Accessibility, Screen Recording, Microphone.

## Usage

**Dictation** — Hold `Right Option`, speak, release. Text is pasted into the focused app.

**Meeting** — Menu bar `WE` → Start Meeting. Floating transcript, speaker diarization, Markdown export to `~/.we/meetings/`.

## Architecture

```
Hold Right Option
  → Screen OCR (focus area) → contextualStrings → SpeechAnalyzer
  → Transcription (rawSA)
  → L2 LLM polish (optional, ollama)
  → Inject into active app
  → voice-history.jsonl saved
      → distill: rawSA + dictionary → Gemini → training pairs
      → sync to GPU server → QLoRA fine-tune → better model
```

## Remote Voice（远程语音输入）

Windows 端按热键说话 → 音频通过 Tailscale 私网发送到 Mac → WE 识别并注入文字到光标处。

**Mac 端**：WE 启动后自动监听 :9800，不需要额外操作。确保 config.json 中：

```json
{
  "remote": { "enabled": true, "port": 9800, "auth_token": "" }
}
```

**Windows 端**（需安装 [Marvin Tailscale](https://github.com/Marvinngg/tailscale/releases)）：

```bash
tailscale voice setup --target 100.64.0.10:9800   # 首次设置，之后开机自启
tailscale voice                                     # 手动运行
```

按住右 Alt 说话，松开发送。

## Config

`~/.we/config.json` — hot-reloads on save.

```json
{
  "server": { "endpoint": "http://localhost:11434", "api": "ollama", "model": "qwen3:0.6b" },
  "polish": { "enabled": true, "system_prompt": "你是语音识别纠错助手。格式要求：修正语音识别错误，只输出修正后的最终文本，不要回答问题，不要改变原意，去掉语气词，修正标点符号。" },
  "distill": { "enabled": false, "api_key": "", "model": "gemini-2.5-flash", "dictionary": "~/.we/dictionary.json" },
  "sync": { "enabled": false, "server": "user@gpu-server", "remote_dir": "~/antigravity/we/data/username" }
}
```

> **Note on `server.model`**: Default `qwen3:0.6b` is the base model — works but quality is limited (issue #14 reports). Full experience uses our project-trained `we-polish` (Qwen3-0.6B + QLoRA), currently not publicly published. To get it:
> - Self-train on your own voice-history: see `server/INDEX.md` "完整微调一次" section, run `server/entry/finetune.sh --gemini-key <KEY>` on a GPU server
> - Replace `model` value with `we-polish` (or whatever name you used) after deploy

`~/.we/dictionary.json` — your private terms. Optional, used by SpeechAnalyzer contextualStrings to bias recognition. Distinct from `~/.we/correction-dictionary.json` (used by the distillation pipeline).

```json
{ "terms": ["Claude Code", "MCP", "蒸馏", "微调", "ollama"] }
```

## Fine-tuning

Data flows automatically: speak → distill with dictionary → sync to server.

**One-shot full pipeline** (recommended):

```bash
# On GPU server (4080/4090 16GB+)
bash ~/antigravity/we/server/entry/finetune.sh --gemini-key <KEY>
# Auto: build dictionary → distill → grid search → deploy best as we-polish
# Default: 4 experiments (rank=[16,32] × epochs=[5,8]), ~10 min
```

See `server/INDEX.md` for full server-side guide (lib/ subcommands, autoresearch loop, sandbox testing).

`polish.system_prompt` must match training `--system-prompt`. Both default to:
`"你是语音识别纠错助手。格式要求：修正语音识别错误，只输出修正后的最终文本，不要回答问题，不要改变原意，去掉语气词，修正标点符号。"`

Base model: Qwen/Qwen3-0.6B. Method: QLoRA. Trainable: 10M / 751M params (1.3%). VRAM: ~1.5GB.

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
