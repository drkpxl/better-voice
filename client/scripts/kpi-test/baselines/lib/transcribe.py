"""单条音频转写接口。

按"用户视角 + 全链路"原则，**默认模式 = finalText**（走完整 VoicePipeline 含 L2 polish）。
辅助模式：rawSA 可作为诊断对照（不计入 KPI 主指标）。

实现策略：
  - finalText: 调 BetterVoice `--bench-meeting` 单条入口（已含 SA + 全链路），从结果 JSON 取 hypothesis
                或调一个专门的 `BetterVoice --bench-voice <wav>` 入口（目前不存在，会在 milestones 阶段加）
  - rawSA:     直接调用 Apple Speech 框架（Python 端通过命令行包装层）

当前为 stub，等 milestones/m11_voice_e2e.sh 落地后填实。
"""

from __future__ import annotations
import json
import subprocess
import tempfile
import os
from pathlib import Path
from dataclasses import dataclass
from typing import Optional


@dataclass
class TranscribeResult:
    text: str                       # 最终文本（用于 KPI 计算）
    mode: str                       # "finalText" | "rawSA" | "we_polish"
    elapsed_ms: int                 # 总耗时
    raw_response: Optional[dict] = None    # 完整 JSON（便于追溯）


def _find_we_binary() -> Path:
    """定位编译好的 BetterVoice 可执行文件。"""
    here = Path(__file__).resolve().parent
    # 从 client/scripts/kpi-test/baselines/lib/ 回到 client/
    client_dir = here.parents[3]
    candidates = [
        client_dir / ".build" / "BetterVoice.app" / "Contents" / "MacOS" / "BetterVoice",
        client_dir / ".build" / "release" / "BetterVoice",
        client_dir / ".build" / "debug" / "BetterVoice",
    ]
    for c in candidates:
        if c.exists():
            return c
    raise FileNotFoundError(
        f"BetterVoice binary not found. Run `cd client && make build` first. "
        f"Searched: {[str(c) for c in candidates]}"
    )


def transcribe_final(audio_path: str | Path, locale: str = "zh-CN") -> TranscribeResult:
    """走完整 VoicePipeline：SA → L1 → L2 polish → 注入前的 finalText。

    实现路径（待 milestones 阶段提供专门 CLI 入口后接入）：
        BetterVoice --bench-voice <wav> [--locale zh-CN] --output <result.json>

    返回 result.json 中的 finalText 字段。
    """
    raise NotImplementedError(
        "transcribe_final() awaits `BetterVoice --bench-voice` CLI entry. "
        "Will be filled in Stage 2 (milestones)."
    )


def transcribe_meeting(audio_path: str | Path, locale: str = "zh-CN") -> TranscribeResult:
    """走完整 MeetingSession：SA → SegmentBuffer → polishBatch → diarize → markdown.

    实现：调用现有 `BetterVoice --bench-meeting <wav> --output result.json`，
    从结果中拼接所有 segments 的 finalText 作为完整 hypothesis。
    """
    we = _find_we_binary()
    audio_path = Path(audio_path).resolve()

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        out_path = f.name

    try:
        proc = subprocess.run(
            [str(we), "--bench-meeting", str(audio_path),
             "--locale", locale, "--output", out_path],
            capture_output=True, text=True, timeout=600
        )
        if proc.returncode != 0:
            raise RuntimeError(f"BetterVoice --bench-meeting failed:\n{proc.stderr}")

        with open(out_path) as f:
            data = json.load(f)

        # MeetingBenchmark 输出含 hypothesis（所有 segments text 拼接）
        text = data.get("hypothesis", "")
        elapsed_ms = int(data.get("total_processing_s", 0) * 1000)
        return TranscribeResult(text=text, mode="finalText", elapsed_ms=elapsed_ms, raw_response=data)
    finally:
        if os.path.exists(out_path):
            os.unlink(out_path)


def transcribe_raw_sa(audio_path: str | Path, locale: str = "zh-CN") -> TranscribeResult:
    """诊断模式：只跑 SA，不走 L2。

    用途：定位"finalText 错"的根因——是 SA 没听对，还是 L2 改坏了。
    **不计入 KPI 主指标**，仅作为分析辅助。

    实现路径：待 `BetterVoice --bench-voice --no-polish` 接入后填实。
    """
    raise NotImplementedError(
        "transcribe_raw_sa() awaits `BetterVoice --bench-voice --no-polish`. "
        "Will be filled in Stage 2."
    )


if __name__ == "__main__":
    # 自测：拿一个真实音频跑会议模式
    import sys
    if len(sys.argv) != 2:
        print("Usage: transcribe.py <audio.wav>")
        sys.exit(1)
    result = transcribe_meeting(sys.argv[1])
    print(f"mode={result.mode} elapsed={result.elapsed_ms}ms")
    print(f"text: {result.text[:200]}")
