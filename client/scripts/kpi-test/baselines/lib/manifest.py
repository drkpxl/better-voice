"""测试集 manifest 加载工具。

manifest.jsonl 统一 schema（每行一条）：
    {
      "id": "001",
      "audio": "audio/001.wav",       相对路径，相对 manifest 所在目录
      "ground_truth": "用户期望光标处出现的文字",
      "len": 6,                        ground_truth 字符数（中文按字符）
      "category": "command|sentence|long|meeting"
    }

meeting 测试集额外要求：
    {
      "id": "m001",
      "audio": "session-1.wav",
      "ground_truth": "完整会议参考稿",
      "key_facts": [                   §3.2 L4 ④ 预标注 20 个关键事实
        "项目 deadline 是 2026-06-30",
        "Marvin 负责微调管线",
        ...
      ]
    }
"""

import json
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class TestSample:
    id: str
    audio_path: Path           # 绝对路径（manifest 加载后已展开）
    ground_truth: str
    length: int                # 字符数
    category: str = "general"
    key_facts: Optional[List[str]] = None    # 仅 meeting 子集有


def load_manifest(manifest_path: str | Path) -> List[TestSample]:
    """加载 manifest.jsonl，返回 TestSample 列表。

    校验项：
    - 每条必须有 id / audio / ground_truth
    - audio 文件必须存在
    - ground_truth 不能为空
    """
    manifest_path = Path(manifest_path).resolve()
    base_dir = manifest_path.parent
    samples: List[TestSample] = []

    if not manifest_path.exists():
        raise FileNotFoundError(f"manifest not found: {manifest_path}")

    with manifest_path.open() as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                raise ValueError(f"{manifest_path}:{line_no} invalid JSON: {e}")

            for required in ("id", "audio", "ground_truth"):
                if required not in obj:
                    raise ValueError(f"{manifest_path}:{line_no} missing '{required}'")

            audio_path = (base_dir / obj["audio"]).resolve()
            if not audio_path.exists():
                raise FileNotFoundError(f"{manifest_path}:{line_no} audio missing: {audio_path}")

            gt = obj["ground_truth"]
            if not gt:
                raise ValueError(f"{manifest_path}:{line_no} empty ground_truth")

            samples.append(TestSample(
                id=obj["id"],
                audio_path=audio_path,
                ground_truth=gt,
                length=obj.get("len", len(gt)),
                category=obj.get("category", "general"),
                key_facts=obj.get("key_facts"),
            ))

    return samples


if __name__ == "__main__":
    # CLI 自测：python3 manifest.py <manifest.jsonl>
    import sys
    if len(sys.argv) != 2:
        print("Usage: manifest.py <manifest.jsonl>")
        sys.exit(1)
    samples = load_manifest(sys.argv[1])
    print(f"Loaded {len(samples)} samples")
    for s in samples[:3]:
        print(f"  {s.id} ({s.length}字): {s.ground_truth[:40]}")
    if len(samples) > 3:
        print(f"  ... + {len(samples) - 3} more")
