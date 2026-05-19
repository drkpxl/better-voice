#!/bin/bash
# §3.1 L2 #7 ② 完成标准：自动微调
#
# 用户视角：用户在 GPU 服务器一条命令跑通蒸馏→合并→训练→评估→部署链路
#
# 校验：
#   (a) server/entry/finetune.sh 存在且可执行
#   (b) help 信息可见（说明脚本结构正确）
#   (c) 现有 server/entry/cron-merge.sh（cron 用）也存在
#
# 注：本测试不实际触发训练（耗时长 + 占 GPU）。
# 真实"自动微调跑通"的证据来自最新一次 run_pipeline.sh 的成功执行记录
# （workdir/<timestamp>/checkpoints/adapter 存在即视为通过）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(cd "$KPI_ROOT/../../.." && pwd)"

PIPELINE="$PROJECT_DIR/server/entry/finetune.sh"
CRON_PIPELINE="$PROJECT_DIR/server/entry/cron-merge.sh"

if [ ! -f "$PIPELINE" ]; then
    cat <<EOF
{
  "pdf_ref": "§3.1 L2 #7 ②",
  "name": "自动微调",
  "status": "fail",
  "score": 0,
  "evidence": null,
  "note": "server/entry/finetune.sh missing"
}
EOF
    exit 0
fi

# 静态检查
checks_a=$([ -x "$PIPELINE" ] && echo True || echo False)
checks_b=$(grep -qE "QLoRA Training|Grid search" "$PIPELINE" && echo True || echo False)
checks_c=$([ -f "$CRON_PIPELINE" ] && echo True || echo False)

# 最近一次 workdir 是否有 adapter（证据：脚本真跑过且训练完成）
LATEST_ADAPTER=$(ls -dt "$PROJECT_DIR"/server/workdir/*/checkpoints/adapter 2>/dev/null | head -1 || true)
checks_d=$([ -n "$LATEST_ADAPTER" ] && [ -d "$LATEST_ADAPTER" ] && echo True || echo False)

python3 - <<PYEOF
import json
checks = {
    "pipeline_executable": $checks_a,
    "pipeline_contains_training_stage": $checks_b,
    "cron_pipeline_exists": $checks_c,
    "latest_adapter_present": $checks_d,
}
passed = sum(checks.values())
if passed == 4:
    status, score = "pass", 1.0
elif passed >= 3:
    status, score = "partial", 0.7
else:
    status, score = "fail", 0

print(json.dumps({
    "pdf_ref": "§3.1 L2 #7 ②",
    "name": "自动微调",
    "status": status,
    "score": score,
    "evidence": {
        "pipeline_script": "$PIPELINE",
        "latest_adapter": "$LATEST_ADAPTER",
        "checks": checks,
    },
}, ensure_ascii=False, indent=2))
PYEOF
