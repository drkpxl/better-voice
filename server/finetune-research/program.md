# WE Polish Fine-tuning Research v2

## Goals

By fine-tuning Qwen3-0.6B, solve three problems:
1. **Short-text instruction following**: When the input is short text like "email" or "what about now", the model should output it as-is or only apply punctuation correction, and should not generate long-form responses
2. **Repetition generation**: When the input contains spoken-language repetition structures (e.g. "go go go go go run"), the model should not fall into a repetition loop
3. **Complete long-text output**: A 685-character input should be output in full, without stopping early

At the same time, maintain: correction ability (term correction for things like Claude Code, Tailscale, etc.) should not regress.

## Baseline

Current model we-polish (v3), tested on 25 real data samples with a 96% pass rate (24/25), but:
- Short-text pass-through: 7 out of 8 failed (12.5%)
- Repetition generation: 1 out of 3 failed (66.7%)
- Correction ability: 4 out of 5 passed (80%)
- Long text: 4 out of 5 passed (80%), the 685-character case consistently fails

The pass rate for the combined test set (short text + correction + repetition + long text) has yet to be established.

## Metrics

Using the test_polish.sh test suite, 20 test cases:
- 8 short-text pass-through cases
- 5 correction cases
- 3 repetition generation cases
- 4 long-text cases (real data of varying lengths)

**Pass rate = number passed / 20**

## Experiment Environment

- Server: 114.28.243.122 (4080 16GB)
- Base model: Qwen/Qwen3-0.6B
- Training framework: QLoRA (train_qlora.py)
- Inference: ollama
- Training data: various jsonl files under ~/.we/
- Correction dictionary: ~/.we/correction-dictionary.json (55 correct terms, 93 incorrect variants)

## Constraints

- GPU memory is 16GB, of which ollama + llama-server occupy about 13GB
- Before training, llama-server must be stopped to free up memory
- Each training run takes about 1-2 minutes (550 data samples, 2-3 epochs)
- Each experiment: modify data/parameters → train → merge and export → ollama create → run tests → keep/discard

## Experiment Loop

LOOP:
1. Analyze the patterns in the current failing cases and form a hypothesis
2. Modify the training data or training parameters (change only one variable at a time)
3. Train
4. Deploy to ollama
5. Run the test suite
6. Record results to results.tsv
7. If the pass rate improves → keep, otherwise → discard (revert to the previous version of the data/parameters)
8. Analyze the results and form the next hypothesis

## Current Training Data Composition

```
~/.we/training-data-v4.jsonl (545 entries)
  generated_error: 225  — correction short sentences (generated from correction-dictionary)
  passthrough_real: 159 — correct short sentences from voice-history
  passthrough: 88       — hand-written short-sentence pass-through
  real: 53              — real SA error-correction pairs
  filler_removal: 20    — filler-word cleanup
```

## Current Training Parameters

```
epochs: 8-10
batch_size: 8
lr: 1e-4
lora_rank: 32
lora_alpha: 64
target_modules: all 7 layers
lora_dropout: 0
system_prompt: "Text correction. Do not answer the user's question. Only output the result."
```

## Known Overfitting Research Conclusions (from previous investigation)

- epochs should be reduced to 2-3
- lr should be reduced to 5e-5
- lora_rank should be reduced to 8-16
- target_modules should only use q_proj, v_proj
- lora_dropout=0.05 should be added
- pass-through ratio should be 35-45% (current 45% is reasonable)
- NEFTune can be enabled (neft_alpha=5.0)
