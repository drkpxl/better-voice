"""Curses TUI for reviewing consensus disagreement sites.

Reviewing ~100 sites by typing corrections is slow and error-prone; nearly always the right answer is
already one of the engine votes, so the primary interaction is *selecting* rather than typing. Custom
entry stays available for the cases where every engine was wrong -- which is exactly what happens on
jargon.

`ReviewState` holds all decision logic and is pure, so it can be tested without a terminal; the
curses layer only renders it and feeds it keys.

Stdlib only.
"""

from __future__ import annotations

import curses
import shutil
import subprocess
from dataclasses import dataclass, field

from consensus import ABSENT
from timings import clock

CUSTOM = "\x00custom"
PLAY_PAD_S = 1.2      # start playback slightly before the word
PLAY_LEN_S = 3.5


@dataclass
class Option:
    token: str          # a real token, ABSENT, or CUSTOM
    votes: int

    def label(self) -> str:
        if self.token == ABSENT:
            return "(delete — nothing was said here)"
        if self.token == CUSTOM:
            return "(type something else…)"
        return self.token


@dataclass
class ReviewState:
    tokens: list[str]
    sites: list[dict]
    timestamps: list[float | None] = field(default_factory=list)
    index: int = 0                                  # which site
    cursor: int = 0                                 # which option within the site
    edits: dict[int, str | None] = field(default_factory=dict)
    decided: set[int] = field(default_factory=set)  # site indices acted on
    status: str = ""

    # -- current site ------------------------------------------------------

    @property
    def site(self) -> dict:
        return self.sites[self.index]

    @property
    def token_index(self) -> int:
        return self.site["index"]

    def options(self) -> list[Option]:
        """Votes highest-first, with the consensus pick surfaced first among equals, then CUSTOM."""
        raw = self.site["options"]
        chosen = self.site["chosen"]
        opts = sorted(raw.items(), key=lambda kv: (-kv[1], kv[0] != chosen, kv[0]))
        out = [Option(token, votes) for token, votes in opts]
        if not any(o.token == ABSENT for o in out):
            out.append(Option(ABSENT, 0))
        out.append(Option(CUSTOM, 0))
        return out

    def total_votes(self) -> int:
        return max(sum(self.site["options"].values()), 1)

    def current_token(self) -> str:
        idx = self.token_index
        return self.tokens[idx] if 0 <= idx < len(self.tokens) else "(end)"

    def context(self, width: int = 6) -> tuple[str, str]:
        idx = self.token_index
        before = " ".join(self.tokens[max(0, idx - width):idx])
        after = " ".join(self.tokens[idx + 1:idx + 1 + width])
        return before, after

    def timestamp(self) -> float | None:
        idx = self.token_index
        if 0 <= idx < len(self.timestamps):
            return self.timestamps[idx]
        return None

    # -- actions -----------------------------------------------------------

    def move_cursor(self, delta: int) -> None:
        n = len(self.options())
        self.cursor = (self.cursor + delta) % n

    def accept(self, custom: str | None = None) -> None:
        """Record the selected option for this site, then advance."""
        opts = self.options()
        option = opts[self.cursor]
        token = custom if custom is not None else option.token
        if token == CUSTOM:
            return  # caller must supply text for CUSTOM
        idx = self.token_index
        if token == ABSENT:
            self.edits[idx] = None
        elif token != self.current_token():
            self.edits[idx] = token
        else:
            self.edits.pop(idx, None)  # same as consensus; no edit needed
        self.decided.add(self.index)
        self.advance(1)

    def advance(self, delta: int) -> None:
        self.index = max(0, min(len(self.sites) - 1, self.index + delta))
        self.cursor = 0

    def at_end(self) -> bool:
        return self.index >= len(self.sites) - 1

    def final_tokens(self) -> list[str]:
        """Apply edits by original index, so deletions cannot shift unreviewed positions."""
        out: list[str] = []
        for i, token in enumerate(self.tokens):
            if i in self.edits:
                replacement = self.edits[i]
                if replacement is not None:
                    out.append(replacement)
            else:
                out.append(token)
        return out

    def progress(self) -> str:
        return f"{self.index + 1}/{len(self.sites)}  decided {len(self.decided)}  edits {len(self.edits)}"


# ---------------------------------------------------------------------------
# audio playback
# ---------------------------------------------------------------------------

def play(audio: str, seconds: float | None) -> str:
    if seconds is None:
        return "no timestamp for this word"
    if shutil.which("ffplay") is None:
        return "ffplay not found (brew install ffmpeg)"
    start = max(0.0, seconds - PLAY_PAD_S)
    subprocess.Popen(
        ["ffplay", "-ss", f"{start:.2f}", "-t", str(PLAY_LEN_S),
         "-autoexit", "-nodisp", "-loglevel", "quiet", audio],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return f"playing from {clock(start)}"


# ---------------------------------------------------------------------------
# curses layer
# ---------------------------------------------------------------------------

HELP = "↑↓ select · ⏎ accept · p play · e type · ←→ skip · q save+quit"


def _draw(stdscr, state: ReviewState) -> None:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    ts = state.timestamp()

    header = f" Review {state.progress()} "
    stamp = f" audio {clock(ts)} "
    stdscr.attron(curses.A_REVERSE)
    stdscr.addnstr(0, 0, header + " " * max(0, width - len(header) - len(stamp)) + stamp, width - 1)
    stdscr.attroff(curses.A_REVERSE)

    before, after = state.context()
    row = 2
    stdscr.addnstr(row, 2, "context:", width - 4, curses.A_DIM)
    row += 1
    # The contested word is bracketed and bold so the eye lands on it immediately.
    line = f"…{before} "
    stdscr.addnstr(row, 2, line, width - 4)
    x = 2 + len(line)
    word = f"[{state.current_token()}]"
    if x + len(word) < width - 2:
        stdscr.addnstr(row, x, word, width - x - 2, curses.A_BOLD | curses.A_STANDOUT)
        x += len(word)
    if x + 1 < width - 2:
        stdscr.addnstr(row, x, f" {after}…", width - x - 2)

    row += 2
    stdscr.addnstr(row, 2, f"engine votes ({state.total_votes()} engines):", width - 4, curses.A_DIM)
    row += 1
    total = state.total_votes()
    for i, option in enumerate(state.options()):
        if row >= height - 2:
            break
        selected = i == state.cursor
        share = f"{option.votes}/{total}" if option.token not in (CUSTOM,) else "    "
        pct = f"{option.votes / total:>4.0%}" if option.token != CUSTOM else "    "
        text = f" {'▸' if selected else ' '} {i + 1}. {option.label():<34} {share:>6} {pct} "
        attr = curses.A_REVERSE if selected else curses.A_NORMAL
        if option.token == ABSENT:
            attr |= curses.A_DIM
        stdscr.addnstr(row, 2, text, width - 4, attr)
        row += 1

    if state.status:
        stdscr.addnstr(height - 3, 2, state.status[: width - 4], width - 4, curses.A_DIM)
    stdscr.attron(curses.A_REVERSE)
    stdscr.addnstr(height - 1, 0, HELP.ljust(width - 1)[: width - 1], width - 1)
    stdscr.attroff(curses.A_REVERSE)
    stdscr.refresh()


def _prompt(stdscr, label: str) -> str:
    height, width = stdscr.getmaxyx()
    curses.echo()
    curses.curs_set(1)
    stdscr.addnstr(height - 2, 2, label.ljust(width - 4), width - 4)
    stdscr.refresh()
    try:
        raw = stdscr.getstr(height - 2, 2 + len(label), 60)
        text = raw.decode("utf-8", "replace").strip()
    except Exception:  # noqa: BLE001
        text = ""
    curses.noecho()
    curses.curs_set(0)
    return text


def run_tui(state: ReviewState, audio: str) -> ReviewState:
    def loop(stdscr):
        curses.curs_set(0)
        stdscr.keypad(True)
        while True:
            _draw(stdscr, state)
            key = stdscr.getch()

            if key in (ord("q"), 27):                       # q / ESC
                return
            elif key in (curses.KEY_DOWN, ord("j"), 9):     # ↓ / j / tab
                state.move_cursor(1)
            elif key in (curses.KEY_UP, ord("k")):
                state.move_cursor(-1)
            elif key in (curses.KEY_RIGHT, ord("]")):
                state.advance(1)
            elif key in (curses.KEY_LEFT, ord("[")):
                state.advance(-1)
            elif key in (ord("p"), ord(" ")):
                state.status = play(audio, state.timestamp())
            elif key in (ord("e"), ord("/")):
                text = _prompt(stdscr, "correct word: ")
                if text:
                    state.edits[state.token_index] = text
                    state.decided.add(state.index)
                    state.status = f"set to “{text}”"
                    state.advance(1)
            elif key in (curses.KEY_ENTER, 10, 13):
                opts = state.options()
                if opts[state.cursor].token == CUSTOM:
                    text = _prompt(stdscr, "correct word: ")
                    if text:
                        state.edits[state.token_index] = text
                        state.decided.add(state.index)
                        state.advance(1)
                else:
                    was_last = state.at_end()
                    state.accept()
                    if was_last:
                        return
            elif ord("1") <= key <= ord("9"):
                target = key - ord("1")
                if target < len(state.options()):
                    state.cursor = target

    curses.wrapper(loop)
    return state
