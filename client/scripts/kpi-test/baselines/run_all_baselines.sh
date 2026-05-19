#!/bin/bash
# 跑所有 KPI 基线测试 → 输出 baselines-results.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/baselines-results.json}"

declare -a SCRIPTS=(
    "short_command_accuracy.sh"
    "medium_wer.sh"
    "long_retention.sh"
    "meeting_facts.sh"
    "meeting_wer.sh"
)

echo "[" > "$OUTPUT"
FIRST=true
for s in "${SCRIPTS[@]}"; do
    RESULT=$(bash "$SCRIPT_DIR/$s" 2>/dev/null || echo '{"status":"fail","note":"script crashed"}')
    if [ "$FIRST" = true ]; then FIRST=false; else echo "," >> "$OUTPUT"; fi
    echo "$RESULT" >> "$OUTPUT"
done
echo "]" >> "$OUTPUT"

python3 - "$OUTPUT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print()
print("=== KPI Baselines ===")
print(f"{'条款':<14} {'状态':<10} {'样本数':<8} {'值':<12} {'名称'}")
print("-" * 80)
for r in data:
    ref = r.get("pdf_ref", "?")
    status = r.get("status", "?")
    value = r.get("value")
    sample = r.get("sample_count", 0)
    name = r.get("name", "?")
    icon = {"ok": "✅ ok", "todo": "⏳ todo", "fail": "❌ fail"}.get(status, status)
    val_str = f"{value*100:.2f}%" if isinstance(value, (int, float)) else "—"
    print(f"{ref:<14} {icon:<10} {sample:<8} {val_str:<12} {name}")
print("-" * 80)
print(f"详细 JSON: {sys.argv[1]}")
PYEOF
