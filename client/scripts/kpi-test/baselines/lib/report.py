"""KPI 报告输出。

三种格式：
  - per_sample.jsonl   每条样本的逐条结果（可追溯）
  - summary.json       本次测试的 5 项基线汇总
  - kpi-report.md      人类可读月度报告（带 PDF 章节号引用）

档位计算遵循 §2.2 一期"看趋势"：
  A 档 ≥ 20% 改善 → 100
  B 档 5%-20% → 70
  C 档 < 5% → 40
  D 档 未记录或退步 → 0
"""

from __future__ import annotations
import json
from pathlib import Path
from datetime import datetime
from dataclasses import dataclass, asdict
from typing import Optional


@dataclass
class BaselineResult:
    """单项基线的本期结果。"""
    name: str                       # "short_command_accuracy" etc.
    pdf_ref: str                    # "§3.2 L4 ①"
    pdf_formula: str                # PDF 原文计算方式
    value: float                    # 本期实测值（0-1 区间，报告时 ×100% 显示）
    unit: str                       # "%" | "ratio" | etc.
    sample_count: int               # 测试样本数
    extra: dict | None = None       # 附加诊断（如长句的 WER 门槛判定）


def write_per_sample(path: Path, rows: list[dict]) -> None:
    """逐条结果落盘，每行一个 sample。

    rows[i] 至少含：id, audio, ground_truth, hypothesis, 该项指标值, mode
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_summary(path: Path, results: list[BaselineResult], phase: str) -> None:
    """汇总写 summary.json。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "phase": phase,
        "timestamp": datetime.now().isoformat(),
        "baselines": [asdict(r) for r in results],
    }
    with path.open("w") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def compute_improvement(initial: float, final: float, higher_is_better: bool) -> dict:
    """计算改善幅度 + 档位（§2.2）。

    higher_is_better:
        True  → 准确率 / 保留率 类（值越大越好）
        False → WER 类（值越小越好）
    """
    if initial == 0:
        return {"delta_pct": None, "tier": "N/A", "tier_score": 0}

    if higher_is_better:
        delta_pct = (final - initial) / initial * 100
    else:
        delta_pct = (initial - final) / initial * 100   # WER 下降 = 改善 = 正值

    # §2.2 档位
    if delta_pct >= 20:
        tier, tier_score = "A", 100
    elif delta_pct >= 5:
        tier, tier_score = "B", 70
    elif delta_pct >= 0:
        tier, tier_score = "C", 40
    else:
        tier, tier_score = "D", 0

    return {"delta_pct": round(delta_pct, 2), "tier": tier, "tier_score": tier_score}


def write_md_report(
    path: Path,
    phase: str,
    results: list[BaselineResult],
    previous: Optional[list[BaselineResult]] = None,
    milestones: Optional[list[dict]] = None,
) -> None:
    """生成 KPI 月度报告 markdown。

    milestones: 里程碑 binary 测试结果列表，每个含 {pdf_ref, name, status, score, evidence}
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# BetterVoice — KPI 测试报告",
        f"",
        f"- 阶段：**{phase}**",
        f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 方法学：见 `client/scripts/kpi-test/README.md` §0",
        f"",
        f"---",
        f"",
    ]

    # 里程碑
    if milestones:
        lines.append("## 里程碑（§3.1）")
        lines.append("")
        lines.append("| 条款 | 完成标准 | 状态 | 完成度系数 |")
        lines.append("|---|---|---|---|")
        for m in milestones:
            status_icon = {"pass": "✅", "partial": "⚠️", "fail": "❌"}.get(m.get("status", "fail"), "❓")
            lines.append(
                f"| {m.get('pdf_ref', '?')} | {m.get('name', '?')} | "
                f"{status_icon} {m.get('status', '?')} | {m.get('score', 0)} |"
            )
        lines.append("")

    # 基线
    lines.append("## 基线（§3.2）")
    lines.append("")
    if previous:
        # 含改善比较
        lines.append("| 条款 | 指标 | 上期 | 本期 | 改善 | 档位（§2.2）|")
        lines.append("|---|---|---|---|---|---|")
        prev_map = {p.name: p for p in previous}
        for r in results:
            p = prev_map.get(r.name)
            higher = "accuracy" in r.name or "retention" in r.name or "recall" in r.name
            if p:
                imp = compute_improvement(p.value, r.value, higher)
                delta_str = f"{imp['delta_pct']:+.2f}%" if imp['delta_pct'] is not None else "N/A"
                lines.append(
                    f"| {r.pdf_ref} | {r.name} | "
                    f"{p.value*100:.2f}{r.unit} | "
                    f"{r.value*100:.2f}{r.unit} | "
                    f"{delta_str} | "
                    f"{imp['tier']} ({imp['tier_score']}) |"
                )
            else:
                lines.append(
                    f"| {r.pdf_ref} | {r.name} | — | "
                    f"{r.value*100:.2f}{r.unit} | — | — |"
                )
    else:
        lines.append("| 条款 | 指标 | 样本数 | 本期值 | 计算方式（PDF 原文）|")
        lines.append("|---|---|---|---|---|")
        for r in results:
            lines.append(
                f"| {r.pdf_ref} | {r.name} | {r.sample_count} | "
                f"{r.value*100:.2f}{r.unit} | {r.pdf_formula} |"
            )
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("**说明**：基线值为 [0, 1] 浮点，报告显示 ×100%。改善方向由指标类型决定")
    lines.append("（准确率/保留率/事实保留越高越好；WER 越低越好）。")

    path.write_text("\n".join(lines))


if __name__ == "__main__":
    # 自测
    sample = BaselineResult(
        name="short_command_accuracy",
        pdf_ref="§3.2 L4 ①",
        pdf_formula="100 条短指令测试集，完全识别正确条数 / 100",
        value=0.85,
        unit="%",
        sample_count=100,
    )
    print(asdict(sample))
    imp = compute_improvement(0.80, 0.90, higher_is_better=True)
    print(imp)
    assert imp["tier"] == "B"   # +12.5% → B 档
