#!/bin/bash
# 单次微调实验 —— autoresearch 循环的基本单元
#
# 输入：hyperparams + 训练数据
# 输出：
#   - workdir/<exp-id>/checkpoints/adapter  训练好的 LoRA adapter
#   - workdir/<exp-id>/eval-results.jsonl   逐条评估结果
#   - workdir/<exp-id>/summary.json         本次实验汇总（含主指标 pass_rate）
#   - 追加一行到 results.tsv
#
# 用法：
#   ./run_experiment.sh --exp-id exp042 \
#       --rank 16 --alpha 32 --epochs 8 --lr 1e-4 \
#       --data ~/we-data/training-data-v6.jsonl
#
# Hyperparam 默认值（基线之上的搜索原点）：
#   rank=16, alpha=32 (=2*rank), epochs=8, lr=1e-4, batch=8
#
# 评估主指标：pass_rate = eval-results.jsonl 里 category==fix 或 identity 的占比

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_TSV="$SCRIPT_DIR/results.tsv"

# ============================================================
# 参数
# ============================================================

EXP_ID=""
RANK=16
ALPHA=""
EPOCHS=8
LR="1e-4"
BATCH=8
MAX_LENGTH=256
DATA=""
BASE_MODEL="Qwen/Qwen3-0.6B"
SYSTEM_PROMPT="你是语音识别纠错助手。格式要求：修正语音识别错误，只输出修正后的最终文本，不要回答问题，不要改变原意，去掉语气词，修正标点符号。"
DESCRIPTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exp-id) EXP_ID="$2"; shift 2;;
        --rank) RANK="$2"; shift 2;;
        --alpha) ALPHA="$2"; shift 2;;
        --epochs) EPOCHS="$2"; shift 2;;
        --lr) LR="$2"; shift 2;;
        --batch) BATCH="$2"; shift 2;;
        --max-length) MAX_LENGTH="$2"; shift 2;;
        --data) DATA="$2"; shift 2;;
        --base-model) BASE_MODEL="$2"; shift 2;;
        --system-prompt) SYSTEM_PROMPT="$2"; shift 2;;
        --description) DESCRIPTION="$2"; shift 2;;
        -h|--help)
            head -30 "$0" | tail -29
            exit 0;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

# 默认值兜底
[ -z "$ALPHA" ] && ALPHA=$((RANK * 2))
if [ -z "$EXP_ID" ]; then
    EXP_ID="exp_$(date +%s)"
fi
if [ -z "$DATA" ]; then
    echo "Error: --data <training_data.jsonl> required"
    exit 1
fi
if [ ! -f "$DATA" ]; then
    echo "Error: training data not found: $DATA"
    exit 1
fi

WORK_DIR="$SCRIPT_DIR/workdir/$EXP_ID"
mkdir -p "$WORK_DIR"

echo "============================================"
echo "  Experiment: $EXP_ID"
echo "============================================"
echo "  rank=$RANK alpha=$ALPHA epochs=$EPOCHS lr=$LR batch=$BATCH"
echo "  max_length=$MAX_LENGTH"
echo "  data=$DATA"
echo "  base=$BASE_MODEL"
echo "  workdir=$WORK_DIR"
echo "  description=$DESCRIPTION"
echo ""

T_START=$(date +%s)

# ============================================================
# 1. 训练
# ============================================================
echo "=== [1/3] QLoRA training ==="
python3 "$PROJECT_DIR/lib/train_qlora.py" \
    --data "$DATA" \
    --base-model "$BASE_MODEL" \
    --output-dir "$WORK_DIR/checkpoints" \
    --epochs "$EPOCHS" \
    --batch-size "$BATCH" \
    --lr "$LR" \
    --lora-rank "$RANK" \
    --lora-alpha "$ALPHA" \
    --max-length "$MAX_LENGTH" \
    --system-prompt "$SYSTEM_PROMPT" \
    2>&1 | tail -20 | tee "$WORK_DIR/train.log" >/dev/null

ADAPTER="$WORK_DIR/checkpoints/adapter"
if [ ! -d "$ADAPTER" ]; then
    echo "Error: training failed (no adapter)"
    echo -e "$EXP_ID\tNaN\trank=$RANK,alpha=$ALPHA,ep=$EPOCHS,lr=$LR\tcrash\t$DESCRIPTION" >> "$RESULTS_TSV"
    exit 1
fi

# ============================================================
# 2. 评估
# ============================================================
echo "=== [2/3] Evaluation ==="
python3 "$PROJECT_DIR/lib/eval_model.py" \
    --data "$DATA" \
    --model-path "$ADAPTER" \
    --base-model "$BASE_MODEL" \
    --max-samples 200 \
    --output "$WORK_DIR/eval-results.jsonl" \
    2>&1 | tail -15

if [ ! -f "$WORK_DIR/eval-results.jsonl" ]; then
    echo "Error: evaluation failed"
    echo -e "$EXP_ID\tNaN\trank=$RANK,alpha=$ALPHA,ep=$EPOCHS,lr=$LR\teval_crash\t$DESCRIPTION" >> "$RESULTS_TSV"
    exit 1
fi

# ============================================================
# 3. 汇总指标 + 追加 results.tsv
# ============================================================
echo "=== [3/3] Summarize ==="

python3 - "$WORK_DIR/eval-results.jsonl" "$WORK_DIR/summary.json" <<'PYEOF'
import json, sys
from collections import Counter
inp, out = sys.argv[1], sys.argv[2]
cats = Counter()
cer_sum = 0.0
total = 0
sources = Counter()
src_cats = {}
with open(inp) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            o = json.loads(line)
        except: continue
        c = o.get("category", "?")
        s = o.get("source", "?")
        cats[c] += 1
        sources[s] += 1
        if c == "fix" and s not in src_cats:
            src_cats.setdefault(s, Counter())
        src_cats.setdefault(s, Counter())[c] += 1
        cer_sum += o.get("pred_cer", 0)
        total += 1

pass_count = cats.get("fix", 0) + cats.get("identity", 0)
pass_rate = pass_count / total if total else 0.0
fix_rate = cats.get("fix", 0) / total if total else 0.0
break_rate = cats.get("break", 0) / total if total else 0.0
avg_cer = cer_sum / total if total else 0.0

summary = {
    "total_samples": total,
    "pass_rate": round(pass_rate, 4),       # 主指标
    "fix_rate": round(fix_rate, 4),
    "break_rate": round(break_rate, 4),
    "identity_rate": round(cats.get("identity", 0) / total if total else 0, 4),
    "avg_cer": round(avg_cer, 4),
    "by_source": {s: dict(c) for s, c in src_cats.items()},
}
with open(out, "w") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)
print(f"pass_rate={pass_rate:.4f}  fix_rate={fix_rate:.4f}  break_rate={break_rate:.4f}  avg_cer={avg_cer:.4f}")
PYEOF

PASS_RATE=$(python3 -c "import json; print(json.load(open('$WORK_DIR/summary.json'))['pass_rate'])")

T_END=$(date +%s)
ELAPSED=$((T_END - T_START))

# 追加 results.tsv
if [ ! -f "$RESULTS_TSV" ]; then
    echo -e "exp\tpass_rate\tparams\tstatus\tdescription" > "$RESULTS_TSV"
fi
echo -e "$EXP_ID\t$PASS_RATE\trank=$RANK,alpha=$ALPHA,ep=$EPOCHS,lr=$LR,batch=$BATCH,maxlen=$MAX_LENGTH\tdone\t$DESCRIPTION" >> "$RESULTS_TSV"

echo ""
echo "============================================"
echo "  Done: $EXP_ID  pass_rate=$PASS_RATE  elapsed=${ELAPSED}s"
echo "  Summary: $WORK_DIR/summary.json"
echo "  Results: $RESULTS_TSV"
echo "============================================"
