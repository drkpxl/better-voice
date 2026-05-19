# WE Polish 微调实验环境（for `autoresearch` skill）

## 启动 autoresearch loop

调用 `autoresearch` skill 并指向这个目录。Skill 会：

1. 读 `program.md` 了解目标 / 度量 / 约束
2. 读 `results.tsv` 看历史实验结果
3. 提出下一个假设
4. 调 `run_experiment.sh` 跑一次实验（约 2-5 分钟）
5. 看 `summary.json` 主指标 `pass_rate`
6. `pass_rate` 提升 → keep；否则 → discard
7. 回到 3，**永不停下问"要不要继续"**

## 单次实验（autoresearch 内部调用）

```bash
./run_experiment.sh \
    --exp-id exp042 \
    --rank 16 --alpha 32 --epochs 8 --lr 1e-4 \
    --data ~/we-data/training-data-v6.jsonl \
    --description "增大 rank 看是否提升纠错"
```

## 输入 / 输出契约

**输入**（hyperparam 搜索空间）：

| 参数 | 默认 | 典型搜索范围 |
|---|---|---|
| `--rank` | 16 | 8 / 16 / 32 |
| `--alpha` | 2×rank | rank / 2×rank / 4×rank |
| `--epochs` | 8 | 3 / 5 / 8 / 10 |
| `--lr` | 1e-4 | 5e-5 / 1e-4 / 2e-4 |
| `--batch` | 8 | 4 / 8 / 16 |
| `--max-length` | 256 | 128 / 256 / 512 |
| `--data` | (必填) | 训练数据 jsonl 路径 |

**输出**：

| 文件 | 内容 |
|---|---|
| `workdir/<exp-id>/checkpoints/adapter/` | 训练完的 LoRA adapter |
| `workdir/<exp-id>/eval-results.jsonl` | 逐条评估（input / expected / predicted / category / pred_cer / source） |
| `workdir/<exp-id>/summary.json` | 主指标 `pass_rate` 等 |
| `results.tsv` 追加一行 | `exp\tpass_rate\tparams\tstatus\tdescription` |

## 主指标定义

`pass_rate = (fix_count + identity_count) / total`，越大越好。

辅助指标：
- `fix_rate`：模型主动改对的比例（理想 ↑）
- `break_rate`：模型把对的改错的比例（理想 ↓）
- `identity_rate`：模型不动（识别为正确无需改）的比例
- `avg_cer`：平均字错率（理想 ↓）

## 与微调管线的关系

```
线 1（微调管线）的 autoresearch 步骤：

  build_dictionary.py → review_dictionary.py（人工审）→ corrected-dictionary.json
       │
       ▼
  gen_distill_gemini.py + corrected-dictionary → training-data.jsonl
       │
       ▼
  ┌──── autoresearch loop（本目录）─────┐
  │   propose → run_experiment.sh → keep/discard → next     │
  │   收敛后选 best pass_rate 的 adapter                     │
  └─────────────────────────────────────────────────────────┘
       │
       ▼
  deploy_model.sh → ollama we-polish 替换
```

## 与 KPI 测试单元（线 2）的关系

**完全独立**。autoresearch 用的是**训练数据的 holdout split**做内部评估（看模型有没有学好）。
KPI 测试单元用的是**用户视角的真实音频测试集**做端到端打分（看用户体验有没有改善）。
最佳 adapter 上线后，KPI 测试自然会在下次月度运行时反映改善。
