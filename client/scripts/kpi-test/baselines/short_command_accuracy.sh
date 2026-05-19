#!/bin/bash
# §3.2 L4 ① 短句指令准确率（< 30 字）
# 走 lib/run_baseline.py 统一实现

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/../results/latest}"
mkdir -p "$OUT_DIR"

python3 "$SCRIPT_DIR/lib/run_baseline.py" \
    --metric short_command_accuracy \
    --output-dir "$OUT_DIR"
