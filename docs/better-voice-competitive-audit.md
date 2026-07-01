# Better Voice — Competitive Feature Audit

**Subject:** [better-voice / ambient-voice](https://github.com/drkpxl/better-voice) vs. the 44 apps in the [FluidAudio showcase](https://github.com/FluidInference/FluidAudio)
**Date:** June 30, 2026 · **Rev 2** (Better Voice re-scored from source code, not just the README)
**Scope:** Every showcase entry, researched at its homepage/repo, scored across a fixed feature schema, weighted for both dictation *and* meeting use cases.

---

## 1. Your *actual* feature set — corrected from a source-level audit

> **Revision note (v2):** The first version of this audit was built from your README. You were right that it undersells the app, so I went back through the **Swift source, all 5 release notes, `docs/`, and the website**. This is the true shipped surface of **v0.6.0** — with the items your README/website *omit* flagged, since you'll want them for the rewrite. **Four things I called "missing" last round are in fact already shipped** (system-audio capture, AI summaries, OpenAI-compatible backend, and the DMG/onboarding/auto-update story). My apologies for the stale-README miss — the matrix rows and gap list below now reflect the real app.

**Dictation**
- Global hotkey (default Right Option) → on-device **Apple SpeechAnalyzer** → optional **LLM polish** → inject at cursor (clipboard + ⌘V). *(Code is actually a toggle, though the README says "hold.")*
- Live **waveform HUD** (notch-aware) + audible start/stop cues.
- **SpeechAnalyzer `contextualStrings` biasing** from your dictionary file.

**Meetings** — *almost entirely missing from the README*
- **System-audio capture via Core Audio process tap** — mic / system / **both** (default *both*), mixed 50/50. Needs only the lighter "System Audio Recording" consent, not full Screen Recording.
- **FluidAudio speaker diarization** + a **post-meeting wrap-up window** to name each detected speaker.
- **AI summaries** with **meeting-type classification** (1:1 / standup / general) and **type-aware prompt templates**, personal-context injected. Notes accrue **live** (per-segment L2 polish during the meeting); exports `transcript.md` + `-summary.md`.

**Personalization**
- **`personal-context.md`** — semantic context injected into *both* the polish and summary prompts.

**Backends & infra** — *also missing from the README*
- LLM polish runs against **Ollama *or* any OpenAI-compatible endpoint** (Bearer API key) — not Ollama-only.
- **Remote Voice** over Tailscale (Windows → Mac, HTTP on port 9800).
- **Ambient / always-listening mode** (`ambient_enabled`, VAD-driven) — off by default.
- **First-launch onboarding**, **Sparkle in-app auto-updates**, **DMG distribution**, a full **Settings window**, config hot-reload, local history/logs (`voice-history.jsonl`, `meeting-history.jsonl`, wav).

Your standout, rare-in-the-field assets remain: the editable **`personal-context.md`** semantic personalization, **type-aware meeting summaries**, and **Tailscale Remote Voice**. Gaps are in Section 5; the README/website fix-list is in Section 5b.

---

## 2. How to read the matrix

**Legend:** ✅ yes / strong · ◐ partial, optional, or planned · — no · ? not stated

**Category (Cat):** **B** = does both dictation + meetings · **D** = dictation-first · **M** = meeting-first · **K** = iOS voice keyboard · **A** = assistant / other voice tool · **L** = library / infra (not an end-user dictation app)

Apps are grouped by category, most-similar-to-you first. **Better Voice is the top row of each table.**

---

## 3. The matrix

### Matrix A — Capture & transcription

| App | Cat | Platform | Dictation | Meeting capture | System audio | Diarization | 100% local | Multilingual |
|---|---|---|---|---|---|---|---|---|
| **★ Better Voice** | **B** | mac (+Win remote) | ✅ | ✅ | ✅ (mic/sys/**both**) | ✅ | ✅ | ◐ (English-first by design) |
| Snaply | B | mac | ✅ | ✅ | ✅ | ? | ✅ | ✅ 100+ |
| Muesli | B | mac (+iOS sync) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ many |
| Dettivo | B | mac | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ 99 |
| Resonant | B | mac, Win(beta) | ✅ | ✅ | ✅ | ? | ✅ | ✅ 40 |
| MimicScribe | B | mac | ✅ | ✅ | ✅ | ✅ | ◐ | ✅ 25 |
| Talat | B | mac, Win | ✅ | ✅ | ✅ | ✅ | ✅ | ? |
| Slipbox | M | mac, iOS | — | ✅ | ✅ | ✅ | ◐ | ? |
| Thoth | M | mac, iOS(beta) | — | ✅ | ✅ | ✅ | ✅ | ✅ 99 |
| Summit AI Notes | M | mac | — | ✅ | ✅ | ✅ | ✅ | ✅ 100+ |
| Meeting Transcriber | M | mac | — | ✅ | ✅ | ✅ | ✅ | ✅ 99 |
| SamScribe | M | mac | — | ✅ | ✅ | ✅ | ✅ | ? |
| OpenOats | M | mac | — | ✅ | ✅ | ◐ (You/Them) | ◐ | ? |
| Audite | M | mac | — | ✅ | ? | — | ✅ | ? |
| Whisper Mate | M | mac | — | ✅ | ✅ | ✅ | ◐ | ✅ 99 |
| Voice Ink | D | mac, iOS | ✅ | — | ? | — | ◐ | ✅ many |
| Spokenly | D | mac, iOS, Win | ✅ | ◐ | ? | ? | ◐ | ✅ 100+ |
| Dictato | D | mac | ✅ | — | — | — | ✅ | ✅ 25–99 |
| Dictate Anywhere | D | mac | ✅ | — | — | — | ◐ | ✅ 25 |
| Altic / Fluid Voice | D | mac | ✅ | — | — | — | ◐ | ✅ up to 99 |
| Speakmac | D | mac | ✅ | — | — | — | ✅ | ✅ 25+ |
| Paraspeech | D | mac, iOS(beta) | ✅ | ◐ (soon) | ? | ? | ◐ | ✅ 100+ |
| Voxeoflow | D | mac | ✅ | — | — | — | ◐ | ✅ 100+ |
| VoiceTypr | D | mac, Win | ✅ | — | — | — | ◐ | ✅ 99 |
| Flowstay | D | mac | ✅ | — | — | — | ✅ | ✅ 25 |
| Hitoku Draft | D | mac | ✅ | — | — | — | ✅ | ✅ many |
| Hex | D | mac | ✅ | — | — | — | ✅ | ✅ 25 |
| MiniWhisper | D | mac | ✅ | — | — | — | ✅ | ✅ many |
| Starling | D | mac | ✅ | — | — | — | ✅ | ◐ EN-first |
| Utter | D | mac | ✅ | — | — | — | ✅ | — EN only |
| WhisKey | K | iOS, mac | ✅ | — | — | — | ✅ | ✅ 12+ |
| Sayboard | K | iOS | ✅ | — | — | — | ✅ | ✅ 90+ |
| NanoVoice | K | iOS | ✅ | — | — | — | ✅ | ✅ 99 |
| VivaDicta | K | iOS, mac, watch | ✅ | ◐ (voice notes) | — | ✅ | ◐ | ✅ 100+ |
| BoltAI | A | mac, iOS | ✅ (secondary) | — | — | — | ◐ | ✅ 25 |
| Enconvo | A | mac | ✅ | — | ◐ (captions) | — | ◐ | ✅ many |
| Super Voice Assistant | A | mac | ✅ | ◐ (screen rec) | — | — | ◐ | ✅ many |
| Ora | A | mac | ◐ (PTT assistant) | — | — | — | ✅ | ? |
| Volocal | A | iOS | — | — | — | — | ✅ | ? |
| Action Phrase | A | iOS, iPad, mac | — (voice control) | — | — | ✅ (rooms) | ✅ | ? |
| Senko | L | cross | — | — | — | ✅ | ✅ | ◐ lang-agnostic |
| macos-speech-server | L | mac | — | — | — | — | ✅ | ✅ 25–30+ |
| Kesha Voice Kit | L | cross | — | — | — | — | ✅ | ✅ 25 (ID 107) |
| mac-whisper-speedtest | L | mac | — | — | — | — | ✅ | ◐ inherits |
| hongbomiao.com | L | cross | — | — | — | — | — | — (not a voice app) |

### Matrix B — Intelligence, personalization & ecosystem

| App | LLM cleanup | AI summaries / notes | Custom vocab | Personal context / memory | Translation | Agent (CLI/MCP/REST) | Open source | Pricing |
|---|---|---|---|---|---|---|---|---|
| **★ Better Voice** | ✅ Ollama **or** OpenAI-compat | ✅ **type-aware** | ✅ dictionary.json | ✅ **personal-context.md** | — | — | ✅ MIT | Free |
| Snaply | ✅ local | ✅ | ? | ? | ✅ | — | — | Free (BYOK opt.) |
| Muesli | ✅ | ✅ | ✅ fuzzy dict | ◐ dict | ? | ✅ local CLI | ✅ MIT | Free / BYOK |
| Dettivo | ✅ local + enhanced | ✅ | ✅ per-lang dict | ✅ **learns + context-aware** | ✅ | ✅ **CLI+REST+MCP** | — | $45 lifetime |
| Resonant | ✅ local | ✅ | ? | ◐ searchable archive | ? | ✅ **MCP + API** | — | Freemium |
| MimicScribe | ✅ (cloud default) | ✅ | — (claims not needed) | ✅ "Your Context" + docs | — | ✅ **MCP** | — | Freemium $6–18/mo |
| Talat | ✅ local LLM | ✅ | ? | ◐ voice memory | ? | ✅ **MCP** + webhooks | — | $49 lifetime |
| Slipbox | ✅ cloud/BYOK/Ollama | ✅ | ? | ✅ adaptive memory | ? | ◐ BYOK endpoints | — | Freemium $99/yr |
| Thoth | ✅ on-device (5 models) | ✅ | ? | — | ◐ involuntary | — | — | Freemium $6.99/mo |
| Summit AI Notes | ✅ local | ✅ | ? | ◐ persistent names | ? | — | — | Freemium / $149 |
| Meeting Transcriber | ✅ local / Claude CLI | ✅ | ✅ CTC boosting | ◐ voice recognition | — | ◐ Claude CLI | ✅ MIT | Free |
| SamScribe | — | — | — | ✅ **cross-session speaker mem** | — | — | ✅ MIT | Free |
| OpenOats | ✅ local/cloud | ✅ | — | ✅ **KB RAG live** | — | ◐ OpenAI-compat | ✅ MIT | Free / BYOK |
| Audite | — | — | — | — | — | — | ✅ MIT | Free |
| Whisper Mate | ✅ | ✅ | ✅ dictionary | — | ✅ | ◐ CLI | — | One-time paid |
| Voice Ink | ✅ | — | ✅ personal dict | ◐ screen/clipboard ctx | ? | — | ✅ GPLv3 | $25–49 lifetime |
| Spokenly | ✅ cloud | — | ? | — | ? | ✅ **MCP** | — | Freemium $99/yr |
| Dictato | ✅ local | — | ✅ vocab + context | ◐ per-app | ✅ | — | — | €19.99 lifetime |
| Dictate Anywhere | ✅ Apple/Ollama/OR | — | ✅ custom vocab | — | — | ◐ Ollama/OpenRouter | ✅ MIT | Free / BYOK |
| Altic / Fluid Voice | ✅ local Fluid Intel. | — | ? | ◐ per-app | ? | ◐ Command Mode | ✅ GPLv3 | Free / BYOK |
| Speakmac | ✅ local cleanup | — | ✅ words/snippets | — | — | — | — | $29–49 one-time |
| Paraspeech | ✅ local Qwen | — | ◐ (soon) | — | ? | — | — | Freemium / $89/yr |
| Voxeoflow | ✅ BYOK Claude | ◐ | ? | — | ✅ DeepL | — | — | Freemium / $39.99 |
| VoiceTypr | ✅ cloud | ◐ presets | ? | — | — | — | ✅ AGPL | One-time / BYOK |
| Flowstay | ✅ local personas | — | ? | — | ✅ personas | — | ✅ | Free forever |
| Hitoku Draft | ✅ local | — | ? | ◐ screen ctx | ? | — | — | $5 one-time |
| Hex | ? | — | ? | — | — | — | ✅ MIT | Free |
| MiniWhisper | ◐ text replace | — | ✅ replacements | — | — | — | ✅ MIT | Free |
| Starling | — | — | — | — | — | — | ✅ MIT | Free |
| Utter | — | — | — | — | — | — | ✅ | Free |
| WhisKey | — | ◐ claims summaries+mindmaps | — | — | — | — | — | Freemium |
| Sayboard | ✅ local LLM | — | ? | — | ? | — | ✅ GPLv3 | Freemium |
| NanoVoice | ◐ smart format | — | ✅ smart replace | — | — | — | — | Free |
| VivaDicta | ✅ 40+ presets | ✅ | ✅ custom dict | ◐ on-device RAG | ✅ | ✅ CLI-agent bridge | ✅ MIT | Freemium / BYOK |
| BoltAI | ✅ chat | ◐ | ? | ◐ memory MCP | ? | ✅ **MCP client** | — | One-time / BYOK |
| Enconvo | ✅ | ◐ | ? | ✅ agent memory + KB | ✅ live captions | ✅ **MCP** + 100 plugins | ◐ ext. only | Freemium |
| Super Voice Assistant | ◐ replace | — | ✅ replacements | — | — | ◐ swift CLI | ✅ | Free / BYOK |
| Ora | ◐ local LLM | — | ? | ◐ skills | — | ◐ skills/scripts | ✅ | Free |
| Volocal | ✅ local Qwen | — | — | — | — | — | ✅ MIT | Free |
| Action Phrase | — | — | ◐ phrases | ◐ voice enroll | — | ◐ OSC/Shortcuts | — | Freemium |
| Senko | — | — | — | — | — | ✅ Python API | ✅ MIT | Free |
| macos-speech-server | — | — | ◐ prompt hint | — | — | ✅ **REST/Wyoming** | ✅ AGPL | Free |
| Kesha Voice Kit | — | — | — | — | — | ✅ CLI + agent | ✅ MIT | Free |
| mac-whisper-speedtest | — | — | — | — | — | ✅ CLI | ✅ MIT | Free |
| hongbomiao.com | — | — | — | — | — | — | ✅ | Free |

> **Other notable capabilities not given their own column:** **Remote / cross-device input** exists in only three entries besides you — `macos-speech-server` (LAN/Tailscale STT server), Muesli/VivaDicta (companion-device *text* sync, not push-to-talk). Your Windows→Mac injection is effectively unique among consumer apps. **TTS** appears in Enconvo, BoltAI, Ora, Volocal, Whisper Mate, Kesha, macos-speech-server — but it's peripheral to the dictation/meeting race.

### ASR engine reference (what each is built on)

| Engine family | Apps using it |
|---|---|
| **Apple SpeechAnalyzer (macOS 26)** | **Better Voice**, Dictato (option), Whisper Mate (option) |
| **Apple Speech (classic)** | OpenOats, Action Phrase, Super Voice Assistant |
| **Parakeet (FluidAudio / CoreML)** | Dettivo, Muesli, Hex, Starling, Utter, MiniWhisper, Dictate Anywhere, BoltAI, Audite, Meeting Transcriber, SamScribe, Kesha, macos-speech-server, Dictato, Volocal, Action Phrase, VivaDicta, Voice Ink (opt.), + more |
| **WhisperKit / whisper.cpp** | VoiceTypr, WhisKey, Flowstay, Sayboard, Thoth, Whisper Mate, Muesli, Hex (opt.), VivaDicta, Super Voice Assistant |
| **Qwen3-ASR / Nemotron / Cohere / SenseVoice** | Muesli, Dettivo, Meeting Transcriber, Altic, macos-speech-server, Dictato |
| **Proprietary / unnamed on-device** | Slipbox, Talat, Summit, Snaply, MimicScribe, Speakmac, Resonant, Hitoku, Paraspeech |

You're one of only ~3 apps betting on Apple's brand-new SpeechAnalyzer. That's a **positioning choice with a cost** — see Gap #3.

---

## 4. Where you actually stand

**You're in a small elite on breadth.** Only ~7 of 44 apps do *both* real system-wide dictation and meeting transcription in one product: **Snaply, Muesli, Dettivo, Resonant, MimicScribe, Talat**, and you. Most of the field is dictation-only (16+ apps) or meeting-only (8 apps). Doing both well is a legitimate wedge.

**Your two moats are real and rare:**

- **`personal-context.md`** — a *semantic* personalization file (your role, who you meet with, recurring topics) beats the static word-list dictionaries almost everyone else ships. Only Dettivo (context-aware Enhanced), MimicScribe ("Your Context"), OpenOats (KB-RAG), and Slipbox (adaptive memory) are in the same conversation, and yours is the most transparent/editable. **Double down on this.**
- **Tailscale Remote Voice** — cross-device push-to-talk injection (Windows→Mac) is effectively unique. Nobody else in the consumer set does it.

**Two things I flagged last round, you've already solved:** system-audio meeting capture and (type-aware!) AI summaries. What genuinely remains vs. the field: **agent/MCP access, cross-*meeting* speaker memory, multilingual, per-app profiles, streaming text, and the macOS-26-only ceiling.** Those are Section 5 — and just as important, your README/website don't yet *say* you do the things you already do (Section 5b).

---

## 5. Gaps & recommendations (re-prioritized after the source audit)

### 🟢 Already shipped — the fix is *marketing, not engineering*
System-audio meeting capture (mic/system/both), **type-aware AI summaries**, OpenAI-compatible backend, DMG + onboarding + Sparkle auto-updates, ambient always-listening mode, and Tailscale Remote Voice are all **done** but under-communicated. See **Section 5b** for exactly where to surface them. This is the single fastest way to look more competitive — you already built it.

### 🔴 P0 — Highest strategic leverage

**1. Escape the macOS-26-only ceiling.**
SpeechAnalyzer locks you to macOS 26, while Hex, Dettivo, Muesli, Summit, Meeting Transcriber, etc. run on macOS **13–14+**. Today that's a massive addressable-market cut. The good news from the source audit: **FluidAudio is already a dependency** (you use it for diarization), so adding **Parakeet ASR as a fallback engine** for macOS 13–15 is low-cost — same framework, runs on the Neural Engine. Keep SpeechAnalyzer as the default on 26, make Parakeet the floor for everyone else. Bonus: Parakeet hands you 25-language coverage for free (Gap #5).

**2. Fix the docs — your stated need, and it's material.**
The README, website, `docs/configuration.md`, and `docs/architecture.md` are all behind the code: the README omits system-audio capture, summaries, ambient mode, and OpenAI-compatible backend; `configuration.md` still says ScreenCaptureKit (you moved to a Core Audio tap) and documents only a fraction of the real config surface; `architecture.md` still describes removed L1/correction-capture stages. **Section 5b is a concrete checklist.** For a zero-star repo in a crowded field, the landing page doing your capabilities justice is worth as much as any feature.

### 🟠 P1 — Real gaps, strong fit for your audience

**3. MCP server + CLI over your dictation & meeting history.** *(confirmed absent in source)*
Clearest emerging trend, perfect fit — your default dictionary literally contains "Claude Code, MCP, ollama," so your users *are* agent people. **Dettivo (CLI+REST+MCP), Talat (MCP), MimicScribe (MCP), Resonant (MCP+API), Spokenly (MCP), Muesli (agent CLI), VivaDicta, Enconvo** all let agents query transcripts or trigger dictation. You already persist `voice-history.jsonl` + `meeting-history.jsonl` + meeting Markdown — expose `search_transcripts`, `insert_text`, `start_meeting`, "what did we decide about X" over stdio MCP. This could be a *headline* feature almost no one in your tier has done well.

**4. Cross-*meeting* persistent speaker memory.** *(confirmed: you name speakers per meeting, but store no voice embeddings)*
Your wrap-up window names speakers for a single meeting; **SamScribe, Muesli, Dettivo, Talat, Summit, MimicScribe, Thoth** save voice embeddings and auto-recognize "Bob" in every future meeting. FluidAudio can produce speaker embeddings, and `personal-context.md` already knows *who you meet with* — fusing the roster with stored voice profiles would be a distinctive, on-brand feature.

**5. Multilingual (you're English-only by design now).**
v0.4.1 deliberately went English-only. That's a defensible focus, but nearly everyone advertises 25–100+ languages. The Parakeet fallback (P0 #1) gives you 25 European languages essentially for free — at minimum expose language selection + auto-detect. Optional upsell: speak-one-language-insert-another **translation** (Dettivo, Voxeoflow, Snaply, Dictato, VivaDicta).

### 🟡 P2 — Polish

**6. Optional streaming text injection + a latency number.** You already have a live waveform HUD and a live meeting transcript panel, but *dictation* still pastes on release (batch). An optional live-inject mode plus a quoted insert latency (rivals advertise: Dettivo ~59ms, Muesli ~0.13s, Dictato ~80ms) closes the perception gap.

**7. Per-app profiles — nearly free for you.** The source shows you *already capture* the target app's identity (`AppIdentity`) but only log it. Use it to switch polish prompt/tone per app (terse in Slack, formatted in Gmail, code-aware in Cursor) — a natural extension of personal-context that Voice Ink, Dictato, Altic, and Dettivo all ship.

**8. Integrations & export.** Direct **Obsidian vault export** (Audite, Slipbox, Dettivo, Talat, Summit), **Calendar-based meeting titles** (Audite, Muesli, Dettivo auto-name from Calendar), **PDF export** (Thoth, Muesli), **webhooks** (Talat). Obsidian + Calendar titles are the highest-ROI.

**9. Finish or drop correction-capture.** `correction_enabled` is documented but the capture code isn't wired into the shipped pipeline. Either **finish it** — a learning loop that watches your post-injection edits is a genuine differentiator almost no one has — or remove it from the docs so it doesn't read as vaporware.

### ⚪ Skip (not your race)
TTS/read-back, live in-meeting "talking points" à la MimicScribe (heavy, pulls you cloud-ward), and voice-control-your-Mac (Altic Command Mode, Action Phrase).

---

## 5b. What your README & website don't yet say (fix-list)

You asked — here's the concrete doc gap. Everything below is **already in the app** but absent or wrong in your public-facing docs:

| Where | Currently says / omits | Should say |
|---|---|---|
| **README + website** | Meeting mode = "floating transcript, diarization, export" | Add **system-audio capture (mic / system / both)** — you hear the *other side* of Zoom/Teams/Meet, no bot, via a lightweight Core Audio tap (no full Screen Recording needed) |
| **README + website** | "summarization (soon)" / not mentioned | **AI summaries shipped**, with **meeting-type-aware prompts** (1:1 / standup / general) and personal-context injection — lead with this; type-aware summaries are rare |
| **README** | "local LLM (ollama)" | Also works with **any OpenAI-compatible endpoint** (BYOK / self-hosted) |
| **README + website** | not mentioned | **Ambient always-listening mode**, **first-launch onboarding**, **Sparkle auto-updates**, **live waveform HUD** |
| **Website** | omits Remote Voice entirely | **Tailscale Remote Voice (Windows → Mac)** — one of your most unique features; it belongs on the landing page |
| **README "hold Right Option… release"** | inaccurate | Code is a **toggle** — fix the copy (or make the code match the copy) |
| **docs/configuration.md** | says system audio uses **ScreenCaptureKit**; documents only `server.*`, `polish.*`, 2 flags | You use a **Core Audio process tap**; document the whole surface: `remote.*`, `hotkey.*`, the full `meeting.*` + `meeting.summarization.*`, `server.summarization_model/num_ctx/num_predict`, `language`, `onboarding_version` |
| **docs/architecture.md** | describes removed L1 `AlternativeSwap` + `CorrectionCapture` stages | Update to the shipped L2-only pipeline |
| **Repo** | 0 stars, no screenshots/GIF, no CI badges | Add a demo GIF (dictation + a meeting summary), screenshots, and a one-line "what makes it different" (local + personal-context + Remote Voice) |

*Want me to draft the rewritten README and website copy from this? Say the word and I'll produce both.*

---

## 6. One-paragraph summary

After reading the source (not just the README): Better Voice is further along than its docs suggest. It's in the rare "does both dictation and meetings" tier, it already ships **system-audio meeting capture** and **type-aware AI summaries** (which most rivals *don't* do as well), and it owns three genuinely differentiated ideas almost no one else has — editable **`personal-context.md`** personalization, **type-aware summaries**, and **Tailscale Remote Voice**. So the near-term wins aren't features, they're **telling people what you already built** (fix the README/website — Section 5b) and **letting more people run it** (lift the macOS-26 ceiling with the Parakeet engine you already depend on). The one net-new bet worth making is an **MCP/CLI surface** over your transcript history — it fits your AI-developer audience exactly and would be a headline almost no competitor in your tier has nailed. Do those and you go from "promising, invisible fork" to a legitimately best-in-class local voice tool.

---

## 7. Notes on scope & confidence

- **Not really competitors (flagged for completeness):** `Senko` (diarization *library*), `macos-speech-server` (STT/TTS *server*), `Kesha Voice Kit` (CLI toolkit/agent skill), `mac-whisper-speedtest` (benchmark harness), `Action Phrase` (live-production *voice control*, not transcription), `Volocal`/`Ora` (voice *assistants*), and `hongbomiao.com` (a personal R&D monorepo — appears to be a showcase false positive; no voice feature found).
- **"?" marks** mean the *competitor's* public pages didn't state the feature — not a confirmed "no." (Better Voice itself is now scored from its **source code**, releases, and docs, not just the README — so its row is high-confidence.)
- **Better Voice re-audit sources:** the v0.6.0 Swift source under `client/Sources/` (incl. `SystemAudioCapturer`, `AudioMixer`, `MeetingSession`, `SummarizationClient`, `ModelServer`, `RemoteInbox`, `AmbientController`), all 5 GitHub release notes (v0.3.0→v0.6.0), `docs/configuration.md`, `docs/architecture.md`, and the GitHub Pages site.
- All 44 apps were researched at their live homepages and/or GitHub READMEs (June 2026). Per-app source URLs were captured during research and can be expanded on request.
