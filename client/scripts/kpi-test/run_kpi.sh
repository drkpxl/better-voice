#!/bin/bash
# WE — KPI 自动化测试顶层入口
#
# 用法：
#   ./run_kpi.sh                          # 跑所有里程碑 + 基线（用 latest 子目录）
#   ./run_kpi.sh --phase month1           # 落到 results/2026-05-month1-end/
#   ./run_kpi.sh --phase month2           # 落到 results/2026-07-month2-end/
#   ./run_kpi.sh --milestones-only        # 只跑里程碑
#   ./run_kpi.sh --baselines-only         # 只跑基线
#
# 输出位置（按 phase）：
#   results/<phase>/milestones-status.json
#   results/<phase>/baselines-results.json
#   results/<phase>/kpi-report.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"

PHASE="latest"
MILESTONES_ONLY=false
BASELINES_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase) PHASE="$2"; shift 2 ;;
        --milestones-only) MILESTONES_ONLY=true; shift ;;
        --baselines-only) BASELINES_ONLY=true; shift ;;
        -h|--help)
            head -15 "$0" | tail -14
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# 计算具体目录名
if [ "$PHASE" = "latest" ]; then
    OUT_DIR="$RESULTS_DIR/latest"
elif [ "$PHASE" = "month1" ]; then
    OUT_DIR="$RESULTS_DIR/$(date +%Y-%m)-month1-end"
elif [ "$PHASE" = "month2" ]; then
    OUT_DIR="$RESULTS_DIR/$(date +%Y-%m)-month2-end"
else
    OUT_DIR="$RESULTS_DIR/$PHASE"
fi

mkdir -p "$OUT_DIR"

echo "=== WE KPI Test Run ==="
echo "Phase:      $PHASE"
echo "Output dir: $OUT_DIR"
echo ""

if [ "$BASELINES_ONLY" = false ]; then
    echo ">>> Running milestones..."
    bash "$SCRIPT_DIR/milestones/run_all_milestones.sh" "$OUT_DIR/milestones-status.json"
fi

if [ "$MILESTONES_ONLY" = false ]; then
    echo ""
    echo ">>> Running baselines..."
    bash "$SCRIPT_DIR/baselines/run_all_baselines.sh" "$OUT_DIR/baselines-results.json"
fi

# 生成 markdown 报告
echo ""
echo ">>> Generating markdown report..."
PYTHONPATH="$SCRIPT_DIR/baselines/lib" python3 - "$OUT_DIR" "$PHASE" <<'PYEOF'
import json, sys
from pathlib import Path
from datetime import datetime

out_dir = Path(sys.argv[1])
phase = sys.argv[2]

milestones_path = out_dir / "milestones-status.json"
baselines_path = out_dir / "baselines-results.json"

milestones = json.loads(milestones_path.read_text()) if milestones_path.exists() else []
baselines = json.loads(baselines_path.read_text()) if baselines_path.exists() else []

lines = [
    f"# WE — KPI 测试报告",
    "",
    f"- 阶段：**{phase}**",
    f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
    f"- 方法学：见 `client/scripts/kpi-test/README.md` §0（用户视角 + 全链路）",
    "",
    "---",
    "",
    "## 里程碑（§3.1）",
    "",
    "| 条款 | 名称 | 状态 | 完成度系数 |",
    "|---|---|---|---|",
]
for m in milestones:
    status = m.get("status", "?")
    icon = {"pass": "✅", "partial": "⚠️", "fail": "❌", "todo": "⏳"}.get(status, "❓")
    lines.append(f"| {m.get('pdf_ref','?')} | {m.get('name','?')} | {icon} {status} | {m.get('score',0)} |")

lines += ["", "## 基线（§3.2）", "",
    "| 条款 | 名称 | 状态 | 样本数 | 本期值 |",
    "|---|---|---|---|---|"]
for b in baselines:
    status = b.get("status", "?")
    icon = {"ok": "✅", "todo": "⏳", "fail": "❌"}.get(status, "❓")
    val = b.get("value")
    val_str = f"{val*100:.2f}%" if isinstance(val, (int, float)) else "—"
    lines.append(f"| {b.get('pdf_ref','?')} | {b.get('name','?')} | {icon} {status} | {b.get('sample_count',0)} | {val_str} |")

lines += [
    "", "---", "",
    "**说明**：",
    "- 里程碑完成度系数：完成 1.0 / 部分完成（≥70%）0.7 / 未达 0（§2.1）",
    "- 基线 todo = 测试集未就绪；后续填实即可输出真实数字",
    "- 改善幅度档位（§2.2）需要两个数据点（月 1 末 + 月 2 末），见 README §4",
]
(out_dir / "kpi-report.md").write_text("\n".join(lines))
print(f"  Written: {out_dir / 'kpi-report.md'}")
PYEOF

echo ""
echo "=== Done ==="
echo "Report: $OUT_DIR/kpi-report.md"
