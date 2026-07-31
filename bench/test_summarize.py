"""Tests for the summarization runner, matching the other bench tests' plain-stdlib style.

Guards the one thing that silently invalidates every summarization number: prompt drift.
`summarize.py` hard-codes the summarization prompts so the bench sends byte-identical instructions to
what the app sends. Nothing enforces that by construction, so if `Prompts.swift` is edited and this
copy is not, the bench keeps reporting numbers for a pipeline that no longer exists. These tests
extract the prompts back out of the Swift source and compare.

Run: python3 bench/test_summarize.py
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import summarize as s  # noqa: E402

PROMPTS_SWIFT = Path(__file__).resolve().parent.parent / "client/Sources/Prompts.swift"

FAILURES: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def check_true(label: str, cond: bool, note: str = "") -> None:
    if not cond:
        FAILURES.append(f"{label}{(' — ' + note) if note else ''}")


def _decode_multiline(body: str, closing_indent: str) -> str:
    """Apply Swift's two multiline-literal rules to a raw `\"\"\"` body.

    1. Indentation equal to the CLOSING delimiter's indentation is stripped from every line. Missing
       this was the first bug in this test: the extracted text kept the source's 4-space indent and
       every prompt looked drifted when none of them were.
    2. A trailing `\\` before a newline is a line continuation that removes the newline -- that is how
       the source wraps long rules.

    Dedent runs first, because a continuation join would otherwise glue the next line's indentation
    into the middle of a sentence.
    """
    if closing_indent:
        body = "\n".join(
            ln[len(closing_indent):] if ln.startswith(closing_indent) else ln.lstrip()
            for ln in body.split("\n")
        )
    return re.sub(r"\\\n", "", body).strip()


def swift_literal(name: str) -> str:
    """Extract `static let <name> = \"\"\"...\"\"\"` from Prompts.swift as its runtime value.

    `\\(interp)` is left in place for the caller to substitute.
    """
    src = PROMPTS_SWIFT.read_text()
    m = re.search(rf'static let {re.escape(name)} = """\n(.*?)\n([ \t]*)"""', src, re.S)
    if not m:
        FAILURES.append(f"could not find `static let {name}` in {PROMPTS_SWIFT}")
        return ""
    return _decode_multiline(m.group(1), m.group(2))


def common_rules() -> str:
    src = PROMPTS_SWIFT.read_text()
    m = re.search(r'summarizeCommonRulesEN = """\n(.*?)\n([ \t]*)"""', src, re.S)
    if not m:
        FAILURES.append("summarizeCommonRulesEN not found in Prompts.swift")
        return ""
    return _decode_multiline(m.group(1), m.group(2))


def with_temp(content: str, name: str = "f.md"):
    d = tempfile.mkdtemp()
    p = Path(d) / name
    p.write_text(content)
    return p


# --- prompt parity with the app -------------------------------------------------------------------

def test_prompts_match_swift() -> None:
    rules = common_rules()
    for swift_name, bench_key in (
        ("summarizeGeneralEN", "general"),
        ("summarizeOneOnOneEN", "one_on_one"),
        ("summarizeStandupEN", "standup"),
    ):
        expected = swift_literal(swift_name).replace("\\(summarizeCommonRulesEN)", rules)
        check(
            f"{bench_key} prompt drifted from Prompts.swift's {swift_name} "
            "(update bench/summarize.py PROMPTS in the same commit)",
            s.PROMPTS[bench_key], expected,
        )


def test_title_instruction_matches_swift() -> None:
    check("TITLE instruction drifted from summaryTitleInstructionEN",
          s.TITLE_INSTRUCTION, swift_literal("summaryTitleInstructionEN"))


def test_common_rules_embedded_everywhere() -> None:
    rules = common_rules()
    for key, prompt in s.PROMPTS.items():
        check_true(f"{key} lost the common-rules block", rules in prompt)


# --- fittedNumCtx, mirroring OllamaBackend.fittedNumCtx -------------------------------------------

def test_num_ctx() -> None:
    orig = s.model_max_ctx
    try:
        s.model_max_ctx = lambda m: 262_144
        check("short prompt floors at the requested minimum",
              s.fitted_num_ctx("hello", "sys", 2048, 32768, "m"), 32768)

        prompt = "x" * 400_000                      # 100k tokens at chars/4
        check("long prompt grows past the floor",
              s.fitted_num_ctx(prompt, "", 2048, 32768, "m"), 400_000 // 4 + 2048 + 1024)

        s.model_max_ctx = lambda m: 1_000_000
        check("capped at 256K even when the model claims more",
              s.fitted_num_ctx("x" * 4_000_000, "", 2048, 32768, "m"), 262_144)

        # Clamping DOWN matters: without it Ollama silently drops the front of the transcript.
        s.model_max_ctx = lambda m: 8192
        check("clamped down to a small model's maximum",
              s.fitted_num_ctx("x" * 400_000, "", 2048, 32768, "m"), 8192)

        s.model_max_ctx = lambda m: None
        check("unavailable model max is ignored rather than fatal",
              s.fitted_num_ctx("hello", "", 2048, 32768, "m"), 32768)
    finally:
        s.model_max_ctx = orig


# --- vocabulary / personal context ----------------------------------------------------------------

def test_vocabulary_terms_only() -> None:
    """Replacements are deliberately withheld from the model, per vocabulary.md's own note."""
    p = with_temp("# Vocabulary\n\n## Terms\n- Summit Pass\n- Emmie\n\n"
                  "## Replacements\n- Summit Past -> Summit Pass\n", "vocabulary.md")
    block = s.vocabulary_prompt_block(p)
    check_true("terms reach the prompt", "Summit Pass" in block and "Emmie" in block)
    check_true("replacements are withheld from the prompt", "->" not in block)


def test_vocabulary_empty_without_terms() -> None:
    p = with_temp("# Vocabulary\n\n## Terms\n\n## Replacements\n- a -> b\n", "vocabulary.md")
    check("no terms yields no block", s.vocabulary_prompt_block(p), "")


def test_vocabulary_caps_at_600_chars() -> None:
    terms = "\n".join(f"- term{i:03d}" for i in range(200))
    p = with_temp(f"# Vocabulary\n\n## Terms\n{terms}\n", "vocabulary.md")
    block = s.vocabulary_prompt_block(p)
    check_true("early terms included", "term000" in block)
    check_true("terms past the 600-char cap dropped", "term199" not in block)


def test_missing_files_contribute_nothing() -> None:
    missing = Path(tempfile.mkdtemp()) / "nope.md"
    check("missing vocabulary yields no block", s.vocabulary_prompt_block(missing), "")
    check("missing personal context yields no block", s.personal_context_block(missing), "")


def test_unedited_template_is_still_injected() -> None:
    """An unedited starter template is non-empty, so the app injects it as if it were real context.

    This is the shipping bug the bake-off measured (up to 20 points of thread recall, sign depending
    on the model). The bench reproduces it deliberately. If this ever returns empty, `summarize.py`
    has stopped matching the app and the recorded numbers are no longer comparable to production.
    """
    p = with_temp("# Personal context\n\nEdit freely.\n\n## About me\n\n## People\n\n",
                  "personal-context.md")
    check_true("unedited template is injected, matching PersonalContext.load()",
               s.personal_context_block(p) != "")


# --- title parsing --------------------------------------------------------------------------------

def test_parse_title() -> None:
    title, body = s.parse_title("TITLE: Pod planning\n\n## Summary\nText.")
    check("leading TITLE captured", title, "Pod planning")
    check_true("TITLE stripped from the body", "TITLE:" not in body)
    check_true("body preserved", body.startswith("## Summary"))

    title, body = s.parse_title("## Summary\nText.")
    check("absent title yields None", title, None)
    check("body untouched when no title", body, "## Summary\nText.")

    # Only the FIRST non-empty line counts, matching `parseSummaryTitle`. A stray TITLE: anywhere
    # below it is body text, not the meeting title -- including on line two, which the old
    # five-line-scan version wrongly lifted out.
    deep = "\n".join(["## Summary"] + [f"line {i}" for i in range(10)] + ["TITLE: nope"])
    check("buried TITLE ignored", s.parse_title(deep)[0], None)
    check("TITLE on line two ignored", s.parse_title("## Summary\nTITLE: nope")[0], None)

    # Markdown-dressed titles are tolerated, because the app tolerates them (Voxtral emits the
    # heading form). Each of these must yield the bare title and leave it out of the body.
    for raw, why in [
        ("## TITLE: Pod planning\n\n## Summary\nT.", "heading form"),
        ("# TITLE: Pod planning\n\n## Summary\nT.", "single-hash form"),
        ("**TITLE:** Pod planning\n\n## Summary\nT.", "bold marker"),
        ("**TITLE: Pod planning**\n\n## Summary\nT.", "fully bolded"),
        ("title: Pod planning\n\n## Summary\nT.", "lowercase marker"),
        ("\n\n## TITLE: Pod planning\n\n## Summary\nT.", "leading blank lines"),
    ]:
        title, body = s.parse_title(raw)
        check(f"{why}: title extracted", title, "Pod planning")
        check_true(f"{why}: marker gone from body", "TITLE" not in body)
        check_true(f"{why}: body starts at Summary", body.startswith("## Summary"))

    # Interleaved asterisks and spaces must trim in one pass, as Swift's combined character set does.
    # Chained strips gave "X**" here, which is what this guards against.
    for raw, want in [
        ("TITLE: **X** *\n\n## S", "X"),
        ("TITLE: X* *\n\n## S", "X"),
        ("TITLE: X*  **\n\n## S", "X"),
        ("TITLE: *Q3* Sync\n\n## S", "Q3* Sync"),   # internal asterisk is content, not decoration
    ]:
        check(f"one-pass trim of {raw.splitlines()[0]!r}", s.parse_title(raw)[0], want)

    # Malformed variants must return the response untouched rather than eat a line.
    check("empty title yields None", s.parse_title("TITLE:\n\n## Summary\nT.")[0], None)
    check("body intact when title empty", s.parse_title("TITLE:\n\n## S\nT.")[1], "TITLE:\n\n## S\nT.")
    check("whitespace-only input", s.parse_title("   \n  ")[0], None)

    # A second blank line belongs to the body: only one separator is consumed.
    check("one blank line consumed", s.parse_title("TITLE: X\n\n\n## S")[1], "\n## S")


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):\n")
        for f in FAILURES:
            print(f"  - {f}\n")
        return 1
    print("all summarize tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
