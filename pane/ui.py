#!/usr/bin/env python3
"""balamba chrome panes: the project tree and the git side panel.

Two modes, selected by the single command-line argument:

    python3 pane/ui.py tree
    python3 pane/ui.py git

This file is stdlib-only on purpose (SPEC.md, architecture.md §12).  It never
writes state: every mutation is delegated to ``bin/balamba internal ...``.
It reads config through the tmux user options mirrored by
``balamba_config_to_tmux`` and talks to the private tmux server through plain
``tmux`` (``$TMUX`` is set inside a pane).

The app is deliberately a small, poll-driven terminal program:

* raw mode + alternate screen + hidden cursor while painting;
* SGR mouse (1000/1002/1006) and focus events (1004), parsed with a state
  machine that tolerates partial and batched reads;
* one ``select()`` loop, no busy waiting;
* the tree redraws on input immediately and re-reads tmux/state on the
  configured active/idle interval; the git pane additionally refreshes its
  read-only status document every ``@balamba_git_refresh`` seconds.

The palette is neutral with one accent (see ``Palette`` below); green/red are
reserved for git file codes.  The tree collapses a single-pane tab to one row,
renders a tab plus pane rows when a tab has splits, and pins a contextual
footer with three or four honest key hints.

Nothing here is a library for the shell code; the pure helpers at the top are
kept importable so ``test/t_ui.py`` can exercise them directly.
"""

import errno
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import time
import tty
import unicodedata

# ---------------------------------------------------------------------------
# Config defaults (architecture.md §4).  Read from @balamba_* options.
# ---------------------------------------------------------------------------
CONFIG_DEFAULTS = {
    "tree_width": 30,
    "git_width": 34,
    "active_refresh": 1,
    "idle_refresh": 5,
    "git_refresh": 2,
    "editor": "vi",
    "default_ref": "origin/main",
    "default_agent": "opencode",
    "theme": "auto",
    "accent": "blue",
}

REFRESH_KEYS = ("active_refresh", "idle_refresh", "git_refresh")

# ---------------------------------------------------------------------------
# Palette: neutral text plus one accent.  Green/red are reserved for git.
# ---------------------------------------------------------------------------
# 24-bit RGB per role (the brief's numbers).
ROLE_RGB = {
    "text": (201, 209, 217),       # #c9d1d9
    "bright": (240, 246, 252),     # #f0f6fc
    "dim": (110, 118, 129),        # #6e7681
    "dimmer": (72, 79, 88),        # #484f58
    "unread": (210, 153, 34),      # #d29922
    "add": (63, 185, 80),          # #3fb950
    "modify": (210, 153, 34),      # #d29922
    "delete": (248, 81, 73),       # #f85149
    "selbg": (28, 33, 40),         # #1c2128
}

# 256-colour fallback (252/231/244/238/178/71/178/203/236).
ROLE_256 = {
    "text": 252,
    "bright": 231,
    "dim": 244,
    "dimmer": 238,
    "unread": 178,
    "add": 71,
    "modify": 178,
    "delete": 203,
    "selbg": 236,
}

# 16-colour fallback: plain ANSI foreground/background codes.
ROLE_16 = {
    "text": 37,
    "bright": 97,
    "dim": 90,
    "dimmer": 90,
    "unread": 33,
    "add": 32,
    "modify": 33,
    "delete": 31,
    "selbg": 100,
}

# The accent is the one saturated colour in the UI.  Blue is the default.
ACCENT_RGB = {
    "blue": (88, 166, 255),
    "cyan": (57, 197, 207),
    "magenta": (188, 140, 255),
    "yellow": (227, 179, 65),
}
ACCENT_256 = {"blue": 75, "cyan": 80, "magenta": 141, "yellow": 178}
ACCENT_16 = {"blue": 34, "cyan": 36, "magenta": 35, "yellow": 33}

THEME_MODES = ("truecolor", "256", "16")
ACCENT_NAMES = ("blue", "cyan", "magenta", "yellow")


def detect_theme(theme, env=None):
    """Resolve ``auto|truecolor|256|16`` against COLORTERM/TERM."""
    theme = str(theme or "auto").strip().lower()
    if theme in THEME_MODES:
        return theme
    env = env if env is not None else os.environ
    colorterm = str(env.get("COLORTERM") or "").lower()
    term = str(env.get("TERM") or "").lower()
    if "truecolor" in colorterm or "24bit" in colorterm:
        return "truecolor"
    if "256color" in term:
        return "256"
    return "16"


def normalize_accent(accent):
    accent = str(accent or "").strip().lower()
    return accent if accent in ACCENT_NAMES else "blue"


class Palette(object):
    """Cached SGR builder.

    Every attribute a row needs is computed once per palette, and every
    ``style`` combination is memoised: the render loop never rebuilds the same
    escape string twice, so a full repaint allocates only row text.
    """

    def __init__(self, theme, accent, env=None):
        self.theme = detect_theme(theme, env)
        self.accent = normalize_accent(accent)
        self._cache = {}

    # -- individual colours -------------------------------------------------
    def _fg_code(self, role):
        if role == "accent":
            if self.theme == "truecolor":
                return "38;2;%d;%d;%d" % ACCENT_RGB[self.accent]
            if self.theme == "256":
                return "38;5;%d" % ACCENT_256[self.accent]
            return "%d" % ACCENT_16[self.accent]
        if role not in ROLE_RGB:
            role = "text"
        if self.theme == "truecolor":
            return "38;2;%d;%d;%d" % ROLE_RGB[role]
        if self.theme == "256":
            return "38;5;%d" % ROLE_256[role]
        return "%d" % ROLE_16[role]

    def _bg_code(self, role):
        if role not in ROLE_RGB:
            role = "selbg"
        if self.theme == "truecolor":
            return "48;2;%d;%d;%d" % ROLE_RGB[role]
        if self.theme == "256":
            return "48;5;%d" % ROLE_256[role]
        return "%d" % ROLE_16[role]

    # -- public cached builders --------------------------------------------
    def fg(self, role):
        key = ("fg", role)
        value = self._cache.get(key)
        if value is None:
            value = "\x1b[" + self._fg_code(role) + "m"
            self._cache[key] = value
        return value

    def bg(self, role="selbg"):
        key = ("bg", role)
        value = self._cache.get(key)
        if value is None:
            value = "\x1b[" + self._bg_code(role) + "m"
            self._cache[key] = value
        return value

    def sgr(self, fg=None, bg=None, bold=False):
        """Combined cached SGR: ``fg``/``bg`` roles plus optional bold."""
        key = ("sgr", fg, bg, bool(bold))
        value = self._cache.get(key)
        if value is not None:
            return value
        codes = []
        if fg:
            codes.append(self._fg_code(fg))
        if bg:
            codes.append(self._bg_code(bg))
        if bold:
            codes.append("1")
        value = "\x1b[" + ";".join(codes) + "m" if codes else ""
        self._cache[key] = value
        return value


_DEFAULT_PALETTE = None


def default_palette():
    """Deterministic palette for pure rendering tests."""
    global _DEFAULT_PALETTE
    if _DEFAULT_PALETTE is None:
        _DEFAULT_PALETTE = Palette("truecolor", "blue", {})
    return _DEFAULT_PALETTE


def make_palette(theme="auto", accent="blue", env=None):
    return Palette(theme, accent, env)


# ---------------------------------------------------------------------------
# Glyphs: unicode by default, ASCII when the locale cannot encode them.
# ---------------------------------------------------------------------------
class Glyphs(object):
    def __init__(self, ascii_only=False):
        self.ascii = bool(ascii_only)
        if self.ascii:
            self.chevron_open = "v"
            self.chevron_closed = ">"
            self.agent = "A"
            self.shell = "$"
            self.pane = "-"
            self.unread = "*"
            self.select = "|"
            self.rule = "-"
            self.ellipsis = "~"
            self.tl = "+"
            self.tr = "+"
            self.bl = "+"
            self.br = "+"
            self.h = "-"
            self.v = "|"
            self.ahead = ">"
            self.behind = "<"
        else:
            self.chevron_open = "▾"
            self.chevron_closed = "▸"
            self.agent = "◆"
            self.shell = "›"
            self.pane = "·"
            self.unread = "●"
            self.select = "▌"
            self.rule = "─"
            self.ellipsis = "…"
            self.tl = "╭"
            self.tr = "╮"
            self.bl = "╰"
            self.br = "╯"
            self.h = "─"
            self.v = "│"
            self.ahead = "↑"
            self.behind = "↓"


_DEFAULT_GLYPHS = None


def default_glyphs():
    global _DEFAULT_GLYPHS
    if _DEFAULT_GLYPHS is None:
        _DEFAULT_GLYPHS = Glyphs(False)
    return _DEFAULT_GLYPHS


def detect_ascii(env=None):
    """True when the locale/terminal cannot be assumed to render UTF-8."""
    env = env if env is not None else os.environ
    for key in ("LC_ALL", "LC_CTYPE", "LANG"):
        value = env.get(key)
        if value:
            lowered = str(value).lower()
            return not ("utf-8" in lowered or "utf8" in lowered)
    try:
        encoding = (getattr(sys.stdout, "encoding", "") or "").lower()
    except Exception:  # noqa: BLE001 - encoding query must never break paint
        encoding = ""
    if encoding:
        return not ("utf-8" in encoding or "utf8" in encoding)
    return False


def make_glyphs(ascii_only=False):
    return Glyphs(ascii_only)


# ---------------------------------------------------------------------------
# ANSI building blocks
# ---------------------------------------------------------------------------
ALT_ON = "\x1b[?1049h"
ALT_OFF = "\x1b[?1049l"
CURSOR_HIDE = "\x1b[?25l"
CURSOR_SHOW = "\x1b[?25h"
WRAP_OFF = "\x1b[?7l"
WRAP_ON = "\x1b[?7h"
MOUSE_ON = "\x1b[?1000h\x1b[?1002h\x1b[?1006h"
MOUSE_OFF = "\x1b[?1006l\x1b[?1002l\x1b[?1000l"
FOCUS_ON = "\x1b[?1004h"
FOCUS_OFF = "\x1b[?1004l"
RESET = "\x1b[0m"
CLEAR_LINE = "\x1b[K"
CLEAR_SCREEN = "\x1b[2J"

SGR_BOLD = "1"
SGR_DIM = "2"
SGR_REVERSE = "7"

# Legacy aliases kept for tests/helpers that still name a colour directly.
# Rendering never uses these: it always goes through a Palette role.
SGR_GREEN = "32"
SGR_YELLOW = "33"
SGR_RED = "31"
SGR_CYAN = "36"
SGR_MAGENTA = "35"
SGR_BLUE = "34"


def sgr(*codes):
    """Build an SGR sequence from numeric/string codes (no reset)."""
    parts = [str(c) for c in codes if str(c)]
    if not parts:
        return ""
    return "\x1b[" + ";".join(parts) + "m"


# ---------------------------------------------------------------------------
# Display width / unicode-safe truncation (never split a wide cell)
# ---------------------------------------------------------------------------
def _char_width(ch):
    """Terminal cell width of one code point."""
    if not ch:
        return 0
    code = ord(ch)
    if code == 0:
        return 0
    if ch in ("\u200b", "\u200c", "\u200d", "\ufe0e", "\ufe0f"):
        return 0
    if unicodedata.combining(ch):
        return 0
    cat = unicodedata.category(ch)
    if cat in ("Mn", "Me", "Cf"):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def display_width(text):
    """Number of terminal columns ``text`` occupies."""
    return sum(_char_width(ch) for ch in text or "")


def truncate_display(text, width):
    """Keep at most ``width`` columns of ``text``; never split a wide char.

    A trailing combining mark still attached to the last kept base character is
    preserved.  A wide character that does not fit is dropped entirely, so the
    result is safe to write into a fixed-width cell.
    """
    if width <= 0 or not text:
        return ""
    used = 0
    out = []
    for ch in text:
        w = _char_width(ch)
        if used + w > width:
            if w == 0:
                out.append(ch)
                continue
            break
        out.append(ch)
        used += w
    return "".join(out)


def truncate_ellipsis(text, width, mark="…"):
    """Truncate the head of ``text`` and mark the cut with ``mark`` (one cell)."""
    if width <= 0 or not text:
        return ""
    if display_width(text) <= width:
        return text
    if width <= display_width(mark):
        return truncate_display(mark, width)
    return truncate_display(text, width - display_width(mark)) + mark


def truncate_left_display(text, width):
    """Keep the *tail* of ``text`` in ``width`` columns (paths/filenames)."""
    if width <= 0 or not text:
        return ""
    if display_width(text) <= width:
        return text
    target = width - 1
    if target <= 0:
        return "…" if width >= 1 else ""
    used = 0
    out = []
    for ch in reversed(text):
        w = _char_width(ch)
        if used + w > target:
            if w == 0:
                out.append(ch)
                continue
            break
        out.append(ch)
        used += w
    return "…" + "".join(reversed(out))


def pad_display(text, width, align="left"):
    """Truncate then pad ``text`` to exactly ``width`` columns."""
    if width <= 0:
        return ""
    text = truncate_display(text, width)
    fill = width - display_width(text)
    if fill <= 0:
        return text
    if align == "right":
        return " " * fill + text
    if align == "center":
        left = fill // 2
        return " " * left + text + " " * (fill - left)
    return text + " " * fill


def _safe_text(text):
    """Replace terminal control characters so state/error text cannot escape."""
    if not text:
        return ""
    out = []
    for ch in text:
        if ch in ("\n", "\r", "\t"):
            out.append(" ")
            continue
        if unicodedata.category(ch) in ("Cc", "Cs"):
            out.append(" ")
            continue
        out.append(ch)
    return "".join(out)


def _attr_code(value):
    """One attribute as an SGR prefix (palette strings or numeric codes)."""
    text = str(value)
    if not text:
        return ""
    if text.startswith("\x1b["):
        return text
    return sgr(text)


def _attr_list(value):
    """Normalise one style or a sequence of styles into a tuple."""
    if not value:
        return ()
    if isinstance(value, str):
        return (value,)
    return tuple(value)


def _apply_attrs(text, attrs, base_attrs=()):
    """Wrap text in SGR attributes; combine base (selection) with local style."""
    prefix = "".join(_attr_code(c) for c in _attr_list(base_attrs))
    prefix += "".join(_attr_code(c) for c in _attr_list(attrs))
    if not prefix:
        return text
    return prefix + text + RESET


def compose_segments(segments, width, base_attrs=()):
    """Render ``[(attrs, text)]`` to exactly ``width`` columns.

    Truncation is by display width across segment boundaries, so no half-cell
    is ever written.  ``base_attrs`` (selection background, for instance)
    applies to every cell, including padding, and is merged with each segment
    style.
    """
    if width <= 0:
        return ""
    used = 0
    out = []
    for attrs, text in segments:
        if used >= width:
            break
        remaining = width - used
        chunk = truncate_display(_safe_text(text), remaining)
        if not chunk:
            continue
        out.append(_apply_attrs(chunk, attrs, base_attrs))
        used += display_width(chunk)
    if used < width:
        pad = " " * (width - used)
        out.append(_apply_attrs(pad, (), base_attrs))
    return "".join(out)


def compose_plain(segments, width):
    """Plain-text version of compose_segments (for tests/debugging)."""
    used = 0
    out = []
    for _attrs, text in segments:
        if used >= width:
            break
        chunk = truncate_display(_safe_text(text), width - used)
        out.append(chunk)
        used += display_width(chunk)
    if used < width:
        out.append(" " * (width - used))
    return "".join(out)


def compose_right(left_segments, right_segments, width, base_attrs=()):
    """Left-aligned text plus right-aligned segments, padded to ``width``.

    Used for the dim task count and the unread dot, both of which must hold
    the right edge without breaking the row's selection background.
    """
    if width <= 0:
        return ""
    right_width = sum(display_width(_safe_text(text))
                      for _attrs, text in right_segments)
    if right_width <= 0:
        return compose_segments(left_segments, width, base_attrs)
    if right_width >= width:
        return compose_segments(right_segments, width, base_attrs)
    left_width = max(0, width - right_width - 1)
    left = compose_segments(left_segments, left_width, base_attrs)
    gap = width - left_width - right_width
    return (left + _apply_attrs(" " * gap, (), base_attrs) +
            compose_segments(right_segments, right_width, base_attrs))


# ---------------------------------------------------------------------------
# Input parsing: keys, SGR mouse, focus, tolerant of partial reads
# ---------------------------------------------------------------------------
MOUSE_RE = re.compile(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])")
CSI_RE = re.compile(rb"\x1b\[([0-9;]*)([A-Za-z~])")

KEY_NAMES = {
    "A": "Up",
    "B": "Down",
    "C": "Right",
    "D": "Left",
    "H": "Home",
    "F": "End",
    "I": "FocusIn",
    "O": "FocusOut",
    "Z": "BackTab",
}

TILDE_KEYS = {
    "1": "Home",
    "7": "Home",
    "4": "End",
    "8": "End",
    "5": "PgUp",
    "6": "PgDn",
    "2": "Insert",
    "3": "Delete",
}


def _is_partial_mouse(buf):
    """True when ``buf`` is a strict prefix of a valid SGR mouse sequence."""
    if not buf.startswith(b"\x1b[<"):
        return False
    body = buf[3:]
    if not body:
        return True
    # digits/semicolons followed by nothing or M/m
    if not re.fullmatch(rb"[0-9;]*", body):
        return False
    return True


def _is_partial_csi(buf):
    """True when ``buf`` starts a CSI sequence that may still be completed."""
    if not buf.startswith(b"\x1b["):
        return False
    body = buf[2:]
    if not body:
        return True
    # params (digits/;) and optional intermediate bytes; no final byte yet
    return re.fullmatch(rb"[0-9;]*", body) is not None


def parse_input(data, force_esc=False):
    """Parse a byte buffer into events.

    Returns ``(events, rest)``.  ``events`` items are either::

        ("key", name)            name from KEY_NAMES / TILDE_KEYS or a literal
        ("mouse", b, x, y, True)  True = press/motion (M), False = release (m)

    x/y are the 1-based pane-local coordinates from SGR.

    ``rest`` is an incomplete sequence retained for the next read.  A lone ESC
    is retained unless ``force_esc`` (the caller uses a short timeout so a user
    pressing Esc is not stuck waiting for a follow-up byte).
    """
    buf = data
    events = []
    while buf:
        if buf.startswith(b"\x1b[<"):
            m = MOUSE_RE.match(buf)
            if m:
                bnum = int(m.group(1))
                x = int(m.group(2))
                y = int(m.group(3))
                pressed = m.group(4) == b"M"
                events.append(("mouse", bnum, x, y, pressed))
                buf = buf[m.end():]
                continue
            if _is_partial_mouse(buf):
                break
            # Malformed mouse prefix: drop the ESC and continue.
            buf = buf[1:]
            continue

        if buf.startswith(b"\x1b["):
            m = CSI_RE.match(buf)
            if m:
                params = m.group(1).decode("ascii", "ignore")
                final = m.group(2).decode("ascii", "ignore")
                buf = buf[m.end():]
                if final == "~":
                    first = params.split(";", 1)[0] if params else ""
                    events.append(("key", TILDE_KEYS.get(first, "Unknown")))
                else:
                    events.append(("key", KEY_NAMES.get(final, "Unknown")))
                continue
            if _is_partial_csi(buf):
                break
            buf = buf[1:]
            continue

        if buf[0] == 0x1B:
            if len(buf) == 1 and not force_esc:
                break
            events.append(("key", "Esc"))
            buf = buf[1:]
            continue

        byte = buf[0]
        if byte in (0x0A, 0x0D):
            events.append(("key", "Enter"))
            buf = buf[1:]
            continue
        if byte == 0x09:
            events.append(("key", "Tab"))
            buf = buf[1:]
            continue
        if byte < 0x20 or byte == 0x7F:
            # Ctrl-C / Ctrl-D / backspace etc. are not mapped; drop them.
            buf = buf[1:]
            continue

        # One UTF-8 character (partial multibyte input stays buffered).
        decoded = None
        for size in (1, 2, 3, 4):
            if len(buf) < size:
                break
            try:
                decoded = buf[:size].decode("utf-8")
            except UnicodeDecodeError:
                continue
            else:
                buf = buf[size:]
                break
        if decoded is None:
            # Either an incomplete multibyte char at the end of the buffer or
            # a genuinely invalid byte; keep it only in the former case.
            try:
                buf.decode("utf-8")
            except UnicodeDecodeError as exc:
                if exc.reason == "unexpected end of data":
                    break
            buf = buf[1:]
            continue
        events.append(("key", decoded))

    return events, buf


# ---------------------------------------------------------------------------
# Viewport / scrolling
# ---------------------------------------------------------------------------
def viewport_slice(total, cursor, scroll, height):
    """Return ``(indices, start)`` for a scrolling list.

    ``indices`` has at most ``height`` entries; ``None`` marks an ellipsis row
    (top or bottom).  The cursor row is always inside the returned slice when
    ``total > 0``.  ``start`` is the new scroll origin.
    """
    if height <= 0 or total <= 0:
        return [], 0
    cursor = max(0, min(int(cursor), total - 1))
    scroll = max(0, int(scroll))
    if total <= height:
        return list(range(total)), 0

    start = max(0, min(scroll, total - height))
    for _ in range(max(8, height * 2 + 4)):
        top = start > 0
        cap_top = 1 if top else 0
        need_bottom = start + (height - cap_top) < total
        cap = height - cap_top - (1 if need_bottom else 0)
        if cap < 1:
            # Very short pane: prefer showing rows over both markers.
            start = max(0, min(cursor, total - height))
            top = start > 0
            need_bottom = total > height
            cap = height - (1 if top else 0) - (1 if need_bottom else 0)
            if cap < 1:
                top = False
                need_bottom = False
                cap = height
        if cursor < start:
            start = cursor
            continue
        if cursor >= start + cap:
            start = cursor - cap + 1
            continue
        break

    top = start > 0
    cap_top = 1 if top else 0
    need_bottom = start + (height - cap_top) < total
    cap = height - cap_top - (1 if need_bottom else 0)
    if cap < 1:
        top = False
        need_bottom = False
        cap = height
    indices = []
    if top:
        indices.append(None)
    indices.extend(range(start, min(total, start + cap)))
    if need_bottom and len(indices) < height:
        indices.append(None)
    return indices, start


def hit_test(display_row, indices):
    """Map a 0-based terminal row to a global row index (None = no row)."""
    if display_row < 0 or display_row >= len(indices):
        return None
    return indices[display_row]


def clamp_cursor(cursor, total):
    if total <= 0:
        return 0
    return max(0, min(int(cursor), total - 1))


def selectable_indices(rows):
    """Row indices the cursor may own (separator rules are not selectable)."""
    return [i for i, row in enumerate(rows or [])
            if row.get("kind") != "sep"]


def step_selectable(rows, cursor, delta):
    """Move ``delta`` selectable rows from ``cursor``; clamp at the ends."""
    indices = selectable_indices(rows)
    if not indices:
        return 0
    position = 0
    for pos, index in enumerate(indices):
        if index >= cursor:
            position = pos
            break
    else:
        position = len(indices) - 1
    position = max(0, min(position + int(delta), len(indices) - 1))
    return indices[position]


# ---------------------------------------------------------------------------
# State reading (read-only)
# ---------------------------------------------------------------------------
def read_state_file(path):
    """Return ``(state, error)``.  Never raises for missing/corrupt state."""
    if not path:
        return None, "BALAMBA_STATE is not set"
    try:
        with open(path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return None, "no state at %s" % path
    except OSError as exc:
        return None, "cannot read state: %s" % exc
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        return None, "invalid state: %s" % exc
    if not isinstance(state, dict):
        return None, "invalid state: not a JSON object"
    if not isinstance(state.get("projects"), list):
        return None, "invalid state: projects is not a list"
    return state, None


def _tab_sort_key(pair):
    index, tab = pair
    window = tab.get("window")
    if isinstance(window, int):
        return (0, window, index)
    return (1, 0, index)


def sorted_tabs(tabs):
    return [tab for _i, tab in sorted(enumerate(tabs or []), key=_tab_sort_key)]


def _live_tab_info(live, tab_id):
    live = live or {}
    tabs = live.get("tabs") or {}
    return tabs.get(tab_id) or {}


def _pane_name(pane, index):
    name = pane.get("name")
    if name:
        return str(name)
    command = pane.get("live_command")
    if command:
        return str(command)
    return "pane %d" % (index + 1)


def _tab_panes(tab):
    panes = []
    for index, pane in enumerate(tab.get("panes") or []):
        if not isinstance(pane, dict):
            continue
        entry = dict(pane)
        if not isinstance(entry.get("index"), int):
            entry["index"] = index
        panes.append(entry)
    return panes


def build_rows(state, live=None, tab_expanded=None):
    """Build the flat tree row model from a state document.

    Row dicts carry everything the renderer and the action handlers need::

        kind        project | task | tab | pane | sep
        key         stable identity across refreshes
        pid, tid    owning project/task ids (tid only for task rows/tabs)
        context     "proj" or "task:<tid>"
        tab_id      terminal id (tab and pane rows)
        pane_index  0-based content index (pane rows, single-tab rows)
        window      live window index (tab rows only)
        depth       0=project, 1=task, 2=tab/single-tab, 3=pane
        name        display text
        path        project/task worktree path for the editor
        expanded    project/task/tab expansion flag
        has_children
        single      a tab with exactly one content pane collapses to one row
        pane_count  content pane count
        unread      window_activity_flag, propagated to parents
        active_context / active_window / pane_active
    """
    state = state or {}
    active = state.get("active") or {}
    active_pid = active.get("project")
    active_ctx = active.get("context")
    live = live or {}
    active_window = live.get("active_window")
    if active_window is None and isinstance(active.get("window"), int):
        # While this window is inactive we skip the tmux window list; the
        # stored active window is still a useful highlight anchor.
        active_window = active.get("window")
    tab_expanded = tab_expanded or {}

    def tab_unread(tab, info):
        # Never show a marker for the window the client is currently viewing.
        if info.get("active"):
            return False
        return bool(info.get("flag"))

    def make_tab_rows(tab, pid, tid, context, depth, path, unread):
        tab_id = tab.get("id")
        info = _live_tab_info(live, tab_id)
        window = tab.get("window")
        if not isinstance(window, int):
            window = info.get("window")
        is_active_window = (
            (isinstance(window, int) and active_window is not None and
             window == active_window)
            or bool(info.get("active"))
        )
        panes = _tab_panes(tab)
        pane_count = tab.get("pane_count")
        if not isinstance(pane_count, int) or pane_count < 1:
            pane_count = max(1, len(panes))
        single = (len(panes) <= 1 and pane_count <= 1)
        key = "tab:%s:%s" % (pid, tab_id)
        if single:
            expanded = False
        else:
            expanded = bool(tab_expanded.get(key, True))
        tab_name = tab.get("name") or "tab"
        live_command = ""
        pane_index = 0
        if panes:
            try:
                pane_index = int(tab.get("active_pane") or 0)
            except (TypeError, ValueError):
                pane_index = 0
            if pane_index < 0 or pane_index >= len(panes):
                pane_index = 0
            live_command = str(panes[pane_index].get("live_command") or "")
        rows = [{
            "kind": "tab",
            "key": key,
            "pid": pid,
            "tid": tid,
            "context": context,
            "tab_id": tab_id,
            "window": window if isinstance(window, int) else None,
            "depth": depth,
            "name": tab_name,
            "path": path,
            "expanded": expanded,
            "has_children": not single,
            "single": single,
            "pane_count": pane_count,
            "pane_index": pane_index if single else None,
            "live_command": live_command,
            "unread": unread,
            "active_context": False,
            "active_window": is_active_window,
            "pane_active": False,
            "tab_kind": tab.get("kind") or "shell",
            "branch": None,
            "task_count": 0,
        }]
        if single or not expanded:
            return rows
        try:
            active_pane = int(tab.get("active_pane") or 0)
        except (TypeError, ValueError):
            active_pane = 0
        for index, pane in enumerate(panes):
            pane_active = bool(pane.get("active")) or index == active_pane
            rows.append({
                "kind": "pane",
                "key": "pane:%s:%s:%d" % (pid, tab_id, index),
                "pid": pid,
                "tid": tid,
                "context": context,
                "tab_id": tab_id,
                "window": window if isinstance(window, int) else None,
                "depth": depth + 1,
                "name": _pane_name(pane, index),
                "path": path,
                "expanded": False,
                "has_children": False,
                "single": False,
                "pane_count": pane_count,
                "pane_index": index,
                "live_command": str(pane.get("live_command") or ""),
                "unread": False,
                "active_context": False,
                "active_window": is_active_window,
                "pane_active": pane_active,
                "tab_kind": None,
                "branch": None,
                "task_count": 0,
            })
        return rows

    rows = []
    projects = [p for p in (state.get("projects") or []) if p.get("id")]
    for project_pos, project in enumerate(projects):
        pid = project.get("id")
        project_expanded = bool(project.get("expanded"))
        project_tabs = project.get("tabs") or []
        tasks = project.get("tasks") or []
        project_unread = False
        child_rows = []

        if project_expanded:
            for tab in sorted_tabs(project_tabs):
                info = _live_tab_info(live, tab.get("id"))
                tab_unread_flag = tab_unread(tab, info)
                project_unread = project_unread or tab_unread_flag
                child_rows.extend(
                    make_tab_rows(tab, pid, None, "proj", 2,
                                  project.get("path"), tab_unread_flag)
                )

            for task in tasks:
                tid = task.get("id")
                if not tid:
                    continue
                context = "task:%s" % tid
                task_tabs = sorted_tabs(task.get("tabs") or [])
                task_unread = False
                task_rows = []
                for tab in task_tabs:
                    info = _live_tab_info(live, tab.get("id"))
                    tab_unread_flag = tab_unread(tab, info)
                    task_unread = task_unread or tab_unread_flag
                    task_rows.extend(
                        make_tab_rows(tab, pid, tid, context, 2,
                                      task.get("path"), tab_unread_flag)
                    )
                project_unread = project_unread or task_unread
                child_rows.append({
                    "kind": "task",
                    "key": "task:%s:%s" % (pid, tid),
                    "pid": pid,
                    "tid": tid,
                    "context": context,
                    "tab_id": None,
                    "window": None,
                    "depth": 1,
                    "name": task.get("name") or tid,
                    "path": task.get("path"),
                    "expanded": bool(task.get("expanded")),
                    "has_children": bool(task_tabs),
                    "single": False,
                    "pane_count": 0,
                    "pane_index": None,
                    "live_command": "",
                    "unread": task_unread,
                    "active_context": (
                        pid == active_pid and active_ctx == context
                    ),
                    "active_window": False,
                    "pane_active": False,
                    "tab_kind": None,
                    "branch": task.get("branch"),
                    "task_count": 0,
                })
                if task.get("expanded"):
                    child_rows.extend(task_rows)
        else:
            # A collapsed project is one line, but unread state still bubbles
            # up from the terminals that are hidden beneath it.
            for tab in project_tabs:
                info = _live_tab_info(live, tab.get("id"))
                project_unread = project_unread or tab_unread(tab, info)
            for task in tasks:
                for tab in task.get("tabs") or []:
                    info = _live_tab_info(live, tab.get("id"))
                    project_unread = project_unread or tab_unread(tab, info)

        rows.append({
            "kind": "project",
            "key": "project:%s" % pid,
            "pid": pid,
            "tid": None,
            "context": "proj",
            "tab_id": None,
            "window": None,
            "depth": 0,
            "name": project.get("name") or pid,
            "path": project.get("path"),
            "expanded": project_expanded,
            "has_children": bool(project_tabs or tasks),
            "single": False,
            "pane_count": 0,
            "pane_index": None,
            "live_command": "",
            "unread": project_unread,
            "active_context": (
                pid == active_pid and active_ctx == "proj"
            ),
            "active_window": False,
            "pane_active": False,
            "tab_kind": None,
            "branch": None,
            "task_count": len(tasks),
        })
        rows.extend(child_rows)
        # A calm dim rule separates project groups (not a selectable row).
        if project_pos < len(projects) - 1:
            rows.append({
                "kind": "sep",
                "key": "sep:%s" % pid,
                "pid": pid,
                "tid": None,
                "context": "proj",
                "tab_id": None,
                "window": None,
                "depth": 0,
                "name": "",
                "path": None,
                "expanded": False,
                "has_children": False,
                "single": False,
                "pane_count": 0,
                "pane_index": None,
                "live_command": "",
                "unread": False,
                "active_context": False,
                "active_window": False,
                "pane_active": False,
                "tab_kind": None,
                "branch": None,
                "task_count": 0,
            })

    return rows


def find_row(rows, key):
    for index, row in enumerate(rows):
        if row.get("key") == key:
            return index
    return None


def parent_key(row):
    """Key of the row that owns this one (for Left/back navigation)."""
    if not row:
        return None
    if row.get("kind") == "task":
        return "project:%s" % row.get("pid")
    if row.get("kind") == "pane":
        return "tab:%s:%s" % (row.get("pid"), row.get("tab_id"))
    if row.get("kind") == "tab":
        if row.get("tid"):
            return "task:%s:%s" % (row.get("pid"), row.get("tid"))
        return "project:%s" % row.get("pid")
    return None


def first_child_index(rows, index):
    """Visible row directly below a parent row, or None."""
    if index is None or rows is None:
        return None
    parent = rows[index]
    if index + 1 >= len(rows):
        return None
    child = rows[index + 1]
    if child.get("depth") == int(parent.get("depth") or 0) + 1:
        return index + 1
    return None


# ---------------------------------------------------------------------------
# Contextual footer and help overlay (pure)
# ---------------------------------------------------------------------------
FOOTER_MOUSE = "click select · again open · r-click menu"
FOOTER_MOUSE_COMPACT = "click · again · r-click menu"
FOOTER_MOUSE_TINY = "click · menu"
FOOTER_HELP = "? close · j/k scroll"
TREE_FOOTER_TALL = 12


def tree_footer_count(height):
    """One footer line on short terminals, two when there is room."""
    return 2 if int(height) >= TREE_FOOTER_TALL else 1


def footer_actions(row, width=None):
    """Three or four honest actions for the selected row's kind.

    With a width, drop trailing actions only when the joined line would not
    fit: the default 30-column tree shows three actions, and 24 columns still
    shows the two most important ones.
    """
    if not row or row.get("kind") == "sep":
        actions = ["? help", "p project"]
    else:
        kind = row.get("kind")
        if kind == "project":
            actions = ["? help", "enter open", "n task", "t term"]
        elif kind == "task":
            actions = ["? help", "enter open", "t term", "d close"]
        elif kind == "pane":
            actions = ["? help", "enter focus", "t term"]
            actions.append("d close" if row.get("tid") else "e edit")
        elif row.get("has_children"):
            actions = ["? help", "enter open", "l panes", "t term"]
        else:
            actions = ["? help", "enter open", "t term", "e edit"]
    if width is None:
        return actions
    for count in range(len(actions), 0, -1):
        if display_width(" · ".join(actions[:count])) <= width:
            return actions[:count]
    return actions[:1]


def mouse_footer(width=None):
    """The mouse hint, compacted only when the full line would be cut."""
    if width is None or display_width(FOOTER_MOUSE) <= width:
        return FOOTER_MOUSE
    if display_width(FOOTER_MOUSE_COMPACT) <= width:
        return FOOTER_MOUSE_COMPACT
    return FOOTER_MOUSE_TINY


def tree_footer_lines(row, height, width=None):
    """Footer strings for the tree (help mode uses ``FOOTER_HELP``)."""
    lines = [" · ".join(footer_actions(row, width))]
    if tree_footer_count(height) >= 2:
        lines.append(mouse_footer(width))
    return lines


# Key column is kept narrow so the overlay stays readable at the default
# ~30-column tree width (and still trims gracefully at 24).
HELP_SECTIONS = [
    ("NAVIGATION", [
        "j/k ↑↓     move",
        "g/G        top/bottom",
        "h/l ←→     fold/unfold",
        "Enter      open/focus",
        "?          close help",
    ]),
    ("SESSIONS", [
        "n          new task",
        "t          new terminal",
        "d          close task",
        "e          editor",
        "p          add project",
    ]),
    ("MOUSE", [
        "click      select",
        "click again open",
        "chevron    fold/unfold",
        "wheel      scroll",
        "right-click menu",
        "text select needs C-a [",
    ]),
    ("TMUX", [
        "C-a N/T/P  task/term",
        'C-a " / %  split h/v',
        "C-a z      zoom pane",
        "C-a d      detach",
    ]),
    ("DIFF / COPY", [
        "Enter file diff popup",
        "C-a [      copy-mode",
    ]),
]


def help_content():
    """``[(role, text)]``: section headings are ``section`` rows."""
    lines = []
    for section, entries in HELP_SECTIONS:
        if lines:
            lines.append(("blank", ""))
        lines.append(("section", section))
        for entry in entries:
            lines.append(("text", entry))
    return lines


def help_max_scroll(width, height):
    """Scrollable content rows inside the overlay (0 when it all fits)."""
    if width < 20 or height < 8:
        return 0
    inner_height = max(1, (height - 1) - 2)
    return max(0, len(help_content()) - inner_height)


def help_key_action(name, scroll, max_scroll):
    """Return ``(action, new_scroll)`` for a key while help is open."""
    scroll = max(0, min(int(scroll), int(max_scroll)))
    if name in ("?", "Esc", "q"):
        return "close", scroll
    if name in ("j", "Down"):
        return "scroll", min(max_scroll, scroll + 1)
    if name in ("k", "Up"):
        return "scroll", max(0, scroll - 1)
    if name == "PgDn":
        return "scroll", min(max_scroll, scroll + 5)
    if name == "PgUp":
        return "scroll", max(0, scroll - 5)
    if name in ("g", "Home"):
        return "scroll", 0
    if name in ("G", "End"):
        return "scroll", max_scroll
    return "none", scroll


# ---------------------------------------------------------------------------
# Git status presentation (pure functions)
# ---------------------------------------------------------------------------
CONFLICT_CODES = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
GIT_SECTIONS = (
    (0, "Conflicts"),
    (1, "Staged"),
    (2, "Unstaged"),
    (3, "Untracked"),
)


def _status_xy(item):
    status = item.get("status") or "  "
    if not isinstance(status, str):
        status = "  "
    status = (status + "  ")[:2]
    return status[0], status[1]


def git_file_category(item):
    """0 conflict, 1 staged, 2 unstaged, 3 untracked (render order)."""
    x, y = _status_xy(item)
    status = x + y
    if status in CONFLICT_CODES or x == "U" or y == "U":
        return 0
    if item.get("untracked"):
        return 3
    if item.get("staged"):
        return 1
    if item.get("unstaged"):
        return 2
    return 2


def sort_git_files(files):
    """Conflict, staged, unstaged, untracked; stable within a category."""
    pairs = sorted(
        enumerate(files or []),
        key=lambda pair: (git_file_category(pair[1]), pair[0]),
    )
    return [item for _index, item in pairs]


def group_git_files(files):
    """``[(label, [items])]`` in section order, omitting empty sections."""
    buckets = {category: [] for category, _label in GIT_SECTIONS}
    for item in files or []:
        buckets[git_file_category(item)].append(item)
    groups = []
    for category, label in GIT_SECTIONS:
        if buckets[category]:
            groups.append((label, buckets[category]))
    return groups


def git_frame_rows(files):
    """Render rows for the git list: section headers plus file rows.

    File entries carry their index in ``sort_git_files(files)`` so cursor and
    hit testing stay in sync with the flat list.
    """
    ordered = sort_git_files(files)
    frames = []
    position = 0
    for label, items in group_git_files(ordered):
        frames.append({"kind": "section", "label": label, "count": len(items)})
        for item in items:
            frames.append({"kind": "file", "item": item, "index": position})
            position += 1
    return frames


def git_frame_index(files, file_index):
    """Frame row index of the selected file (section rows shift it down)."""
    frames = git_frame_rows(files)
    file_index = max(0, int(file_index))
    seen = 0
    for index, frame in enumerate(frames):
        if frame.get("kind") != "file":
            continue
        if seen == file_index:
            return index
        seen += 1
    return max(0, len(frames) - 1)


def format_ahead_behind(ahead, behind, glyphs=None):
    """``↑3 ↓1`` style summary; blank when both are null/zero."""
    glyphs = glyphs or default_glyphs()
    parts = []
    if isinstance(ahead, int) and ahead > 0:
        parts.append("%s%d" % (glyphs.ahead, ahead))
    if isinstance(behind, int) and behind > 0:
        parts.append("%s%d" % (glyphs.behind, behind))
    return " ".join(parts)


def git_header_text(status, glyphs=None):
    """Return ``(branch_or_detached, ahead_behind)`` for the header line."""
    status = status or {}
    branch = status.get("branch")
    counters = format_ahead_behind(status.get("ahead"), status.get("behind"),
                                   glyphs)
    if branch:
        return branch, counters
    if status.get("detached"):
        head = status.get("head") or ""
        short = head[:7] if isinstance(head, str) and head else ""
        return ("detached @ %s" % short if short else "detached"), counters
    return "unknown", counters


def format_git_row_text(item):
    """Plain text for a porcelain entry: ``XY path`` (rename shown with ->)."""
    x, y = _status_xy(item)
    path = item.get("path") or ""
    orig = item.get("orig_path")
    if orig:
        target = "%s -> %s" % (orig, path)
    else:
        target = path
    return "%s%s %s" % (x, y, target)


def _git_role_for_char(char):
    if char in ("A",):
        return "add"
    if char in ("M", "R", "C", "T"):
        return "modify"
    if char in ("D", "U"):
        return "delete"
    return "dimmer"


def git_row_segments(item, palette=None):
    """Styled segments for a file line.

    The XY badge is coloured by state (green added, amber modified, red
    deleted/conflict); the path itself is normal text.  Untracked files show a
    single ``?`` badge.
    """
    palette = palette or default_palette()
    x, y = _status_xy(item)
    status = x + y
    path = item.get("path") or ""
    orig = item.get("orig_path")
    display_path = "%s -> %s" % (orig, path) if orig else path
    conflict = (status in CONFLICT_CODES or x == "U" or y == "U")
    if item.get("untracked") or status == "??":
        return [
            (palette.sgr(fg="modify", bold=True), "?"),
            (palette.sgr(fg="text"), " "),
            (palette.sgr(fg="text"), " "),
            (palette.sgr(fg="text"), display_path),
        ]
    if conflict:
        xstyle = palette.sgr(fg="delete", bold=True)
        ystyle = xstyle
    else:
        xstyle = palette.sgr(fg=_git_role_for_char(x))
        ystyle = palette.sgr(fg=_git_role_for_char(y))
    return [
        (xstyle, x),
        (ystyle, y),
        (palette.sgr(fg="text"), " "),
        (palette.sgr(fg="text"), display_path),
    ]


def active_context_path(state):
    """Resolve ``(project-id, context, path)`` for the active context."""
    state = state or {}
    active = state.get("active") or {}
    pid = active.get("project")
    context = active.get("context") or "proj"
    if not pid:
        return None, None, None
    project = None
    for candidate in state.get("projects") or []:
        if candidate.get("id") == pid:
            project = candidate
            break
    if project is None:
        return pid, context, None
    if context.startswith("task:"):
        tid = context[len("task:"):]
        for task in project.get("tasks") or []:
            if task.get("id") == tid:
                return pid, context, task.get("path")
        return pid, context, None
    return pid, context, project.get("path")


def git_diff_command(path, item, pager="less -R"):
    """Shell command (for display-popup, run by sh) showing the right diff.

    * tracked with unstaged changes -> ``git diff HEAD -- <path>``
    * only staged                    -> ``git diff --cached -- <path>``
    * untracked                      -> the file itself
    Everything is shell-quoted, so spaces, quotes and unicode in paths survive,
    and the pipeline is POSIX sh syntax (no bash-only constructs).
    """
    item = item or {}
    rel = item.get("path") or ""
    if item.get("untracked"):
        producer = sh_join(["cat", "--", rel])
    elif item.get("unstaged"):
        producer = sh_join(
            ["git", "-c", "color.ui=always", "diff", "HEAD", "--", rel]
        )
    elif item.get("staged"):
        producer = sh_join(
            ["git", "-c", "color.ui=always", "diff", "--cached", "--", rel]
        )
    else:
        producer = sh_join(
            ["git", "-c", "color.ui=always", "diff", "HEAD", "--", rel]
        )
    return "%s | %s" % (producer, pager)


def menu_items_for_row(row, state):
    """Return ``[(label, key, argv)]`` for the right-click menu.

    ``argv`` is a balamba command (the caller wraps it in ``run-shell -b``);
    editor items have ``None`` because they are a tmux popup, and the Help
    item has ``["@help"]`` because it sends ``?`` back into this pane.
    """
    help_item = ("Help", "?", ["@help"])
    if not row:
        return [("Add project", "p", ["internal", "add-project"]), help_item]
    pid = row.get("pid")
    kind = row.get("kind")
    items = []
    if kind == "project":
        items.append(("New task", "n", ["internal", "new-task"]))
        items.append(("New terminal", "t", ["internal", "new-terminal"]))
        items.append(("Add project", "p", ["internal", "add-project"]))
        toggle = "collapse" if row.get("expanded") else "expand"
        items.append((toggle.capitalize(), "e", ["internal", toggle, pid]))
    elif kind == "task":
        items.append(("New terminal", "t", ["internal", "new-terminal"]))
        items.append(("New task", "n", ["internal", "new-task"]))
        items.append(
            ("Close task", "d", ["internal", "close-task", pid, row.get("tid")])
        )
        toggle = "collapse" if row.get("expanded") else "expand"
        items.append(
            (toggle.capitalize(), "x",
             ["internal", toggle, pid, row.get("tid")])
        )
        items.append(("Open in editor", "o", None))
    elif kind == "pane":
        items.append(("New terminal", "t", ["internal", "new-terminal"]))
        if row.get("tid"):
            items.append(
                ("Close task", "d",
                 ["internal", "close-task", pid, row.get("tid")])
            )
        items.append(("Open in editor", "o", None))
    else:
        items.append(("New terminal", "t", ["internal", "new-terminal"]))
        if row.get("tid"):
            items.append(
                ("Close task", "d",
                 ["internal", "close-task", pid, row.get("tid")])
            )
        items.append(("Open in editor", "o", None))
    items.append(help_item)
    return items


# ---------------------------------------------------------------------------
# Small tmux / balamba helpers
# ---------------------------------------------------------------------------
def tmux_run(args, timeout=5):
    """Run plain ``tmux`` (reaches the private server via $TMUX).

    Without $TMUX there is no private server target: plain ``tmux`` would
    reach the user's normal server, which balamba must never touch.  Refuse
    instead (headless pty tests still render from state).
    """
    if not os.environ.get("TMUX"):
        return None
    try:
        proc = subprocess.run(
            ["tmux"] + list(args),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def tmux_option(name, default):
    value = tmux_run(["show", "-gv", name])
    if value is None:
        return default
    value = value.strip()
    return value if value != "" else default


def read_timeout_option(name, default):
    value = tmux_option(name, str(default))
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(1, min(number, 3600))


def pane_window_state(pane_id):
    """Return ``(window_active, window_index)`` for our own pane.

    Always pass ``-t`` (spike 4: a background pane otherwise reports the
    client's current window).
    """
    if not pane_id:
        return True, None
    out = tmux_run(
        ["display", "-p", "-t", pane_id, "#{window_active}\t#{window_index}"]
    )
    if not out:
        return True, None
    line = out.strip().splitlines()[0] if out.strip() else ""
    pieces = line.split("\t")
    active = pieces[0].strip() == "1" if pieces else True
    index = None
    if len(pieces) > 1:
        try:
            index = int(pieces[1])
        except ValueError:
            index = None
    return active, index


def list_clients():
    """Client names attached to the private server (empty when detached)."""
    out = tmux_run(["list-clients", "-F", "#{client_name}"], timeout=2)
    if not out:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def _client_rows():
    """``(client_name, window_id, pane_id)`` for every attached client."""
    out = tmux_run(
        ["list-clients", "-F", "#{client_name}\t#{window_id}\t#{pane_id}"],
        timeout=2)
    rows = []
    if not out:
        return rows
    for line in out.splitlines():
        pieces = line.split("\t")
        if len(pieces) < 3:
            continue
        rows.append((pieces[0], pieces[1], pieces[2]))
    return rows


def client_for_pane(pane_id):
    """The attached client currently displaying ``pane_id``'s window.

    ``display-popup``/``display-menu`` opened from a background pane have no
    client context of their own; without ``-c`` tmux may pick the wrong client
    when several are attached.  Prefer a client whose active pane is the pane
    itself, then any client viewing the same window.  Returns ``None`` when no
    client is attached (the callers then skip the UI instead of failing).
    """
    if not pane_id:
        return None
    window = tmux_run(["display", "-p", "-t", pane_id, "#{window_id}"])
    if not window:
        return None
    window = window.strip()
    fallback = None
    for client, client_window, active_pane in _client_rows():
        if client_window != window:
            continue
        if active_pane == pane_id:
            return client
        if fallback is None:
            fallback = client
    return fallback


def list_windows():
    """Map tab id -> {window, flag, active} plus the active window index."""
    # One process for all windows (spike 4): index, tab id, activity, active.
    out = tmux_run([
        "list-windows",
        "-F",
        "#{window_index}\t#{@balamba_tab}\t#{window_activity_flag}\t#{window_active}",
    ])
    tabs = {}
    active_window = None
    if not out:
        return {"tabs": tabs, "active_window": active_window}
    for line in out.splitlines():
        pieces = line.split("\t")
        if len(pieces) < 3:
            continue
        try:
            index = int(pieces[0])
        except ValueError:
            continue
        tab_id = pieces[1]
        flag = pieces[2].strip() == "1"
        is_active = len(pieces) > 3 and pieces[3].strip() == "1"
        if is_active:
            active_window = index
        if tab_id:
            tabs[tab_id] = {
                "window": index,
                "flag": flag,
                "active": is_active,
            }
    return {"tabs": tabs, "active_window": active_window}


def shell_quote(text):
    """POSIX sh single-quote quoting (works in sh, not just bash)."""
    text = str(text)
    if text and re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", text):
        return text
    return "'" + text.replace("'", "'\\''") + "'"


def sh_join(argv):
    return " ".join(shell_quote(a) for a in argv)


def tmux_dq(text):
    """Double-quote one tmux command argument (tmux expands $ and formats)."""
    text = str(text)
    text = text.replace("\\", "\\\\")
    text = text.replace('"', '\\"')
    text = text.replace("$", "\\$")
    return '"' + text + '"'


def tmux_format_escape(text):
    return str(text).replace("#", "##")


# ---------------------------------------------------------------------------
# Rendering: tree
# ---------------------------------------------------------------------------
TREE_MIN_WIDTH = 10
TREE_MIN_HEIGHT = 5


def row_chevron_col(row):
    """0-based column of a row's chevron (selection bar reserves column 0)."""
    return 1 + int(row.get("depth") or 0) * 2


def is_chevron_click(row, col):
    if not row or not row.get("has_children"):
        return False
    start = row_chevron_col(row)
    return start <= int(col) <= start + 1


def _row_right_segments(row, palette, glyphs):
    """Right-aligned dim count and amber unread dot."""
    right = []
    if row.get("kind") == "project":
        count = int(row.get("task_count") or 0)
        if count:
            label = "%d task%s" % (count, "" if count == 1 else "s")
            right.append((palette.sgr(fg="dim"), label))
    if row.get("unread") and row.get("kind") != "pane":
        if right:
            right.append((palette.sgr(fg="dim"), " "))
        right.append((palette.sgr(fg="unread"), glyphs.unread))
    return right


def tree_row_segments(row, selected, width, palette=None, glyphs=None):
    """Styled segments for one tree row (without the selection bar)."""
    palette = palette or default_palette()
    glyphs = glyphs or default_glyphs()
    width = max(0, int(width))
    kind = row.get("kind") or "tab"
    if kind == "sep":
        return ([(palette.sgr(fg="dimmer"), glyphs.rule * max(1, width))], [])
    depth = int(row.get("depth") or 0)
    indent = "  " * depth
    right = _row_right_segments(row, palette, glyphs)
    right_width = sum(display_width(text) for _attrs, text in right)
    budget = max(0, width - right_width - (1 if right_width else 0) - 1)

    if kind in ("project", "task"):
        marker = " "
        if row.get("has_children"):
            marker = (glyphs.chevron_open if row.get("expanded")
                      else glyphs.chevron_closed)
        prefix_segments = [
            (palette.sgr(fg="dimmer"), indent),
            (palette.sgr(fg="dim"), marker + " "),
        ]
    elif kind == "pane":
        prefix_segments = [
            (palette.sgr(fg="dimmer"), indent),
            (palette.sgr(fg="dim"), glyphs.pane + " "),
        ]
    else:
        # tab: single-pane tabs use a kind glyph, split tabs a chevron.
        if row.get("has_children"):
            marker = (glyphs.chevron_open if row.get("expanded")
                      else glyphs.chevron_closed)
            marker_style = palette.sgr(fg="dim")
        else:
            agent = (row.get("tab_kind") == "agent")
            marker = glyphs.agent if agent else glyphs.shell
            marker_style = palette.sgr(fg="accent" if agent else "dim")
        prefix_segments = [
            (palette.sgr(fg="dimmer"), indent),
            (marker_style, marker + " "),
        ]

    used = sum(display_width(text) for _attrs, text in prefix_segments)
    name = _safe_text(row.get("name") or "")
    name_budget = max(1, budget - used)
    name_text = truncate_ellipsis(name, name_budget, glyphs.ellipsis)

    if kind == "project":
        style = palette.sgr(fg="text", bold=True)
    elif row.get("active_context") or row.get("active_window"):
        style = palette.sgr(fg="accent", bold=True)
    elif kind == "pane" and row.get("pane_active"):
        style = palette.sgr(fg="accent", bold=True)
    elif kind == "pane":
        style = palette.sgr(fg="text")
    else:
        style = palette.sgr(fg="text")
    segments = list(prefix_segments) + [(style, name_text)]
    used += display_width(name_text)

    detail = ""
    detail_style = palette.sgr(fg="dim")
    if kind == "task":
        branch = row.get("branch")
        if branch:
            room = budget - used - 2
            if room >= display_width(str(branch)):
                detail = str(branch)
    elif kind == "pane":
        command = str(row.get("live_command") or "")
        if command and command != name:
            room = budget - used - 2
            if room > 1:
                detail = truncate_ellipsis(command, room, glyphs.ellipsis)
    elif kind == "tab":
        if row.get("has_children"):
            count = int(row.get("pane_count") or 0)
            label = "%d pane%s" % (count, "" if count == 1 else "s")
            room = budget - used - 2
            if room >= display_width(label):
                detail = label
        else:
            command = str(row.get("live_command") or "")
            if command and command != name:
                room = budget - used - 2
                if room > 1:
                    detail = truncate_ellipsis(command, room, glyphs.ellipsis)
    if detail:
        segments.append((detail_style, "  " + detail))

    return segments, right


def tree_row_parts(row, selected, width, palette=None, glyphs=None):
    """Full row including the accent selection bar / selection background."""
    palette = palette or default_palette()
    glyphs = glyphs or default_glyphs()
    if row.get("kind") == "sep":
        return ([(palette.sgr(fg="dimmer"), glyphs.rule * max(1, width))], [])
    segments, right = tree_row_segments(row, selected, width, palette, glyphs)
    bar = (palette.sgr(fg="accent", bold=True) if selected
           else palette.sgr(fg="dimmer"))
    return ([(bar, glyphs.select if selected else " ")] + segments, right)


def render_tree(rows, cursor, scroll, width, height, palette=None, glyphs=None):
    """Render the tree; returns ``(lines, new_scroll)``."""
    palette = palette or default_palette()
    glyphs = glyphs or default_glyphs()
    width = max(1, int(width))
    height = max(1, int(height))
    if width < TREE_MIN_WIDTH or height < TREE_MIN_HEIGHT:
        message = "balamba: pane too small"
        return [compose_segments([(palette.sgr(fg="dim"), message)], width)], 0

    row_at_cursor = None
    if rows:
        cursor = clamp_cursor(cursor, len(rows))
        while cursor < len(rows) and rows[cursor].get("kind") == "sep":
            cursor += 1
        if cursor >= len(rows):
            usable = selectable_indices(rows)
            cursor = usable[-1] if usable else 0
        row_at_cursor = rows[cursor] if rows else None

    footer = tree_footer_lines(row_at_cursor, height, width)
    body_height = max(1, height - len(footer))

    body_lines = []
    start = 0
    if not rows:
        body_lines.append(
            compose_segments([(palette.sgr(fg="dim"), "no projects")], width))
        body_lines.append(
            compose_segments([(palette.sgr(fg="dim"), "press p to add one")],
                             width))
    else:
        indices, start = viewport_slice(len(rows), cursor, scroll, body_height)
        for index in indices:
            if index is None:
                body_lines.append(
                    compose_segments([(palette.sgr(fg="dim"), glyphs.ellipsis)],
                                     width))
                continue
            row = rows[index]
            selected = index == cursor and row.get("kind") != "sep"
            segments, right = tree_row_parts(
                row, selected, width, palette, glyphs)
            base = [palette.bg("selbg")] if selected else []
            body_lines.append(
                compose_right(segments, right, width, base))
    if len(body_lines) < body_height:
        body_lines.extend([""] * (body_height - len(body_lines)))
    footer_lines = [
        compose_segments([(palette.sgr(fg="dim"), line)], width)
        for line in footer[:max(0, height - body_height)]
    ]
    return body_lines[:body_height] + footer_lines, start


def render_error(width, height, message, palette=None, glyphs=None):
    palette = palette or default_palette()
    glyphs = glyphs or default_glyphs()
    width = max(1, int(width))
    height = max(1, int(height))
    if width < TREE_MIN_WIDTH or height < TREE_MIN_HEIGHT:
        return [compose_segments([(palette.sgr(fg="dim"), "balamba: too small")],
                                 width)]
    lines = [
        compose_segments(
            [(palette.sgr(fg="delete", bold=True), "state unavailable")], width),
        compose_segments([(palette.sgr(fg="dim"), message)], width),
    ]
    footer = tree_footer_lines(None, height, width)
    body_height = max(1, height - len(footer))
    if len(lines) < body_height:
        lines.extend([""] * (body_height - len(lines)))
    lines = lines[:body_height]
    lines.extend(
        compose_segments([(palette.sgr(fg="dim"), line)], width)
        for line in footer)
    return lines[:height]


# ---------------------------------------------------------------------------
# Rendering: help overlay (in-pane, never a tmux popup)
# ---------------------------------------------------------------------------
def render_help(width, height, palette=None, glyphs=None, scroll=0,
                help_open=True):
    """Bordered in-pane help with a pinned ``? close · j/k scroll`` footer."""
    palette = palette or default_palette()
    glyphs = glyphs or default_glyphs()
    width = max(1, int(width))
    height = max(1, int(height))
    if width < 20 or height < 8:
        lines = [
            compose_segments([(palette.sgr(fg="dim"),
                               truncate_ellipsis(
                                   "help — ? closes", width, glyphs.ellipsis))],
                             width)
        ]
        return lines[:height]

    footer = [FOOTER_HELP]
    box_height = max(3, height - len(footer))
    inner_width = max(1, width - 4)
    inner_height = max(1, box_height - 2)
    content = help_content()
    max_scroll = max(0, len(content) - inner_height)
    scroll = max(0, min(int(scroll), max_scroll))

    top = (glyphs.tl + glyphs.h + " help " +
           glyphs.h * max(0, width - 9) + glyphs.tr)
    top = pad_display(top, width, "left")
    bottom = (glyphs.bl + glyphs.h * max(0, width - 2) + glyphs.br)
    bottom = pad_display(bottom, width, "left")

    lines = [compose_segments([(palette.sgr(fg="accent"), top)], width)]
    visible = content[scroll:scroll + inner_height]
    for _kind, text in visible:
        row = glyphs.v + " " + pad_display(text, inner_width) + " " + glyphs.v
        style = (palette.sgr(fg="accent", bold=True)
                 if _kind == "section" else palette.sgr(fg="text"))
        lines.append(compose_segments([(style, row)], width))
    for _ in range(inner_height - len(visible)):
        row = glyphs.v + " " * (inner_width + 2) + glyphs.v
        lines.append(compose_segments([(palette.sgr(fg="dim"), row)], width))
    lines.append(compose_segments([(palette.sgr(fg="accent"), bottom)], width))
    lines.extend(
        compose_segments([(palette.sgr(fg="dim"), line)], width)
        for line in footer)
    return lines[:height]


# ---------------------------------------------------------------------------
# Rendering: git
# ---------------------------------------------------------------------------
GIT_MIN_WIDTH = 10
GIT_MIN_HEIGHT = 5


def render_git(status, error, cursor, scroll, width, height, palette=None,
               glyphs=None):
    """Render the git pane.  Returns ``(lines, start)``."""
    palette = palette or default_palette()
    glyphs = glyphs or default_glyphs()
    width = max(1, int(width))
    height = max(1, int(height))
    if width < GIT_MIN_WIDTH or height < GIT_MIN_HEIGHT:
        return [compose_segments([(palette.sgr(fg="dim"), "balamba: pane too small")],
                                 width)], 0

    footer = "enter diff · r refresh"
    body_height = max(1, height - 2)  # header + footer
    lines = []
    if error:
        branch = "unknown"
        ahead_behind = ""
        detached = False
    elif not status:
        branch = "no status"
        ahead_behind = ""
        detached = False
    else:
        branch, ahead_behind = git_header_text(status, glyphs)
        detached = bool(status.get("detached")) and not status.get("branch")

    branch_style = (palette.sgr(fg="unread", bold=True) if detached
                    else palette.sgr(fg="text", bold=True))
    header_segments = [(branch_style, branch)]
    if ahead_behind:
        header_segments.append((palette.sgr(fg="dim"), "  "))
        header_segments.append((palette.sgr(fg="dim"), ahead_behind))
    lines.append(compose_segments(header_segments, width))

    body_lines = []
    start = 0
    if error:
        body_lines.append(
            compose_segments([(palette.sgr(fg="delete", bold=True), "error")],
                             width))
        body_lines.append(
            compose_segments([(palette.sgr(fg="dim"), error)], width))
    elif not status:
        body_lines.append(
            compose_segments([(palette.sgr(fg="dim"), "waiting for status")],
                             width))
    else:
        files = sort_git_files(status.get("files") or [])
        if not files:
            body_lines.append(
                compose_segments(
                    [(palette.sgr(fg="dim"), "working tree clean")], width))
        else:
            frames = git_frame_rows(files)
            cursor = clamp_cursor(cursor, len(files))
            cursor_frame = git_frame_index(files, cursor)
            indices, start = viewport_slice(
                len(frames), cursor_frame, scroll, body_height)
            for index in indices:
                if index is None:
                    body_lines.append(
                        compose_segments([(palette.sgr(fg="dim"),
                                           glyphs.ellipsis)], width))
                    continue
                frame = frames[index]
                if frame.get("kind") == "section":
                    text = "%s %d" % (frame.get("label"),
                                      frame.get("count") or 0)
                    body_lines.append(
                        compose_segments([(palette.sgr(fg="dim"), text)],
                                         width))
                    continue
                item = frame.get("item") or {}
                selected = frame.get("index") == cursor
                bar = (palette.sgr(fg="accent", bold=True) if selected
                       else palette.sgr(fg="dimmer"))
                segments = [(bar, glyphs.select if selected else " ")]
                segments.extend(git_row_segments(item, palette))
                # Long paths keep their tail (the filename) rather than the
                # tree prefix: left-truncate the path segment with an ellipsis.
                used = sum(display_width(text)
                           for _attrs, text in segments[:-1])
                path_attrs, path_text = segments[-1]
                room = max(1, width - used)
                if display_width(path_text) > room:
                    segments[-1] = (path_attrs,
                                    truncate_left_display(path_text, room))
                base = [palette.bg("selbg")] if selected else []
                body_lines.append(compose_segments(segments, width, base))
    if len(body_lines) < body_height:
        body_lines.extend([""] * (body_height - len(body_lines)))
    lines.extend(body_lines[:body_height])
    lines.append(compose_segments([(palette.sgr(fg="dim"), footer)], width))
    return lines[:height], start


# ---------------------------------------------------------------------------
# App loop
# ---------------------------------------------------------------------------
class UIApp:
    def __init__(self, mode):
        self.mode = mode
        self.stdin_fd = sys.stdin.fileno()
        self.stdout = sys.stdout
        self.old_termios = None
        self.running = True
        self.resize_pending = True
        self.need_poll = True
        self.dirty = True
        self.last_frame = None
        self.width = 80
        self.height = 24
        self.parser_buf = b""
        self.esc_deadline = None
        self.children = []
        self.sync_proc = None

        # theme + glyphs
        self.palette = make_palette("auto", "blue", os.environ)
        self.glyphs = make_glyphs(ascii_only=detect_ascii(os.environ))

        # tree
        self.rows = []
        self.tree_error = None
        self.state = None
        self.cursor = 0
        self.tree_scroll = 0
        self.press = None  # (y, x, row_index)
        self.tab_expanded = {}

        # help overlay
        self.help_open = False
        self.help_scroll = 0

        # git
        self.git_status = None
        self.git_error = None
        self.git_selected_path = None
        self.git_cursor = 0
        self.git_scroll = 0
        self.git_path = None
        self.git_fetched_at = 0.0

        # config / environment
        self.root = os.environ.get("BALAMBA_ROOT") or os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))
        self.state_path = os.environ.get("BALAMBA_STATE", "")
        self.pane_id = os.environ.get("TMUX_PANE", "")
        # architecture §12.1: actions run $BALAMBA_ROOT/bin/balamba.  Do not
        # honour a stale BALAMBA_BIN from the tmux server environment — tests
        # and nested installs set BALAMBA_ROOT and expect the matching bin.
        self.bin = os.path.join(self.root, "bin", "balamba")
        self.config = dict(CONFIG_DEFAULTS)
        self.next_poll = 0.0
        self.wake_r = None
        self.wake_w = None
        self._wake_registered = False

    # -- terminal -----------------------------------------------------------
    def _terminal_size(self):
        # Inside a pane trust tmux's own geometry: detached windows can be
        # resized with resize-window before the pty's winsize catches up, and
        # rendering to a stale width clips the right edge.
        if os.environ.get("TMUX") and self.pane_id:
            out = tmux_run(
                ["display", "-p", "-t", self.pane_id,
                 "#{pane_width}\t#{pane_height}"], timeout=2)
            if out:
                pieces = out.strip().split("\t")
                if len(pieces) >= 2:
                    try:
                        width = int(pieces[0])
                        height = int(pieces[1])
                    except ValueError:
                        width = height = 0
                    if width > 0 and height > 0:
                        return width, height
        for stream in (self.stdout, sys.stdin):
            try:
                size = os.get_terminal_size(stream.fileno())
            except (OSError, ValueError, AttributeError):
                continue
            if size.columns > 0 and size.lines > 0:
                return size.columns, size.lines
        return 80, 24

    def enter_terminal(self):
        try:
            self.old_termios = termios.tcgetattr(self.stdin_fd)
        except termios.error:
            self.old_termios = None
        if self.old_termios is not None:
            try:
                tty.setraw(self.stdin_fd)
            except termios.error:
                self.old_termios = None
        self._write(
            ALT_ON + CURSOR_HIDE + WRAP_OFF + MOUSE_ON + FOCUS_ON + CLEAR_SCREEN
        )
        self.width, self.height = self._terminal_size()

    def leave_terminal(self):
        # Order matters: mouse modes off, focus off, autowrap back, cursor
        # visible, then leave the alternate screen.
        try:
            self._write(
                MOUSE_OFF + FOCUS_OFF + WRAP_ON + CURSOR_SHOW + ALT_OFF
            )
        except OSError:
            pass
        if self.old_termios is not None:
            try:
                termios.tcsetattr(self.stdin_fd, termios.TCSADRAIN,
                                  self.old_termios)
            except termios.error:
                pass
        self.old_termios = None

    def _write(self, text):
        # Write through the fd directly: when the pty is already gone (EOF /
        # SIGHUP) the TextIOWrapper could keep a failed buffer and make the
        # interpreter exit 120 during shutdown.  os.write keeps shutdown clean.
        data = text.encode("utf-8", "replace")
        fd = self.stdout.fileno()
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError(errno.EIO, "short write")
            view = view[written:]

    def _tree_body_height(self):
        return max(1, self.height - tree_footer_count(self.height))

    def paint(self):
        if self.help_open:
            self.help_scroll = max(
                0, min(self.help_scroll,
                       help_max_scroll(self.width, self.height)))
            lines = render_help(self.width, self.height, self.palette,
                                self.glyphs, self.help_scroll)
        elif self.mode == "tree":
            if self.tree_error:
                lines = render_error(self.width, self.height, self.tree_error,
                                     self.palette, self.glyphs)
            else:
                lines, start = render_tree(
                    self.rows, self.cursor, self.tree_scroll, self.width,
                    self.height, self.palette, self.glyphs)
                if start != self.tree_scroll:
                    self.tree_scroll = start
        else:
            lines, start = render_git(
                self.git_status, self.git_error, self.git_cursor,
                self.git_scroll, self.width, self.height,
                self.palette, self.glyphs)
            if start != self.git_scroll:
                self.git_scroll = start

        frame_parts = []
        for row, line in enumerate(lines[: self.height]):
            frame_parts.append("\x1b[%d;1H" % (row + 1))
            if line:
                # Composed lines are padded to exactly the pane width, which
                # overwrites stale cells.  Do not append CLEAR_LINE here: with
                # autowrap off the cursor rests *on* the last cell and EL
                # would erase the final character of a full-width line.
                frame_parts.append(line)
            else:
                frame_parts.append(CLEAR_LINE)
        if len(lines) < self.height:
            frame_parts.append("\x1b[%d;1H%s" % (len(lines) + 1, CLEAR_LINE))
            frame_parts.append("\x1b[J")
        frame = "".join(frame_parts)
        self.dirty = False
        if frame == self.last_frame:
            return
        self.last_frame = frame
        try:
            self._write(frame)
        except OSError:
            self.running = False

    # -- config / tmux ------------------------------------------------------
    def load_config(self):
        mapping = [
            ("tree_width", "@balamba_tree_width", 30),
            ("git_width", "@balamba_git_width", 34),
            ("active_refresh", "@balamba_active_refresh", 1),
            ("idle_refresh", "@balamba_idle_refresh", 5),
            ("git_refresh", "@balamba_git_refresh", 2),
            ("editor", "@balamba_editor", os.environ.get("EDITOR") or "vi"),
            ("default_ref", "@balamba_default_ref", "origin/main"),
            ("default_agent", "@balamba_default_agent", "opencode"),
            ("theme", "@balamba_theme", "auto"),
            ("accent", "@balamba_accent", "blue"),
        ]
        for key, option, default in mapping:
            value = tmux_option(option, default)
            if key in REFRESH_KEYS:
                try:
                    number = int(str(value).strip())
                except (TypeError, ValueError):
                    number = default
                self.config[key] = max(1, min(number, 3600))
            else:
                self.config[key] = value if value else default
        self.palette = make_palette(self.config.get("theme", "auto"),
                                    self.config.get("accent", "blue"),
                                    os.environ)
        self.glyphs = make_glyphs(ascii_only=detect_ascii(os.environ))

    def refresh_interval(self, active):
        if self.mode == "git":
            return self.config["git_refresh"] if active else self.config[
                "idle_refresh"]
        return self.config["active_refresh"] if active else self.config[
            "idle_refresh"]

    # -- actions ------------------------------------------------------------
    def spawn(self, argv, track=True, quiet=False):
        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL if quiet else None,
                close_fds=True,
            )
        except OSError:
            return None
        if track:
            self.children.append(proc)
        # Give a state-changing action a moment, then poll quickly.
        self.next_poll = min(self.next_poll, time.monotonic() + 0.2)
        return proc

    def internal(self, *args):
        return [self.bin, "internal"] + [str(a) for a in args]

    def reap(self):
        alive = []
        for proc in self.children:
            if proc.poll() is None:
                alive.append(proc)
            else:
                self.need_poll = True
                self.dirty = True
        self.children = alive

    def open_popup(self, command, cwd=None):
        if not os.environ.get("TMUX"):
            return
        client = client_for_pane(self.pane_id)
        if not client:
            # No attached client: a popup has nowhere to appear.  Stay quiet
            # instead of surfacing a tmux error from a background action.
            return
        args = ["tmux", "display-popup", "-c", client, "-E",
                "-w", "90%", "-h", "85%"]
        if self.pane_id:
            args += ["-t", self.pane_id]
        if cwd:
            args += ["-d", cwd]
        args.append(command)
        self.spawn(args, track=False)

    def open_editor(self, path):
        if not path:
            return
        editor = self.config.get("editor") or os.environ.get("EDITOR") or "vi"
        self.open_popup(editor, cwd=path)

    def open_menu(self, row):
        if not os.environ.get("TMUX"):
            return
        client = client_for_pane(self.pane_id)
        if not client:
            return
        items = menu_items_for_row(row, self.state)
        pid = row.get("pid") if row else None
        context = row.get("context") if row else None
        args = ["tmux", "display-menu", "-c", client, "-T", tmux_format_escape(
            "balamba" if not row else "balamba · %s" % row.get("name"))]
        if self.pane_id:
            args += ["-t", self.pane_id]
        for label, key, argv in items:
            if argv == ["@help"]:
                # Send '?' back into this pane: the menu lives in tmux, the
                # overlay lives here.
                command = "send-keys -t %s -l -- ?" % shell_quote(self.pane_id)
                args += [tmux_format_escape(label), key, command]
                continue
            if argv is None:
                # Editor is a tmux popup, not a CLI mutation.
                path = row.get("path") if row else None
                if not path:
                    continue
                command = ("display-popup -c %s -E -w 90%% -h 85%%"
                           " -d %s %s") % (
                               shell_quote(client),
                               shell_quote(path),
                               self.config.get("editor") or "vi",
                           )
                args += [tmux_format_escape(label), key, command]
                continue
            full = list(argv)
            if full[:1] == ["internal"] and pid:
                # Pass the clicked project/context explicitly: the CLI then
                # never depends on whichever context happens to be active
                # (no activate-then-delay race).
                if full[1:2] == ["new-task"]:
                    command = sh_join(self.internal("new-task", pid))
                elif full[1:2] == ["new-terminal"]:
                    command = sh_join(
                        self.internal("new-terminal", pid, context or "proj"))
                else:
                    command = sh_join(self.internal(*full[1:]))
            else:
                command = sh_join(full)
            item_cmd = "run-shell -b " + tmux_dq(
                tmux_format_escape(command))
            args += [tmux_format_escape(label), key, item_cmd]
        self.spawn(args, track=False)

    # -- tree actions -------------------------------------------------------
    def current_row(self):
        if not self.rows:
            return None
        self.cursor = clamp_cursor(self.cursor, len(self.rows))
        if self.rows[self.cursor].get("kind") == "sep":
            usable = selectable_indices(self.rows)
            if not usable:
                return None
            if self.cursor > usable[-1]:
                self.cursor = usable[-1]
            else:
                self.cursor = step_selectable(self.rows, self.cursor, 1)
        return self.rows[self.cursor] if self.rows else None

    def activate_row(self, row):
        if not row:
            return
        pid = row.get("pid")
        context = row.get("context") or "proj"
        if row.get("kind") == "pane":
            self.spawn(self.internal(
                "focus-pane", pid, context, row.get("tab_id"),
                row.get("pane_index")))
            return
        if row.get("kind") == "tab" and row.get("window") is not None:
            self.spawn(self.internal("activate", pid, context,
                                     row.get("window")))
        else:
            self.spawn(self.internal("activate", pid, context))

    def toggle_row(self, row, expand=None):
        if not row:
            return
        kind = row.get("kind")
        if kind in ("project", "task"):
            if expand is None:
                expand = not bool(row.get("expanded"))
            verb = "expand" if expand else "collapse"
            if kind == "task":
                self.spawn(self.internal(verb, row.get("pid"),
                                         row.get("tid")))
            else:
                self.spawn(self.internal(verb, row.get("pid")))
            return
        if kind == "tab" and row.get("has_children"):
            if expand is None:
                expand = not bool(row.get("expanded"))
            self.tab_expanded[row.get("key")] = bool(expand)
            row["expanded"] = bool(expand)
            self.dirty = True

    def new_task(self):
        row = self.current_row()
        pid = row.get("pid") if row else None
        if not pid and self.state:
            pid = (self.state.get("active") or {}).get("project")
        if not pid:
            return
        # One command, with the project named explicitly.  This used to
        # activate first and delay new-task by 0.35s, which raced whenever the
        # selected row was not the active context.
        self.spawn(self.internal("new-task", pid))

    def new_terminal(self):
        row = self.current_row()
        if not row:
            return
        pid = row.get("pid")
        context = row.get("context") or "proj"
        if not pid:
            return
        # Same rule as new_task: name the target context, do not activate
        # first and hope the next command happens after the state write.
        self.spawn(self.internal("new-terminal", pid, context))

    def close_task(self):
        row = self.current_row()
        if not row:
            return
        pid = row.get("pid")
        tid = row.get("tid")
        if pid and tid:
            self.spawn(self.internal("close-task", pid, tid))

    def move_cursor(self, delta):
        if not self.rows:
            return
        self.cursor = step_selectable(self.rows, self.cursor, delta)
        self.dirty = True

    def ensure_visible(self):
        if self.mode == "tree":
            body_height = self._tree_body_height()
            indices, start = viewport_slice(
                len(self.rows), self.cursor, self.tree_scroll, body_height)
            self.tree_scroll = start
            if self.cursor not in [i for i in indices if i is not None]:
                self.tree_scroll = max(0, self.cursor - body_height + 2)
        else:
            files = self.git_files_for_display()
            list_height = max(1, self.height - 2)
            frames = git_frame_rows(files)
            cursor_frame = git_frame_index(files, self.git_cursor) if files else 0
            _indices, start = viewport_slice(
                max(1, len(frames)), cursor_frame, self.git_scroll, list_height)
            self.git_scroll = start

    def git_files_for_display(self):
        if not self.git_status:
            return []
        return sort_git_files(self.git_status.get("files") or [])

    def git_select(self, index):
        files = self.git_files_for_display()
        if not files:
            self.git_cursor = 0
            self.git_selected_path = None
            return
        self.git_cursor = clamp_cursor(index, len(files))
        self.git_selected_path = files[self.git_cursor].get("path")

    # -- help overlay -------------------------------------------------------
    def open_help(self):
        self.help_open = True
        self.help_scroll = 0
        self.dirty = True

    def handle_help_key(self, name):
        action, scroll = help_key_action(
            name, self.help_scroll,
            help_max_scroll(self.width, self.height))
        if action == "close":
            self.help_open = False
            self.help_scroll = 0
        elif action == "scroll":
            self.help_scroll = scroll
        self.dirty = True

    def handle_help_mouse(self, b, x, y, pressed):
        if b & 64:
            direction = -1 if (b & 3) == 0 else 1
            max_scroll = help_max_scroll(self.width, self.height)
            self.help_scroll = max(
                0, min(max_scroll, self.help_scroll + direction * 3))
            self.dirty = True

    # -- tree events --------------------------------------------------------
    def handle_tree_key(self, name):
        if name == "?":
            self.open_help()
            return
        if name in ("j", "Down"):
            self.move_cursor(1)
        elif name in ("k", "Up"):
            self.move_cursor(-1)
        elif name in ("g", "Home"):
            usable = selectable_indices(self.rows)
            if usable:
                self.cursor = usable[0]
                self.tree_scroll = 0
                self.dirty = True
        elif name in ("G", "End"):
            usable = selectable_indices(self.rows)
            if usable:
                self.cursor = usable[-1]
                self.dirty = True
        elif name == "PgUp":
            self.move_cursor(-max(1, self._tree_body_height() - 2))
        elif name == "PgDn":
            self.move_cursor(max(1, self._tree_body_height() - 2))
        elif name in ("h", "Left"):
            row = self.current_row()
            if row and row.get("kind") in ("project", "task", "tab") and row.get(
                    "expanded") and row.get("has_children"):
                self.toggle_row(row, expand=False)
            else:
                pk = parent_key(row)
                if pk:
                    index = find_row(self.rows, pk)
                    if index is not None:
                        self.cursor = index
                        self.dirty = True
        elif name in ("l", "Right"):
            row = self.current_row()
            if row and row.get("has_children") and row.get("kind") in (
                    "project", "task", "tab"):
                if not row.get("expanded"):
                    self.toggle_row(row, expand=True)
                else:
                    child = first_child_index(self.rows, self.cursor)
                    if child is not None:
                        self.cursor = child
                        self.dirty = True
        elif name == "Enter":
            self.activate_row(self.current_row())
        elif name == "n":
            self.new_task()
        elif name == "t":
            self.new_terminal()
        elif name == "d":
            self.close_task()
        elif name == "e":
            row = self.current_row()
            if row:
                self.open_editor(row.get("path"))
        elif name == "p":
            self.spawn(self.internal("add-project"))
        elif name == "r":
            self.need_poll = True
            self.dirty = True
        elif name == "q":
            pass
        else:
            return
        self.ensure_visible()

    def handle_tree_mouse(self, b, x, y, pressed):
        col = max(0, x - 1)
        row_y = max(0, y - 1)
        if b & 64:
            # Wheel: 64 up, 65 down (1-based SGR button code).
            direction = -1 if (b & 3) == 0 else 1
            self.move_cursor(direction * 3)
            self.ensure_visible()
            return
        if b & 32:
            return  # drag/motion: ignored
        if b & 3 == 2:
            if pressed:
                index = self._tree_row_at(row_y)
                if index is not None and self.rows[index].get(
                        "kind") != "sep":
                    self.cursor = index
                    self.dirty = True
                    self.open_menu(self.rows[index])
            return
        if b & 3 != 0:
            return
        if pressed:
            index = self._tree_row_at(row_y)
            self.press = (row_y, col, index)
            return
        # Release: press+release on the same row = click.
        press = self.press
        self.press = None
        if not press:
            return
        py, px, pindex = press
        index = self._tree_row_at(row_y)
        if index is None or index != pindex or py != row_y:
            return
        row = self.rows[index]
        if row.get("kind") == "sep":
            return
        if is_chevron_click(row, px):
            self.cursor = index
            self.toggle_row(row)
            self.dirty = True
            return
        if index == self.cursor:
            self.activate_row(row)
        else:
            self.cursor = index
            self.dirty = True
        self.ensure_visible()

    def _tree_row_at(self, row_y):
        indices, _start = viewport_slice(
            len(self.rows), self.cursor, self.tree_scroll,
            self._tree_body_height())
        return hit_test(row_y, indices)

    # -- git events ---------------------------------------------------------
    def handle_git_key(self, name):
        files = self.git_files_for_display()
        if name == "?":
            self.open_help()
            return
        if name in ("j", "Down"):
            if files:
                self.git_select(self.git_cursor + 1)
                self.dirty = True
        elif name in ("k", "Up"):
            if files:
                self.git_select(self.git_cursor - 1)
                self.dirty = True
        elif name in ("g", "Home"):
            self.git_select(0)
            self.git_scroll = 0
            self.dirty = True
        elif name in ("G", "End"):
            if files:
                self.git_select(len(files) - 1)
                self.dirty = True
        elif name == "PgUp":
            self.git_select(self.git_cursor - max(1, self.height - 3))
            self.dirty = True
        elif name == "PgDn":
            self.git_select(self.git_cursor + max(1, self.height - 3))
            self.dirty = True
        elif name == "Enter":
            self.open_git_file()
        elif name == "r":
            self.need_poll = True
            self.git_fetched_at = 0.0
            self.dirty = True
        elif name == "q":
            pass
        else:
            return
        self.ensure_visible()

    def handle_git_mouse(self, b, x, y, pressed):
        row_y = max(0, y - 1)
        files = self.git_files_for_display()
        if b & 64:
            direction = -1 if (b & 3) == 0 else 1
            if files:
                self.git_select(self.git_cursor + direction * 3)
                self.dirty = True
                self.ensure_visible()
            return
        if b & 3 != 0 or not pressed:
            return
        if row_y < 1:
            return
        if not files:
            return
        list_height = max(1, self.height - 2)
        frames = git_frame_rows(files)
        indices, _start = viewport_slice(
            len(frames), git_frame_index(files, self.git_cursor),
            self.git_scroll, list_height)
        frame_index = hit_test(row_y - 1, indices)
        if frame_index is None:
            return
        frame = frames[frame_index]
        if frame.get("kind") != "file":
            return
        self.git_select(frame.get("index") or 0)
        self.dirty = True
        self.open_git_file()

    def open_git_file(self, index=None):
        files = self.git_files_for_display()
        if not files:
            return
        if index is None:
            index = self.git_cursor
        index = clamp_cursor(index, len(files))
        item = files[index]
        path = self.git_path or (
            self.git_status.get("path") if self.git_status else None)
        pager = "less -R" if shutil.which("less") else "cat"
        command = git_diff_command(path, item, pager=pager)
        self.open_popup(command, cwd=path)

    # -- state/tmux polling -------------------------------------------------
    def poll(self):
        active, _pane_index = pane_window_state(self.pane_id)
        was_active = getattr(self, "_last_active", None)
        self._last_active = active
        if self.mode == "git" and active and was_active is False:
            # The window just became active: do not wait for the next tick.
            self.git_fetched_at = 0.0
        if self.mode == "tree" and active and os.environ.get("TMUX"):
            # Adopt native splits once per active-window poll.  A split shows
            # up within roughly one refresh (1 s).  Fire and forget: the
            # backend debounces unchanged pane sets, and a failed sync is
            # retried on the next poll.
            if self.sync_proc is None or self.sync_proc.poll() is not None:
                self.sync_proc = self.spawn(self.internal("sync"), track=False,
                                            quiet=True)
        state, error = read_state_file(self.state_path)
        self.state = state
        if self.mode == "tree":
            live = list_windows() if active else {
                "tabs": {}, "active_window": None}
            if state is not None:
                self.tree_error = None
                old_key = None
                if self.rows:
                    old_key = self.rows[clamp_cursor(
                        self.cursor, len(self.rows))].get("key")
                self.rows = build_rows(state, live, self.tab_expanded)
                if old_key:
                    index = find_row(self.rows, old_key)
                    if index is not None:
                        self.cursor = index
                    else:
                        self.cursor = clamp_cursor(self.cursor, len(self.rows))
                elif self.rows:
                    self.cursor = self._initial_cursor()
                self.cursor = clamp_cursor(self.cursor, len(self.rows))
                if self.rows and self.rows[self.cursor].get("kind") == "sep":
                    self.cursor = step_selectable(self.rows, self.cursor, 1)
                self.dirty = True
            else:
                self.tree_error = error or "state unavailable"
                self.rows = []
                self.dirty = True
        else:
            if state is None:
                self.git_error = error or "state unavailable"
                self.git_status = None
                self.git_path = None
                self.dirty = True
            else:
                _pid, _ctx, path = active_context_path(state)
                path_changed = path != self.git_path
                self.git_path = path
                now = time.monotonic()
                due = (now - self.git_fetched_at) >= self.config["git_refresh"]
                if path is None:
                    self.git_status = None
                    self.git_error = "no active context"
                    self.dirty = True
                elif active and (path_changed or due or self.need_poll):
                    self.fetch_status(path)
                self.dirty = True
        self.need_poll = False
        self.next_poll = time.monotonic() + self.refresh_interval(active)

    def _initial_cursor(self):
        if not self.state or not self.rows:
            return 0
        active = self.state.get("active") or {}
        pid = active.get("project")
        context = active.get("context") or "proj"
        key = ("project:%s" % pid) if context == "proj" else (
            "task:%s:%s" % (pid, context[len("task:"):]))
        index = find_row(self.rows, key)
        return index if index is not None else 0

    def fetch_status(self, path):
        try:
            proc = subprocess.run(
                [self.bin, "internal", "status", path],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            self.git_status = None
            self.git_error = "git status timed out"
            self.git_fetched_at = time.monotonic()
            self.dirty = True
            return
        except OSError as exc:
            self.git_status = None
            self.git_error = "cannot run balamba: %s" % exc
            self.git_fetched_at = time.monotonic()
            self.dirty = True
            return
        self.git_fetched_at = time.monotonic()
        text = proc.stdout.decode("utf-8", "replace").strip()
        try:
            data = json.loads(text)
        except (json.JSONDecodeError, ValueError):
            self.git_status = None
            err = proc.stderr.decode("utf-8", "replace").strip()
            self.git_error = err or text or "git status failed"
            self.dirty = True
            return
        if not isinstance(data, dict):
            self.git_status = None
            self.git_error = "git status returned an unexpected document"
            self.dirty = True
            return
        if data.get("error") and not data.get("files") and not data.get("branch"):
            self.git_status = None
            self.git_error = str(data.get("error"))
            self.dirty = True
            return
        self.git_status = data
        self.git_error = None
        # Keep the selection on the same path when it still exists.
        files = sort_git_files(data.get("files") or [])
        if files:
            if self.git_selected_path is not None:
                for index, item in enumerate(files):
                    if item.get("path") == self.git_selected_path:
                        self.git_cursor = index
                        break
                else:
                    self.git_cursor = clamp_cursor(self.git_cursor, len(files))
            else:
                self.git_cursor = clamp_cursor(self.git_cursor, len(files))
            self.git_selected_path = files[self.git_cursor].get("path")
        else:
            self.git_cursor = 0
            self.git_selected_path = None
        self.dirty = True

    # -- main loop ----------------------------------------------------------
    def _install_signals(self):
        self.wake_r, self.wake_w = os.pipe()
        os.set_blocking(self.wake_r, False)
        os.set_blocking(self.wake_w, False)
        try:
            signal.set_wakeup_fd(self.wake_w)
            self._wake_registered = True
        except (ValueError, OSError):
            self._wake_registered = False

        def on_stop(_signum, _frame):
            self.running = False

        def on_winch(_signum, _frame):
            self.resize_pending = True
            self.dirty = True

        signal.signal(signal.SIGTERM, on_stop)
        signal.signal(signal.SIGINT, on_stop)
        signal.signal(signal.SIGHUP, on_stop)
        signal.signal(signal.SIGWINCH, on_winch)

    def _drain_wake(self):
        if self.wake_r is None:
            return
        try:
            while True:
                chunk = os.read(self.wake_r, 4096)
                if not chunk:
                    break
        except (BlockingIOError, OSError):
            pass

    def _handle_events(self):
        events, rest = parse_input(self.parser_buf, force_esc=False)
        self.parser_buf = rest
        if events:
            self.esc_deadline = None
            # Any input may mean this pane just got focus; poll soon.
            self.next_poll = min(self.next_poll, time.monotonic() + 0.05)
        for event in events:
            if event[0] == "key":
                name = event[1]
                if name == "FocusIn":
                    self.need_poll = True
                    self.dirty = True
                    if self.mode == "git":
                        self.git_fetched_at = 0.0
                    continue
                if name == "FocusOut":
                    continue
                if self.help_open:
                    self.handle_help_key(name)
                    continue
                if self.mode == "tree":
                    self.handle_tree_key(name)
                else:
                    self.handle_git_key(name)
            elif event[0] == "mouse":
                _tag, b, x, y, pressed = event
                if self.help_open:
                    self.handle_help_mouse(b, x, y, pressed)
                elif self.mode == "tree":
                    self.handle_tree_mouse(b, x, y, pressed)
                else:
                    self.handle_git_mouse(b, x, y, pressed)
            self.dirty = True
        if self.parser_buf == b"\x1b":
            if self.esc_deadline is None:
                self.esc_deadline = time.monotonic() + 0.05
        elif self.parser_buf:
            self.esc_deadline = None

    def _flush_esc(self):
        if self.parser_buf == b"\x1b" and self.esc_deadline is not None:
            if time.monotonic() >= self.esc_deadline:
                events, rest = parse_input(self.parser_buf, force_esc=True)
                self.parser_buf = rest
                self.esc_deadline = None
                for event in events:
                    if event[0] == "key":
                        if self.help_open:
                            self.handle_help_key(event[1])
                        elif self.mode == "tree":
                            self.handle_tree_key(event[1])
                        else:
                            self.handle_git_key(event[1])
                self.dirty = True

    def run(self):
        self._install_signals()
        try:
            self.enter_terminal()
            self.load_config()
            self.next_poll = 0.0
            while self.running:
                if self.resize_pending:
                    self.resize_pending = False
                    self.width, self.height = self._terminal_size()
                    self.last_frame = None
                    self.dirty = True
                now = time.monotonic()
                timeout = max(0.0, self.next_poll - now)
                if self.esc_deadline is not None:
                    delay = max(0.0, self.esc_deadline - now)
                    timeout = delay if timeout is None else min(timeout, delay)
                if timeout is not None:
                    timeout = min(timeout, 5.0)

                fds = [self.stdin_fd]
                if self.wake_r is not None:
                    fds.append(self.wake_r)
                try:
                    ready, _w, _e = select.select(fds, [], [], timeout)
                except (OSError, ValueError):
                    break

                if not self.running:
                    break
                if self.wake_r is not None and self.wake_r in ready:
                    self._drain_wake()
                    if self.resize_pending:
                        self.resize_pending = False
                        self.width, self.height = self._terminal_size()
                        self.last_frame = None
                        self.dirty = True

                if self.stdin_fd in ready:
                    try:
                        data = os.read(self.stdin_fd, 4096)
                    except OSError as exc:
                        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                            data = b""
                        elif exc.errno == errno.EIO:
                            break  # pty closed
                        else:
                            break
                    if data == b"":
                        break  # EOF: exit cleanly
                    self.parser_buf += data
                    self._handle_events()
                    self._flush_esc()

                self.reap()

                now = time.monotonic()
                if self.need_poll or now >= self.next_poll:
                    self.poll()
                self._flush_esc()

                if self.dirty:
                    self.paint()
        finally:
            self.running = False
            for proc in self.children:
                if proc.poll() is None:
                    try:
                        proc.terminate()
                    except OSError:
                        pass
            if self.sync_proc is not None and self.sync_proc.poll() is None:
                try:
                    self.sync_proc.terminate()
                except OSError:
                    pass
            self.leave_terminal()
            if self._wake_registered:
                try:
                    signal.set_wakeup_fd(-1)
                except (ValueError, OSError):
                    pass
            for fd in (self.wake_r, self.wake_w):
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            self.wake_r = self.wake_w = None
        return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) != 1 or argv[0] not in ("tree", "git"):
        sys.stderr.write("usage: ui.py tree|git\n")
        return 1
    app = UIApp(argv[0])
    try:
        return app.run()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
