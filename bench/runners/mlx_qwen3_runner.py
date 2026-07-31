# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-qwen3-asr"]
# ///
"""Qwen3-ASR-on-MLX runner for the pipeline bake-off.

Same contract as the other ASR runners: WAV in, one JSON object on stdout with `engine`, `text`,
`cold_s`, `warm_s`, `runs`, `error`. Diagnostics go to stderr.

Uses the `Session` API rather than the one-shot `transcribe()` so the model is loaded once and
`load_s` is measured separately from transcription -- unlike mlx_whisper, this package exposes that
seam, so the split is real here rather than estimated.

Run: uv run --script mlx_qwen3_runner.py --audio in.wav [--model Qwen/Qwen3-ASR-0.6B] [--repeats 3]
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time

DEFAULT_MODEL = "Qwen/Qwen3-ASR-0.6B"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--engine", default=None)
    args = parser.parse_args()

    engine = args.engine or f"qwen3-asr:{args.model.rsplit('/', 1)[-1]}"
    record: dict[str, object] = {"engine": engine, "model": args.model, "text": "", "error": None}

    try:
        from mlx_qwen3_asr import Session
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"import failed: {type(exc).__name__}: {exc}"
        print(json.dumps(record))
        return 1

    try:
        load_start = time.perf_counter()
        session = Session(model=args.model)
        load_s = time.perf_counter() - load_start
        print(f"  load: {load_s:.2f}s", file=sys.stderr)

        durations: list[float] = []
        text = ""
        for i in range(max(1, args.repeats)):
            start = time.perf_counter()
            result = session.transcribe(args.audio)
            elapsed = time.perf_counter() - start
            text = (getattr(result, "text", "") or "").strip()
            durations.append(elapsed)
            print(f"  pass {i}: {elapsed:.2f}s", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"{type(exc).__name__}: {exc}"
        print(json.dumps(record))
        return 1

    # First transcribe still absorbs graph compilation even with the model already loaded, so it is
    # reported as cold and excluded from the warm median when there is more than one pass.
    record.update(
        text=text,
        load_s=round(load_s, 3),
        cold_s=round(durations[0], 3),
        warm_s=round(statistics.median(durations[1:]), 3) if len(durations) > 1 else round(durations[0], 3),
        runs=[round(d, 3) for d in durations],
    )
    print(json.dumps(record))
    return 0


if __name__ == "__main__":
    sys.exit(main())
