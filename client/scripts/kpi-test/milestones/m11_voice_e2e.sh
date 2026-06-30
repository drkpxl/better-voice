#!/bin/bash
# §3.1 L4 #11 ① 完成标准：录入语音 → 转写 → 输出文字
#
# 用户视角全链路：用一段已知音频跑 BetterVoice --bench-voice（走完整 ContextEnhancer +
# SpeechAnalyzer + L2 polish 链路，但不注入光标），校验：
#   (a) BetterVoice --bench-voice 进程能正常退出（无超时）
#   (b) 输出 JSON 含 finalText 且非空
#   (c) 输出 JSON 含 rawSA（SA 转写产物存在）
#   (d) ctx_ms / sa_ms / total_ms 字段齐全（链路三段都跑了）
#
# 4 项全过 → pass(1.0) / 3 项 → partial(0.7) / 其它 → fail(0)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(cd "$KPI_ROOT/../../.." && pwd)"

# 找 BetterVoice 二进制（优先 .app bundle，回退 debug）
BV_BIN="$PROJECT_DIR/client/.build/BetterVoice.app/Contents/MacOS/BetterVoice"
[ -x "$BV_BIN" ] || BV_BIN="$PROJECT_DIR/client/.build/release/BetterVoice"
[ -x "$BV_BIN" ] || BV_BIN="$PROJECT_DIR/client/.build/debug/BetterVoice"

if [ ! -x "$BV_BIN" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L4 #11 ①",
  "name": "录入语音 → 转写 → 输出文字",
  "status": "fail",
  "score": 0,
  "evidence": null,
  "note": "BetterVoice binary not found; run 'cd client && make build' first"
}
EOF
    exit 0
fi

# 找一条真实音频
TEST_AUDIO=$(ls -t "$HOME/.better-voice/audio"/*.wav 2>/dev/null | head -1)
if [ -z "${TEST_AUDIO:-}" ] || [ ! -f "$TEST_AUDIO" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L4 #11 ①",
  "name": "录入语音 → 转写 → 输出文字",
  "status": "todo",
  "score": 0,
  "evidence": null,
  "note": "no test audio in ~/.better-voice/audio/"
}
EOF
    exit 0
fi

RESULT_JSON=$(mktemp -t m11_voice_e2e.XXXXXX.json)
trap 'rm -f "$RESULT_JSON"' EXIT

# 跑 bench-voice，硬超时 60s（即时录音应该几秒就完成）
exit_code=0
perl -e 'alarm(60); exec @ARGV' -- "$BV_BIN" --bench-voice "$TEST_AUDIO" --output "$RESULT_JSON" >/dev/null 2>&1 || exit_code=$?

# 检查
if [ ! -f "$RESULT_JSON" ] || [ ! -s "$RESULT_JSON" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L4 #11 ①",
  "name": "录入语音 → 转写 → 输出文字",
  "status": "fail",
  "score": 0,
  "evidence": {"exit_code": $exit_code},
  "note": "bench-voice produced no output (timeout or crash)"
}
EOF
    exit 0
fi

python3 - "$RESULT_JSON" "$exit_code" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
exit_code = int(sys.argv[2])

checks = {
    "process_exited_cleanly": exit_code == 0,
    "has_finalText": bool(d.get("finalText")),
    "has_rawSA": bool(d.get("rawSA")),
    "timing_complete": all(d.get(k) is not None for k in ("ctx_ms", "sa_ms", "total_ms")),
}
passed = sum(checks.values())

if passed == 4:
    status, score = "pass", 1.0
elif passed == 3:
    status, score = "partial", 0.7
else:
    status, score = "fail", 0

print(json.dumps({
    "pdf_ref": "§3.1 L4 #11 ①",
    "name": "录入语音 → 转写 → 输出文字",
    "status": status,
    "score": score,
    "evidence": {
        "audio": d.get("audio"),
        "duration_s": d.get("duration_s"),
        "rawSA": d.get("rawSA"),
        "finalText": d.get("finalText"),
        "ctx_ms": d.get("ctx_ms"),
        "sa_ms": d.get("sa_ms"),
        "l2_ms": d.get("l2_ms"),
        "total_ms": d.get("total_ms"),
        "checks": checks,
    },
}, ensure_ascii=False, indent=2))
PYEOF
