#!/bin/bash
# §3.2 L4 ② 中等长度 WER（30-100 字）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/../results/latest}"
mkdir -p "$OUT_DIR"
python3 "$SCRIPT_DIR/lib/run_baseline.py" --metric medium_wer --output-dir "$OUT_DIR"
