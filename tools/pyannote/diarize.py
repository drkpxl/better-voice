#!/usr/bin/env python3
"""Gold-standard speaker diarization with pyannote.audio.

Runs pyannote/speaker-diarization-3.1 on a WAV file and writes a `<wav>.speakers.json`
sidecar in Better Voice's bench format — a JSON array of {"speaker","start","end"} —
so the app's --bench-meeting DER-proxy can score our pipeline against this reference.

Usage:
    .venv/bin/python diarize.py /path/to/audio.wav [--num-speakers N] [--out path.json]

Requires: the pyannote/speaker-diarization-3.1 and pyannote/segmentation-3.0 gated models
accepted on huggingface.co and a token available via `huggingface-cli login` or the
HUGGING_FACE_HUB_TOKEN env var.
"""
import argparse
import json
import os
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser(description="pyannote gold-standard diarization -> Better Voice sidecar")
    ap.add_argument("wav", help="path to a mono/stereo WAV file")
    ap.add_argument("--num-speakers", type=int, default=None,
                    help="fix the speaker count (omit to let pyannote decide)")
    ap.add_argument("--out", default=None,
                    help="output sidecar path (default: <wav>.speakers.json)")
    args = ap.parse_args()

    if not os.path.exists(args.wav):
        print(f"error: file not found: {args.wav}", file=sys.stderr)
        return 2

    token = os.environ.get("HUGGING_FACE_HUB_TOKEN") or os.environ.get("HF_TOKEN")

    import torch
    from pyannote.audio import Pipeline

    print("loading pyannote/speaker-diarization-3.1 ...", flush=True)
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=token,  # None is fine if already logged in via huggingface-cli (pyannote 4.x uses `token=`)
    )

    # Apple Silicon acceleration when available.
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
        print("device: mps", flush=True)
    else:
        print("device: cpu", flush=True)

    kwargs = {}
    if args.num_speakers is not None:
        kwargs["num_speakers"] = args.num_speakers

    t0 = time.time()
    diarization = pipeline(args.wav, **kwargs)
    elapsed = time.time() - t0

    # pyannote 4.x returns a DiarizeOutput dataclass; the Annotation is on .speaker_diarization.
    # Older versions returned the Annotation directly (which has .itertracks itself).
    annotation = getattr(diarization, "speaker_diarization", diarization)

    segments = []
    speakers = set()
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        segments.append({"speaker": str(speaker), "start": round(turn.start, 3), "end": round(turn.end, 3)})
        speakers.add(str(speaker))
    segments.sort(key=lambda s: s["start"])

    out_path = args.out or (args.wav + ".speakers.json")
    with open(out_path, "w") as f:
        json.dump(segments, f, indent=2)

    print(f"pyannote: {len(speakers)} speakers, {len(segments)} segments, {elapsed:.1f}s")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
