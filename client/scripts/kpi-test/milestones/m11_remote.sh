#!/bin/bash
# §3.1 L4 #11 ③ 完成标准：跨网传输可用
#
# 用户视角全链路：模拟 Windows 端 tailscale voice 发音频到 Mac 端 :9800，
# 校验：
#   (a) WE 进程存在且 RemoteInbox 监听 :9800
#   (b) HTTP POST WAV → 返回 200
#   (c) debug.log 出现 Remote Received WAV + Transcribed + Timing 完整链路
#   (d) voice-history.jsonl 在测试时间窗口内新增一条
#
# 4 项全过 → pass(1.0) / 3 项 → partial(0.7) / 其它 → fail(0)

set -uo pipefail   # 注意：不带 -e（允许各步骤失败但仍输出 JSON）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
WE_LOG="$HOME/.we/debug.log"
VOICE_HISTORY="$HOME/.we/voice-history.jsonl"

# 找一个真实 WAV 测试
TEST_AUDIO=$(ls -t "$HOME/.we/audio"/*.wav 2>/dev/null | head -1)

# 步骤值（默认全 0/false）
process_listening_9800=False
http_code="000"
log_received=0
log_transcribed=0
log_timing=0
voice_history_new=0
note=""

if [ -z "${TEST_AUDIO:-}" ] || [ ! -f "${TEST_AUDIO:-}" ]; then
    note="no test audio in ~/.we/audio/"
else
    PID=$(pgrep -x WE 2>/dev/null | head -1)
    if [ -z "${PID:-}" ]; then
        note="WE process not running; start WE first"
    else
        # (a) 监听 :9800?
        LSOF_OUT=$(lsof -nP -p "$PID" 2>/dev/null || true)
        if echo "$LSOF_OUT" | grep -q ":9800"; then
            process_listening_9800=True
        fi

        T_START_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S")

        # (b) curl POST
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:9800/transcribe" \
            --data-binary @"$TEST_AUDIO" --max-time 60 2>/dev/null || echo "000")

        # 等管线处理完成
        sleep 4

        # (c) 日志链路
        LOG_TAIL=$(tail -80 "$WE_LOG" 2>/dev/null || echo "")
        log_received=$(echo "$LOG_TAIL" | grep -c "Remote Received WAV" 2>/dev/null || echo 0)
        log_transcribed=$(echo "$LOG_TAIL" | grep -c "Remote Transcribed:" 2>/dev/null || echo 0)
        log_timing=$(echo "$LOG_TAIL" | grep -c "Remote Timing:" 2>/dev/null || echo 0)

        # (d) voice-history 新增条目
        if [ -f "$VOICE_HISTORY" ]; then
            voice_history_new=$(python3 - "$VOICE_HISTORY" "$T_START_ISO" <<'PYEOF' 2>/dev/null
import json, sys
from datetime import datetime, timezone
path, t_start = sys.argv[1], sys.argv[2]
try:
    threshold = datetime.fromisoformat(t_start).replace(tzinfo=timezone.utc)
except Exception:
    print(0); sys.exit(0)
n = 0
try:
    with open(path) as f:
        for line in f:
            try:
                obj = json.loads(line)
                ts = obj.get("timestamp")
                if not ts:
                    continue
                ts_obj = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if ts_obj >= threshold:
                    n += 1
            except Exception:
                continue
except FileNotFoundError:
    pass
print(n)
PYEOF
            )
            voice_history_new=${voice_history_new:-0}
        fi
    fi
fi

# 输出 JSON
python3 - <<PYEOF
import json
checks = {
    "process_listening_9800": $process_listening_9800,
    "http_200": "$http_code" == "200",
    "log_chain_complete": int("$log_received") > 0 and int("$log_transcribed") > 0 and int("$log_timing") > 0,
    "voice_history_appended": int("$voice_history_new") > 0,
}
passed = sum(checks.values())
if passed == 4:
    status, score = "pass", 1.0
elif passed == 3:
    status, score = "partial", 0.7
else:
    status, score = "fail", 0

result = {
    "pdf_ref": "§3.1 L4 #11 ③",
    "name": "跨网传输可用",
    "status": status,
    "score": score,
    "evidence": {
        "audio": "${TEST_AUDIO:-}",
        "http_code": "$http_code",
        "log_received": int("$log_received"),
        "log_transcribed": int("$log_transcribed"),
        "log_timing": int("$log_timing"),
        "voice_history_new": int("$voice_history_new"),
        "checks": checks,
    },
}
note = """${note}"""
if note:
    result["note"] = note
print(json.dumps(result, ensure_ascii=False, indent=2))
PYEOF
