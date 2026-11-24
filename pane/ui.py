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
}

REFRESH_KEYS = ("active_refresh", "idle_refresh", "git_refresh")

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


def _apply_attrs(text, attrs, base_attrs=()):
    """Wrap text in SGR attributes; combine base (selection) with local style."""
    codes = [str(c) for c in base_attrs if str(c)]
    codes += [str(c) for c in attrs if str(c)]
    if not codes:
        return text
    return sgr(*codes) + text + RESET


def compose_segments(segments, width, base_attrs=()):
    """Render ``[(attrs, text)]`` to exactly ``width`` columns.

    Truncation is by display width across segment boundaries, so no half-cell
    is ever written.  ``base_attrs`` (selection reverse, for instance) applies
    to every cell, including padding, and is merged with each segment style.
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


def build_rows(state, live=None):
    """Build the flat tree row model from a state document.

    Row dicts carry everything the renderer and the action handlers need::

        kind        project | task | tab
        key         stable identity across refreshes
        pid, tid    owning project/task ids (tid only for task rows/tabs)
        context     "proj" or "task:<tid>"
        tab_id      terminal id (tab rows only)
        window      live window index (tab rows only)
        depth       0/1/2
        name        display text
        path        project/task worktree path for the editor
        expanded    project/task expansion flag
        has_children
        unread      window_activity_flag, propagated to parents
        active_context / active_window
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

    def tab_unread(tab, info):
        # Never show a marker for the window the client is currently viewing.
        if info.get("active"):
            return False
        return bool(info.get("flag"))

    def make_tab_row(tab, pid, tid, context, depth, path):
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
        return {
            "kind": "tab",
            "key": "tab:%s:%s" % (pid, tab_id),
            "pid": pid,
            "tid": tid,
            "context": context,
            "tab_id": tab_id,
            "window": window if isinstance(window, int) else None,
            "depth": depth,
            "name": tab.get("name") or "tab",
            "path": path,
            "expanded": False,
            "has_children": False,
            "unread": tab_unread(tab, info),
            "active_context": False,
            "active_window": is_active_window,
            "tab_kind": tab.get("kind") or "shell",
        }

    rows = []
    for project in state.get("projects") or []:
        pid = project.get("id")
        if not pid:
            continue
        project_expanded = bool(project.get("expanded"))
        project_tabs = project.get("tabs") or []
        tasks = project.get("tasks") or []
        project_unread = False
        child_rows = []

        if project_expanded:
            for tab in sorted_tabs(project_tabs):
                info = _live_tab_info(live, tab.get("id"))
                project_unread = project_unread or tab_unread(tab, info)
                child_rows.append(
                    make_tab_row(tab, pid, None, "proj", 1, project.get("path"))
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
                    task_unread = task_unread or tab_unread(tab, info)
                    task_rows.append(
                        make_tab_row(tab, pid, tid, context, 2, task.get("path"))
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
                    "unread": task_unread,
                    "active_context": (
                        pid == active_pid and active_ctx == context
                    ),
                    "active_window": False,
                    "tab_kind": None,
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
            "unread": project_unread,
            "active_context": (
                pid == active_pid and active_ctx == "proj"
            ),
            "active_window": False,
            "tab_kind": None,
        })
        rows.extend(child_rows)

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
    if row.get("kind") == "tab":
        if row.get("tid"):
            return "task:%s:%s" % (row.get("pid"), row.get("tid"))
        return "project:%s" % row.get("pid")
    return None


# ---------------------------------------------------------------------------
# Git status presentation (pure functions)
# ---------------------------------------------------------------------------
CONFLICT_CODES = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}


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


def format_ahead_behind(ahead, behind):
    """``↑3 ↓1`` style summary; blank when both are null/zero."""
    parts = []
    if isinstance(ahead, int) and ahead > 0:
        parts.append("↑%d" % ahead)
    if isinstance(behind, int) and behind > 0:
        parts.append("↓%d" % behind)
    return " ".join(parts)


def git_header_text(status):
    """Return ``(branch_or_detached, ahead_behind)`` for the header line."""
    status = status or {}
    branch = status.get("branch")
    if not branch:
        branch = "detached HEAD" if status.get("detached") else "unknown"
    return branch, format_ahead_behind(status.get("ahead"), status.get("behind"))


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


def git_row_segments(item):
    """Styled segments for a file line: staged green, unstaged red/yellow."""
    x, y = _status_xy(item)
    status = x + y
    path = item.get("path") or ""
    orig = item.get("orig_path")
    display_path = "%s -> %s" % (orig, path) if orig else path
    cat = git_file_category(item)

    if cat == 0 or status in CONFLICT_CODES or x == "U" or y == "U":
        xstyle = [SGR_BOLD, SGR_MAGENTA]
        ystyle = [SGR_BOLD, SGR_MAGENTA]
        pstyle = [SGR_MAGENTA]
    elif item.get("untracked") or status == "??":
        xstyle = [SGR_CYAN]
        ystyle = [SGR_CYAN]
        pstyle = [SGR_CYAN]
    elif item.get("staged") and item.get("unstaged"):
        xstyle = [SGR_GREEN]
        ystyle = [SGR_RED]
        pstyle = []
    elif item.get("staged"):
        xstyle = [SGR_GREEN]
        ystyle = [SGR_GREEN]
        pstyle = [SGR_GREEN]
    else:
        xstyle = [SGR_RED]
        ystyle = [SGR_RED]
        pstyle = [SGR_RED]
    return [
        (xstyle, x),
        (ystyle, y),
        ([], " "),
        (pstyle, display_path),
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

    ``argv`` is a balamba command (the caller will wrap it in
    ``run-shell -b``); editor items are added by the app because they are a
    tmux popup rather than a CLI mutation.
    """
    if not row:
        return [("Add project", "p", ["internal", "add-project"])]
    pid = row.get("pid")
    kind = row.get("kind")
    items = []
    if kind == "project":
        items.append(("New task", "n", ["internal", "new-task"]))
        items.append(("New terminal", "t", ["internal", "new-terminal"]))
        items.append(("Add project", "p", ["internal", "add-project"]))
        toggle = "collapse" if row.get("expanded") else "expand"
        items.append(
            (toggle.capitalize(), "e", ["internal", toggle, pid])
        )
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
    else:
        items.append(("New terminal", "t", ["internal", "new-terminal"]))
        if row.get("tid"):
            items.append(
                ("Close task", "d",
                 ["internal", "close-task", pid, row.get("tid")])
            )
        items.append(("Open in editor", "o", None))
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


def tree_row_segments(row, selected, width):
    depth = int(row.get("depth") or 0)
    indent = "  " * depth
    kind = row.get("kind")
    if kind in ("project", "task"):
        if row.get("has_children"):
            chevron = "▾" if row.get("expanded") else "▸"
        else:
            chevron = " "
        prefix = indent + chevron + " "
    else:
        icon = "$" if row.get("tab_kind") != "agent" else "A"
        prefix = indent + icon + " "

    name = row.get("name") or ""
    style = []
    if row.get("active_context"):
        style = [SGR_BOLD, SGR_GREEN]
    elif row.get("active_window"):
        style = [SGR_BOLD, SGR_CYAN]

    unread = bool(row.get("unread"))
    dot_room = 2 if unread and width >= 3 else 0
    left_width = max(1, width - dot_room)
    left = truncate_display(prefix + name, left_width)
    segments = [(style, left)]
    if unread and dot_room:
        used = display_width(left)
        gap = max(0, width - used - 1)
        segments.append(([], " " * gap))
        segments.append(([SGR_YELLOW], "●"))
    return segments


def render_tree(rows, cursor, scroll, width, height):
    """Render the tree; returns ``(lines, new_scroll)``."""
    if width < TREE_MIN_WIDTH or height < TREE_MIN_HEIGHT:
        message = "balamba: pane too small"
        return [compose_segments([([SGR_DIM], message)], max(width, 1))], 0
    if not rows:
        return [compose_segments([([SGR_DIM], "no projects — press p")],
                                 width)], 0

    cursor = clamp_cursor(cursor, len(rows))
    indices, start = viewport_slice(len(rows), cursor, scroll, height)
    lines = []
    for index in indices:
        if index is None:
            lines.append(compose_segments([([SGR_DIM], "…")], width))
            continue
        row = rows[index]
        selected = index == cursor
        base = [SGR_REVERSE] if selected else []
        lines.append(
            compose_segments(tree_row_segments(row, selected, width),
                             width, base)
        )
    return lines, start


def render_error(width, height, message):
    if width < TREE_MIN_WIDTH or height < TREE_MIN_HEIGHT:
        return [compose_segments([([SGR_DIM], "balamba: too small")],
                                 max(width, 1))]
    lines = [
        compose_segments([([SGR_BOLD, SGR_RED], "state unavailable")], width),
        compose_segments([([SGR_DIM], message)], width),
    ]
    return lines


# ---------------------------------------------------------------------------
# Rendering: git
# ---------------------------------------------------------------------------
GIT_MIN_WIDTH = 10
GIT_MIN_HEIGHT = 5


def render_git(status, error, cursor, scroll, width, height):
    """Render the git pane.  Returns ``(lines, start)``."""
    if width < GIT_MIN_WIDTH or height < GIT_MIN_HEIGHT:
        return [compose_segments([([SGR_DIM], "balamba: pane too small")],
                                 max(width, 1))], 0

    lines = []
    if error:
        branch = "unknown"
        ahead_behind = ""
    elif not status:
        branch = "no status"
        ahead_behind = ""
    else:
        branch, ahead_behind = git_header_text(status)

    header_segments = [([SGR_BOLD], branch)]
    if ahead_behind:
        header_segments.append(([], "  "))
        header_segments.append(([SGR_GREEN], ahead_behind))
    lines.append(compose_segments(header_segments, width))

    if error:
        lines.append(compose_segments([([SGR_RED], "error")], width))
        lines.append(compose_segments([([SGR_DIM], error)], width))
        return lines, 0

    if not status:
        lines.append(compose_segments([([SGR_DIM], "waiting for status")], width))
        return lines, 0

    files = sort_git_files(status.get("files") or [])
    if not files:
        lines.append(compose_segments([([SGR_GREEN], "clean")], width))
        return lines, 0

    lines.append(compose_segments([([SGR_DIM], "─" * width)], width))
    list_height = max(0, height - 2)
    cursor = clamp_cursor(cursor, len(files))
    indices, start = viewport_slice(len(files), cursor, scroll, list_height)
    for index in indices:
        if index is None:
            lines.append(compose_segments([([SGR_DIM], "…")], width))
            continue
        selected = index == cursor
        base = [SGR_REVERSE] if selected else []
        segments = git_row_segments(files[index])
        # Long paths keep their tail (the filename) rather than the tree prefix.
        if len(segments) >= 4 and display_width(segments[3][1]) > width:
            used = display_width(segments[0][1]) + display_width(segments[1][1]) + 1
            segments[3] = (segments[3][0],
                           truncate_left_display(segments[3][1],
                                                 max(1, width - used)))
        lines.append(compose_segments(segments, width, base))
    return lines, start


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
        self.pending = []

        # tree
        self.rows = []
        self.tree_error = None
        self.state = None
        self.cursor = 0
        self.tree_scroll = 0
        self.press = None  # (y, x, row_index)

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

    def paint(self):
        if self.mode == "tree":
            if self.tree_error:
                lines = render_error(self.width, self.height, self.tree_error)
                start = 0
            else:
                lines, start = render_tree(self.rows, self.cursor,
                                           self.tree_scroll, self.width,
                                           self.height)
                if start != self.tree_scroll:
                    self.tree_scroll = start
        else:
            result = render_git(self.git_status, self.git_error, self.git_cursor,
                                self.git_scroll, self.width, self.height)
            lines, start = result
            if start != self.git_scroll:
                self.git_scroll = start

        frame_parts = []
        for row, line in enumerate(lines[: self.height]):
            frame_parts.append("\x1b[%d;1H" % (row + 1))
            frame_parts.append(line)
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

    def refresh_interval(self, active):
        if self.mode == "git":
            return self.config["git_refresh"] if active else self.config[
                "idle_refresh"]
        return self.config["active_refresh"] if active else self.config[
            "idle_refresh"]

    # -- actions ------------------------------------------------------------
    def spawn(self, argv, track=True):
        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=None,
                close_fds=True,
            )
        except OSError:
            return None
        if track:
            self.children.append(proc)
        # Give a state-changing action a moment, then poll quickly.
        self.next_poll = min(self.next_poll, time.monotonic() + 0.2)
        return proc

    def schedule(self, argv, delay=0.0):
        if delay <= 0:
            self.spawn(argv)
        else:
            self.pending.append((time.monotonic() + delay, argv))

    def internal(self, *args):
        return [self.bin, "internal"] + [str(a) for a in args]

    def run_pending(self):
        if not self.pending:
            return
        now = time.monotonic()
        ready = []
        keep = []
        for due, argv in self.pending:
            (ready if now >= due else keep).append((due, argv))
        self.pending = keep
        for _due, argv in ready:
            self.spawn(argv)

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
        args = ["tmux", "display-popup", "-E", "-w", "90%", "-h", "85%"]
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
        items = menu_items_for_row(row, self.state)
        pid = row.get("pid") if row else None
        context = row.get("context") if row else None
        args = ["tmux", "display-menu", "-T", tmux_format_escape(
            "balamba" if not row else "balamba · %s" % row.get("name"))]
        if self.pane_id:
            args += ["-t", self.pane_id]
        for label, key, argv in items:
            if argv is None:
                # Editor is a tmux popup, not a CLI mutation.
                path = row.get("path") if row else None
                if not path:
                    continue
                command = "tmux display-popup -E -w 90%% -h 85%% -d %s %s" % (
                    shell_quote(path),
                    self.config.get("editor") or "vi",
                )
                args += [tmux_format_escape(label), key, command]
                continue
            full = list(argv)
            if full[:1] == ["internal"] and pid:
                # Menu actions must apply to the clicked context, not only the
                # active one; activating first is cheap and idempotent.
                if full[1:2] == ["new-task"]:
                    if self._selected_needs_activate(pid, "proj"):
                        command = (
                            sh_join(self.internal("activate", pid, "proj"))
                            + " && "
                            + sh_join(self.internal("new-task"))
                        )
                    else:
                        command = sh_join(self.internal("new-task"))
                elif full[1:2] == ["new-terminal"]:
                    target_ctx = context or "proj"
                    if self._selected_needs_activate(pid, target_ctx):
                        command = (
                            sh_join(self.internal("activate", pid, target_ctx))
                            + " && "
                            + sh_join(self.internal("new-terminal"))
                        )
                    else:
                        command = sh_join(self.internal("new-terminal"))
                else:
                    command = sh_join(self.internal(*full[1:]))
            else:
                command = sh_join(full)
            item_cmd = "run-shell -b " + tmux_dq(
                tmux_format_escape(command))
            args += [tmux_format_escape(label), key, item_cmd]
        self.spawn(args, track=False)

    def _selected_needs_activate(self, pid, context):
        if not self.state:
            return False
        active = self.state.get("active") or {}
        return not (active.get("project") == pid
                    and active.get("context") == context)

    # -- tree actions -------------------------------------------------------
    def current_row(self):
        if not self.rows:
            return None
        self.cursor = clamp_cursor(self.cursor, len(self.rows))
        return self.rows[self.cursor]

    def activate_row(self, row):
        if not row:
            return
        pid = row.get("pid")
        context = row.get("context") or "proj"
        if row.get("kind") == "tab" and row.get("window") is not None:
            self.spawn(self.internal("activate", pid, context,
                                     row.get("window")))
        else:
            self.spawn(self.internal("activate", pid, context))

    def toggle_row(self, row, expand=None):
        if not row or row.get("kind") not in ("project", "task"):
            return
        if expand is None:
            expand = not bool(row.get("expanded"))
        verb = "expand" if expand else "collapse"
        if row.get("kind") == "task":
            self.spawn(self.internal(verb, row.get("pid"), row.get("tid")))
        else:
            self.spawn(self.internal(verb, row.get("pid")))

    def new_task(self):
        row = self.current_row()
        pid = row.get("pid") if row else None
        if not pid and self.state:
            pid = (self.state.get("active") or {}).get("project")
        if not pid:
            return
        if self._selected_needs_activate(pid, "proj"):
            self.schedule(self.internal("activate", pid, "proj"))
            self.schedule(self.internal("new-task"), delay=0.35)
        else:
            self.spawn(self.internal("new-task"))

    def new_terminal(self):
        row = self.current_row()
        if not row:
            return
        pid = row.get("pid")
        context = row.get("context") or "proj"
        if self._selected_needs_activate(pid, context):
            self.schedule(self.internal("activate", pid, context))
            self.schedule(self.internal("new-terminal"), delay=0.35)
        else:
            self.spawn(self.internal("new-terminal"))

    def close_task(self):
        row = self.current_row()
        if not row:
            return
        pid = row.get("pid")
        tid = row.get("tid")
        if not tid and row.get("kind") == "tab":
            tid = row.get("tid")
        if pid and tid:
            self.spawn(self.internal("close-task", pid, tid))

    def move_cursor(self, delta):
        if not self.rows:
            return
        self.cursor = clamp_cursor(self.cursor + delta, len(self.rows))
        self.dirty = True

    def ensure_visible(self):
        if self.mode == "tree":
            indices, start = viewport_slice(
                len(self.rows), self.cursor, self.tree_scroll, self.height)
            self.tree_scroll = start
            if self.cursor not in [i for i in indices if i is not None]:
                self.tree_scroll = max(0, self.cursor - self.height + 2)
        else:
            list_height = max(1, self.height - 2)
            indices, start = viewport_slice(
                max(1, len(self.git_files_for_display())), self.git_cursor,
                self.git_scroll, list_height)
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

    # -- tree events --------------------------------------------------------
    def handle_tree_key(self, name):
        if name in ("j", "Down"):
            self.move_cursor(1)
        elif name in ("k", "Up"):
            self.move_cursor(-1)
        elif name in ("g", "Home"):
            if self.rows:
                self.cursor = 0
                self.tree_scroll = 0
                self.dirty = True
        elif name in ("G", "End"):
            if self.rows:
                self.cursor = len(self.rows) - 1
                self.dirty = True
        elif name == "PgUp":
            self.move_cursor(-max(1, self.height - 2))
        elif name == "PgDn":
            self.move_cursor(max(1, self.height - 2))
        elif name in ("h", "Left"):
            row = self.current_row()
            if row and row.get("kind") in ("project", "task") and row.get(
                    "expanded"):
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
            if row and row.get("kind") in ("project", "task"):
                if not row.get("expanded"):
                    self.toggle_row(row, expand=True)
                else:
                    # Move into the first child, if it is currently visible.
                    if self.rows and self.cursor + 1 < len(self.rows):
                        child = self.rows[self.cursor + 1]
                        if child.get("depth") == row.get("depth", 0) + 1:
                            self.cursor += 1
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
                if index is not None:
                    self.cursor = index
                    self.dirty = True
                self.open_menu(self.current_row())
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
        if (row.get("kind") in ("project", "task") and row.get("has_children")
                and px <= int(row.get("depth") or 0) * 2 + 1):
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
            len(self.rows), self.cursor, self.tree_scroll, self.height)
        return hit_test(row_y, indices)

    # -- git events ---------------------------------------------------------
    def handle_git_key(self, name):
        files = self.git_files_for_display()
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
        list_height = max(1, self.height - 2)
        if files:
            indices, start = viewport_slice(
                len(files), self.git_cursor, self.git_scroll, list_height)
            self.git_scroll = start

    def handle_git_mouse(self, b, x, y, pressed):
        row_y = max(0, y - 1)
        if b & 64:
            direction = -1 if (b & 3) == 0 else 1
            files = self.git_files_for_display()
            if files:
                self.git_select(self.git_cursor + direction * 3)
                self.dirty = True
                list_height = max(1, self.height - 2)
                _indices, start = viewport_slice(
                    len(files), self.git_cursor, self.git_scroll, list_height)
                self.git_scroll = start
            return
        if b & 3 != 0 or not pressed:
            return
        if row_y < 2:
            return
        files = self.git_files_for_display()
        if not files:
            return
        list_height = max(1, self.height - 2)
        indices, _start = viewport_slice(
            len(files), self.git_cursor, self.git_scroll, list_height)
        index = hit_test(row_y - 2, indices)
        if index is None:
            return
        self.git_select(index)
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
                self.rows = build_rows(state, live)
                if old_key:
                    index = find_row(self.rows, old_key)
                    if index is not None:
                        self.cursor = index
                    else:
                        self.cursor = clamp_cursor(self.cursor, len(self.rows))
                elif self.rows:
                    self.cursor = self._initial_cursor()
                self.cursor = clamp_cursor(self.cursor, len(self.rows))
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
                if self.mode == "tree":
                    self.handle_tree_key(name)
                else:
                    self.handle_git_key(name)
            elif event[0] == "mouse":
                _tag, b, x, y, pressed = event
                if self.mode == "tree":
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
                        if self.mode == "tree":
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
                if self.pending:
                    due = min(item[0] for item in self.pending)
                    delay = max(0.0, due - now)
                    timeout = delay if timeout is None else min(timeout, delay)
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

                self.run_pending()
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
