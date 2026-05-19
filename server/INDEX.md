# WE Server — 入口索引

唯一权威的"该用哪个脚本"导览。新接手 / 二开都从这里读。

---

## 目录约定

```
server/
├─ entry/       ← 用户主入口（3 个）。你想做某件事，从这里挑
├─ lib/         ← 子步骤（不直接调用，被 entry 串起来）
├─ scripts/     ← deprecated 旧脚本（仍可用，逐步淘汰；保留兼容性）
├─ finetune-research/  ← autoresearch 实验环境
└─ eval/        ← 历史评估框架（被 KPI 测试取代，文档保留）
```

---

## 你想做什么？

### 完整微调一次（无人值守）

**入口**：`server/entry/finetune.sh`

```bash
# GPU 服务器上跑
bash ~/antigravity/we/server/entry/finetune.sh --gemini-key <KEY>
# 默认 4 组实验（rank=[16,32] × epochs=[5,8]），约 8-15 分钟
```

流程：
1. 自动构建错词表（`lib/build_dictionary.py`）
2. AI 蒸馏 + 合并训练对（`lib/gen_distill_gemini.py` + `lib/merge_pairs.py`）
3. 网格搜索 N 个 hyperparam 组合（`finetune-research/run_experiment.sh × N`）
4. 选 best `pass_rate` 自动部署到 ollama（`entry/deploy.sh`）

### 部署一个 adapter 到 ollama（单步）

**入口**：`server/entry/deploy.sh`

```bash
bash server/entry/deploy.sh \
    --adapter <path-to-adapter> \
    --base-model Qwen/Qwen3-0.6B \
    --model-name we-polish
```

### 服务器定时合并（cron）

**入口**：`server/entry/cron-merge.sh`

```cron
*/10 * * * * bash ~/antigravity/we/server/entry/cron-merge.sh
```

扫描 `data/<user>/` 下所有用户目录，发现 `distill-gemini.jsonl` 就合并成 `merged-pairs.jsonl`。

### autoresearch 自主迭代（Claude 接管）

让 Claude invoke `autoresearch` skill，指向 `server/finetune-research/`。
Skill 会自动 propose → run_experiment → keep/discard → 循环。
详见 `server/finetune-research/README.md`。

### 字典审核（人工）

```bash
# 1) 自动构建一份候选
python3 server/lib/build_dictionary.py

# 2) 导出 markdown 审核表
python3 server/lib/review_dictionary.py export \
    --input ~/.we/archive/dictionaries/dictionary.auto.json \
    --output ~/.we/archive/dictionaries/dictionary-review.md

# 3) 在 markdown 里改 [decision] / rename / errors-keep

# 4) 应用审核结果（写回正式字典）
python3 server/lib/review_dictionary.py apply \
    --review ~/.we/archive/dictionaries/dictionary-review.md \
    --output ~/.we/correction-dictionary.json
```

---

## entry/ 三个入口的完整契约

| 入口 | 用法 | 输出 |
|---|---|---|
| `entry/finetune.sh` | `--gemini-key K [--ranks ... --epochs ... --lrs ...]` | best adapter 部署到 ollama；workdir + results.tsv 记录每次实验 |
| `entry/deploy.sh` | `--adapter PATH [--base-model NAME --model-name NAME]` | ollama 中 NAME 模型替换 |
| `entry/cron-merge.sh` | （cron 调用，无参数） | 各用户目录的 `merged-pairs.jsonl` |

---

## lib/ 子步骤（一般不直接调用）

| 文件 | 职责 |
|---|---|
| `lib/paths.py` | 中央路径常量（可被 `WE_DATA_DIR` env 覆盖） |
| `lib/build_dictionary.py` | 从 voice-history 自动抽错词候选 |
| `lib/gen_distill_gemini.py` | 调 Gemini API 蒸馏训练对 |
| `lib/gen_training_data.py` | 早期合成训练对（基于 CORRECTION_MAP 模板，已被 distill 取代） |
| `lib/merge_pairs.py` | 合并多源训练对 + 去重 + sample_weight |
| `lib/train_qlora.py` | QLoRA 训练（Qwen3-0.6B） |
| `lib/eval_model.py` | 加载 adapter 评估（fix/break/identity/CER） |
| `lib/review_dictionary.py` | 字典 ↔ markdown 双向审核 |

---

## scripts/ deprecated（不要在新代码里调用）

| 文件 | 状态 | 接任者 |
|---|---|---|
| `scripts/run_pipeline.sh` | 仍可用，被 `entry/finetune.sh` 包装 | `entry/finetune.sh` |
| `scripts/run_distill.sh` | 仍可用，早期版本，无 auto-build / 无 train | `entry/finetune.sh` |
| `scripts/deploy_server.sh` | cron 安装小工具（27 行） | 保持 |

---

## 沙箱测试（隔离环境）

任何 `lib/*.py` 和 `entry/*.sh` 都支持 `WE_DATA_DIR` env 覆盖数据根目录：

```bash
# 不污染真实 ~/.we/
WE_DATA_DIR=/tmp/we-test python3 server/lib/build_dictionary.py --output /tmp/test.json
WE_DATA_DIR=/tmp/we-test bash server/entry/finetune.sh --gemini-key K
```

---

## 与客户端的对应

| 客户端 | 服务端 |
|---|---|
| `client/Sources/WEDataDir.swift` | `server/lib/paths.py` |
| `WEDataDir.url`（默认 `~/.we`） | `paths.WE_DATA_DIR`（默认 `~/.we`，可被 `WE_DATA_DIR` env 覆盖） |
| `WEDataDir.voiceHistoryURL` | `paths.VOICE_HISTORY` |
| `WEDataDir.correctionDictURL` | `paths.CORRECTION_DICTIONARY` |
| `WEDataDir.archiveDictionaries` | `paths.ARCHIVE_DICTIONARIES` |
| `WEDataDir.archiveTrainingSnapshots` | `paths.ARCHIVE_TRAINING_SNAPSHOTS` |
| `WEDataDir.archiveTestSets` | `paths.ARCHIVE_TEST_SETS` |
| `WEDataDir.archiveReports` | `paths.ARCHIVE_REPORTS` |
