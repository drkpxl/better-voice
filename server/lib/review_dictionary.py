#!/usr/bin/env python3
"""字典人工审核工具（双向：dictionary.json ↔ review.md）

用法：

  # 1) 生成 markdown 审核表（json → md）
  python3 review_dictionary.py export \\
      --input  ~/.we/dictionary.auto.json \\
      --output ~/.we/dictionary-review.md

  # 2) 你在 dictionary-review.md 里改 [decision] / rename / errors，保存

  # 3) 应用审核结果（md → json）
  python3 review_dictionary.py apply \\
      --review ~/.we/dictionary-review.md \\
      --output ~/.we/correction-dictionary.json    # 覆盖正式字典

Markdown 格式（每条 term 一段，5 个固定字段）：

  ## term: Claude
  freq: 61
  errors: cloud, clob, 克劳德, cloudcode
  source: voice-history + auto
  [decision]: keep

  审核操作：
    [decision]: keep        保留（默认）
    [decision]: drop        删除此 term
    [decision]: edit        要改 rename / errors / 两者（看下方两行）
    rename: <新 term 名>     可选；用于改大小写或拼写
    errors-keep: a, b, c     可选；仅保留这几个 errors 形式
"""

from __future__ import annotations
import argparse
import json
import re
import sys
from pathlib import Path


# ============================================================
# export: json → md
# ============================================================

def export_to_md(dictionary: dict, out_path: Path) -> None:
    """把 dictionary.json 转成审核 markdown。

    排序策略：
      1. source 含 "auto" 的（即新发现的）优先（更需要审核）
      2. 同 source 内按 frequency 降序
    """
    def sort_key(item):
        term, entry = item
        source = entry.get("source", "")
        # auto-only 优先级最高（最需审核），混合次之，纯 manual 最后
        if "auto" in source and "manual" not in source and "实测" not in source:
            priority = 0
        elif "auto" in source:
            priority = 1
        else:
            priority = 2
        freq = entry.get("frequency", 0)
        return (priority, -freq, term)

    items = sorted(dictionary.items(), key=sort_key)

    lines = [
        "# WE 错词表人工审核",
        "",
        f"自动构建总计 **{len(dictionary)}** 条 term。下方按「新发现优先 → 频次降序」排序。",
        "",
        "## 审核操作说明",
        "",
        "每条 term 后的 `[decision]` 字段：",
        "",
        "- `keep`：保留（默认）",
        "- `drop`：删掉此 term（不进字典）",
        "- `edit`：要改 term 名 / errors 列表，**再加可选行**：",
        "  - `rename: <新名>`",
        "  - `errors-keep: a, b, c`（仅保留这几个错形）",
        "",
        "保存后执行：",
        "",
        "```bash",
        "python3 server/scripts/review_dictionary.py apply \\",
        "    --review ~/.we/dictionary-review.md \\",
        "    --output ~/.we/correction-dictionary.json",
        "```",
        "",
        "---",
        "",
    ]

    # 分两段：新发现的 / 既有的
    new_terms = [(t, e) for t, e in items if "auto" in e.get("source", "") and "manual" not in e.get("source", "") and "实测" not in e.get("source", "")]
    mixed_terms = [(t, e) for t, e in items if "auto" in e.get("source", "") and t not in [t2 for t2, _ in new_terms]]
    old_terms = [(t, e) for t, e in items if "auto" not in e.get("source", "")]

    def render_section(title: str, entries: list) -> list:
        out = [f"## {title}（{len(entries)} 条）", ""]
        for term, entry in entries:
            errs = entry.get("errors", [])
            out += [
                f"### term: {term}",
                f"freq: {entry.get('frequency', 0)}",
                f"errors: {', '.join(errs) if errs else '(无)'}",
                f"source: {entry.get('source', '?')}",
                "[decision]: keep",
                "",
            ]
        return out

    if new_terms:
        lines += render_section("一、新发现的 term（最需审核）", new_terms)
    if mixed_terms:
        lines += render_section("二、auto 补充的既有 term", mixed_terms)
    if old_terms:
        lines += render_section("三、纯手动 term（一般不动）", old_terms)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines))
    print(f"Exported {len(dictionary)} terms to {out_path}")
    print(f"  - new (auto-only):     {len(new_terms)}")
    print(f"  - mixed (manual+auto): {len(mixed_terms)}")
    print(f"  - manual only:         {len(old_terms)}")


# ============================================================
# apply: md → json
# ============================================================

_TERM_HEADER = re.compile(r"^###\s+term:\s+(.+?)\s*$", re.M)


def parse_review_md(md_text: str) -> tuple[dict, dict]:
    """解析审核 markdown，返回 (kept_dict, stats)。

    解析每个 `### term: <name>` 块，读 freq / errors / source / [decision] / rename / errors-keep。
    """
    blocks = []
    cur_term = None
    cur_buf: list[str] = []
    for line in md_text.splitlines():
        m = _TERM_HEADER.match(line)
        if m:
            if cur_term:
                blocks.append((cur_term, cur_buf))
            cur_term = m.group(1).strip()
            cur_buf = []
        else:
            if cur_term:
                cur_buf.append(line)
    if cur_term:
        blocks.append((cur_term, cur_buf))

    kept: dict = {}
    stats = {"total": len(blocks), "kept": 0, "dropped": 0, "edited": 0, "renamed": 0}

    for term, buf in blocks:
        fields = {"freq": 0, "errors": [], "source": "manual", "decision": "keep",
                  "rename": None, "errors_keep": None}
        for line in buf:
            line = line.strip()
            if not line:
                continue
            if line.startswith("freq:"):
                try:
                    fields["freq"] = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
            elif line.startswith("errors:"):
                val = line.split(":", 1)[1].strip()
                if val and val != "(无)":
                    fields["errors"] = [e.strip() for e in val.split(",") if e.strip()]
            elif line.startswith("source:"):
                fields["source"] = line.split(":", 1)[1].strip()
            elif line.startswith("[decision]:"):
                fields["decision"] = line.split(":", 1)[1].strip().lower()
            elif line.startswith("rename:"):
                v = line.split(":", 1)[1].strip()
                if v:
                    fields["rename"] = v
            elif line.startswith("errors-keep:"):
                val = line.split(":", 1)[1].strip()
                fields["errors_keep"] = [e.strip() for e in val.split(",") if e.strip()]

        decision = fields["decision"]
        if decision == "drop":
            stats["dropped"] += 1
            continue
        if decision == "edit":
            stats["edited"] += 1
        else:
            stats["kept"] += 1

        # 应用 rename / errors-keep
        final_term = fields["rename"] or term
        if fields["rename"]:
            stats["renamed"] += 1
        final_errors = fields["errors_keep"] if fields["errors_keep"] is not None else fields["errors"]

        kept[final_term] = {
            "errors": final_errors,
            "frequency": fields["freq"],
            "source": fields["source"] + " + reviewed",
        }

    return kept, stats


def apply_review(review_path: Path, out_path: Path) -> None:
    md_text = review_path.read_text()
    kept, stats = parse_review_md(md_text)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(kept, ensure_ascii=False, indent=2))

    print(f"Applied {review_path} → {out_path}")
    print(f"  Total scanned:   {stats['total']}")
    print(f"  Kept:            {stats['kept']}")
    print(f"  Dropped:         {stats['dropped']}")
    print(f"  Edited:          {stats['edited']}  (renamed: {stats['renamed']})")
    print(f"  Final terms:     {len(kept)}")


# ============================================================
# CLI
# ============================================================

def main():
    p = argparse.ArgumentParser(description="Dictionary human review tool (json ↔ md)")
    sub = p.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser("export", help="json → review markdown")
    pe.add_argument("--input", required=True, help="dictionary.json (e.g. dictionary.auto.json)")
    pe.add_argument("--output", required=True, help="review markdown to write")

    pa = sub.add_parser("apply", help="review markdown → corrected dictionary.json")
    pa.add_argument("--review", required=True, help="reviewed markdown file")
    pa.add_argument("--output", required=True, help="output dictionary.json")

    args = p.parse_args()

    if args.cmd == "export":
        in_path = Path(args.input).expanduser()
        out_path = Path(args.output).expanduser()
        if not in_path.exists():
            print(f"Error: {in_path} not found")
            return 1
        d = json.loads(in_path.read_text())
        export_to_md(d, out_path)
    elif args.cmd == "apply":
        review_path = Path(args.review).expanduser()
        out_path = Path(args.output).expanduser()
        if not review_path.exists():
            print(f"Error: {review_path} not found")
            return 1
        apply_review(review_path, out_path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
