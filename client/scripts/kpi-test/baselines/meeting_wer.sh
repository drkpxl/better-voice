#!/bin/bash
# §3.2 L4 ⑤ 会议 WER
#
# PDF 原文：标准 WER 测量
# 用户视角：会议 markdown 整体内容相对 ground truth 的词错率
# 测试对象：MeetingExporter 产出的 markdown 或 hypothesis 拼接

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KPI_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$KPI_ROOT/data/meeting/manifest.jsonl"

if [ ! -f "$MANIFEST" ]; then
    echo '{"pdf_ref":"§3.2 L4 ⑤","name":"meeting_wer","status":"todo","value":null,"note":"manifest missing"}'
    exit 0
fi

echo '{"pdf_ref":"§3.2 L4 ⑤","name":"meeting_wer","status":"todo","value":null,"note":"awaits Stage 4 integration"}'
