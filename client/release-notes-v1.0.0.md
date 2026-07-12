## Better Voice 1.0.0

On-device dictation and meeting notes for macOS — and as of 1.0, **your meetings land in Apple Notes**. Everything is processed locally on your Mac; audio never leaves the machine.

### New in 1.0

- **Meetings live in Apple Notes.** Drop in a recording (or paste a transcript) and the wizard transcribes, tells speakers apart, writes a titled summary, and creates two notes — the summary and the full transcript — in Apple Notes folders you pick once. The summary opens in Notes when it's done. Search, editing, sharing, and iCloud sync all happen in Notes; there's no in-app library to manage and no files to keep track of.
- **Notarized.** Signed with a Developer ID and notarized by Apple — just drag **BetterVoice2.app** to `/Applications` and open it. No Gatekeeper workarounds.
- **In-app updates.** The app checks for new versions and updates itself in place (menu bar → **Check for Updates…**). Because the app is signed with a stable Developer ID, your permissions survive updates.

### Features

- **Dictation** — hold your hotkey, speak, release; cleaned-up text is inserted at your cursor in any app. On-device Apple `SpeechAnalyzer` transcription with an optional local LLM cleanup pass.
- **Meetings to Apple Notes** — drop an `.m4a`/`.mp3`/`.wav` (or paste a transcript) and a guided wizard transcribes → separates & names speakers → summarizes → adds both notes to Apple Notes with a matching title like `Jun 18th - Q3 Roadmap Sync`. Voices you've named are recognized and suggested next time.
- **Independent model providers per feature** — dictation cleanup and meeting summarization each pick their own provider: Apple on-device, Ollama, or any OpenAI-compatible server.

### Requirements

macOS 26+, Apple silicon. Apple Intelligence recommended for the zero-setup default.

### Install

Download the `.dmg` from [voice.baselinemakes.com](https://voice.baselinemakes.com), drag **BetterVoice2.app** to `/Applications`, then launch. Grant Microphone / Input Monitoring / Accessibility when prompted; the first time you set up meeting import, macOS will also ask to let Better Voice control Notes (that's how your transcripts and summaries get saved — the app only ever creates notes, it never reads them).
