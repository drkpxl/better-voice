# WE v0.3.0

Removes the self-training / fine-tuning subsystem and replaces its personalization with a simple, editable **personal context** file injected into the polish prompt. On a modern Mac, a general ~4B model in ollama produces better cleanup out of the box than a fine-tuned 0.6B model — with none of the pipeline complexity.

## What changed

### ✨ Personal context (replaces self-training)
- New file `~/.we/personal-context.md` — free-text Markdown you edit by hand (who you meet with, your role, your company, recurring topics, jargon).
- Its contents are appended to the L2 polish system prompt so the model can disambiguate names, acronyms, and references. The same mechanism is wired to be reused by the upcoming summarization feature.
- Controlled by `polish.personal_context_enabled` (default `true`); the model is instructed to use the context only for disambiguation and never to output or act on it.
- **Why it's better than fine-tuning:** editable in seconds, carries meaning (not just word spellings), needs no GPU/retraining, and one file serves both cleanup and summarization.

Real A/B on `qwen3.5:4b-mlx`, same input "...synced with aaron about the atless platform layton see ess ell ohs for the cue three road map":
- **Without** context → "...the Atlas platform, **Layton, see, Essell, OHS** for the **Cue 3** roadmap."
- **With** context → "...the Atlas platform **latency SLOs** for the **Q3** roadmap."

### 🗑️ Removed: the entire training pipeline
- Deleted the whole `server/` directory: Whisper + Gemini 2.5 Flash distillation, QLoRA fine-tuning of Qwen3-0.6B, evaluation, GGUF/ollama deploy, and the autoresearch grid-search environment.
- Removed the client→server sync: `sync-to-server.sh`, the launchd watcher plist, and the `make sync` / `install-sync` / `uninstall-sync` targets.
- Removed the training-related KPI milestones (`m7_dict_build`, `m7_finetune`, `m7_report`); transcription/diarization/retention baselines and the `m11_*` runtime milestones remain.

### ⚙️ Config
- Default `server.model` is now `qwen3.5:4b-mlx` (was `qwen3:0.6b`). Point it at any model your ollama has (`ollama list`).
- Dead `distill` and `sync` config sections removed from defaults (silently ignored if present in an existing `~/.we/config.json`).
- New `polish.personal_context_enabled` (default `true`).

### 🔧 Kept working
- Transcription → polish → injection path is unchanged apart from the prompt augmentation.
- Local `voice-history.jsonl` / `meeting-history.jsonl` logs and `audio/*.wav` are still written as **local debugging artifacts** (they index each other).
- SpeechAnalyzer biasing via `dictionary.json` / `ContextEnhancer` is unchanged.

## Upgrade notes
- Pull a 4B model if you haven't: e.g. it's served via ollama as `qwen3.5:4b-mlx`.
- Optionally create `~/.we/personal-context.md` (a starter template is created on first use) and fill in your details.
- If you previously ran `make install-sync`, remove the leftover agent: `launchctl unload ~/Library/LaunchAgents/com.antigravity.we.sync.plist` and delete that plist.
