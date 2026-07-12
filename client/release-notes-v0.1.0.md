## Better Voice 0.1.0

First public release of the rebuilt Better Voice — on-device dictation and meeting notes for macOS.

**⚠️ Not yet notarized.** This build is self-signed. On first launch macOS Gatekeeper will block it; after dragging the app to `/Applications`, run:

```
xattr -cr /Applications/BetterVoice2.app
```

A notarized 1.0 will follow.

### What's here

- **Dictation** — hold your hotkey, speak, release; cleaned-up text is inserted at your cursor in any app. On-device Apple `SpeechAnalyzer` transcription with an optional local LLM cleanup pass.
- **Meeting notes from a file** — drop an `.m4a`/`.mp3`/`.wav` (or paste a transcript) and a guided wizard transcribes → separates & names speakers → summarizes → saves to an editable library.
- **Independent model providers per feature** — dictation cleanup and meeting summarization each pick their own provider: Apple on-device, Ollama, or any OpenAI-compatible server. Mix and match.

### Requirements

macOS 26+, Apple silicon. Apple Intelligence recommended for the zero-setup default.

### Install

Download the `.dmg`, drag **BetterVoice2.app** to `/Applications`, run the `xattr` command above, then launch and grant Microphone / Input Monitoring / Accessibility.
