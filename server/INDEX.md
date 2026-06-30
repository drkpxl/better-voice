# WE Server — Entry Index

The single authoritative guide to "which script should I use". Start here whether you're onboarding or doing further development.

---

## Directory Conventions

```
server/
├─ entry/       ← Main user entry points (3 total). Pick from here based on what you want to do
├─ lib/         ← Sub-steps (not called directly; strung together by entry)
├─ scripts/     ← deprecated old scripts (still usable, being phased out gradually; kept for compatibility)
├─ finetune-research/  ← autoresearch experiment environment
└─ eval/        ← legacy evaluation framework (superseded by KPI tests; docs retained)
```

---

## What do you want to do?

### Run a full fine-tune once (unattended)

**Entry point**: `server/entry/finetune.sh`

```bash
# Run on the GPU server
bash ~/antigravity/we/server/entry/finetune.sh --gemini-key <KEY>
# Defaults to 4 experiment groups (rank=[16,32] × epochs=[5,8]), about 8-15 minutes
```

Process:
1. Automatically build the error-word table (`lib/build_dictionary.py`)
2. AI distillation + merge training pairs (`lib/gen_distill_gemini.py` + `lib/merge_pairs.py`)
3. Grid search over N hyperparameter combinations (`finetune-research/run_experiment.sh × N`)
4. Pick the best `pass_rate` and auto-deploy to ollama (`entry/deploy.sh`)

### Deploy a single adapter to ollama (single step)

**Entry point**: `server/entry/deploy.sh`

```bash
bash server/entry/deploy.sh \
    --adapter <path-to-adapter> \
    --base-model Qwen/Qwen3-0.6B \
    --model-name we-polish
```

### Scheduled server-side merge (cron)

**Entry point**: `server/entry/cron-merge.sh`

```cron
*/10 * * * * bash ~/antigravity/we/server/entry/cron-merge.sh
```

Scans all user directories under `data/<user>/`; whenever it finds `distill-gemini.jsonl` it merges them into `merged-pairs.jsonl`.

### autoresearch autonomous iteration (handed off to Claude)

Have Claude invoke the `autoresearch` skill, pointed at `server/finetune-research/`.
The skill automatically loops through propose → run_experiment → keep/discard.
See `server/finetune-research/README.md` for details.

### Dictionary review (manual)

```bash
# 1) Automatically build a candidate set
python3 server/lib/build_dictionary.py

# 2) Export the markdown review table
python3 server/lib/review_dictionary.py export \
    --input ~/.we/archive/dictionaries/dictionary.auto.json \
    --output ~/.we/archive/dictionaries/dictionary-review.md

# 3) Edit [decision] / rename / errors-keep in the markdown

# 4) Apply the review results (write back to the official dictionary)
python3 server/lib/review_dictionary.py apply \
    --review ~/.we/archive/dictionaries/dictionary-review.md \
    --output ~/.we/correction-dictionary.json
```

---

## Full contract for the three entry points in entry/

| Entry point | Usage | Output |
|---|---|---|
| `entry/finetune.sh` | `--gemini-key K [--ranks ... --epochs ... --lrs ...]` | Best adapter deployed to ollama; workdir + results.tsv records each experiment |
| `entry/deploy.sh` | `--adapter PATH [--base-model NAME --model-name NAME]` | Replaces the NAME model in ollama |
| `entry/cron-merge.sh` | (invoked by cron, no arguments) | `merged-pairs.jsonl` for each user directory |

---

## lib/ sub-steps (generally not called directly)

| File | Responsibility |
|---|---|
| `lib/paths.py` | Central path constants (can be overridden by the `WE_DATA_DIR` env var) |
| `lib/build_dictionary.py` | Automatically extracts error-word candidates from voice-history |
| `lib/gen_distill_gemini.py` | Calls the Gemini API to distill training pairs |
| `lib/gen_training_data.py` | Early synthetic training pairs (based on CORRECTION_MAP templates, superseded by distill) |
| `lib/merge_pairs.py` | Merges training pairs from multiple sources + dedup + sample_weight |
| `lib/train_qlora.py` | QLoRA training (Qwen3-0.6B) |
| `lib/eval_model.py` | Loads adapter for evaluation (fix/break/identity/CER) |
| `lib/review_dictionary.py` | Two-way dictionary ↔ markdown review |

---

## scripts/ deprecated (do not call from new code)

| File | Status | Successor |
|---|---|---|
| `scripts/run_pipeline.sh` | Still usable, wrapped by `entry/finetune.sh` | `entry/finetune.sh` |
| `scripts/run_distill.sh` | Still usable, early version, no auto-build / no train | `entry/finetune.sh` |
| `scripts/deploy_server.sh` | cron install helper (27 lines) | unchanged |

---

## Sandbox testing (isolated environment)

Any `lib/*.py` and `entry/*.sh` support overriding the data root directory via the `WE_DATA_DIR` env var:

```bash
# Avoid polluting the real ~/.we/
WE_DATA_DIR=/tmp/we-test python3 server/lib/build_dictionary.py --output /tmp/test.json
WE_DATA_DIR=/tmp/we-test bash server/entry/finetune.sh --gemini-key K
```

---

## Correspondence with the client

| Client | Server |
|---|---|
| `client/Sources/WEDataDir.swift` | `server/lib/paths.py` |
| `WEDataDir.url` (defaults to `~/.we`) | `paths.WE_DATA_DIR` (defaults to `~/.we`, can be overridden by the `WE_DATA_DIR` env var) |
| `WEDataDir.voiceHistoryURL` | `paths.VOICE_HISTORY` |
| `WEDataDir.correctionDictURL` | `paths.CORRECTION_DICTIONARY` |
| `WEDataDir.archiveDictionaries` | `paths.ARCHIVE_DICTIONARIES` |
| `WEDataDir.archiveTrainingSnapshots` | `paths.ARCHIVE_TRAINING_SNAPSHOTS` |
| `WEDataDir.archiveTestSets` | `paths.ARCHIVE_TEST_SETS` |
| `WEDataDir.archiveReports` | `paths.ARCHIVE_REPORTS` |
