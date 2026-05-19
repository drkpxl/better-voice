#!/bin/bash
# §3.1 L2 #7 ① 完成标准：自动构建错词表
#
# 用户视角：用户不手动维护 dictionary，从 voice-history.jsonl 自动构建。
#
# 校验：
#   (a) server/lib/build_dictionary.py 存在且语法正确
#   (b) 跑一次能成功 exit 0
#   (c) 输出 JSON 含至少 N 条术语（默认 N=10）
#   (d) JSON schema 符合：term -> {errors, frequency, source}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(cd "$KPI_ROOT/../../.." && pwd)"

BUILD_SCRIPT="$PROJECT_DIR/server/lib/build_dictionary.py"

if [ ! -f "$BUILD_SCRIPT" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L2 #7 ①",
  "name": "自动构建错词表",
  "status": "fail",
  "score": 0,
  "evidence": null,
  "note": "server/lib/build_dictionary.py missing"
}
EOF
    exit 0
fi

# (a) syntax check
syntax_ok=False
if python3 -m py_compile "$BUILD_SCRIPT" 2>/dev/null; then
    syntax_ok=True
fi

# (b)+(c)+(d) 跑一次到临时文件 + 校验
TMP_OUT=$(mktemp -t dictionary.auto.XXXXXX.json)
trap 'rm -f "$TMP_OUT"' EXIT

exit_code=0
python3 "$BUILD_SCRIPT" --output "$TMP_OUT" >/dev/null 2>&1 || exit_code=$?

# (c)+(d)
schema_ok=False
term_count=0
if [ -f "$TMP_OUT" ] && [ -s "$TMP_OUT" ]; then
    if python3 -c "
import json, sys
d = json.load(open('$TMP_OUT'))
if not isinstance(d, dict) or len(d) < 10:
    sys.exit(1)
for k, v in list(d.items())[:3]:
    if not isinstance(v, dict): sys.exit(1)
    if 'errors' not in v or 'frequency' not in v or 'source' not in v: sys.exit(1)
    if not isinstance(v['errors'], list): sys.exit(1)
" >/dev/null 2>&1; then
        schema_ok=True
    fi
    term_count=$(python3 -c "import json; print(len(json.load(open('$TMP_OUT'))))" 2>/dev/null || echo 0)
fi

python3 - <<PYEOF
import json
checks = {
    "syntax_ok": $syntax_ok,
    "exited_cleanly": $exit_code == 0,
    "min_terms": $term_count >= 10,
    "schema_ok": $schema_ok,
}
passed = sum(checks.values())
if passed == 4:
    status, score = "pass", 1.0
elif passed >= 3:
    status, score = "partial", 0.7
else:
    status, score = "fail", 0

print(json.dumps({
    "pdf_ref": "§3.1 L2 #7 ①",
    "name": "自动构建错词表",
    "status": status,
    "score": score,
    "evidence": {
        "script": "$BUILD_SCRIPT",
        "term_count": $term_count,
        "exit_code": $exit_code,
        "checks": checks,
    },
}, ensure_ascii=False, indent=2))
PYEOF
