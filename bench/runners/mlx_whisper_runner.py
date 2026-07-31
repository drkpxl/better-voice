# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-whisper"]
# ///
"""Whisper-on-MLX runner for the pipeline bake-off.

Contract (shared by every ASR runner): takes a WAV, prints one JSON object to stdout with
`engine`, `text`, `cold_s`, `warm_s`, `runs`, and `error`. Nothing else goes to stdout -- progress
and warnings go to stderr so the driver can parse stdout unconditionally.

`cold_s` is the first pass including model load; `warm_s` is the median of the remaining passes.
Both are reported rather than trying to isolate a `load_s`, because mlx_whisper loads lazily inside
`transcribe` and the two costs are not cleanly separable from outside. They answer different
questions anyway: cold is the first-use UX cost, warm is throughput.

Run: uv run --script mlx_whisper_runner.py --audio in.wav [--model <hf-repo>] [--repeats 3]
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--engine", default=None, help="label for the output record")
    args = parser.parse_args()

    engine = args.engine or f"whisper:{args.model.rsplit('/', 1)[-1]}"
    record: dict[str, object] = {"engine": engine, "model": args.model, "text": "", "error": None}

    try:
        import mlx_whisper
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"import failed: {type(exc).__name__}: {exc}"
        print(json.dumps(record))
        return 1

    def transcribe() -> tuple[str, list]:
        # language is pinned to English: leaving it auto lets the detector wobble between runs,
        # which would show up as accuracy noise rather than a property of the model.
        out = mlx_whisper.transcribe(args.audio, path_or_hf_repo=args.model, language="en")
        # Segment boundaries are emitted so the harness can check long-form stability against the
        # audio timeline -- without them, truncation and late collapse are undetectable for this
        # engine. Deliberately NOT word_timestamps=True: that adds a second alignment pass and would
        # inflate the throughput number this same run is measuring.
        segments = [
            {
                "start": round(float(s["start"]), 3),
                "end": round(float(s["end"]), 3),
                "text": (s.get("text") or "").strip(),
            }
            for s in (out.get("segments") or [])
            if s.get("start") is not None and s.get("end") is not None
        ]
        return (out.get("text") or "").strip(), segments

    try:
        durations: list[float] = []
        text = ""
        segments: list = []
        for i in range(max(1, args.repeats) + 1):
            start = time.perf_counter()
            text, segments = transcribe()
            elapsed = time.perf_counter() - start
            durations.append(elapsed)
            print(f"  pass {i}: {elapsed:.2f}s", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"{type(exc).__name__}: {exc}"
        print(json.dumps(record))
        return 1

    record.update(
        text=text,
        segments=segments,
        cold_s=round(durations[0], 3),
        warm_s=round(statistics.median(durations[1:]), 3) if len(durations) > 1 else round(durations[0], 3),
        runs=[round(d, 3) for d in durations],
    )
    print(json.dumps(record))
    return 0


if __name__ == "__main__":
    sys.exit(main())
