#!/bin/bash
# §3.2 L4 ④ 会议关键事实保留率
#
# PDF 原文：会议测试集预标注 20 个关键事实，识别到的 / 20 × 100%
# 用户视角：用户开完会，导出的 Markdown 纪要里包含多少个关键事实
# 测试对象：MeetingExporter 产出的 markdown（走完整 MeetingSession 链路）
# 实现：调 BetterVoice --bench-meeting，从 hypothesis 检索每个 key_fact 的子串

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$KPI_ROOT/data/meeting/manifest.jsonl"

if [ ! -f "$MANIFEST" ]; then
    echo '{"pdf_ref":"§3.2 L4 ④","name":"meeting_facts","status":"todo","value":null,"note":"manifest missing"}'
    exit 0
fi

echo '{"pdf_ref":"§3.2 L4 ④","name":"meeting_facts","status":"todo","value":null,"note":"awaits Stage 4 integration"}'
