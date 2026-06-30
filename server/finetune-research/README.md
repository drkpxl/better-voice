# WE Polish Fine-tuning Experiment Environment (for `autoresearch` skill)

## Starting the autoresearch loop

Invoke the `autoresearch` skill and point it at this directory. The skill will:

1. Read `program.md` to understand the goal / metrics / constraints
2. Read `results.tsv` to see historical experiment results
3. Propose the next hypothesis
4. Call `run_experiment.sh` to run one experiment (about 2-5 minutes)
5. Check the `summary.json` primary metric `pass_rate`
6. If `pass_rate` improves → keep; otherwise → discard
7. Go back to step 3, **never stop to ask "should we continue?"**

## Single experiment (called internally by autoresearch)

```bash
./run_experiment.sh \
    --exp-id exp042 \
    --rank 16 --alpha 32 --epochs 8 --lr 1e-4 \
    --data ~/we-data/training-data-v6.jsonl \
    --description "Increase rank to see if correction accuracy improves"
```

## Input / Output Contract

**Input** (hyperparameter search space):

| Parameter | Default | Typical search range |
|---|---|---|
| `--rank` | 16 | 8 / 16 / 32 |
| `--alpha` | 2×rank | rank / 2×rank / 4×rank |
| `--epochs` | 8 | 3 / 5 / 8 / 10 |
| `--lr` | 1e-4 | 5e-5 / 1e-4 / 2e-4 |
| `--batch` | 8 | 4 / 8 / 16 |
| `--max-length` | 256 | 128 / 256 / 512 |
| `--data` | (required) | Path to training data jsonl |

**Output**:

| File | Content |
|---|---|
| `workdir/<exp-id>/checkpoints/adapter/` | Trained LoRA adapter |
| `workdir/<exp-id>/eval-results.jsonl` | Per-item evaluation (input / expected / predicted / category / pred_cer / source) |
| `workdir/<exp-id>/summary.json` | Primary metric `pass_rate`, etc. |
| `results.tsv` appends one row | `exp\tpass_rate\tparams\tstatus\tdescription` |

## Primary Metric Definition

`pass_rate = (fix_count + identity_count) / total`, higher is better.

Auxiliary metrics:
- `fix_rate`: proportion of cases the model actively corrected (ideally ↑)
- `break_rate`: proportion of cases the model turned correct into incorrect (ideally ↓)
- `identity_rate`: proportion of cases the model left unchanged (recognized as already correct, no edit needed)
- `avg_cer`: average character error rate (ideally ↓)

## Relationship to the Fine-tuning Pipeline

```
Line 1 (fine-tuning pipeline)'s autoresearch step:

  build_dictionary.py → review_dictionary.py (manual review) → corrected-dictionary.json
       │
       ▼
  gen_distill_gemini.py + corrected-dictionary → training-data.jsonl
       │
       ▼
  ┌──── autoresearch loop (this directory) ─────┐
  │   propose → run_experiment.sh → keep/discard → next     │
  │   After convergence, select the adapter with the best pass_rate │
  └─────────────────────────────────────────────────────────┘
       │
       ▼
  deploy_model.sh → ollama we-polish replacement
```

## Relationship to the KPI Test Suite (Line 2)

**Completely independent**. autoresearch uses a **holdout split of the training data** for internal evaluation (checking whether the model has learned well).
The KPI test suite uses a **real-world audio test set from the user's perspective** for end-to-end scoring (checking whether the user experience has improved).
Once the best adapter is deployed, the KPI tests will naturally reflect the improvement in the next monthly run.
