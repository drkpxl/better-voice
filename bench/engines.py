"""ASR and cleanup engine invocation for the pipeline bake-off.

Every engine is a subprocess behind one contract, so a broken dependency fails a single column
rather than the whole run. Engines never raise into the driver: failures come back as a record with
`error` set and empty `text`, which the scorer treats as a 1.0-WER cell.

Stdlib only.
"""

from __future__ import annotations

import json
import shutil
import statistics
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP_BINARY = REPO / "client" / ".build" / "debug" / "BetterVoice2"
FLUIDAUDIO_DIR = REPO / "client" / ".build" / "checkouts" / "FluidAudio"
FLUIDAUDIO_BINARY = FLUIDAUDIO_DIR / ".build" / "debug" / "fluidaudiocli"
RUNNERS = Path(__file__).resolve().parent / "runners"

# Timeout per engine invocation. Generous because a cold run may download a model, but finite so one
# wedged engine cannot hang the whole grid.
TIMEOUT_S = 3600


@dataclass
class AsrResult:
    engine: str
    text: str = ""
    cold_s: float | None = None
    warm_s: float | None = None
    audio_s: float | None = None
    error: str | None = None
    n_speakers: int | None = None
    n_segments: int | None = None
    raw: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.error is None and bool(self.text.strip())

    @property
    def rtfx(self) -> float | None:
        if self.audio_s and self.warm_s:
            return round(self.audio_s / self.warm_s, 1)
        return None


def _run(cmd: list[str], cwd: Path | None = None) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT_S, check=False
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {TIMEOUT_S}s"
    except FileNotFoundError as exc:
        return 127, "", str(exc)


# ---------------------------------------------------------------------------
# The app's own import pipeline, via its bench CLI
# ---------------------------------------------------------------------------

def run_app_pipeline(audio: Path, workspace: Path, audio_s: float | None = None, repeats: int = 3,
                     multi_speaker: bool = False) -> AsrResult:
    """The app's own import pipeline, end to end, via `--bench-meeting`.

    This was `run_apple`, labelling its output `engine="apple"` back when `TranscriberFactory` could
    return Apple's `SpeechTranscriber`. It cannot: `make()` returns Parakeet unconditionally since the
    Apple ASR stack was deleted. So the function kept working and kept reporting **Parakeet numbers
    under the name "apple"** -- a silently wrong measurement, which is worse than a broken one.

    Renamed rather than deleted because it measures something nothing else does: the *shipped* path,
    including phrase synthesis, `SegmentBuffer` grouping, diarization and vocabulary replacement.
    `run_fluidaudio` measures the engine in isolation via `fluidaudiocli`. When the two disagree, the
    difference is the app's own code, which is exactly what a regression check wants.

    `--no-polish` used to be passed here and was mandatory, because `ImportPipeline` ran an LLM
    cleanup pass internally. It doesn't, so the flag is gone from both sides.
    """
    result = AsrResult(engine="app-pipeline")
    if not APP_BINARY.exists():
        result.error = f"app binary missing: {APP_BINARY} (run: cd client && swift build)"
        return result

    durations: list[float] = []
    payload: dict = {}
    for _ in range(max(1, repeats)):
        out_json = workspace / "app_pipeline.json"
        cmd = [
            str(APP_BINARY), "--bench-meeting", str(audio),
            "--workspace", str(workspace), "--output", str(out_json),
        ]
        # Multi-speaker mode runs FluidAudio diarization and attributes segments to speakers; single
        # mode skips it entirely and emits a flat transcript. Meeting audio needs the former.
        #
        # Appended, not inserted at a fixed index: the previous version did `cmd.insert(4, ...)`,
        # which silently depended on `--no-polish` occupying position 3. Removing that flag would have
        # moved `--single` into the middle of `--workspace`'s value.
        if not multi_speaker:
            cmd.append("--single")
        start = time.perf_counter()
        code, _, stderr = _run(cmd)
        durations.append(time.perf_counter() - start)
        if code != 0:
            result.error = f"exit {code}: {stderr.strip()[:400]}"
            return result
        try:
            payload = json.loads(out_json.read_text())
        except Exception as exc:  # noqa: BLE001
            result.error = f"unparseable output: {exc}"
            return result

    result.text = payload.get("hypothesis", "") or ""
    result.audio_s = payload.get("duration_s") or audio_s
    result.cold_s = round(durations[0], 3)
    # The app reports its own in-process pipeline time, which excludes process launch -- a fairer
    # throughput number than wall clock. Wall clock is kept as cold_s for the UX-cost view.
    result.warm_s = payload.get("total_processing_s") or round(
        statistics.median(durations[1:]) if len(durations) > 1 else durations[0], 3
    )
    result.n_speakers = payload.get("n_speakers")
    result.n_segments = payload.get("n_segments")
    result.raw = payload
    return result


# ---------------------------------------------------------------------------
# FluidAudio CoreML models, via fluidaudiocli
# ---------------------------------------------------------------------------

FLUIDAUDIO_VERSIONS = {
    "parakeet-tdt-v3": "v3",
    "parakeet-tdt-v2": "v2",
    "parakeet-tdt-ctc-110m": "110m",
}


def ensure_fluidaudio_built() -> str | None:
    """Build fluidaudiocli once. Returns an error string, or None on success.

    Built ahead of the run rather than via `swift run` per invocation, because `swift run` would
    fold compilation time into the first transcription's measurement.
    """
    if FLUIDAUDIO_BINARY.exists():
        return None
    if not FLUIDAUDIO_DIR.exists():
        return f"FluidAudio checkout missing at {FLUIDAUDIO_DIR} (run: cd client && swift build)"
    if shutil.which("swift") is None:
        return "swift not on PATH"
    code, _, stderr = _run(["swift", "build", "--product", "fluidaudiocli"], cwd=FLUIDAUDIO_DIR)
    if code != 0:
        return f"fluidaudiocli build failed: {stderr.strip()[-500:]}"
    if not FLUIDAUDIO_BINARY.exists():
        return f"fluidaudiocli built but not at {FLUIDAUDIO_BINARY}"
    return None


def run_fluidaudio(audio: Path, workspace: Path, engine: str, audio_s: float | None = None,
                   repeats: int = 3, version: str | None = None) -> AsrResult:
    result = AsrResult(engine=engine)
    version = version or FLUIDAUDIO_VERSIONS.get(engine)
    if version is None:
        result.error = f"unknown FluidAudio engine {engine}"
        return result
    if (err := ensure_fluidaudio_built()) is not None:
        result.error = err
        return result

    durations: list[float] = []
    payload: dict = {}
    for _ in range(max(1, repeats)):
        out_json = workspace / f"{engine}.json"
        cmd = [
            str(FLUIDAUDIO_BINARY), "transcribe", str(audio),
            "--model-version", version,
            "--output-json", str(out_json),
        ]
        start = time.perf_counter()
        code, _, stderr = _run(cmd, cwd=FLUIDAUDIO_DIR)
        durations.append(time.perf_counter() - start)
        if code != 0:
            result.error = f"exit {code}: {stderr.strip()[-400:]}"
            return result
        try:
            payload = json.loads(out_json.read_text())
        except Exception as exc:  # noqa: BLE001
            result.error = f"unparseable output: {exc}"
            return result

    result.text = payload.get("text", "") or ""
    # fluidaudiocli reports durationSeconds/rtfx as 0 in this code path, so fall back to the
    # duration ffprobe measured during `prepare` -- otherwise RTFx is silently unavailable.
    result.audio_s = payload.get("durationSeconds") or audio_s
    result.cold_s = round(durations[0], 3)
    reported = payload.get("processingTimeSeconds")
    result.warm_s = round(
        reported if reported else (statistics.median(durations[1:]) if len(durations) > 1 else durations[0]),
        3,
    )
    result.raw = payload
    return result


# ---------------------------------------------------------------------------
# MLX models, via uv-managed runner scripts
# ---------------------------------------------------------------------------

MLX_ENGINES = {
    "qwen3-asr-0.6b": ("mlx_qwen3_runner.py", "Qwen/Qwen3-ASR-0.6B"),
    "qwen3-asr-1.7b": ("mlx_qwen3_runner.py", "Qwen/Qwen3-ASR-1.7B"),
    "whisper-large-v3-turbo": ("mlx_whisper_runner.py", "mlx-community/whisper-large-v3-turbo"),
}

# Runner families, for engines that are not in the curated registry above. Most newly released speech
# models are a new set of weights for a runtime that already has a runner here, so `family:hf-repo`
# lets one be evaluated with no code edit at all -- which is the difference between "try the new
# model" being a five-minute job and a code change plus a review.
RUNNER_FAMILIES = {
    "whisper": "mlx_whisper_runner.py",
    "qwen3-asr": "mlx_qwen3_runner.py",
}


def run_mlx(audio: Path, engine: str, audio_s: float | None, repeats: int = 3,
            script: str | None = None, model: str | None = None) -> AsrResult:
    result = AsrResult(engine=engine, audio_s=audio_s)
    if script is None or model is None:
        spec = MLX_ENGINES.get(engine)
        if spec is None:
            result.error = f"unknown MLX engine {engine}"
            return result
        script, model = spec
    if shutil.which("uv") is None:
        result.error = "uv not on PATH (needed to run MLX engines)"
        return result

    cmd = [
        "uv", "run", "--script", str(RUNNERS / script),
        "--audio", str(audio), "--model", model,
        "--engine", engine, "--repeats", str(repeats),
    ]
    code, stdout, stderr = _run(cmd)
    # The runner prints exactly one JSON object on stdout; uv's own chatter goes to stderr. Take the
    # last non-empty line so any stray stdout output cannot break parsing.
    line = next((ln for ln in reversed(stdout.splitlines()) if ln.strip().startswith("{")), None)
    if line is None:
        result.error = f"exit {code}: no JSON on stdout. stderr: {stderr.strip()[-400:]}"
        return result
    try:
        payload = json.loads(line)
    except Exception as exc:  # noqa: BLE001
        result.error = f"unparseable JSON: {exc}"
        return result

    result.raw = payload
    result.error = payload.get("error")
    result.text = payload.get("text", "") or ""
    result.cold_s = payload.get("cold_s")
    result.warm_s = payload.get("warm_s")
    return result


ASR_ENGINES = ["app-pipeline", *FLUIDAUDIO_VERSIONS, *MLX_ENGINES]


# ---------------------------------------------------------------------------
# Engine specs
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class EngineSpec:
    """A resolved engine: what to run, and what to call the result.

    `name` is the label everything downstream keys on -- the per-engine ASR file, the results table,
    the baseline entry. It is derived deterministically from the spec string so that re-evaluating the
    same model twice lands on the same baseline row instead of creating a second one.
    """

    name: str
    kind: str                      # "app" | "fluidaudio" | "mlx"
    version: str | None = None     # FluidAudio model version
    script: str | None = None      # MLX runner filename
    model: str | None = None       # MLX model repo
    registered: bool = False       # present in the curated registry


def _label_from_repo(repo: str) -> str:
    """`mlx-community/whisper-large-v3` -> `whisper-large-v3`; `Qwen/Qwen3-ASR-3B` -> `qwen3-asr-3b`."""
    tail = repo.rstrip("/").rsplit("/", 1)[-1]
    return tail.lower()


def resolve_engine(spec: str) -> EngineSpec:
    """Resolve a registered engine name or an ad-hoc `family:model` spec.

    Accepted forms:

        parakeet-tdt-v3                          a curated registry name
        whisper:mlx-community/whisper-large-v3   any repo the MLX Whisper runner can load
        qwen3-asr:Qwen/Qwen3-ASR-3B              any repo the MLX Qwen3-ASR runner can load
        fluidaudio:v3                            any --model-version fluidaudiocli accepts
        my-label=whisper:mlx-community/...       the same, with an explicit result label

    Raises ValueError with the known names on an unrecognized spec, because a typo silently becoming
    a new engine label would produce a baseline row that never matches anything again.
    """
    spec = (spec or "").strip()
    if not spec:
        raise ValueError("empty engine spec")

    label = None
    if "=" in spec:
        label, _, spec = spec.partition("=")
        label = label.strip()
        spec = spec.strip()

    if spec == "app-pipeline":
        return EngineSpec(name=label or "app-pipeline", kind="app", registered=True)
    if spec in FLUIDAUDIO_VERSIONS:
        return EngineSpec(name=label or spec, kind="fluidaudio",
                          version=FLUIDAUDIO_VERSIONS[spec], registered=True)
    if spec in MLX_ENGINES:
        script, model = MLX_ENGINES[spec]
        return EngineSpec(name=label or spec, kind="mlx", script=script, model=model,
                          registered=True)

    family, sep, rest = spec.partition(":")
    if sep and rest:
        if family == "fluidaudio":
            return EngineSpec(name=label or f"fluidaudio-{rest}", kind="fluidaudio", version=rest)
        if family in RUNNER_FAMILIES:
            return EngineSpec(name=label or _label_from_repo(rest), kind="mlx",
                              script=RUNNER_FAMILIES[family], model=rest)
        raise ValueError(
            f"unknown runner family {family!r}. Known families: "
            f"{', '.join(sorted(RUNNER_FAMILIES))}, fluidaudio. "
            f"A model on a genuinely new runtime needs a runner in bench/runners/ -- see the README."
        )

    raise ValueError(
        f"unknown engine {spec!r}. Registered: {', '.join(ASR_ENGINES)}. "
        f"Or use family:model, e.g. whisper:mlx-community/whisper-large-v3, "
        f"qwen3-asr:Qwen/Qwen3-ASR-3B, fluidaudio:v3."
    )


def run_asr(engine, audio: Path, workspace: Path, audio_s: float | None, repeats: int = 3,
            multi_speaker: bool = False) -> AsrResult:
    """Run one engine. `engine` is a spec string or an already-resolved EngineSpec."""
    if isinstance(engine, EngineSpec):
        spec = engine
    else:
        try:
            spec = resolve_engine(engine)
        except ValueError as exc:
            return AsrResult(engine=str(engine), error=str(exc))

    if spec.kind == "app":
        result = run_app_pipeline(audio, workspace, audio_s, repeats, multi_speaker)
    elif spec.kind == "fluidaudio":
        result = run_fluidaudio(audio, workspace, spec.name, audio_s, repeats,
                               version=spec.version)
    elif spec.kind == "mlx":
        result = run_mlx(audio, spec.name, audio_s, repeats, script=spec.script, model=spec.model)
    else:
        return AsrResult(engine=spec.name, error=f"unknown engine kind {spec.kind}")

    # The label is authoritative: run_app_pipeline hardcodes its engine name and the MLX runners echo back
    # whatever --engine they were given, so an explicit label would otherwise be lost and the result
    # would overwrite the file of the engine it was meant to sit beside.
    result.engine = spec.name
    return result


# ---------------------------------------------------------------------------
# Cleanup stage, via the app's --bench-polish CLI
# ---------------------------------------------------------------------------

@dataclass
class CleanupResult:
    backend: str
    outputs: list[str] = field(default_factory=list)
    seconds: list[float] = field(default_factory=list)
    # Stored as a field, not left to the median_s property: asdict() drops properties, so a
    # consumer reading the serialized record would silently get no cleanup latency at all.
    median_seconds: float | None = None
    vocabulary_terms: int = 0
    error: str | None = None

    @property
    def median_s(self) -> float | None:
        return round(statistics.median(self.seconds), 3) if self.seconds else None


# label -> (--api, --model). "none" is handled by the driver, not dispatched here.
CLEANUP_BACKENDS = {
    "apple-on-device": ("apple", None),
    "gemma4-12b": ("ollama", "gemma4:12b-mlx"),
    "qwen3.5-4b": ("ollama", "qwen3.5:4b-mlx"),
    "qwen3.5-9b": ("ollama", "qwen3.5:9b-mlx"),
}


def run_cleanup(text: str, backend: str, workspace: Path, repeats: int = 3) -> CleanupResult:
    """RETIRED. The cleanup stage no longer exists in the app.

    `--bench-polish` and `PolishBenchmark` were deleted along with the LLM cleanup stage, which the
    bake-off measured as worth 0.0 WER points on the backend the app actually shipped
    (`bench/results/2026-07-30-results.json`) while costing ~4s of a ~5s wait.

    This fails loudly rather than being deleted outright, because the app no longer RECOGNISES
    `--bench-polish`: it falls through the BENCH dispatch and launches the GUI, so a `./run.py cleanup`
    invocation would hang on a windowed app instead of erroring. A dead subcommand that hangs is worse
    than one that explains itself. The historical results stay valid and are kept in
    `bench/results/2026-07-30-results.json`.
    """
    return CleanupResult(
        backend=backend,
        error=(
            "the cleanup stage was removed from the app; --bench-polish no longer exists. "
            "Historical numbers: bench/results/2026-07-30-results.json"
        ),
    )
