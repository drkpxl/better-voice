# WE — KPI 自动化测试框架

按《Marvin 个人考核激励方案》PDF（`~/.claude/skills/marvin-kpi/references/kpi-plan.md`）严格定义的里程碑/基线指标，做自动化测试 + 月度报告产出。

---

## 0. 核心方法学：用户视角 + 全链路

**所有测试都以用户实际使用场景为准，跑完整链路，不局部 mock**。

| 错误做法 ❌ | 正确做法 ✅ |
|---|---|
| 单独测 SA 转写质量 | 测 `按热键 → SA → L1 → L2 → 注入光标` 的端到端 `finalText` |
| 用合成/朗读式音频做测试集 | 用真实使用场景音频（自然语速、停顿、口音、术语）|
| ground truth = 逐字音节稿 | ground truth = 用户期望光标处出现的文字（纠错后、去语气词、含标点）|
| 测 RemoteInbox 收到 HTTP 200 | 测 Windows 说话 → Mac 光标处真的出现文字 |
| 单独测 L2 模型的 prompt | 测完整管线下 finalText 的 WER / 完整度 |

**理由**：KPI §3.2 持续改善赋分反映的是"用户实际体验的改善"，不是任何中间环节的指标。中间环节的指标只能作为诊断辅助，不能替代用户视角的端到端测量。

---

## 1. 框架结构

```
kpi-test/
├── milestones/          §3.1 里程碑层 — binary 输出（pass/fail → 完成度系数）
├── baselines/           §3.2 基线层 — continuous 输出（数字 → 改善幅度档位）
│   └── lib/             共享辅助库（transcribe / metrics / manifest / report）
├── data/                测试集（不进 git，详见 §3）
└── results/             测试结果（进 git，KPI 留存证据）
    └── YYYY-MM-end/     每月一目录（月 1 末 / 月 2 末分别归档）
```

---

## 2. KPI 条目 → 脚本映射

### 里程碑层（一期）

| KPI 条款 | 完成标准（PDF 原文）| 脚本 |
|---|---|---|
| §3.1 L4 #11 ① | 录入语音 → 转写 → 输出文字 | `milestones/m11_voice_e2e.sh` |
| §3.1 L4 #11 ② | 会议模式可录可转 | `milestones/m11_meeting.sh` |
| §3.1 L4 #11 ③ | 跨网传输可用 | `milestones/m11_remote.sh` |
| §3.1 L2 #7 ① | 自动构建错词表 | `milestones/m7_dict_build.sh` |
| §3.1 L2 #7 ② | 自动微调 | `milestones/m7_finetune.sh` |
| §3.1 L2 #7 ③ | 输出报告 | `milestones/m7_report.sh` |

每个脚本输出 `{status: pass|partial|fail, score: 1.0|0.7|0, evidence: ...}`。
对应 §2.1 完成度系数：完成 1.0 / 部分完成（≥70%）0.7 / 未达 0。

### 基线层（一期 L4 五项 — WE 直接相关）

| KPI 条款 | 计算方式（PDF 原文）| 脚本 |
|---|---|---|
| §3.2 L4 ① | 100 条短指令测试集，完全识别正确条数 / 100 × 100% | `baselines/short_command_accuracy.sh` |
| §3.2 L4 ② | 100 条中等长度测试集，整体 WER | `baselines/medium_wer.sh` |
| §3.2 L4 ③ | 50 条长段，转写字数 / 原文字数（多次平均），且 WER < 15% | `baselines/long_retention.sh` |
| §3.2 L4 ④ | 会议测试集预标注 20 个关键事实，识别到的 / 20 × 100% | `baselines/meeting_facts.sh` |
| §3.2 L4 ⑤ | 标准 WER 测量 | `baselines/meeting_wer.sh` |

---

## 3. 测试集要求

按 §0 方法学，测试集必须满足：

1. **真实使用场景**：自然语速、自然停顿、用户实际词汇（含项目术语：Claude Code / Tailscale / 蒸馏 / Ghostty 等）
2. **ground truth 是用户期望文字**：不是音节逐字稿。包含标点、去语气词、技术词正确拼写
3. **隔离环境录制**：避免环境噪声不可控影响测试结果
4. **每次复测用同一份测试集**：才能算改善（§2.4）

测试集分布（按 PDF §3.2 L4 字数要求）：

- `data/short/`：100 条 < 30 字（短指令为主，如"打开 Ghostty"、"看一下今天的 GitHub 项目状态"）
- `data/medium/`：100 条 30-100 字（一段话级别）
- `data/long/`：50 条 ≥ 100 字（长论述）
- `data/meeting/`：会议录音 + 20 个关键事实标注

每个目录下 `manifest.jsonl` 描述测试集：

```jsonl
{"id": "001", "audio": "audio/001.wav", "ground_truth": "打开 Claude Code", "len": 6}
{"id": "002", "audio": "audio/002.wav", "ground_truth": "看一下今天的 GitHub 项目状态", "len": 13}
```

**测试集不进 git**（音频文件大），用 `.gitignore` 排除。

---

## 4. 复测流程（§2.4）

每期 2 个数据点：

```bash
# 月 1 末（初始值，2026-05-31 前）
./run_kpi.sh --phase month1

# 月 2 末（末值，2026-06-30 前）
./run_kpi.sh --phase month2

# 持续改善赋分（自动算）
python3 baselines/lib/report.py --compare month1 month2
```

输出 `results/<phase>-end/kpi-report.md`。

按 §2.2 一期档位（看趋势）：

- A 档：改善 ≥ 20% → 100 分
- B 档：5%-20% → 70 分
- C 档：< 5% → 40 分
- D 档：未记录或退步 → 0 分

---

## 5. 与现有 WE 代码的关系

**复用**：

- `WE --bench-meeting <wav>` — 会议模式端到端跑通的现成入口
- `server/eval_model.py` — L2 模型评估
- `server/eval/benchmarks/run_transcription.sh` — 转写 benchmark 基础设施
- `server/scripts/run_pipeline.sh` — 微调一键流水线

**新增**：

- `server/build_dictionary.py` — 自动构建错词表（填补 §3.1 L2 #7 ① 缺失）
- `client/scripts/kpi-test/` — 本框架

不重写现有功能；本框架只做"按 KPI 视角包装 + 测试集组织 + 报告生成"。

---

## 6. KPI 章节速查

- §2.1 里程碑赋分公式：重点等级 × 完成度系数 × 时间系数
- §2.2 持续改善档位：A/B/C/D
- §2.4 基线记录时机：月 1 末初始 + 月 2 末末值
- §3.1 一期基建里程碑（5 层 23 项）
- §3.2 一期工程基线（21 项）
- §4.1 二期里程碑 / §4.2 二期目标
- §5.1 三期里程碑 / §5.2 三期用户评估
