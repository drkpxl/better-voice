# Better Voice — KPI Automated Testing Framework

Automated testing + monthly report generation, based strictly on the milestone/baseline metrics defined in the "Marvin Personal Performance Incentive Plan" PDF (`~/.claude/skills/marvin-kpi/references/kpi-plan.md`).

---

## 0. Core Methodology: User Perspective + Full Pipeline

**All tests are based on actual user usage scenarios, running the full pipeline end-to-end, with no partial mocking**.

| Wrong Approach ❌ | Correct Approach ✅ |
|---|---|
| Testing SA transcription quality in isolation | Testing the end-to-end `finalText` of `hotkey press → SA → L1 → L2 → cursor injection` |
| Using synthetic/read-aloud audio as the test set | Using audio from real usage scenarios (natural speech rate, pauses, accents, terminology) |
| ground truth = verbatim syllable-by-syllable transcript | ground truth = the text the user expects to appear at the cursor (post-correction, filler words removed, with punctuation) |
| Testing that RemoteInbox receives an HTTP 200 | Testing that text actually appears at the Mac cursor when speaking on Windows |
| Testing the L2 model's prompt in isolation | Testing the WER / completeness of finalText across the full pipeline |

**Rationale**: The KPI §3.2 continuous-improvement scoring reflects "improvement in the user's actual experience," not any intermediate-stage metric. Intermediate metrics can only serve as diagnostic aids — they cannot replace end-to-end measurement from the user's perspective.

---

## 1. Framework Structure

```
kpi-test/
├── milestones/          §3.1 milestone layer — binary output (pass/fail → completion coefficient)
├── baselines/           §3.2 baseline layer — continuous output (number → improvement tier)
│   └── lib/             shared helper library (transcribe / metrics / manifest / report)
├── data/                test sets (not committed to git, see §3)
└── results/             test results (committed to git, KPI retained evidence)
    └── YYYY-MM-end/     one directory per month (end-of-month-1 / end-of-month-2 archived separately)
```

---

## 2. KPI Items → Script Mapping

### Milestone Layer (Phase 1)

| KPI Clause | Completion Criteria (PDF original text) | Script |
|---|---|---|
| §3.1 L4 #11 ① | Voice input → transcription → text output | `milestones/m11_voice_e2e.sh` |
| §3.1 L4 #11 ② | Meeting mode can record and transcribe | `milestones/m11_meeting.sh` |
| §3.1 L4 #11 ③ | Cross-network transmission works | `milestones/m11_remote.sh` |

> The §3.1 L2 #7 milestones (auto-build mis-recognized word list, automatic
> fine-tuning, output report) were removed along with the self-training pipeline.
> Personalization is now handled by `~/.better-voice/personal-context.md` injected into the
> polish prompt (see `docs/configuration.md`).

Each script outputs `{status: pass|partial|fail, score: 1.0|0.7|0, evidence: ...}`.
Corresponds to the §2.1 completion coefficient: complete 1.0 / partially complete (≥70%) 0.7 / not achieved 0.

### Baseline Layer (Phase 1, Five L4 Items — Directly Relevant to Better Voice)

| KPI Clause | Calculation Method (PDF original text) | Script |
|---|---|---|
| §3.2 L4 ① | 100-item short-command test set; number of fully correctly recognized items / 100 × 100% | `baselines/short_command_accuracy.sh` |
| §3.2 L4 ② | 100-item medium-length test set; overall WER | `baselines/medium_wer.sh` |
| §3.2 L4 ③ | 50 long passages; transcribed character count / original character count (averaged over multiple runs), with WER < 15% | `baselines/long_retention.sh` |
| §3.2 L4 ④ | Meeting test set pre-annotated with 20 key facts; facts recognized / 20 × 100% | `baselines/meeting_facts.sh` |
| §3.2 L4 ⑤ | Standard WER measurement | `baselines/meeting_wer.sh` |

---

## 3. Test Set Requirements

Per the §0 methodology, the test set must satisfy:

1. **Real usage scenarios**: natural speech rate, natural pauses, the user's actual vocabulary (including project terminology: Claude Code / Tailscale / distillation / Ghostty, etc.)
2. **Ground truth is the text the user expects**: not a syllable-by-syllable transcript. Includes punctuation, filler words removed, technical terms spelled correctly
3. **Recorded in an isolated environment**: to avoid uncontrolled environmental noise affecting test results
4. **Use the same test set for every re-test**: only then can improvement be measured (§2.4)

Test set distribution (per the PDF §3.2 L4 word-count requirements):

- `data/short/`: 100 items, < 30 characters (mostly short commands, e.g. "Open Ghostty", "Check today's GitHub project status")
- `data/medium/`: 100 items, 30-100 characters (paragraph-level)
- `data/long/`: 50 items, ≥ 100 characters (long-form narration)
- `data/meeting/`: meeting recordings + 20 key-fact annotations

Each directory's `manifest.jsonl` describes the test set:

```jsonl
{"id": "001", "audio": "audio/001.wav", "ground_truth": "打开 Claude Code", "len": 6}
{"id": "002", "audio": "audio/002.wav", "ground_truth": "看一下今天的 GitHub 项目状态", "len": 13}
```

**Test sets are not committed to git** (audio files are large); excluded via `.gitignore`.

---

## 4. Re-testing Process (§2.4)

Two data points per phase:

```bash
# End of month 1 (initial value, before 2026-05-31)
./run_kpi.sh --phase month1

# End of month 2 (final value, before 2026-06-30)
./run_kpi.sh --phase month2

# Continuous improvement scoring (calculated automatically)
python3 baselines/lib/report.py --compare month1 month2
```

Outputs `results/<phase>-end/kpi-report.md`.

Per §2.2 Phase 1 tiers (based on trend):

- Tier A: improvement ≥ 20% → 100 points
- Tier B: 5%-20% → 70 points
- Tier C: < 5% → 40 points
- Tier D: not recorded or regressed → 0 points

---

## 5. Relationship to Existing Better Voice Code

**Reused**:

- `BetterVoice --bench-meeting <wav>` — existing entry point for running meeting mode end-to-end
- `client/scripts/kpi-test/baselines/` — transcription/diarization/retention quality baselines

**New**:

- `client/scripts/kpi-test/` — this framework

Does not rewrite existing functionality; this framework only does "KPI-perspective wrapping + test set organization + report generation."

**Note**: `--bench-voice`, `--bench-meeting`, `--test-alternatives`, `--test-context-capacity`, and `--test-truncation` are compiled only into debug builds (`BENCH` define, active when `configuration == .debug`) so they don't ship in the release binary. Build with a plain `swift build` (what `client && make build` already does) — a release build (`swift build -c release`) won't recognize these flags.

---

## 6. KPI Section Quick Reference

- §2.1 Milestone scoring formula: priority level × completion coefficient × time coefficient
- §2.2 Continuous improvement tiers: A/B/C/D
- §2.4 Baseline recording timing: end-of-month-1 initial value + end-of-month-2 final value
- §3.1 Phase 1 infrastructure milestones (5 layers, 23 items)
- §3.2 Phase 1 engineering baselines (21 items)
- §4.1 Phase 2 milestones / §4.2 Phase 2 goals
- §5.1 Phase 3 milestones / §5.2 Phase 3 user evaluation
