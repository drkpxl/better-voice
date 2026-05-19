#!/bin/bash
# §3.1 L2 #7 ③ 完成标准：输出报告
#
# 用户视角：训练跑完之后，能拿到一份评估报告说明微调效果（fix/break/identity/CER）
#
# 校验：
#   (a) server/lib/eval_model.py 存在
#   (b) 最近一次 workdir 含 eval_results.jsonl
#   (c) eval_results.jsonl 含必要字段（input/expected/predicted/category/pred_cer）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(cd "$KPI_ROOT/../../.." && pwd)"

EVAL_SCRIPT="$PROJECT_DIR/server/lib/eval_model.py"
LATEST_RESULT=$(ls -t "$PROJECT_DIR"/server/workdir/*/eval_results.jsonl 2>/dev/null | head -1 || true)

checks_a=$([ -f "$EVAL_SCRIPT" ] && echo True || echo False)
checks_b=$([ -n "$LATEST_RESULT" ] && [ -f "$LATEST_RESULT" ] && echo True || echo False)

# (c) schema 校验
checks_c=False
if [ -n "$LATEST_RESULT" ] && [ -f "$LATEST_RESULT" ]; then
    if python3 -c "
import json, sys
required = {'input', 'expected', 'predicted', 'category', 'pred_cer'}
with open('$LATEST_RESULT') as f:
    first = f.readline().strip()
    if not first:
        sys.exit(1)
    try:
        obj = json.loads(first)
    except Exception:
        sys.exit(1)
    if not required.issubset(obj.keys()):
        sys.exit(1)
" 2>/dev/null; then
        checks_c=True
    fi
fi

python3 - <<PYEOF
import json
checks = {
    "eval_script_present": $checks_a,
    "latest_eval_jsonl_present": $checks_b,
    "eval_jsonl_schema_ok": $checks_c,
}
passed = sum(checks.values())
if passed == 3:
    status, score = "pass", 1.0
elif passed == 2:
    status, score = "partial", 0.7
else:
    status, score = "fail", 0

print(json.dumps({
    "pdf_ref": "§3.1 L2 #7 ③",
    "name": "输出报告",
    "status": status,
    "score": score,
    "evidence": {
        "eval_script": "$EVAL_SCRIPT",
        "latest_eval_result": "$LATEST_RESULT",
        "checks": checks,
    },
}, ensure_ascii=False, indent=2))
PYEOF
