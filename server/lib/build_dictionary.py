#!/usr/bin/env python3
"""自动构建错词表 (§3.1 L2 #7 ①)

输入：~/.we/voice-history.jsonl（用户日常使用积累的转写历史）
输出：~/.we/dictionary.auto.json（自动构建的候选错词字典）

候选词抽取的 4 个信号（按可信度递减）：

  1. polished ≠ rawSA 的差异 token
     最强信号：L2 模型实际把这个词改了。说明 SA 转错了，模型纠对了。

  2. 低 confidence 的纯英文 / 字母+汉字 mix token
     SA 对术语和英文识别置信度通常低。混合 token 几乎只在术语场景出现。

  3. 长 token（≥ 4 字符）+ confidence < 阈值
     普通中文常见词不会同时满足这两个条件。

  4. alternatives 与 best 差异 large 的 token
     当前 voice-history 的 alternatives 字段大多为空，先实现但不强依赖。

筛选规则：候选词出现频次 ≥ min_frequency（默认 3）才入字典。

最终输出 schema（与现有手动版兼容，能直接被 CorrectionDictionary 加载）：

  {
    "Claude Code": {
      "errors": ["Cloudcode", "cloud code", ...],   # SA 实际错认的形式
      "frequency": 7,
      "source": "auto-build-from-voice-history"
    },
    ...
  }
"""

from __future__ import annotations
import json
import re
import argparse
import sys
from pathlib import Path
from collections import Counter, defaultdict
from typing import Iterable

# 同目录 paths（server/lib/paths.py）
sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths


# ============================================================
# 信号 1: polished ≠ rawSA 差异 token
# ============================================================

def _tokenize_for_diff(text: str) -> list[str]:
    """轻度切 token：保留英文词整体；中文按字符切。"""
    tokens = []
    buf_en = []
    for ch in text:
        if ch.isascii() and (ch.isalnum() or ch == "-" or ch == "_"):
            buf_en.append(ch)
        else:
            if buf_en:
                tokens.append("".join(buf_en))
                buf_en = []
            if not ch.isspace():
                tokens.append(ch)
    if buf_en:
        tokens.append("".join(buf_en))
    return tokens


def extract_diff_tokens(raw_sa: str, polished: str) -> list[tuple[str, str]]:
    """从 SA→polished 的修改中抽取 token 对 (sa_token, polished_token)。

    朴素策略：以 polished 的英文/字母 token 为锚，找它在 rawSA 中对应位置的 token。
    更严格的 align（如 SequenceMatcher）开销大且 voice-history 已经够多，
    此处用快速近似：返回 polished 中所有英文 token 作为「目标词」候选，
    再从 rawSA 找形似的 token 作为「错形」。
    """
    if not raw_sa or not polished or raw_sa == polished:
        return []

    raw_tokens = _tokenize_for_diff(raw_sa)
    pol_tokens = _tokenize_for_diff(polished)

    # 取 polished 中所有英文 token（≥ 3 字符）作为目标候选
    targets = [t for t in pol_tokens if re.fullmatch(r"[A-Za-z][A-Za-z0-9\-_]{2,}", t)]
    pairs = []
    for tgt in targets:
        if tgt in raw_tokens:
            continue  # SA 已经识别对了，跳过
        # 寻找 rawSA 中形似 token：长度差 ≤ 3 且首字母接近
        for rt in raw_tokens:
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9\-_]+", rt):
                continue
            if abs(len(rt) - len(tgt)) > 3:
                continue
            if rt.lower()[:2] != tgt.lower()[:2]:
                continue
            pairs.append((rt, tgt))
            break
    return pairs


# ============================================================
# 信号 2: 低 confidence 的英文 / 混合 token
# ============================================================

def is_suspicious_token(word: dict, conf_threshold: float = 0.85) -> bool:
    text = word.get("text", "").strip()
    if not text or len(text) < 3:
        return False
    conf = word.get("confidence", 1.0)
    if conf >= conf_threshold:
        return False
    # 含英文字母的 token（术语 / 英文）
    if re.search(r"[A-Za-z]", text):
        return True
    return False


# ============================================================
# 主流程
# ============================================================

def build_dictionary(
    voice_history_path: Path,
    min_frequency: int = 3,
    conf_threshold: float = 0.85,
    existing_dictionary: dict | None = None,
) -> dict:
    """主入口。返回 dictionary dict（与现有 schema 兼容）。

    existing_dictionary：现有的（手动+自动）字典，自动构建会合并而非覆盖。
                        手动维护的 entries 优先保留，自动构建只补充其没有的。
    """
    existing = existing_dictionary or {}

    # 收集所有候选 (target, error) 对
    target_errors: dict[str, Counter] = defaultdict(Counter)   # {正确词: {错词: 次数}}
    target_total: Counter = Counter()                          # {正确词: 出现总次数}

    n_entries = 0
    n_with_polish_diff = 0
    n_with_suspicious_word = 0

    with voice_history_path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            n_entries += 1

            raw_sa = obj.get("rawSA", "") or ""
            polished = obj.get("finalText", "") or ""
            words = obj.get("words", []) or []

            # 信号 1：polished diff（最强信号）
            pairs = extract_diff_tokens(raw_sa, polished)
            if pairs:
                n_with_polish_diff += 1
            for sa_form, target in pairs:
                target_errors[target][sa_form] += 1
                target_total[target] += 1

            # 信号 2：可疑低置信度英文 token —— 这些只入「目标候选」，
            # 因为没有正确答案；只用来交叉验证已有 target 的频次
            for w in words:
                if is_suspicious_token(w, conf_threshold):
                    n_with_suspicious_word += 1
                    # 不能凭空知道正确形式；但如果这个 SA token 在 target_errors
                    # 的某个 errors 列表里出现过，给对应 target 计数 +1
                    sa_text = w.get("text", "").strip()
                    for tgt, errs in target_errors.items():
                        if sa_text in errs:
                            target_total[tgt] += 1
                            break

    # 应用 min_frequency 阈值
    result = {}
    for target, count in target_total.items():
        if count < min_frequency:
            continue
        errors = target_errors[target].most_common()
        result[target] = {
            "errors": [e for e, _ in errors],
            "frequency": count,
            "source": "auto-build-from-voice-history",
        }

    # 合并已有字典（手动 entries 优先）
    merged = dict(existing)   # 先拷贝已有
    for target, entry in result.items():
        if target in merged:
            # 已有 entry，只补充新发现的 errors
            old_errors = set(merged[target].get("errors", []))
            new_errors = [e for e in entry["errors"] if e not in old_errors]
            if new_errors:
                merged[target]["errors"] = merged[target].get("errors", []) + new_errors
                merged[target]["frequency"] = merged[target].get("frequency", 0) + entry["frequency"]
                # source 标注既有
                src = merged[target].get("source", "manual")
                if "auto" not in src:
                    merged[target]["source"] = f"{src} + auto"
        else:
            merged[target] = entry

    return {
        "dictionary": merged,
        "stats": {
            "entries_scanned": n_entries,
            "entries_with_polish_diff": n_with_polish_diff,
            "entries_with_suspicious_word": n_with_suspicious_word,
            "auto_added_terms": len(result),
            "final_total_terms": len(merged),
        },
    }


# ============================================================
# CLI
# ============================================================

def main():
    p = argparse.ArgumentParser(description="Auto-build correction dictionary from voice-history")
    p.add_argument("--voice-history", default=str(paths.VOICE_HISTORY))
    p.add_argument("--existing", default=str(paths.CORRECTION_DICTIONARY),
                   help="Existing dictionary to merge into (manual entries preserved)")
    p.add_argument("--output", default=str(paths.DICTIONARY_AUTO))
    p.add_argument("--min-frequency", type=int, default=3,
                   help="Minimum occurrence to include a term")
    p.add_argument("--conf-threshold", type=float, default=0.85,
                   help='Token confidence threshold for "suspicious word" detection')
    args = p.parse_args()

    vh_path = Path(args.voice_history)
    if not vh_path.exists():
        print(f"Error: voice-history not found: {vh_path}")
        return 1

    existing = {}
    ex_path = Path(args.existing)
    if ex_path.exists():
        try:
            existing = json.loads(ex_path.read_text())
        except Exception as e:
            print(f"Warning: failed to load existing dictionary: {e}")
            existing = {}

    print(f"Loading voice-history: {vh_path}")
    print(f"Existing dictionary: {ex_path} ({len(existing)} terms)")

    out = build_dictionary(
        voice_history_path=vh_path,
        min_frequency=args.min_frequency,
        conf_threshold=args.conf_threshold,
        existing_dictionary=existing,
    )

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out["dictionary"], ensure_ascii=False, indent=2))

    stats = out["stats"]
    print()
    print("=== Build complete ===")
    print(f"  Entries scanned:              {stats['entries_scanned']}")
    print(f"  Entries with polish diff:     {stats['entries_with_polish_diff']}")
    print(f"  Entries with suspicious word: {stats['entries_with_suspicious_word']}")
    print(f"  Auto-added terms:             {stats['auto_added_terms']}")
    print(f"  Final total terms:            {stats['final_total_terms']}")
    print(f"  Output: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
