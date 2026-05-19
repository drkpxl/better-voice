#!/usr/bin/env python3
"""从 voice-history.jsonl 抽样建 KPI 测试集（§3.2 L4 基线用）。

按 PDF §3.2 L4 字数要求分桶 + 抽样：

  short    < 30 字     抽样 100 条 → data/short/manifest.jsonl
  medium   30-100 字   抽样 100 条 → data/medium/manifest.jsonl
  long     ≥ 100 字    抽样 50 条  → data/long/manifest.jsonl

Ground truth 默认取 voice-history.finalText（L2 polish 后用户实际看到的文本）。
**首版未经人工审核**，所有 sample mark `audited: false`，跑出来的基线带 noise。

后续支持 `--manual-review` 模式：把候选 manifest 转 markdown 审核表，
用户在 markdown 里修正 ground_truth 或 drop 不合格 sample。

音频处理：在 data/<bucket>/audio/ 下创建软链指向真实 wav，避免拷贝大文件。
"""

from __future__ import annotations
import argparse
import json
import os
import random
import re
from pathlib import Path
from collections import Counter


# 字数分桶规则
BUCKETS = {
    "short":  (1,   29),    # < 30 字
    "medium": (30,  100),   # 30-100 字
    "long":   (101, 9999),  # ≥ 100 字（PDF 字面"≥ 100 字"）
}

TARGET_SIZES = {
    "short": 100,
    "medium": 100,
    "long": 50,
}


def char_count(text: str) -> int:
    """字符数（不含空白，中文按字符计）。"""
    return sum(1 for c in text if not c.isspace())


def looks_unusable(entry: dict) -> tuple[bool, str]:
    """简单过滤明显不能用的 sample。
    返回 (is_unusable, reason)。
    """
    final = (entry.get("finalText") or "").strip()
    raw = (entry.get("rawSA") or "").strip()
    audio = entry.get("audioPath") or ""

    if not final:
        return True, "empty finalText"
    if not audio or not Path(audio).exists():
        return True, "audio file missing"
    # 过滤纯语气词条目（< 3 字符 + 全是常见语气）
    if char_count(final) < 3:
        return True, "too short"
    if re.fullmatch(r"[嗯啊呢吧哦了的是\s\W]+", final):
        return True, "all filler/punct"
    # 过滤明显重复出错（"啊啊啊啊..."）
    if re.search(r"(.)\1{5,}", final):
        return True, "repetition pattern"
    return False, ""


def load_voice_history(path: Path) -> list[dict]:
    """加载 voice-history.jsonl，每行一个 entry。"""
    entries = []
    with path.open() as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            obj["_line_no"] = line_no
            entries.append(obj)
    return entries


def bucket_entries(entries: list[dict]) -> dict[str, list[dict]]:
    """把 entries 按字数分桶。同时丢弃 unusable。"""
    buckets: dict[str, list[dict]] = {k: [] for k in BUCKETS}
    reasons: Counter = Counter()

    for e in entries:
        unusable, reason = looks_unusable(e)
        if unusable:
            reasons[reason] += 1
            continue
        final = e.get("finalText", "")
        n = char_count(final)
        for name, (lo, hi) in BUCKETS.items():
            if lo <= n <= hi:
                buckets[name].append(e)
                break

    print(f"Bucket sizes (after filter):")
    for k, v in buckets.items():
        print(f"  {k}: {len(v)}")
    if reasons:
        print(f"Filtered out: {dict(reasons)}")

    return buckets


def write_bucket_manifest(
    bucket_name: str,
    entries: list[dict],
    out_dir: Path,
    target_size: int,
    seed: int = 42,
) -> int:
    """从 bucket 中随机抽样 target_size 条 → manifest.jsonl + 软链音频。
    返回实际写入数。
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    audio_dir = out_dir / "audio"
    audio_dir.mkdir(exist_ok=True)

    rng = random.Random(seed)
    if len(entries) > target_size:
        sampled = rng.sample(entries, target_size)
    else:
        sampled = entries[:]
        if len(sampled) < target_size:
            print(f"  WARN {bucket_name}: only {len(sampled)}/{target_size} available")

    manifest_path = out_dir / "manifest.jsonl"
    with manifest_path.open("w") as f:
        for idx, e in enumerate(sampled, 1):
            sample_id = f"{bucket_name[0]}{idx:03d}"   # s001, m001, l001
            audio_src = Path(e["audioPath"])
            audio_link = audio_dir / f"{sample_id}{audio_src.suffix}"
            # 软链
            if audio_link.exists() or audio_link.is_symlink():
                audio_link.unlink()
            audio_link.symlink_to(audio_src)

            entry = {
                "id": sample_id,
                "audio": f"audio/{audio_link.name}",
                "ground_truth": e["finalText"],
                "len": char_count(e["finalText"]),
                "category": bucket_name,
                "audited": False,                   # 首版未审核标记
                "source": {
                    "voice_history_line": e.get("_line_no"),
                    "timestamp": e.get("timestamp"),
                    "rawSA": e.get("rawSA"),        # 留作诊断对照
                },
            }
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    return len(sampled)


def main():
    p = argparse.ArgumentParser(description="Build KPI test manifests from voice-history.jsonl")
    p.add_argument("--voice-history", default=str(Path.home() / ".we" / "voice-history.jsonl"))
    p.add_argument("--out-dir", default=str(Path(__file__).resolve().parent),
                   help="kpi-test/data/ root")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--short", type=int, default=TARGET_SIZES["short"])
    p.add_argument("--medium", type=int, default=TARGET_SIZES["medium"])
    p.add_argument("--long", type=int, default=TARGET_SIZES["long"])
    args = p.parse_args()

    vh_path = Path(args.voice_history).expanduser()
    if not vh_path.exists():
        print(f"Error: {vh_path} not found")
        return 1

    out_root = Path(args.out_dir).expanduser()
    print(f"Loading voice-history: {vh_path}")
    entries = load_voice_history(vh_path)
    print(f"Loaded {len(entries)} entries")
    print()

    buckets = bucket_entries(entries)
    print()

    targets = {"short": args.short, "medium": args.medium, "long": args.long}
    print("Writing manifests:")
    total = 0
    for name in ("short", "medium", "long"):
        written = write_bucket_manifest(
            name, buckets[name], out_root / name, targets[name], args.seed
        )
        print(f"  {name}: {written} samples → {out_root / name / 'manifest.jsonl'}")
        total += written

    print(f"\nDone. Total: {total} samples across {len(buckets)} buckets.")
    print(f"All samples marked audited=false. Review/edit ground_truth in manifest.jsonl as needed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
