# Better Voice — Competitive Advantages

> Internal positioning doc. Everything here is grounded in what the product actually does (or is
> actively being built to do). Status is labeled honestly — **Shipping**, **In progress**, or
> **Roadmap** — so nothing here becomes an overclaim when it reaches a marketing site. Update as
> features land.

The one-line story: **Better Voice is the private, on-device alternative to cloud meeting-notes
tools — it never uploads your audio, asks for less invasive permissions, and tells your voice apart
from everyone else's.**

---

## 1. Everything stays on your Mac (privacy is the default, not a setting)

**Status: Shipping.**

- Speech-to-text runs on-device via Apple's built-in speech models.
- Speaker separation (diarization) runs on-device via local CoreML models.
- Cleanup and meeting summaries run against a **local** model you control (Ollama, or any
  OpenAI-compatible endpoint you point it at) — [why we use Ollama](ollama.html).
- No cloud account, no upload, no analytics, no third party in the loop.

**Why it matters / the pitch:** Most meeting-notes tools (Otter, Fireflies, Fathom, and the cloud
tiers of newer apps) stream your meeting audio to their servers. For anyone discussing customers,
finances, health, legal, or unreleased work, that's a non-starter. Better Voice gives you the same
transcript-and-summary workflow with **nothing leaving the machine**. "Private by architecture, not
by policy."

---

## 2. It asks for *audio*, not your *screen*

**Status: Shipping (0.6.0).**

Better Voice captures the other side of a call using **Core Audio process taps** (macOS 14.4+), which
require only the narrow **System Audio Recording** consent — the purple dot. It does **not** ask for
Screen Recording.

**Why it matters / the pitch:** Nearly every tool that captures meeting audio on a Mac does it
through ScreenCaptureKit, which forces users to grant **full Screen Recording** — the ability to see
everything on your display — just to hear a call. That's a scary, over-broad ask. Better Voice takes
the minimum: it can hear the meeting, and that's it. "We record the meeting, not your screen."

---

## 3. It knows *you* from *them* (per-channel speaker separation)

**Status: Shipping (0.7.0).**

Better Voice captures your microphone and the call's system audio as **separate channels**. Your
voice is attributed to "you" deterministically by channel of origin — it is never confused with a
remote participant — while the remote side is separated into distinct speakers. Because the two
sources are kept apart, **overlapping speech and interruptions** are handled far better than tools
that mix everything into one track and then guess.

**Why it matters / the pitch:** Single-channel meeting tools routinely mislabel who said what,
especially when people talk over each other. Better Voice starts from a structural advantage — it
already knows which audio is yours — so "you" vs. "the room" is always right, and cross-talk degrades
gracefully instead of scrambling the transcript.

---

## 4. Built for real meetings — many voices, not a hard cap

**Status: Shipping (0.7.0).**

The diarizer is clustering-based with **no fixed speaker limit** and a tunable sensitivity, so a
9-person roundtable is separated into 9 speakers, not squeezed into a fixed number of slots. Each
speaker turn also carries a real **voice embedding** and a confidence signal.

**Why it matters / the pitch:** Several on-device diarizers cap out at ~4 fixed speakers — fine for a
1:1, useless for a workshop or a panel. Better Voice scales to the actual number of people in the
room.

---

## 5. Speakers you'll recognize across meetings (fingerprinting)

**Status: Roadmap (foundation shipped in 0.7.0).**

Because Better Voice retains a voice embedding for each speaker, it can build a **persistent speaker
identity** — so "Speaker 3" in today's standup can be recognized as the same person next week, and
eventually named once and remembered. The plumbing (per-speaker embeddings + a speaker-registry
interface) shipped in 0.7.0; cross-meeting recognition is the next feature on top of it.

**Why it matters / the pitch:** Turns a pile of anonymous transcripts into a searchable record of
*who* said things over time — the kind of continuity cloud tools charge a subscription for, done
locally.

---

## 6. Efficient enough to just leave running

**Status: Shipping (0.7.0).**

The audio pipeline is engineered for long meetings on a laptop: diarization is processed in bounded
chunks (peak memory stays flat instead of growing with meeting length), it runs under a timeout so
stopping always returns promptly, and the hot path stays off the main thread. Dictation and meeting
capture live quietly in the menu bar and stay out of the way.

**Why it matters / the pitch:** No fan-spinning, no memory bloat over a two-hour meeting, no app to
babysit. It's ambient.

---

## 7. Your models, your choice

**Status: Shipping.**

Point Better Voice at whatever local model fits your Mac and your quality bar — a fast small model for
snappy cleanup, a larger one for richer summaries — or a self-hosted endpoint on your LAN/Tailscale.
You're not locked to one vendor's model or one cloud's pricing.

---

## 8. It updates and onboards like a real product

**Status: Shipping (0.6.0).**

In-app updates (check on launch + every 14 days, see what changed, "restart to update"), and a
first-run welcome flow that sets up permissions, hotkey, model server, and personal context. Table
stakes, but done properly.

---

## Positioning summary

| Axis | Cloud meeting tools | Better Voice |
|---|---|---|
| Where your audio goes | Their servers | Never leaves your Mac |
| Permission to capture a call | Often full Screen Recording | Audio-only (no screen) |
| You vs. other speakers | Guessed from one mixed track | Known by channel of origin |
| Speaker count | Often capped | Unbounded, tunable |
| Cross-meeting speaker memory | Paid cloud feature | Local (roadmap) |
| Model | Their model, their pricing | Yours, local or self-hosted |

**Headline candidates for a marketing site:**
- "Meeting notes that never leave your Mac."
- "It records the meeting, not your screen."
- "Knows your voice from everyone else's."
- "Private by architecture, not by policy."
