# pyannote gold-standard benchmarking

Generates reference ("gold standard") speaker-diarization labels with
[pyannote.audio](https://github.com/pyannote/pyannote-audio) so we can objectively score Better
Voice's own diarization (speaker count + frame agreement) via the app's `--bench-meeting` DER-proxy.

pyannote is the research-standard baseline (community-1 / speaker-diarization-3.1 lineage). It is a
*reference*, not ground truth — it can itself miss/merge speakers — so we compare against it **and**
against human-verified counts where available.

## One-time setup

```bash
cd tools/pyannote
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "pyannote.audio>=3.1" soundfile
```

Accept the gated models on huggingface.co (one "Agree and access" click each):
- `pyannote/speaker-diarization-3.1`
- `pyannote/segmentation-3.0`
- `pyannote/speaker-diarization-community-1`  (pyannote 4.x resolves 3.1 → this)

Then authenticate: `.venv/bin/huggingface-cli login` (paste an HF **read** token).

## Run

```bash
HUGGING_FACE_HUB_TOKEN=hf_xxx .venv/bin/python diarize.py ../../client/.fixtures/<clip>.wav
```

Writes `<clip>.wav.speakers.json` — a `[{speaker,start,end}]` array. Place it next to the WAV and the
app's bench scores against it automatically:

```bash
cd ../../client
.build/debug/BetterVoice --bench-meeting .fixtures/<clip>.wav --locale en-US   # logs "[Bench] DER-proxy: fer=… scErr=…"
```

## Threshold sweep

The diarization sensitivity is `meeting.diarization.clustering_threshold` (lower = more speakers).
Sweep it against the gold labels by editing `~/.better-voice/config.json` between bench runs.

## Results log

### `videoplayback.wav` (309 s, downmixed to mono — multi-speaker "system audio" only)

Human-verified count: **7 speakers**. pyannote (gold): **6**.

| clustering_threshold | Better Voice speakers | frame error vs pyannote (`fer`) |
|---|---|---|
| 0.55 | 9 | — |
| **0.56–0.57** | **8** | **0.289** (best) |
| 0.58–0.60 | 5 | 0.368 |
| 0.70 (old default) | 4 | — |

Findings: the clusterer jumps 8→5 between 0.57 and 0.58 (7 is unreachable by threshold alone on this
clip). **0.57** = best frame agreement (~71%) and closest reachable count. Chosen as the interim
default. To be re-validated on real app-recorded meetings (mic + system channels), which exercise the
full per-channel pipeline unlike this mono clip.
