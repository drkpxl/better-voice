#!/usr/bin/env python3
"""通用 baseline runner — 把 5 项 baseline 脚本统一到一个实现。

流程：
  1. 加载 manifest.jsonl
  2. 调 BetterVoice --bench-voice --batch（或 --bench-meeting）跑全链路转写
  3. 对每条 sample 算指定 metric
  4. 输出 per-sample jsonl + 汇总 JSON

用法：
  python3 run_baseline.py \\
      --bucket short \\
      --metric command_accuracy \\
      --output-dir ../results/latest
"""

from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# 让 lib/ 内同目录模块可 import
sys.path.insert(0, str(Path(__file__).resolve().parent))
from manifest import load_manifest, TestSample              # noqa: E402
from metrics import (                                       # noqa: E402
    is_completely_correct,
    cer,
    wer,
    retention_rate,
    fact_recall,
)


# ============================================================
# 5 项基线的描述 → 给 KPI 报告引用
# ============================================================

BASELINE_SPECS = {
    "short_command_accuracy": {
        "pdf_ref": "§3.2 L4 ①",
        "pdf_formula": "100 条短指令测试集，完全识别正确条数 / 100",
        "bucket": "short",
        "tool": "bench-voice",
        "higher_is_better": True,
    },
    "medium_wer": {
        "pdf_ref": "§3.2 L4 ②",
        "pdf_formula": "100 条中等长度测试集，整体 WER（词错率）",
        "bucket": "medium",
        "tool": "bench-voice",
        "higher_is_better": False,
    },
    "long_retention": {
        "pdf_ref": "§3.2 L4 ③",
        "pdf_formula": "50 条长段测试集，转写字数 / 原文字数（多次平均），且 WER < 15%",
        "bucket": "long",
        "tool": "bench-voice",
        "higher_is_better": True,
    },
    "meeting_facts": {
        "pdf_ref": "§3.2 L4 ④",
        "pdf_formula": "会议测试集预标注 20 个关键事实，识别到的 / 20",
        "bucket": "meeting",
        "tool": "bench-meeting",
        "higher_is_better": True,
    },
    "meeting_wer": {
        "pdf_ref": "§3.2 L4 ⑤",
        "pdf_formula": "标准 WER 测量",
        "bucket": "meeting",
        "tool": "bench-meeting",
        "higher_is_better": False,
    },
}


def _find_we_binary() -> Path:
    """定位 BetterVoice 可执行文件。"""
    here = Path(__file__).resolve()
    # client/scripts/kpi-test/baselines/lib/run_baseline.py → client/.build/...
    client_dir = here.parents[4]
    for c in (
        client_dir / ".build" / "BetterVoice.app" / "Contents" / "MacOS" / "BetterVoice",
        client_dir / ".build" / "release" / "BetterVoice",
        client_dir / ".build" / "debug" / "BetterVoice",
    ):
        if c.exists():
            return c
    raise FileNotFoundError("BetterVoice binary not found. Run `cd client && make build` first.")


def _data_root() -> Path:
    here = Path(__file__).resolve()
    return here.parents[2] / "data"


def run_batch(
    manifest_path: Path,
    tool: str,
    we_bin: Path,
) -> Path:
    """跑 BetterVoice --bench-voice --batch（或 --bench-meeting），返回结果目录。

    每个 sample 输出一个 <id>.json，含 finalText 等。
    """
    out_dir = Path(tempfile.mkdtemp(prefix="kpi_batch_"))
    cmd = [
        str(we_bin),
        f"--{tool}",
        "--batch", str(manifest_path),
        "--output-dir", str(out_dir),
    ]
    print(f"  Running: {' '.join(cmd)}", file=sys.stderr)
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    if proc.returncode != 0:
        print(f"  BetterVoice batch returncode={proc.returncode}", file=sys.stderr)
        print(f"  stderr: {proc.stderr[-500:]}", file=sys.stderr)
    return out_dir


def load_hypothesis(result_dir: Path, sample_id: str) -> str | None:
    """从批处理输出读 finalText。"""
    p = result_dir / f"{sample_id}.json"
    if not p.exists():
        return None
    try:
        d = json.loads(p.read_text())
    except Exception:
        return None
    # bench-voice 输出 finalText；bench-meeting 输出 hypothesis
    return d.get("finalText") or d.get("hypothesis")


# ============================================================
# 每项 baseline 的具体计算
# ============================================================

def compute_short(samples: list[TestSample], result_dir: Path) -> tuple[float, list[dict]]:
    """短句完全识别准确率。"""
    rows = []
    correct = 0
    for s in samples:
        hyp = load_hypothesis(result_dir, s.id) or ""
        ok = is_completely_correct(s.ground_truth, hyp)
        if ok:
            correct += 1
        rows.append({
            "id": s.id,
            "audio": str(s.audio_path),
            "ground_truth": s.ground_truth,
            "hypothesis": hyp,
            "correct": ok,
            "cer": round(cer(s.ground_truth, hyp), 4),
        })
    value = correct / len(samples) if samples else 0.0
    return value, rows


def compute_medium_wer(samples: list[TestSample], result_dir: Path) -> tuple[float, list[dict]]:
    """整体 WER：所有 sample 的 hyp 与 gt 累计算（按 PDF 字面"整体 WER"理解为汇总）。
    实际实现：对每条算 WER 后取均值（中文场景行业惯例）。同时报告平均 CER。
    """
    rows = []
    wer_sum = 0.0
    cer_sum = 0.0
    for s in samples:
        hyp = load_hypothesis(result_dir, s.id) or ""
        w = wer(s.ground_truth, hyp)
        c = cer(s.ground_truth, hyp)
        wer_sum += w
        cer_sum += c
        rows.append({
            "id": s.id,
            "audio": str(s.audio_path),
            "ground_truth": s.ground_truth,
            "hypothesis": hyp,
            "wer": round(w, 4),
            "cer": round(c, 4),
        })
    avg_wer = wer_sum / len(samples) if samples else 0.0
    return avg_wer, rows


def compute_long_retention(samples: list[TestSample], result_dir: Path) -> tuple[float, list[dict]]:
    """长句保留率 + WER < 15% 门槛。

    PDF 原文：转写字数 / 原文字数（多次平均），且 WER < 15%
    返回值：平均保留率。同时在 rows 里标记每条是否通过 WER 门槛。
    """
    rows = []
    ret_sum = 0.0
    pass_wer = 0
    for s in samples:
        hyp = load_hypothesis(result_dir, s.id) or ""
        r = retention_rate(s.ground_truth, hyp)
        w = wer(s.ground_truth, hyp)
        ret_sum += r
        wer_ok = w < 0.15
        if wer_ok:
            pass_wer += 1
        rows.append({
            "id": s.id,
            "audio": str(s.audio_path),
            "ground_truth_len": s.length,
            "hypothesis_len": len([c for c in hyp if not c.isspace()]),
            "retention_rate": round(r, 4),
            "wer": round(w, 4),
            "passes_wer_threshold": wer_ok,
        })
    avg_ret = ret_sum / len(samples) if samples else 0.0
    return avg_ret, rows


COMPUTE_FNS = {
    "short_command_accuracy": compute_short,
    "medium_wer": compute_medium_wer,
    "long_retention": compute_long_retention,
}


# ============================================================
# Main
# ============================================================

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--metric", required=True, choices=list(BASELINE_SPECS.keys()))
    p.add_argument("--output-dir", required=True, help="results/<phase>/ 目录")
    p.add_argument("--manifest", help="override manifest path")
    p.add_argument("--skip-transcribe", action="store_true",
                   help="如已有 results 子目录，跳过转写直接算指标")
    p.add_argument("--reuse-dir", help="用已有的转写结果目录（配合 --skip-transcribe）")
    args = p.parse_args()

    spec = BASELINE_SPECS[args.metric]
    bucket = spec["bucket"]
    tool = spec["tool"]

    # 1. manifest
    if args.manifest:
        manifest_path = Path(args.manifest)
    else:
        manifest_path = _data_root() / bucket / "manifest.jsonl"

    if not manifest_path.exists():
        out = {
            "pdf_ref": spec["pdf_ref"],
            "name": args.metric,
            "status": "todo",
            "value": None,
            "sample_count": 0,
            "note": f"manifest missing: {manifest_path}",
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    samples = load_manifest(manifest_path)
    if not samples:
        out = {
            "pdf_ref": spec["pdf_ref"],
            "name": args.metric,
            "status": "todo",
            "value": None,
            "sample_count": 0,
            "note": "empty manifest",
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    # 2. 转写（或复用）
    if args.skip_transcribe and args.reuse_dir:
        result_dir = Path(args.reuse_dir)
    else:
        try:
            we_bin = _find_we_binary()
        except FileNotFoundError as e:
            out = {"pdf_ref": spec["pdf_ref"], "name": args.metric, "status": "fail",
                   "value": None, "note": str(e)}
            print(json.dumps(out, ensure_ascii=False, indent=2))
            return 1
        print(f"  Transcribing {len(samples)} samples via {tool}...", file=sys.stderr)
        result_dir = run_batch(manifest_path, tool, we_bin)

    # 3. compute
    if args.metric not in COMPUTE_FNS:
        out = {"pdf_ref": spec["pdf_ref"], "name": args.metric, "status": "todo",
               "value": None, "note": "compute fn not implemented yet"}
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    value, rows = COMPUTE_FNS[args.metric](samples, result_dir)

    # 4. 落盘
    out_dir = Path(args.output_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    per_sample_path = out_dir / f"{args.metric}.jsonl"
    with per_sample_path.open("w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    # 5. 输出 KPI summary（baselines 脚本捕捉它作为 JSON）
    summary = {
        "pdf_ref": spec["pdf_ref"],
        "name": args.metric,
        "status": "ok",
        "value": round(value, 4),
        "sample_count": len(samples),
        "higher_is_better": spec["higher_is_better"],
        "pdf_formula": spec["pdf_formula"],
        "per_sample_jsonl": str(per_sample_path),
        "transcribe_dir": str(result_dir),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
