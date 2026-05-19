"""WE 数据目录路径中心管理（服务端 Python 侧）。

与 client/Sources/WEDataDir.swift 对应。所有访问 ~/.we/ 的 server 脚本应 import 本模块：

    from lib.paths import (
        WE_DATA_DIR,
        VOICE_HISTORY,
        CORRECTION_DICTIONARY,
        ARCHIVE_DICTIONARIES,
        ...
    )

环境变量覆盖：

    WE_DATA_DIR=/tmp/we-test python3 build_dictionary.py
        # 数据根目录被覆盖到 /tmp/we-test/

这样可以做沙箱测试，不污染用户的真实 ~/.we/。
"""

from __future__ import annotations
import os
from pathlib import Path


# ============================================================
# 根目录（可被 WE_DATA_DIR env 覆盖）
# ============================================================

WE_DATA_DIR: Path = Path(
    os.environ.get("WE_DATA_DIR", Path.home() / ".we")
).expanduser().resolve()


# ============================================================
# 活跃文件 / 目录（client/Sources/WEDataDir.swift 中对应）
# ============================================================

CONFIG               = WE_DATA_DIR / "config.json"
LOG                  = WE_DATA_DIR / "debug.log"

VOICE_HISTORY        = WE_DATA_DIR / "voice-history.jsonl"
MEETING_HISTORY      = WE_DATA_DIR / "meeting-history.jsonl"
CORRECTIONS          = WE_DATA_DIR / "corrections.jsonl"

CORRECTION_DICTIONARY = WE_DATA_DIR / "correction-dictionary.json"
# README 文档化的 SA contextualStrings 简单数组用
CONTEXTUAL_DICTIONARY = WE_DATA_DIR / "dictionary.json"

AUDIO                = WE_DATA_DIR / "audio"
MEETINGS             = WE_DATA_DIR / "meetings"
MODELS               = WE_DATA_DIR / "models"
KPI                  = WE_DATA_DIR / "kpi"


# ============================================================
# 归档子目录（Phase B 规划）
# ============================================================

ARCHIVE                    = WE_DATA_DIR / "archive"
ARCHIVE_DICTIONARIES       = ARCHIVE / "dictionaries"
ARCHIVE_TRAINING_SNAPSHOTS = ARCHIVE / "training-snapshots"
ARCHIVE_TEST_SETS          = ARCHIVE / "test-sets"
ARCHIVE_REPORTS            = ARCHIVE / "reports"


# ============================================================
# 中间产物（dictionary 构建期）
# ============================================================

DICTIONARY_AUTO   = WE_DATA_DIR / "dictionary.auto.json"
DICTIONARY_REVIEW = WE_DATA_DIR / "dictionary-review.md"


# ============================================================
# 便捷函数
# ============================================================

def ensure_dirs() -> None:
    """确保所有活跃 + 归档子目录存在。"""
    for d in [
        WE_DATA_DIR, AUDIO, MEETINGS, MODELS, KPI,
        ARCHIVE, ARCHIVE_DICTIONARIES, ARCHIVE_TRAINING_SNAPSHOTS,
        ARCHIVE_TEST_SETS, ARCHIVE_REPORTS,
    ]:
        d.mkdir(parents=True, exist_ok=True)


if __name__ == "__main__":
    # 自检：打印所有路径，方便确认 WE_DATA_DIR 覆盖是否生效
    import json
    print(json.dumps({
        "root": str(WE_DATA_DIR),
        "voice_history": str(VOICE_HISTORY),
        "correction_dictionary": str(CORRECTION_DICTIONARY),
        "audio": str(AUDIO),
        "archive": str(ARCHIVE),
    }, indent=2))
