#!/bin/bash
# §3.2 L4 ③ 长句完整保留率（≥ 100 字）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/../results/latest}"
mkdir -p "$OUT_DIR"
python3 "$SCRIPT_DIR/lib/run_baseline.py" --metric long_retention --output-dir "$OUT_DIR"
