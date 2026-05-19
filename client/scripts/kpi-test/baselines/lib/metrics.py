"""KPI §3.2 L4 五项基线指标的计算。

严格按 PDF 原文计算，无主观调整。每个函数对应一项基线。

中文规范化：去除前后空白；保留标点（PDF 没说去标点，严格字面看带标点更安全）。
分词：jieba（中文 WER 必须先分词，否则会按字符=CER）。
"""

from __future__ import annotations
import re
from typing import List


# ============================================================
# 工具
# ============================================================

def _normalize(text: str) -> str:
    """轻度归一化：trim + 折叠多空格。不动标点、不动大小写、不动数字。
    严格模式：测试集 ground_truth 怎么标，hyp 也应该长这样。
    """
    return re.sub(r"\s+", " ", text.strip())


def _tokenize_zh(text: str) -> List[str]:
    """中文分词。优先 jieba；失败时退化为字符级（等价 CER）。"""
    try:
        import jieba
        return [tok for tok in jieba.lcut(text) if tok.strip()]
    except ImportError:
        # 字符级降级（WER 数值会等于 CER，不影响逻辑但精度变化）
        return [c for c in text if not c.isspace()]


def _edit_distance(a: List, b: List) -> int:
    """Levenshtein 编辑距离（token 序列）。"""
    if not a:
        return len(b)
    if not b:
        return len(a)
    dp = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        prev = dp[0]
        dp[0] = i
        for j, cb in enumerate(b, 1):
            cur = dp[j]
            cost = 0 if ca == cb else 1
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + cost)
            prev = cur
    return dp[-1]


# ============================================================
# 字 / 词错率
# ============================================================

def cer(reference: str, hypothesis: str) -> float:
    """字错率 (Character Error Rate)。
    范围 [0, +∞)；正常情况 [0, 1]，hyp 极长时可能 > 1。"""
    ref = _normalize(reference)
    hyp = _normalize(hypothesis)
    ref_chars = [c for c in ref if not c.isspace()]
    hyp_chars = [c for c in hyp if not c.isspace()]
    if not ref_chars:
        return 0.0 if not hyp_chars else 1.0
    return _edit_distance(ref_chars, hyp_chars) / len(ref_chars)


def wer(reference: str, hypothesis: str) -> float:
    """词错率 (Word Error Rate)。中文用 jieba 分词。
    PDF §3.2 L4 字面要求 WER；中文行业惯例同时报 CER，可两个都给。"""
    ref_tokens = _tokenize_zh(_normalize(reference))
    hyp_tokens = _tokenize_zh(_normalize(hypothesis))
    if not ref_tokens:
        return 0.0 if not hyp_tokens else 1.0
    return _edit_distance(ref_tokens, hyp_tokens) / len(ref_tokens)


# ============================================================
# §3.2 L4 ① 短句指令准确率（< 30 字）
# ============================================================

def is_completely_correct(reference: str, hypothesis: str) -> bool:
    """"完全识别正确"判定。
    严格：归一化后字符级完全相等（含标点）。
    若需要宽松（去标点 / 数字归一化等），需要 KPI 评定时另行声明。
    """
    return _normalize(reference) == _normalize(hypothesis)


def short_command_accuracy(samples: List[tuple[str, str]]) -> float:
    """传入 [(gt, hyp), ...]，返回完全正确率 [0, 1]。
    KPI 报告时 ×100% 显示为百分比。
    """
    if not samples:
        return 0.0
    correct = sum(1 for gt, hyp in samples if is_completely_correct(gt, hyp))
    return correct / len(samples)


# ============================================================
# §3.2 L4 ③ 长句完整保留率（≥ 100 字）
# ============================================================

def retention_rate(reference: str, hypothesis: str) -> float:
    """转写字数 / 原文字数。
    PDF §3.2 L4 ③ 原文："转写字数 / 原文字数（多次平均），且 WER < 15%"。
    本函数只算字数比，"多次平均"和 WER 门槛由调用方处理。
    """
    ref_chars = [c for c in _normalize(reference) if not c.isspace()]
    hyp_chars = [c for c in _normalize(hypothesis) if not c.isspace()]
    if not ref_chars:
        return 1.0 if not hyp_chars else float("inf")
    return len(hyp_chars) / len(ref_chars)


# ============================================================
# §3.2 L4 ④ 会议关键事实保留率
# ============================================================

def fact_recall(key_facts: List[str], hypothesis: str) -> float:
    """关键事实保留率 = 识别到的 / 总数。
    判定：每个 fact 视作子串；做轻度归一化后，hyp 中包含 fact 的关键 token 即算识别到。
    严格做法：先精确子串匹配，再降级到分词级 fuzzy。
    """
    if not key_facts:
        return 0.0
    hyp_norm = _normalize(hypothesis)
    hits = 0
    for fact in key_facts:
        fact_norm = _normalize(fact)
        # 第一档：直接子串匹配
        if fact_norm in hyp_norm:
            hits += 1
            continue
        # 第二档：去标点 + 空格后子串匹配
        f_strip = re.sub(r"[^\w]", "", fact_norm)
        h_strip = re.sub(r"[^\w]", "", hyp_norm)
        if f_strip and f_strip in h_strip:
            hits += 1
    return hits / len(key_facts)


# ============================================================
# CLI 自测
# ============================================================
if __name__ == "__main__":
    # 简单 sanity check
    assert is_completely_correct("打开 Claude Code", "打开 Claude Code")
    assert not is_completely_correct("打开 Claude Code", "打开 Cloudcode")
    assert cer("打开", "打开") == 0.0
    assert cer("打开", "打卡") == 0.5  # 1 替换 / 2 字
    assert 0.0 < wer("打开 Claude Code", "打开 Cloudcode") <= 1.0
    assert retention_rate("一二三四五六七八九十", "一二三四五") == 0.5
    assert fact_recall(["A", "B", "C"], "包含 A 和 C，但漏了") == 2 / 3
    print("metrics.py sanity check passed")
