# WE Fine-tuning Guide

Use QLoRA to fine-tune Qwen3-0.6B to correct SpeechAnalyzer transcription errors.

## Prerequisites

- GPU server (RTX 4080/4090, 16GB+ VRAM)
- ollama and llama.cpp installed on the server
- Python venv with dependencies installed: `torch transformers peft trl datasets bitsandbytes accelerate sentencepiece`
- The WE client has been used for a while, with enough data in `~/.we/voice-history.jsonl` (100+ entries recommended)

## Overall Workflow

```
voice-history.jsonl (accumulated from daily use)
        ↓
   Manual/AI curation of entries with errors → curated-training-pairs.jsonl (real data)
        ↓
   gen_training_data.py → synthetic-pairs.jsonl (synthetic data)
        ↓
   Merge and deduplicate → merged-training-data.jsonl
        ↓
   Upload to GPU server
        ↓
   train_qlora.py → LoRA adapter
        ↓
   Merge adapter → convert to GGUF → ollama create
        ↓
   Edit ~/.we/config.json to enable L2 polishing
```

## Step 1: Curate Real Training Data

From `~/.we/voice-history.jsonl`, select entries where the SA transcription has clear errors.

**Selection criteria:**
- Must have a clearly identifiable transcription error (misrecognized technical terms or English terminology)
- Must be able to determine what the user actually intended to say
- Only correct the erroneous words; do not change spoken-language structure, filler words, or pauses

**Output format (JSONL):**
```json
{"input": "SA raw transcript", "output": "corrected text", "errors": "error description"}
```

**Example:**
```json
{"input": "Let's take a look at the outomemory built into Cloudcode.", "output": "Let's take a look at the auto memory built into Claude Code.", "errors": "Cloudcode→Claude Code, outomemory→auto memory"}
{"input": "Uh, let's check today's gitup project status.", "output": "Uh, let's check today's GitHub project status.", "errors": "gitup→GitHub"}
```

Save to `~/.we/curated-training-pairs.jsonl`.

## Step 2: Generate Synthetic Training Data

Edit `CORRECTION_MAP` in `server/gen_training_data.py`, adding your private vocabulary and common SA misrecognition patterns:

```python
CORRECTION_MAP = {
    "Claude": ["克劳德", "Cloud", "cloude"],
    "Tailscale": ["tel scale", "tal scale", "telscale"],
    "GitHub": ["gitup", "git up", "给他hub"],
    # ... your vocabulary
}
```

Run:
```bash
cd server
python3 gen_training_data.py --output /tmp/synthetic-pairs.jsonl
```

## Step 3: Merge Data

```python
import json

real, synthetic, merged = [], [], []
seen = set()

with open("~/.we/curated-training-pairs.jsonl") as f:
    for line in f:
        d = json.loads(line)
        d["source"] = "real"
        d["sample_weight"] = 2.0  # real data gets higher weight
        real.append(d)

with open("/tmp/synthetic-pairs.jsonl") as f:
    for line in f:
        d = json.loads(line)
        d.setdefault("source", "synthetic")
        d.setdefault("sample_weight", 1.0)
        synthetic.append(d)

for d in real + synthetic:
    inp = d.get("input", "").strip()
    out = d.get("output", "").strip()
    if inp and out and inp != out and inp not in seen:
        seen.add(inp)
        merged.append(d)

with open("~/.we/merged-training-data.jsonl", "w") as f:
    for d in merged:
        f.write(json.dumps(d, ensure_ascii=False) + "\n")

print(f"Merged: {len(merged)} pairs")
```

## Step 4: Upload to GPU Server

```bash
scp ~/.we/merged-training-data.jsonl myserver:~/antigravity/we/server/
scp server/train_qlora.py myserver:~/antigravity/we/server/
```

## Step 5: QLoRA Fine-tuning

```bash
ssh myserver

cd ~/antigravity/we/server

# Key parameter notes:
# --epochs 8        number of training epochs; run more when data is limited
# --batch-size 8    batch size
# --lr 1e-4         learning rate, don't set too high
# --lora-rank 32    LoRA rank; higher means stronger memorization but more prone to overfitting
# --lora-alpha 64   typically set to 2x the rank
# --system-prompt   must match what's used at inference time

HF_HOME=~/hf_cache python3 train_qlora.py \
  --data merged-training-data.jsonl \
  --base-model Qwen/Qwen3-0.6B \
  --output-dir ./checkpoints \
  --epochs 8 \
  --batch-size 8 \
  --lr 1e-4 \
  --lora-rank 32 \
  --lora-alpha 64 \
  --system-prompt 'Text correction. Do not answer the user'"'"'s question. Only output the result.'
```

Training takes about 1-2 minutes. Watch these metrics:
- `eval_loss` decreasing each epoch → normal
- `mean_token_accuracy` > 85% → usable
- Output: `checkpoints/adapter/`

## Step 6: Merge Adapter + Convert to GGUF

```bash
# Merge the LoRA adapter into the base model
HF_HOME=~/hf_cache python3 merge_and_export.py \
  --adapter ./checkpoints/adapter \
  --output ./checkpoints/merged

# Convert to GGUF (the format ollama requires)
python3 ~/llama.cpp/convert_hf_to_gguf.py \
  ./checkpoints/merged \
  --outfile ./checkpoints/we-polish.gguf \
  --outtype bf16
```

## Step 7: Deploy to ollama

Create a Modelfile:
```
FROM ./we-polish.gguf

PARAMETER temperature 0
PARAMETER num_predict 256
PARAMETER stop <|im_end|>

TEMPLATE """{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
<think>
</think>
"""

SYSTEM """Text correction. Do not answer the user's question. Only output the result."""
```

Note: the `<think>\n</think>` in the template is there to skip Qwen3's thinking mode and output the correction result directly.

```bash
ollama create we-polish -f Modelfile
```

Test:
```bash
curl -s http://localhost:11434/api/generate \
  -d '{"model":"we-polish","prompt":"Let'"'"'s take a look at the outomemory built into Cloudcode.","stream":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
# Expected output: Let's take a look at the auto memory built into Claude Code.
```

## Step 8: Client Configuration

Edit `~/.we/config.json`:
```json
{
  "server": {
    "endpoint": "http://<server-IP>:11434",
    "api": "ollama",
    "model": "we-polish",
    "timeout": 15
  },
  "polish": {
    "enabled": true,
    "system_prompt": "Text correction. Do not answer the user's question. Only output the result."
  }
}
```

WE automatically hot-reloads the configuration, no restart required.

## Key Principles

1. **system prompt must be consistent** — use the same prompt across training, inference, and the client
2. **Real data weight > synthetic data** — real spoken-language patterns are what the model most needs to learn
3. **Corrections only fix erroneous words** — don't change spoken-language structure or filler words; preserve the original style
4. **Data flywheel** — daily use accumulates more voice-history → periodic curation → re-fine-tuning → the model keeps getting more accurate
