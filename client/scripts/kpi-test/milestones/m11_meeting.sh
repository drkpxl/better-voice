#!/bin/bash
# §3.1 L4 #11 ② 完成标准：会议模式可录可转
#
# 用户视角全链路：调 WE --bench-meeting 对一段已知 ground truth 的会议音频，
# 校验：
#   (a) 输出 JSON 有 hypothesis（即转写产物存在）
#   (b) n_segments > 0（说明分段逻辑工作）
#   (c) markdown_path 存在且文件非空（导出链路通）
#   (d) duration_s > 0（说明音频被实际处理）
#
# 4 项全过 → status=pass, score=1.0
# 缺一 → partial, score=0.7
# 缺二以上 → fail, score=0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(cd "$KPI_ROOT/../../.." && pwd)"

WE_BIN="$PROJECT_DIR/client/.build/WE.app/Contents/MacOS/WE"
[ -x "$WE_BIN" ] || WE_BIN="$PROJECT_DIR/client/.build/release/WE"
[ -x "$WE_BIN" ] || WE_BIN="$PROJECT_DIR/client/.build/debug/WE"

if [ ! -x "$WE_BIN" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L4 #11 ②",
  "name": "会议模式可录可转",
  "status": "fail",
  "score": 0,
  "evidence": null,
  "note": "WE binary not found; run 'cd client && make build'"
}
EOF
    exit 0
fi

# 测试音频：用 meeting 测试集第一条；若不存在，告诉用户
TEST_AUDIO="$KPI_ROOT/data/meeting/sample-1.wav"
if [ ! -f "$TEST_AUDIO" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L4 #11 ②",
  "name": "会议模式可录可转",
  "status": "todo",
  "score": 0,
  "evidence": null,
  "note": "test audio $TEST_AUDIO missing; populate data/meeting/ first"
}
EOF
    exit 0
fi

RESULT_JSON=$(mktemp -t m11_meeting_result.XXXXXX.json)
trap 'rm -f "$RESULT_JSON"' EXIT

if ! "$WE_BIN" --bench-meeting "$TEST_AUDIO" --output "$RESULT_JSON" >/dev/null 2>&1; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L4 #11 ②",
  "name": "会议模式可录可转",
  "status": "fail",
  "score": 0,
  "evidence": null,
  "note": "WE --bench-meeting failed"
}
EOF
    exit 0
fi

# 4 项检查（用 python 解析 JSON）
python3 - "$RESULT_JSON" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)

checks = {
    "has_hypothesis": bool(d.get("hypothesis")),
    "has_segments": d.get("n_segments", 0) > 0,
    "has_markdown": bool(d.get("markdown_path")) and __import__("os").path.exists(d.get("markdown_path", "")) and __import__("os").path.getsize(d.get("markdown_path", "")) > 0,
    "has_duration": d.get("duration_s", 0) > 0,
}
passed = sum(checks.values())

if passed == 4:
    status, score = "pass", 1.0
elif passed == 3:
    status, score = "partial", 0.7
else:
    status, score = "fail", 0

print(json.dumps({
    "pdf_ref": "§3.1 L4 #11 ②",
    "name": "会议模式可录可转",
    "status": status,
    "score": score,
    "evidence": {
        "audio": d.get("audio"),
        "duration_s": d.get("duration_s"),
        "n_segments": d.get("n_segments"),
        "markdown_path": d.get("markdown_path"),
        "checks": checks,
    }
}, ensure_ascii=False, indent=2))
PYEOF
