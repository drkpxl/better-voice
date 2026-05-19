#!/bin/bash
# 跑所有 KPI 里程碑测试 → 输出 milestones-status.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/milestones-status.json}"

declare -a SCRIPTS=(
    "m11_voice_e2e.sh"
    "m11_meeting.sh"
    "m11_remote.sh"
    "m7_dict_build.sh"
    "m7_finetune.sh"
    "m7_report.sh"
)

echo "[" > "$OUTPUT"
FIRST=true
for s in "${SCRIPTS[@]}"; do
    RESULT=$(bash "$SCRIPT_DIR/$s" 2>/dev/null || echo '{"status":"fail","note":"script crashed"}')
    if [ "$FIRST" = true ]; then FIRST=false; else echo "," >> "$OUTPUT"; fi
    echo "$RESULT" >> "$OUTPUT"
done
echo "]" >> "$OUTPUT"

# 控制台简报
python3 - "$OUTPUT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print()
print("=== KPI Milestones ===")
print(f"{'条款':<14} {'状态':<10} {'系数':<6} {'名称'}")
print("-" * 70)
total_score, total_max = 0, 0
for r in data:
    ref = r.get("pdf_ref", "?")
    status = r.get("status", "?")
    score = r.get("score", 0)
    name = r.get("name", "?")
    icon = {"pass": "✅ pass", "partial": "⚠️ part", "fail": "❌ fail", "todo": "⏳ todo"}.get(status, status)
    print(f"{ref:<14} {icon:<10} {score:<6} {name}")
    total_score += score
    total_max += 1
print("-" * 70)
print(f"完成度系数累计: {total_score:.1f} / {total_max}")
print(f"详细 JSON: {sys.argv[1]}")
PYEOF
