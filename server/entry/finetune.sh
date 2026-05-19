#!/bin/bash
# 完全自动化微调管线（端到端，无人值守）
#
# 输入：Gemini API key + （可选）超参网格
# 流程：
#   [1] 自动构建错词表（build_dictionary.py）
#   [2] AI 蒸馏生成训练对（gen_distill_gemini.py + merge_pairs.py）
#   [3] 网格搜索：跑多个 hyperparam 组合（run_experiment.sh × N）
#   [4] 选 best pass_rate 的实验自动部署到 ollama
#
# 用法：
#   ./finetune.sh --gemini-key <KEY>
#       默认网格：rank=[16,32] × epochs=[5,8] × lr=[1e-4] = 4 个实验
#
#   ./finetune.sh --gemini-key <KEY> \
#       --ranks 8,16,32 --epochs 5,8,10 --lrs 1e-4,5e-5
#       搜索 27 个组合
#
#   ./finetune.sh --skip-distill \      # 复用最新的 training_data.jsonl
#       --ranks 16,32 --epochs 8
#
# 输出：
#   - server/workdir/<timestamp>/                完整管线产物
#   - server/finetune-research/workdir/<exp>/    每个实验单独 workdir
#   - server/finetune-research/results.tsv       所有实验记录
#   - ollama we-polish                            best adapter 自动部署

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESEARCH_DIR="$PROJECT_DIR/finetune-research"
RESULTS_TSV="$RESEARCH_DIR/results.tsv"

# ============================================================
# 参数
# ============================================================

GEMINI_KEY=""
RANKS="16,32"
EPOCHS_LIST="5,8"
LRS="1e-4"
BATCHES="8"
DATA_DIR="${HOME}/we-data"
BASE_MODEL="Qwen/Qwen3-0.6B"
MODEL_NAME="we-polish"
SKIP_DISTILL=false
NO_DEPLOY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gemini-key) GEMINI_KEY="$2"; shift 2;;
        --ranks) RANKS="$2"; shift 2;;
        --epochs) EPOCHS_LIST="$2"; shift 2;;
        --lrs) LRS="$2"; shift 2;;
        --batches) BATCHES="$2"; shift 2;;
        --data-dir) DATA_DIR="$2"; shift 2;;
        --base-model) BASE_MODEL="$2"; shift 2;;
        --model-name) MODEL_NAME="$2"; shift 2;;
        --skip-distill) SKIP_DISTILL=true; shift;;
        --no-deploy) NO_DEPLOY=true; shift;;
        -h|--help)
            head -30 "$0" | tail -29
            exit 0;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

T_START=$(date +%s)

# ============================================================
# Step 1+2: 字典 + 蒸馏 + 合并 (复用 run_pipeline.sh --skip-train)
# ============================================================

if [ "$SKIP_DISTILL" = false ]; then
    if [ -z "$GEMINI_KEY" ]; then
        echo "Error: --gemini-key required (or use --skip-distill to reuse latest)"
        exit 1
    fi

    echo "============================================"
    echo "  Auto-finetune: Step 1+2 (dict + distill)"
    echo "============================================"
    bash "$PROJECT_DIR/scripts/run_pipeline.sh" \
        --gemini-key "$GEMINI_KEY" \
        --data-dir "$DATA_DIR" \
        --base-model "$BASE_MODEL" \
        --skip-train
fi

# 找最新 training_data.jsonl
LATEST_TD=$(ls -t "$PROJECT_DIR"/workdir/*/training_data.jsonl 2>/dev/null | head -1)
if [ -z "$LATEST_TD" ] || [ ! -f "$LATEST_TD" ]; then
    echo "Error: no training_data.jsonl found in $PROJECT_DIR/workdir/"
    echo "       Run without --skip-distill first."
    exit 1
fi

PAIR_COUNT=$(wc -l < "$LATEST_TD")
echo ""
echo "Training data: $LATEST_TD ($PAIR_COUNT pairs)"

# ============================================================
# Step 3: 网格搜索
# ============================================================

echo ""
echo "============================================"
echo "  Step 3: Grid search"
echo "============================================"
echo "  ranks:   $RANKS"
echo "  epochs:  $EPOCHS_LIST"
echo "  lrs:     $LRS"
echo "  batches: $BATCHES"
echo ""

# 估算实验数
TOTAL_EXPS=$(( $(echo $RANKS | tr ',' ' ' | wc -w) \
            * $(echo $EPOCHS_LIST | tr ',' ' ' | wc -w) \
            * $(echo $LRS | tr ',' ' ' | wc -w) \
            * $(echo $BATCHES | tr ',' ' ' | wc -w) ))
echo "Total experiments to run: $TOTAL_EXPS"

# 记录本次 grid run id 用于 best 筛选
GRID_ID="grid_$(date +%s)"
EXP_PREFIX="${GRID_ID}_"

idx=0
for rank in $(echo $RANKS | tr ',' ' '); do
    for ep in $(echo $EPOCHS_LIST | tr ',' ' '); do
        for lr in $(echo $LRS | tr ',' ' '); do
            for bs in $(echo $BATCHES | tr ',' ' '); do
                idx=$((idx + 1))
                EXP_ID="${EXP_PREFIX}r${rank}_e${ep}_lr${lr}_b${bs}"
                echo ""
                echo "  [$idx/$TOTAL_EXPS] $EXP_ID"
                bash "$RESEARCH_DIR/run_experiment.sh" \
                    --exp-id "$EXP_ID" \
                    --rank "$rank" \
                    --epochs "$ep" \
                    --lr "$lr" \
                    --batch "$bs" \
                    --data "$LATEST_TD" \
                    --base-model "$BASE_MODEL" \
                    --description "auto_finetune $GRID_ID" || {
                    echo "  [$idx] FAILED, continuing..."
                }
            done
        done
    done
done

# ============================================================
# Step 4: 选 best + 自动部署
# ============================================================

echo ""
echo "============================================"
echo "  Step 4: Pick best + deploy"
echo "============================================"

# 从 results.tsv 找本次 grid 的 best pass_rate
BEST_LINE=$(awk -F'\t' -v prefix="$EXP_PREFIX" '
    NR > 1 && $1 ~ "^" prefix && $4 == "done" && $2 != "NaN" {print $0}
' "$RESULTS_TSV" | sort -t$'\t' -k2 -rn | head -1)

if [ -z "$BEST_LINE" ]; then
    echo "Error: no successful experiments in this grid run"
    exit 1
fi

BEST_ID=$(echo "$BEST_LINE" | cut -f1)
BEST_RATE=$(echo "$BEST_LINE" | cut -f2)
BEST_PARAMS=$(echo "$BEST_LINE" | cut -f3)
BEST_ADAPTER="$RESEARCH_DIR/workdir/$BEST_ID/checkpoints/adapter"

echo "Best experiment: $BEST_ID"
echo "  pass_rate: $BEST_RATE"
echo "  params:    $BEST_PARAMS"
echo "  adapter:   $BEST_ADAPTER"
echo ""

# Top 5 概览
echo "Top 5 (本次 grid):"
awk -F'\t' -v prefix="$EXP_PREFIX" '
    NR > 1 && $1 ~ "^" prefix && $4 == "done" && $2 != "NaN" {print $0}
' "$RESULTS_TSV" | sort -t$'\t' -k2 -rn | head -5 | \
    awk -F'\t' '{printf "  %-50s %s\t%s\n", $1, $2, $3}'

if [ "$NO_DEPLOY" = false ]; then
    echo ""
    echo "Deploying best..."
    bash "$SCRIPT_DIR/deploy.sh" \
        --adapter "$BEST_ADAPTER" \
        --base-model "$BASE_MODEL" \
        --model-name "$MODEL_NAME"
else
    echo ""
    echo "--no-deploy specified. To deploy manually:"
    echo "  bash $SCRIPT_DIR/deploy.sh --adapter $BEST_ADAPTER --model-name $MODEL_NAME"
fi

T_END=$(date +%s)
ELAPSED=$((T_END - T_START))
echo ""
echo "============================================"
echo "  Auto-finetune done in ${ELAPSED}s"
echo "  Grid id: $GRID_ID"
echo "  Best:    $BEST_ID  ($BEST_RATE)"
echo "============================================"
