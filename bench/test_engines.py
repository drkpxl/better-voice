"""Tests for engine spec resolution.

Adding a newly released model should not require editing code, so `resolve_engine` accepts
`family:model` specs alongside the curated registry names. The property this file guards hardest is
label stability: the resolved name keys the per-engine ASR file, the results table and the baseline
row, so if the same spec resolved to two different labels the baseline would grow a duplicate row and
regression detection would silently never match again.

No subprocesses here -- resolution is pure. The engines themselves are exercised by running them.

Run: python3 bench/test_engines.py
"""

from __future__ import annotations

import sys

from engines import (
    ASR_ENGINES,
    FLUIDAUDIO_VERSIONS,
    MLX_ENGINES,
    RUNNER_FAMILIES,
    resolve_engine,
)

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def expect_error(label: str, spec: str) -> None:
    try:
        resolve_engine(spec)
    except ValueError:
        return
    except Exception as exc:  # noqa: BLE001
        FAILURES.append(f"{label}: raised {type(exc).__name__} instead of ValueError")
        return
    FAILURES.append(f"{label}: {spec!r} resolved instead of raising")


# ---------------------------------------------------------------------------
# Registered names keep working exactly as before
# ---------------------------------------------------------------------------

def test_every_registered_engine_resolves() -> None:
    for name in ASR_ENGINES:
        spec = resolve_engine(name)
        check(f"{name} keeps its label", spec.name, name)
        check(f"{name} marked registered", spec.registered, True)


def test_registered_dispatch_targets() -> None:
    check("app-pipeline", resolve_engine("app-pipeline").kind, "app")
    for name, version in FLUIDAUDIO_VERSIONS.items():
        spec = resolve_engine(name)
        check(f"{name} kind", spec.kind, "fluidaudio")
        check(f"{name} version", spec.version, version)
    for name, (script, model) in MLX_ENGINES.items():
        spec = resolve_engine(name)
        check(f"{name} kind", spec.kind, "mlx")
        check(f"{name} script", spec.script, script)
        check(f"{name} model", spec.model, model)


# ---------------------------------------------------------------------------
# Ad-hoc specs: a new model on an existing runtime needs no code edit
# ---------------------------------------------------------------------------

def test_whisper_family_spec() -> None:
    spec = resolve_engine("whisper:mlx-community/whisper-large-v3")
    check("label from the repo tail", spec.name, "whisper-large-v3")
    check("kind", spec.kind, "mlx")
    check("runner", spec.script, RUNNER_FAMILIES["whisper"])
    check("model passed through verbatim", spec.model, "mlx-community/whisper-large-v3")
    check("not registered", spec.registered, False)


def test_qwen_family_spec_lowercases_the_label() -> None:
    spec = resolve_engine("qwen3-asr:Qwen/Qwen3-ASR-3B")
    check("label lowercased", spec.name, "qwen3-asr-3b")
    check("model keeps its original casing", spec.model, "Qwen/Qwen3-ASR-3B")


def test_fluidaudio_version_spec() -> None:
    spec = resolve_engine("fluidaudio:v4")
    check("label", spec.name, "fluidaudio-v4")
    check("kind", spec.kind, "fluidaudio")
    check("version passed through", spec.version, "v4")


def test_explicit_label() -> None:
    spec = resolve_engine("my-candidate=whisper:mlx-community/whisper-tiny")
    check("explicit label wins", spec.name, "my-candidate")
    check("model still resolved", spec.model, "mlx-community/whisper-tiny")
    # An explicit label on a registered name is allowed: it is how the same model gets measured twice
    # under different settings without the second run overwriting the first.
    check("label on a registered name", resolve_engine("v3-again=parakeet-tdt-v3").name, "v3-again")


def test_label_is_stable_across_repeated_resolution() -> None:
    """The label keys the baseline row, so it must be deterministic."""
    for spec_str in ("whisper:mlx-community/whisper-large-v3", "qwen3-asr:Qwen/Qwen3-ASR-3B",
                     "fluidaudio:v3", "app-pipeline", "parakeet-tdt-v2"):
        first = resolve_engine(spec_str).name
        second = resolve_engine(spec_str).name
        check(f"{spec_str} resolves identically twice", first, second)


def test_adhoc_spec_of_a_registered_model_lands_on_the_same_label() -> None:
    """Spelling the same model either way must reach the same baseline row.

    `whisper-large-v3-turbo` and `whisper:mlx-community/whisper-large-v3-turbo` are the same weights,
    so if they resolved to different labels the baseline would grow two rows for one model and each
    would look like an unmeasured engine to the other. The label derives from the repo tail precisely
    so this converges.
    """
    for registered_name in ("whisper-large-v3-turbo", "qwen3-asr-1.7b", "qwen3-asr-0.6b"):
        registered = resolve_engine(registered_name)
        family = "whisper" if "whisper" in registered_name else "qwen3-asr"
        adhoc = resolve_engine(f"{family}:{registered.model}")
        check(f"{registered_name} converges", adhoc.name, registered.name)
        check(f"{registered_name} same model", adhoc.model, registered.model)

    # FluidAudio is the exception: a bare `--model-version` carries no model name, so `fluidaudio:v3`
    # cannot be known to be `parakeet-tdt-v3`. Use the registered name to land on the existing row.
    check("fluidaudio version specs get their own label",
          resolve_engine("fluidaudio:v3").name != resolve_engine("parakeet-tdt-v3").name, True)


def test_trailing_slash_and_bare_repo() -> None:
    check("trailing slash tolerated",
          resolve_engine("whisper:mlx-community/whisper-tiny/").name, "whisper-tiny")
    check("bare repo name with no org", resolve_engine("whisper:whisper-small").name, "whisper-small")


# ---------------------------------------------------------------------------
# Failure modes: a typo must not become a new engine label
# ---------------------------------------------------------------------------

def test_unknown_specs_raise() -> None:
    expect_error("bare typo", "parakeet-tdt-v9")
    expect_error("unknown family", "sensevoice:some/model")
    expect_error("empty", "")
    expect_error("whitespace only", "   ")
    expect_error("family with no model", "whisper:")


def test_error_message_lists_the_known_names() -> None:
    try:
        resolve_engine("nope")
    except ValueError as exc:
        message = str(exc)
        if "parakeet-tdt-v3" not in message:
            FAILURES.append(f"error should list registered engines: {message}")
        if "whisper:" not in message:
            FAILURES.append(f"error should show the family form: {message}")
    try:
        resolve_engine("badfamily:x/y")
    except ValueError as exc:
        if "runners/" not in str(exc):
            FAILURES.append(f"unknown-family error should point at the runner path: {exc}")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            FAILURES.append(f"{test.__name__}: assertion failed: {exc}")
        except Exception as exc:  # noqa: BLE001
            FAILURES.append(f"{test.__name__}: raised {type(exc).__name__}: {exc}")
    if FAILURES:
        print(f"FAIL — {len(FAILURES)} failure(s):\n")
        for f in FAILURES:
            print(f"  {f}\n")
        return 1
    print(f"PASS — {len(tests)} test functions, all checks green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
