#!/usr/bin/env python3
"""Pure-function unit tests for pane/ui.py (plain python, no pytest).

Run directly:

    python3 test/t_ui.py

It prints TAP-ish ``ok``/``not ok`` lines and exits non-zero on any failure.
test/t_ui.sh runs this file together with the tmux/pty integration tests.
"""

import importlib.util
import ast
import json
import os
import shlex
import re
import subprocess
import sys

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def plain_text(lines):
    return ANSI_RE.sub("", "".join(lines))

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
UI_PATH = os.path.join(REPO, "pane", "ui.py")


def load_ui():
    spec = importlib.util.spec_from_file_location("balamba_ui", UI_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ui = load_ui()
RUN = 0
FAILED = 0


def check(condition, description, detail=""):
    global RUN, FAILED
    RUN += 1
    if condition:
        print("ok %d - %s" % (RUN, description))
    else:
        FAILED += 1
        print("not ok %d - %s" % (RUN, description))
        if detail:
            print("# %s" % detail.replace("\n", " "))


def eq(expected, actual, description):
    check(expected == actual, description,
          "expected %r, got %r" % (expected, actual))


def pane(index, name, live_command="", active=False, launched="shell"):
    return {
        "index": index,
        "cwd": "/tmp",
        "launched": launched,
        "name": name,
        "live_command": live_command or name,
        "active": active,
    }


def tab(tid, name, window, kind="shell", agent=None, panes=None,
        active_pane=0):
    panes = panes or [pane(0, "zsh", "zsh", True)]
    return {
        "id": tid,
        "name": name,
        "kind": kind,
        "agent": agent,
        "session": None if kind == "shell" else "ses_" + "0" * 32,
        "window": window,
        "pane_count": len(panes),
        "layout": "",
        "active_pane": active_pane,
        "panes": panes,
    }


def task(tid, name, path, expanded=False, tabs=None):
    return {
        "id": tid,
        "name": name,
        "slug": tid[2:],
        "path": path,
        "branch": tid[2:],
        "base_ref": "origin/main",
        "created_at": "2026-01-01T00:00:00Z",
        "expanded": expanded,
        "tabs": tabs or [],
    }


def project(pid, name, path, expanded=True, tabs=None, tasks=None):
    return {
        "id": pid,
        "name": name,
        "path": path,
        "expanded": expanded,
        "tabs": tabs or [],
        "tasks": tasks or [],
    }


def fixture_state():
    return {
        "version": 1,
        "active": {"project": "p_alpha", "context": "task:t_one", "window": 2},
        "projects": [
            project("p_alpha", "alpha", "/work/alpha", True,
                    tabs=[tab("tty_a0", "shell 1", 1)],
                    tasks=[
                        task("t_one", "One", "/work/alpha/one", True,
                             tabs=[tab("tty_a1", "shell 2", 2),
                                   tab("tty_a2", "opencode 1", 3, "agent",
                                       "opencode")]),
                        task("t_two", "Two", "/work/alpha/two", False),
                    ]),
            project("p_beta", "beta", "/work/beta", False,
                    tabs=[tab("tty_b0", "shell 1", 4)],
                    tasks=[task("t_b1", "Beta task", "/work/beta/b1", False)]),
        ],
    }


def tcol(palette, role):
    return palette.fg(role)


# ---------------------------------------------------------------------------
# Palette and glyphs
# ---------------------------------------------------------------------------
def test_palette():
    true = ui.make_palette("truecolor", "blue", {})
    eq("truecolor", true.theme, "palette: truecolor selected explicitly")
    eq("\x1b[38;2;201;209;217m", true.fg("text"), "palette: text is #c9d1d9")
    eq("\x1b[38;2;240;246;252m", true.fg("bright"),
       "palette: bright is #f0f6fc")
    eq("\x1b[38;2;110;118;129m", true.fg("dim"), "palette: dim is #6e7681")
    eq("\x1b[38;2;72;79;88m", true.fg("dimmer"),
       "palette: dimmer is #484f58")
    eq("\x1b[38;2;88;166;255m", true.fg("accent"),
       "palette: default blue accent #58a6ff")
    eq("\x1b[38;2;210;153;34m", true.fg("unread"),
       "palette: unread is amber #d29922")
    eq("\x1b[38;2;63;185;80m", true.fg("add"),
       "palette: git add is green #3fb950")
    eq("\x1b[38;2;248;81;73m", true.fg("delete"),
       "palette: git delete/conflict is red #f85149")
    eq("\x1b[48;2;28;33;40m", true.bg("selbg"),
       "palette: selection background is #1c2128")

    magenta = ui.make_palette("truecolor", "magenta", {})
    eq("\x1b[38;2;188;140;255m", magenta.fg("accent"),
       "palette: magenta accent")
    check(magenta.fg("accent") != true.fg("accent"),
          "palette: accent config changes the one accent colour")

    fallback = ui.make_palette("256", "blue", {})
    eq("256", fallback.theme, "palette: 256 mode")
    eq("\x1b[38;5;252m", fallback.fg("text"), "palette: 256 text is 252")
    eq("\x1b[38;5;231m", fallback.fg("bright"), "palette: 256 bright is 231")
    eq("\x1b[38;5;244m", fallback.fg("dim"), "palette: 256 dim is 244")
    eq("\x1b[38;5;238m", fallback.fg("dimmer"), "palette: 256 dimmer is 238")
    eq("\x1b[38;5;75m", fallback.fg("accent"), "palette: 256 blue accent is 75")
    eq("\x1b[38;5;178m", fallback.fg("unread"), "palette: 256 amber is 178")
    eq("\x1b[38;5;71m", fallback.fg("add"), "palette: 256 git add is 71")
    eq("\x1b[38;5;203m", fallback.fg("delete"),
       "palette: 256 git delete is 203")
    eq("\x1b[48;5;236m", fallback.bg("selbg"),
       "palette: 256 selection background is 236")
    eq("\x1b[38;5;141m", ui.make_palette("256", "magenta", {}).fg("accent"),
       "palette: 256 magenta accent is 141")

    basic = ui.make_palette("16", "blue", {})
    eq("16", basic.theme, "palette: 16 mode")
    eq("\x1b[37m", basic.fg("text"), "palette: 16 text")
    eq("\x1b[34m", basic.fg("accent"), "palette: 16 blue accent")
    eq("\x1b[32m", basic.fg("add"), "palette: 16 git add")
    eq("\x1b[31m", basic.fg("delete"), "palette: 16 git delete")
    eq("\x1b[100m", basic.bg("selbg"), "palette: 16 selection background")
    check("38;2;" not in basic.fg("text") and "38;5;" not in basic.fg("text"),
          "palette: 16 mode never emits 24-bit or 256-colour codes")

    # Auto detection from the environment, explicit config always wins.
    eq("truecolor", ui.detect_theme("auto", {
        "COLORTERM": "truecolor", "TERM": "xterm-256color"}),
       "detect: COLORTERM=truecolor wins over TERM")
    eq("truecolor", ui.detect_theme("auto", {
        "COLORTERM": "24bit", "TERM": "screen"}),
       "detect: COLORTERM=24bit")
    eq("256", ui.detect_theme("auto", {"TERM": "tmux-256color"}),
       "detect: *-256color TERM")
    eq("16", ui.detect_theme("auto", {"TERM": "xterm"}),
       "detect: plain TERM falls back to 16")
    eq("16", ui.detect_theme("auto", {}),
       "detect: empty environment falls back to 16")
    eq("16", ui.detect_theme("16", {
        "COLORTERM": "truecolor", "TERM": "xterm-256color"}),
       "detect: explicit theme overrides detection")
    eq("blue", ui.normalize_accent(""), "accent: empty falls back to blue")
    eq("blue", ui.normalize_accent("chartreuse"),
       "accent: unknown falls back to blue")

    # The SGR cache returns the exact same object and does not grow per call.
    a = true.sgr(fg="text", bold=True)
    before = len(true._cache)
    b = true.sgr(fg="text", bold=True)
    after = len(true._cache)
    check(a is b, "cache: repeated style returns the same cached string")
    eq(before, after, "cache: repeated style does not allocate a new entry")
    check(true.sgr(fg="text") != true.sgr(fg="accent"),
          "cache: different roles get different entries")
    check("\x1b[1;38;2;201;209;217m" == a or
          "\x1b[38;2;201;209;217;1m" == a,
          "cache: bold is combined into one SGR sequence", a)


def test_glyphs():
    uni = ui.make_glyphs(False)
    eq("▾", uni.chevron_open, "glyphs: unicode chevron open")
    eq("▸", uni.chevron_closed, "glyphs: unicode chevron closed")
    eq("◆", uni.agent, "glyphs: agent glyph")
    eq("›", uni.shell, "glyphs: shell glyph")
    eq("·", uni.pane, "glyphs: pane glyph")
    eq("▌", uni.select, "glyphs: selection bar")
    eq(1, ui.display_width(uni.select), "glyphs: selection bar is one cell")
    ascii_g = ui.make_glyphs(True)
    eq("v", ascii_g.chevron_open, "glyphs: ascii chevron")
    eq(">", ascii_g.chevron_closed, "glyphs: ascii closed chevron")
    eq("|", ascii_g.select, "glyphs: ascii selection bar")
    eq("~", ascii_g.ellipsis, "glyphs: ascii ellipsis")
    check(ascii_g.agent.isascii() and ascii_g.shell.isascii() and
          ascii_g.pane.isascii() and ascii_g.unread.isascii(),
          "glyphs: ascii mode has no non-ASCII markers")
    eq(True, ui.detect_ascii({"LANG": "C"}),
       "ascii: LANG=C selects the ASCII fallback")
    eq(False, ui.detect_ascii({"LANG": "en_US.UTF-8"}),
       "ascii: UTF-8 locale keeps unicode glyphs")
    eq(True, ui.detect_ascii({"LC_ALL": "C", "LANG": "en_US.UTF-8"}),
       "ascii: LC_ALL wins over LANG")


# ---------------------------------------------------------------------------
# Row building, unread propagation and active markers
# ---------------------------------------------------------------------------
def test_rows():
    state = fixture_state()
    live = {
        "tabs": {
            "tty_a0": {"window": 1, "flag": False, "active": False},
            "tty_a1": {"window": 2, "flag": False, "active": True},
            "tty_a2": {"window": 3, "flag": True, "active": False},
            "tty_b0": {"window": 4, "flag": True, "active": False},
        },
        "active_window": 2,
    }
    rows = ui.build_rows(state, live)
    names = [(r["kind"], r["name"], r["depth"]) for r in rows]
    eq([
        ("project", "alpha", 0),
        ("tab", "shell 1", 2),
        ("task", "One", 1),
        ("tab", "shell 2", 2),
        ("tab", "opencode 1", 2),
        ("task", "Two", 1),
        ("sep", "", 0),
        ("project", "beta", 0),
    ], names, "row order: project, own tabs, tasks, expanded task tabs")

    beta = rows[-1]
    eq(False, beta["expanded"], "collapsed project keeps its state flag")
    eq(True, beta["has_children"], "collapsed project still knows it has children")
    eq(True, beta["unread"], "unread propagates from hidden project tabs")
    eq([], [r for r in rows if r["pid"] == "p_beta" and r["kind"] == "task"],
       "collapsed project hides its task rows")

    one = [r for r in rows if r["kind"] == "task" and r["tid"] == "t_one"][0]
    eq(True, one["expanded"], "task expansion comes from state")
    eq(True, one["unread"], "unread propagates from a terminal to its task")
    eq(True, one["active_context"], "active task row is marked as the context")

    alpha = rows[0]
    eq(True, alpha["unread"], "unread propagates from a terminal to the project")
    eq(False, alpha["active_context"], "project row is not active when a task is")
    eq(2, alpha["task_count"], "project carries its task count")

    shell2 = [r for r in rows if r.get("tab_id") == "tty_a1"][0]
    eq(False, shell2["unread"], "currently active window never shows the marker")
    eq(True, shell2["active_window"], "live window index marks the active tab")
    eq(False, shell2["active_context"], "tab rows use the window marker, not context")
    eq(True, shell2["single"], "one-pane tab collapses to a single row")
    eq(False, shell2["has_children"], "collapsed tab has no child pane rows")
    eq("zsh", shell2["live_command"], "single tab carries its pane's live command")

    opencode = [r for r in rows if r.get("tab_id") == "tty_a2"][0]
    eq(True, opencode["unread"], "background terminal shows the unread marker")
    eq("agent", opencode["tab_kind"], "tab kind is carried for the icon")
    eq(False, opencode["active_window"], "a background tab is not the active window")

    # A tab whose live window index drifted still finds its parent.
    eq("task:t_one", opencode["context"],
       "task tab carries its owner context")
    eq("/work/alpha/one", opencode["path"],
       "task tab carries the worktree path for the editor")

    # State.active.window is the fallback when no live list is available
    # (inactive chrome pane): active highlight still works.
    rows2 = ui.build_rows(state, {"tabs": {}, "active_window": None})
    shell2b = [r for r in rows2 if r.get("tab_id") == "tty_a1"][0]
    eq(True, shell2b["active_window"],
       "stored active window is used when live windows are unavailable")

    # Project row count is right-aligned and the separator is not selectable.
    sep = [r for r in rows if r["kind"] == "sep"][0]
    eq([i for i, r in enumerate(rows) if r["kind"] != "sep"],
       ui.selectable_indices(rows),
       "separator rows do not participate in selection")


def test_rows_empty():
    eq([], ui.build_rows({"version": 1, "active": {}, "projects": []}, {}),
       "empty state builds no rows")
    eq([], ui.build_rows(None, None), "missing state builds no rows")
    eq("project:p", ui.parent_key(
        {"kind": "task", "pid": "p", "tid": "t"}),
       "parent key of a task")
    eq("task:p:t", ui.parent_key(
        {"kind": "tab", "pid": "p", "tid": "t", "tab_id": "tty_x"}),
       "parent key of a task tab")
    eq("tab:p:tty_x", ui.parent_key(
        {"kind": "pane", "pid": "p", "tid": "t", "tab_id": "tty_x"}),
       "parent key of a pane")


def test_collapse_rules():
    state = {
        "version": 1,
        "active": {"project": "p", "context": "task:t", "window": 1},
        "projects": [project("p", "proj", "/w", True, tasks=[
            task("t", "Task", "/w/t", True, tabs=[
                tab("tty_one", "single", 1,
                    panes=[pane(0, "zsh", "zsh", True)]),
                tab("tty_two", "split", 2,
                    panes=[pane(0, "zsh", "zsh", True),
                           pane(1, "nvim", "nvim", False)],
                    active_pane=0),
            ]),
        ])],
    }
    rows = ui.build_rows(state, {})
    tabs = [r for r in rows if r["kind"] == "tab"]
    eq(2, len(tabs), "collapse: two tab rows")
    single, split = tabs
    eq(True, single["single"], "collapse: one-pane tab is single")
    eq(2, single["depth"], "collapse: single-pane tab indents 4 (depth 2)")
    eq(False, single["has_children"], "collapse: single-pane tab has no chevron")
    eq(False, split["single"], "collapse: two-pane tab keeps a tab row")
    eq(True, split["expanded"], "collapse: split tab expands by default")
    eq(2, split["pane_count"], "collapse: split tab carries its pane count")
    panes = [r for r in rows if r["kind"] == "pane"]
    eq(2, len(panes), "collapse: split tab renders two pane rows")
    eq([3, 3], [p["depth"] for p in panes],
       "collapse: pane rows indent 6 (depth 3)")
    eq(["zsh", "nvim"], [p["name"] for p in panes],
       "collapse: pane rows use their names")
    eq([True, False], [p["pane_active"] for p in panes],
       "collapse: active pane flag is carried")

    collapsed = ui.build_rows(state, {}, {"tab:p:tty_two": False})
    eq([], [r for r in collapsed if r["kind"] == "pane"],
       "collapse: a collapsed split tab hides its pane rows")
    split2 = [r for r in collapsed if r["kind"] == "tab" and
              r["tab_id"] == "tty_two"][0]
    eq(False, split2["expanded"], "collapse: in-memory tab expansion is used")
    eq(True, split2["has_children"],
       "collapse: a collapsed split tab still shows a chevron")


# ---------------------------------------------------------------------------
# Mouse hit testing (SGR coordinates are 1-based)
# ---------------------------------------------------------------------------
def test_hit_testing():
    eq(0, ui.hit_test(0, [0, 1, 2]), "hit test: first row")
    eq(2, ui.hit_test(2, [0, 1, 2]), "hit test: third row")
    eq(None, ui.hit_test(3, [0, 1, 2]), "hit test: below the viewport")
    eq(None, ui.hit_test(-1, [0, 1, 2]), "hit test: negative row")
    eq(5, ui.hit_test(1, [4, 5, 6]), "hit test: scrolled viewport offset")
    eq(None, ui.hit_test(0, [None, 4, 5]), "hit test: ellipsis row is not a row")

    # 1-based SGR y -> 0-based display row -> global row index.
    indices = [10, 11, 12]
    eq(11, ui.hit_test(2 - 1, indices), "SGR y=2 maps to the second visible row")
    eq(12, ui.hit_test(3 - 1, indices), "SGR y=3 maps to the third visible row")

    rows = ui.build_rows(fixture_state(), {})
    wide = [r for r in rows if r["kind"] == "project"][0]
    eq(1, ui.row_chevron_col(wide),
       "chevron column follows the reserved selection bar")
    check(ui.is_chevron_click(wide, 1) and ui.is_chevron_click(wide, 2),
          "chevron hit test accepts its two-column cell")
    check(not ui.is_chevron_click(wide, 4),
          "chevron hit test rejects the row body")
    task_row = [r for r in rows if r["kind"] == "task"][0]
    eq(3, ui.row_chevron_col(task_row),
       "task chevron is indented two columns")
    pane_row = {"kind": "pane", "depth": 3, "has_children": False}
    check(not ui.is_chevron_click(pane_row, 7),
          "pane rows never own a chevron")


# ---------------------------------------------------------------------------
# SGR mouse / key parser
# ---------------------------------------------------------------------------
def test_parser():
    events, rest = ui.parse_input(b"\x1b[<0;5;3M")
    eq([("mouse", 0, 5, 3, True)], events, "SGR left press parses")
    eq(b"", rest, "SGR complete sequence leaves no remainder")

    events, rest = ui.parse_input(b"\x1b[<2;25;6M\x1b[<2;25;6m")
    eq([("mouse", 2, 25, 6, True), ("mouse", 2, 25, 6, False)], events,
       "multiple SGR events in one read")
    eq(b"", rest, "multiple events consume the buffer")

    events, rest = ui.parse_input(b"\x1b[<0;5")
    eq([], events, "partial SGR yields no events")
    eq(b"\x1b[<0;5", rest, "partial SGR is retained")
    events, rest = ui.parse_input(rest + b";3M")
    eq([("mouse", 0, 5, 3, True)], events, "partial SGR completes on the next read")

    events, rest = ui.parse_input(b"j\x1b[<0;5;3Mk")
    eq([("key", "j"), ("mouse", 0, 5, 3, True), ("key", "k")], events,
       "key and mouse events interleave in one read")

    eq(([("mouse", 64, 3, 4, True)], b""), ui.parse_input(b"\x1b[<64;3;4M"),
       "wheel-up button decodes as b=64")
    eq(([("mouse", 65, 3, 4, True)], b""), ui.parse_input(b"\x1b[<65;3;4M"),
       "wheel-down button decodes as b=65")

    eq(([("key", "Up")], b""), ui.parse_input(b"\x1b[A"), "arrow up")
    eq(([("key", "Down")], b""), ui.parse_input(b"\x1b[B"), "arrow down")
    eq(([("key", "Right")], b""), ui.parse_input(b"\x1b[C"), "arrow right")
    eq(([("key", "Left")], b""), ui.parse_input(b"\x1b[D"), "arrow left")
    eq(([("key", "Home")], b""), ui.parse_input(b"\x1b[H"), "Home (CSI H)")
    eq(([("key", "End")], b""), ui.parse_input(b"\x1b[F"), "End (CSI F)")
    eq(([("key", "Home")], b""), ui.parse_input(b"\x1b[1~"), "Home (CSI 1~)")
    eq(([("key", "End")], b""), ui.parse_input(b"\x1b[4~"), "End (CSI 4~)")
    eq(([("key", "PgUp")], b""), ui.parse_input(b"\x1b[5~"), "PageUp")
    eq(([("key", "PgDn")], b""), ui.parse_input(b"\x1b[6~"), "PageDown")
    eq(([("key", "FocusIn")], b""), ui.parse_input(b"\x1b[I"), "focus-in event")
    eq(([("key", "FocusOut")], b""), ui.parse_input(b"\x1b[O"), "focus-out event")

    eq(([("key", "Enter")], b""), ui.parse_input(b"\r"), "CR is Enter")
    eq(([("key", "Enter")], b""), ui.parse_input(b"\n"), "LF is Enter")
    eq(([("key", "j")], b""), ui.parse_input(b"j"), "printable key")
    eq(([("key", "?")], b""), ui.parse_input(b"?"), "question mark key")
    eq(([], b"\x1b"), ui.parse_input(b"\x1b"), "lone ESC is held briefly")
    eq(([("key", "Esc")], b""), ui.parse_input(b"\x1b", force_esc=True),
       "lone ESC is emitted after the timeout")
    eq(([("key", "é")], b""), ui.parse_input("é".encode()), "utf-8 printable key")
    events, rest = ui.parse_input("é".encode()[:1])
    eq([], events, "partial utf-8 yields no event")
    eq("é".encode()[:1], rest, "partial utf-8 is retained")
    events, _rest = ui.parse_input(rest + "é".encode()[1:])
    eq([("key", "é")], events, "partial utf-8 completes")


# ---------------------------------------------------------------------------
# Unicode-safe truncation / padding
# ---------------------------------------------------------------------------
def test_unicode():
    eq(3, ui.display_width("abc"), "ASCII width")
    eq(4, ui.display_width("漢字"), "CJK width is two cells per character")
    eq(2, ui.display_width("🙂"), "emoji width is two cells")
    eq(1, ui.display_width("e\u0301"), "combining mark adds no width")
    eq(0, ui.display_width("\u0301"), "standalone combining mark width 0")

    eq("ab", ui.truncate_display("abcdef", 2), "truncate by columns")
    eq("a漢字", ui.truncate_display("a漢字b", 5), "CJK truncated on a cell boundary")
    eq("a漢", ui.truncate_display("a漢字", 4), "never emit half of a wide character")
    eq("", ui.truncate_display("漢", 1), "wide char does not fit in one column")
    eq("🙂", ui.truncate_display("🙂🙂", 2), "one emoji fits in two columns")
    eq("", ui.truncate_display("🙂", 1), "emoji is never split")
    eq("e\u0301", ui.truncate_display("e\u0301x", 1),
       "combining mark stays with its base character")

    eq("abcdef", ui.truncate_ellipsis("abcdef", 6),
       "ellipsis: text that fits is unchanged")
    eq("ab…", ui.truncate_ellipsis("abcdef", 3),
       "ellipsis: truncation is marked by display width")
    eq("漢…", ui.truncate_ellipsis("漢字", 3),
       "ellipsis: wide characters are never split")
    eq("…", ui.truncate_ellipsis("漢字", 1),
       "ellipsis: a one-column budget is just the marker")
    eq("ab~", ui.truncate_ellipsis("abcdef", 3, "~"),
       "ellipsis: ASCII fallback marker")

    eq("abcdef", ui.pad_display("abcdef", 6), "exact width is unchanged")
    eq("ab    ", ui.pad_display("ab", 6), "left padding")
    eq("    ab", ui.pad_display("ab", 6, "right"), "right padding")
    eq(4, ui.display_width(ui.pad_display("漢", 4)),
       "padding counts wide cells correctly")
    eq(4, ui.display_width(ui.pad_display("🙂🙂🙂", 4)),
       "padding after wide-char truncation is exact")

    wrapped = ui.compose_segments([([ui.SGR_BOLD], "漢字🙂abc")], 5)
    plain = ui.compose_plain([([], "漢字🙂abc")], 5)
    eq(5, ui.display_width(plain), "compose truncates to exactly the width")
    eq(True, wrapped.startswith("\x1b[") or "\x1b[" in wrapped,
       "styled compose emits ANSI")

    eq("a b c ", ui.compose_plain([([], "a\nb\x1bc")], 6),
       "control characters in names/errors are rendered as spaces")

    # Styled segments truncate across boundaries and pad the remainder.
    plain = ui.compose_plain([([], "a漢"), ([], "b🙂c")], 6)
    eq(6, ui.display_width(plain), "segmented compose pads to width")
    eq("a漢b🙂", plain, "segmented compose truncates without splitting")

    # Right-aligned counts keep the row at the exact width.
    right = ui.compose_right([([], "alpha")], [([], "2 tasks")], 24)
    eq(24, ui.display_width(right), "compose_right pads to the pane width")
    eq("alpha            2 tasks", right,
       "compose_right pins the dim count to the right edge")
    right_unicode = ui.compose_right(
        [([], "漢字")], [([], ui.make_glyphs(False).unread)], 10)
    eq(10, ui.display_width(right_unicode),
       "compose_right truncates and pads unicode safely")


# ---------------------------------------------------------------------------
# Viewport / cursor visibility
# ---------------------------------------------------------------------------
def test_viewport():
    for total, cursor, scroll, height in [
        (1, 0, 0, 5), (5, 0, 0, 5), (5, 4, 0, 5), (20, 0, 0, 5),
        (20, 4, 0, 5), (20, 5, 0, 5), (20, 19, 0, 5), (20, 10, 0, 5),
        (20, 10, 8, 5), (20, 10, 18, 5), (100, 50, 0, 10),
        (100, 99, 90, 10), (20, 0, 0, 1), (20, 10, 0, 1),
    ]:
        indices, start = ui.viewport_slice(total, cursor, scroll, height)
        visible = [i for i in indices if i is not None]
        check(len(indices) <= height,
              "viewport %d/%d/%d/%d fits the height" % (
                  total, cursor, scroll, height))
        check(cursor in visible,
              "viewport %d/%d/%d/%d keeps the cursor visible" % (
                  total, cursor, scroll, height),
              "indices=%r" % (indices,))
        check(all(i is None or 0 <= i < total for i in indices),
              "viewport %d/%d/%d/%d stays in range" % (
                  total, cursor, scroll, height))

    indices, start = ui.viewport_slice(20, 0, 0, 5)
    eq([0, 1, 2, 3, None], indices, "top of a long list has a bottom ellipsis")
    eq(0, start, "top scroll origin")
    indices, start = ui.viewport_slice(20, 10, 8, 5)
    eq([None, 8, 9, 10, None], indices,
       "middle of a long list has both ellipses")
    indices, _start = ui.viewport_slice(4, 0, 0, 5)
    eq([0, 1, 2, 3], indices, "short list shows no ellipsis")

    rows = [{"kind": "project"}, {"kind": "sep"}, {"kind": "tab"},
            {"kind": "pane"}]
    eq([0, 2, 3], ui.selectable_indices(rows),
       "selectable rows skip separators")
    eq(2, ui.step_selectable(rows, 0, 1),
       "cursor movement skips a separator row")
    eq(3, ui.step_selectable(rows, 3, 9),
       "cursor movement clamps at the last selectable row")
    eq(0, ui.step_selectable(rows, 2, -9),
       "cursor movement clamps at the first selectable row")


# ---------------------------------------------------------------------------
# Contextual footer and help overlay
# ---------------------------------------------------------------------------
def test_footer():
    rows = ui.build_rows(fixture_state(), {})
    project_row = [r for r in rows if r["kind"] == "project"][0]
    task_row = [r for r in rows if r["kind"] == "task"][0]
    single_tab = [r for r in rows if r["kind"] == "tab" and
                  not r["has_children"]][0]
    split_tab = {"kind": "tab", "has_children": True, "expanded": True}
    pane_row = {"kind": "pane", "tid": None, "name": "zsh"}

    eq(["? help", "enter open", "n task", "t term"],
       ui.footer_actions(project_row), "footer: project actions")
    eq(["? help", "enter open", "t term", "d close"],
       ui.footer_actions(task_row), "footer: task actions")
    eq(["? help", "enter open", "t term", "e edit"],
       ui.footer_actions(single_tab), "footer: single-pane tab actions")
    eq(["? help", "enter open", "l panes", "t term"],
       ui.footer_actions(split_tab), "footer: split tab actions")
    eq(["? help", "enter focus", "t term", "e edit"],
       ui.footer_actions(pane_row), "footer: pane actions")
    eq(["? help", "enter focus", "t term", "d close"],
       ui.footer_actions({"kind": "pane", "tid": "t_one"}),
       "footer: task pane advertises close")
    eq(["? help", "p project"], ui.footer_actions(None),
       "footer: empty tree advertises project add")

    eq(1, ui.tree_footer_count(11), "footer: short terminal keeps one line")
    eq(2, ui.tree_footer_count(12), "footer: two lines when they fit")
    eq(2, len(ui.tree_footer_lines(task_row, 24)),
       "footer: tall tree adds the mouse line")
    eq(1, len(ui.tree_footer_lines(task_row, 10)),
       "footer: short tree keeps one line")
    eq(ui.FOOTER_MOUSE, ui.tree_footer_lines(task_row, 24)[1],
       "footer: mouse line is honest about click/again/menu")
    eq(["? help", "enter open", "t term"],
       ui.footer_actions(task_row, 30),
       "footer: default 30 columns keeps three actions")
    eq(["? help", "enter open"],
       ui.footer_actions(task_row, 24),
       "footer: 24 columns keeps the two most important actions")
    eq(ui.FOOTER_MOUSE_COMPACT, ui.mouse_footer(30),
       "footer: narrow tree compacts the mouse line but keeps right-click")
    eq(ui.FOOTER_MOUSE_TINY, ui.mouse_footer(20),
       "footer: very narrow tree keeps the core mouse hint")
    check(ui.display_width(ui.mouse_footer(30)) <= 30,
          "footer: compact mouse line fits a 30-column tree")

    lines, _start = ui.render_tree(rows, rows.index(task_row), 0, 40, 20)
    text = "".join(lines)
    check("? help" in text and "d close" in text,
          "footer: render pins the contextual hint on the tree")
    check(ui.FOOTER_MOUSE in text, "footer: render includes the mouse line")
    # Only one footer line at a short height.
    lines, _start = ui.render_tree(rows, rows.index(task_row), 0, 40, 10)
    text = "".join(lines)
    check("? help" in text and ui.FOOTER_MOUSE not in text,
          "footer: short panes omit the second footer line")


def test_help():
    content = ui.help_content()
    sections = [text for kind, text in content if kind == "section"]
    eq(["NAVIGATION", "SESSIONS", "MOUSE", "TMUX", "DIFF / COPY"], sections,
       "help: every documented section is present")
    joined = "\n".join(text for _kind, text in content)
    for needle in ("fold/unfold", "new terminal", "right-click",
                   'C-a " / %', "C-a z", "C-a [",
                   "text select needs C-a [",
                   "diff popup"):
        check(needle in joined, "help: documents %r" % needle)
    check("mouse" in joined.lower() and "wheel" in joined,
          "help: mouse guidance is first-class")

    palette = ui.make_palette("truecolor", "blue", {})
    glyphs = ui.make_glyphs(False)
    lines = ui.render_help(60, 40, palette, glyphs)
    text = plain_text(lines)
    check("NAVIGATION" in text and "TMUX" in text and "DIFF / COPY" in text,
          "help: overlay renders its sections")
    check("? close · j/k scroll" in text,
          "help: footer switches to the close/scroll hint")
    eq(40, len(lines), "help: overlay fills the pane height")
    check(all(ui.display_width(ui.compose_plain([([], line)], 60)) <= 60
              for line in lines),
          "help: every overlay line fits the width")
    check("╭" in text and "╰" in text,
          "help: overlay has a bordered box")

    # Scrolling is clamped and exposes content further down.
    max_scroll = ui.help_max_scroll(60, 14)
    check(max_scroll > 0, "help: small overlay is scrollable", max_scroll)
    scrolled = "".join(ui.render_help(60, 14, palette, glyphs,
                                      scroll=max_scroll))
    check("DIFF / COPY" in scrolled,
          "help: scrolling reaches the last section")
    eq("close", ui.help_key_action("?", 3, max_scroll)[0],
       "help: ? closes")
    eq("close", ui.help_key_action("Esc", 0, max_scroll)[0],
       "help: Esc closes")
    eq("close", ui.help_key_action("q", 0, max_scroll)[0],
       "help: q closes")
    eq(("scroll", 1), ui.help_key_action("j", 0, max_scroll),
       "help: j scrolls down")
    eq(("scroll", 0), ui.help_key_action("k", 1, max_scroll),
       "help: k scrolls up")
    eq(("scroll", 0), ui.help_key_action("g", 4, max_scroll),
       "help: g goes to the top")
    eq(("scroll", max_scroll), ui.help_key_action("G", 0, max_scroll),
       "help: G goes to the bottom")
    eq(("scroll", max_scroll), ui.help_key_action("j", max_scroll, max_scroll),
       "help: scroll clamps at the bottom")

    small = ui.render_help(12, 5, palette, glyphs)
    eq(1, len(small), "help: tiny pane degrades to one readable line")
    check("help" in small[0], "help: tiny line still explains itself")
    check(len(ui.render_help(24, 10, palette, glyphs)) <= 10,
          "help: 24x10 overlay fits its pane")


# ---------------------------------------------------------------------------
# Git presentation
# ---------------------------------------------------------------------------
def test_git_formatting():
    palette = ui.make_palette("truecolor", "blue", {})
    glyphs = ui.make_glyphs(False)
    eq(("main", ""), ui.git_header_text(
        {"branch": "main", "detached": False, "ahead": 0, "behind": 0}, glyphs),
       "clean header: branch and blank counters")
    eq(("main", "↑3 ↓1"), ui.git_header_text(
        {"branch": "main", "ahead": 3, "behind": 1}, glyphs),
       "ahead/behind header")
    eq(("main", "↑2"), ui.git_header_text(
        {"branch": "main", "ahead": 2, "behind": 0}, glyphs),
       "ahead only")
    eq(("main", "↓4"), ui.git_header_text(
        {"branch": "main", "ahead": 0, "behind": 4}, glyphs),
       "behind only")
    eq(("detached @ abc1234", ""), ui.git_header_text(
        {"branch": None, "detached": True, "head": "abc123456789",
         "ahead": None, "behind": None}, glyphs),
       "detached header includes a short sha")
    eq(("detached", ""), ui.git_header_text(
        {"branch": None, "detached": True}, glyphs),
       "detached header without a sha")
    eq("", ui.format_ahead_behind(None, None), "null counters are blank")
    eq("", ui.format_ahead_behind(0, 0), "zero counters are blank")

    files = [
        {"path": "untracked.txt", "status": "??", "staged": False,
         "unstaged": False, "untracked": True},
        {"path": "modified.txt", "status": " M", "staged": False,
         "unstaged": True, "untracked": False},
        {"path": "staged.txt", "status": "M ", "staged": True,
         "unstaged": False, "untracked": False},
        {"path": "deleted.txt", "status": " D", "staged": False,
         "unstaged": True, "untracked": False},
        {"path": "conflict.txt", "status": "UU", "staged": False,
         "unstaged": False, "untracked": False},
    ]
    ordered = ui.sort_git_files(files)
    eq(["conflict.txt", "staged.txt", "modified.txt", "deleted.txt",
        "untracked.txt"],
       [item["path"] for item in ordered],
       "file order: conflict, staged, unstaged, untracked")
    eq([0, 1, 2, 2, 3], [ui.git_file_category(i) for i in ordered],
       "categories are stable")

    groups = ui.group_git_files(ordered)
    eq(["Conflicts", "Staged", "Unstaged", "Untracked"],
       [label for label, _items in groups],
       "git: sections in render order")
    eq([1, 1, 2, 1], [len(items) for _label, items in groups],
       "git: section counts")
    frames = ui.git_frame_rows(ordered)
    eq(["section", "file", "section", "file", "section", "file", "file",
        "section", "file"],
       [frame["kind"] for frame in frames],
       "git: section headers interleave with file rows")
    eq(1, ui.git_frame_index(ordered, 0),
       "git: the first file follows the first section header")
    check(ui.git_frame_index(ordered, 4) > ui.git_frame_index(ordered, 0),
          "git: cursor frame moves through later sections")

    eq(" M modified.txt", ui.format_git_row_text(files[1]),
       "raw porcelain XY is preserved in the plain helper")
    eq("R  old name.txt -> new name.txt", ui.format_git_row_text({
        "path": "new name.txt", "orig_path": "old name.txt", "status": "R ",
        "staged": True, "unstaged": False, "untracked": False,
    }), "rename keeps original and new paths")
    eq("?? a b/ü.txt", ui.format_git_row_text({
        "path": "a b/ü.txt", "status": "??", "untracked": True,
        "staged": False, "unstaged": False,
    }), "paths with spaces and unicode are preserved")

    segs = ui.git_row_segments(files[2], palette)
    joined = "".join(text for _attrs, text in segs)
    eq("M  staged.txt", joined, "git row text: staged XY and path")
    attrs = "".join("".join(a) for a, _text in segs)
    check(tcol(palette, "add") in attrs or tcol(palette, "modify") in attrs,
          "git row: added/modified badge uses green/amber", attrs)

    segs = ui.git_row_segments(files[1], palette)
    attrs = "".join("".join(a) for a, _text in segs)
    eq(True, tcol(palette, "modify") in attrs,
       "git row: unstaged badge is amber, not red")
    eq(" M modified.txt", "".join(text for _attrs, text in segs),
       "git row: unstaged separator and path")

    segs = ui.git_row_segments(files[3], palette)
    attrs = "".join("".join(a) for a, _text in segs)
    eq(True, tcol(palette, "delete") in attrs,
       "git row: deleted badge is red")

    segs = ui.git_row_segments(files[0], palette)
    attrs = "".join("".join(a) for a, _text in segs)
    eq(True, "38;2;210;153;34" in attrs,
       "git row: untracked badge is amber")
    eq("?  untracked.txt", "".join(text for _attrs, text in segs),
       "git row: untracked shows a single ? badge")

    segs = ui.git_row_segments(files[4], palette)
    attrs = "".join("".join(a) for a, _text in segs)
    eq(True, "38;2;248;81;73" in attrs,
       "git row: conflict badge is red")

    long_path = "src/" + "/".join(["nested"] * 30) + "/final_file.py"
    truncated = ui.truncate_left_display(long_path, 20)
    check(ui.display_width(truncated) <= 20, "long path truncates by width")
    eq(True, truncated.endswith("final_file.py"),
       "long path truncation keeps the filename tail")
    eq(True, truncated.startswith("…"), "long path truncation marks the cut")

    # diff command: staged vs unstaged vs untracked, and shell-safe quoting.
    cmd = ui.git_diff_command("/r", files[1])
    eq(True, "diff HEAD -- " in cmd and "modified.txt" in cmd,
       "tracked/unstaged uses git diff HEAD -- <file>")
    cmd = ui.git_diff_command("/r", files[2])
    eq(True, "--cached" in cmd, "staged-only uses git diff --cached")
    cmd = ui.git_diff_command("/r", files[0])
    eq(True, cmd.startswith("cat -- "), "untracked shows the file itself")
    cmd = ui.git_diff_command("/r", {
        "path": "a b/ü.txt", "status": " M", "staged": False,
        "unstaged": True, "untracked": False,
    })
    eq(True, "'a b/ü.txt'" in cmd, "diff command quotes spaces and unicode")
    tokens = shlex.split(cmd.split("|", 1)[0])
    eq("a b/ü.txt", tokens[-1], "quoted path round-trips through shlex")
    eq("HEAD", tokens[-3], "git diff HEAD is used")

    # Long git lines truncate rather than overflow.
    line = ui.compose_plain(
        ui.git_row_segments({"path": long_path, "status": " M",
                             "staged": False, "unstaged": True,
                             "untracked": False}, palette), 24)
    eq(24, ui.display_width(line), "git line is exactly pane width")


# ---------------------------------------------------------------------------
# Context path and state reading
# ---------------------------------------------------------------------------
def test_context_and_state():
    state = fixture_state()
    eq(("p_alpha", "task:t_one", "/work/alpha/one"),
       ui.active_context_path(state), "active task resolves to its worktree")
    state["active"]["context"] = "proj"
    eq(("p_alpha", "proj", "/work/alpha"),
       ui.active_context_path(state), "project context resolves to the checkout")
    eq((None, None, None), ui.active_context_path(
        {"version": 1, "active": {"project": None}, "projects": []}),
       "empty active context")

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        missing, err = ui.read_state_file(os.path.join(tmp, "nope.json"))
        eq(None, missing, "missing state has no document")
        check("no state" in err, "missing state explains itself", err)

        bad = os.path.join(tmp, "bad.json")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        parsed, err = ui.read_state_file(bad)
        eq(None, parsed, "corrupt state has no document")
        check("invalid state" in err, "corrupt state explains itself", err)

        empty = os.path.join(tmp, "empty.json")
        with open(empty, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "active": {
                "project": None, "context": None, "window": 0},
                "projects": []}, handle)
        parsed, err = ui.read_state_file(empty)
        eq(None, err, "valid empty state parses")
        eq([], ui.build_rows(parsed, {}), "valid empty state has no rows")


def test_render_smoke():
    palette = ui.make_palette("truecolor", "blue", {})
    glyphs = ui.make_glyphs(False)
    rows = ui.build_rows(fixture_state(), {})
    lines, start = ui.render_tree(rows, 0, 0, 40, 20, palette, glyphs)
    eq(20, len(lines), "tree render fills the pane height (body + footer)")
    rendered = plain_text(lines)
    check("alpha" in rendered, "tree render contains the project name")
    check("One" in rendered, "tree render contains the task name")
    check("▌" in lines[0], "tree render uses the accent selection bar")
    check("\x1b[48;2;28;33;40m" in lines[0],
          "tree render paints the selection background")
    check("\x1b[7m" not in "".join(lines),
          "tree render no longer uses reverse video for selection")
    check("38;2;88;166;255" in lines[2],
          "tree render styles the active context with the accent")
    check("no projects" not in "".join(lines),
          "tree render does not show the empty state with projects")
    check("2 tasks" in rendered,
          "tree render right-aligns the dim task count")
    footer = lines[-1] if len(lines) > 1 else ""
    check("? help" in "".join(lines[-2:]),
          "tree render includes the hint footer")
    check(ui.FOOTER_MOUSE in "".join(lines[-2:]),
          "tree render includes the mouse line when tall")
    start_lines, _start = ui.render_tree(rows, 0, 0, 9, 4, palette, glyphs)
    eq(1, len(start_lines), "tiny pane degrades to one message line")
    empty_lines, _start = ui.render_tree([], 0, 0, 30, 20, palette, glyphs)
    empty_text = "".join(empty_lines)
    check("no projects" in empty_text, "empty tree shows the no-projects hint")
    check("press p to add one" in empty_text,
          "empty tree explains how to add one")

    status = {"branch": "main", "ahead": 3, "behind": 1, "files": [
        {"path": "m.txt", "status": " M", "staged": False,
         "unstaged": True, "untracked": False},
        {"path": "s.txt", "status": "A ", "staged": True,
         "unstaged": False, "untracked": False},
        {"path": "u.txt", "status": "??", "staged": False,
         "unstaged": False, "untracked": True},
    ]}
    lines, _start = ui.render_git(status, None, 0, 0, 40, 20, palette, glyphs)
    text = plain_text(lines)
    eq(20, len(lines), "git render fills the pane height (header + body + footer)")
    check("main" in text and "↑3 ↓1" in text, "git header renders branch/counters")
    check("Staged 1" in text and "Unstaged 1" in text and "Untracked 1" in text,
          "git render shows dim section headers with counts")
    check("m.txt" in text and "s.txt" in text and "u.txt" in text,
          "git file list renders every file")
    check("?\n" not in text and "?  u.txt" in text,
          "git render shows the untracked single-? badge")
    check("enter diff · r refresh" in text,
          "git render pins its footer")
    check("\x1b[48;2;28;33;40m" in lines[2],
          "selected git row uses the selection background")
    check("▌" in lines[2], "selected git row uses the accent bar")
    lines, _start = ui.render_git({"branch": "main", "files": []}, None, 0, 0,
                                  40, 20, palette, glyphs)
    clean_text = plain_text(lines)
    check("working tree clean" in clean_text,
          "clean git pane says working tree clean")
    check(palette.fg("add") not in clean_text,
          "clean git pane is not green")
    lines, _start = ui.render_git(None, "boom", 0, 0, 40, 20, palette, glyphs)
    error_text = plain_text(lines)
    check("boom" in error_text, "git error text is rendered")
    check("error" in error_text, "git error label is rendered")
    lines, _start = ui.render_git(None, None, 0, 0, 9, 4, palette, glyphs)
    eq(1, len(lines), "tiny git pane degrades to one line")

    # 24-column readability: no line exceeds the pane, footer still present.
    lines, _start = ui.render_tree(rows, 0, 0, 24, 10, palette, glyphs)
    for line in lines:
        check(ui.display_width(ui.compose_plain([([], line)], 24)) <= 24,
              "24-column tree row fits", line)
    check(any("? help" in line for line in lines),
          "24-column tree keeps a readable footer")


def test_python38_syntax():
    """pane/ui.py must stay parseable by Python 3.8 (documented minimum)."""
    with open(UI_PATH, "r", encoding="utf-8") as handle:
        source = handle.read()
    try:
        ast.parse(source, filename=UI_PATH, feature_version=(3, 8))
        parsed = True
        detail = ""
    except SyntaxError as exc:
        parsed = False
        detail = str(exc)
    check(parsed, "ui.py parses with Python 3.8 grammar", detail)


def main():
    tests = [
        test_palette,
        test_glyphs,
        test_rows,
        test_rows_empty,
        test_collapse_rules,
        test_hit_testing,
        test_parser,
        test_unicode,
        test_viewport,
        test_footer,
        test_help,
        test_git_formatting,
        test_context_and_state,
        test_render_smoke,
        test_python38_syntax,
    ]
    for test in tests:
        test()
    if FAILED:
        print("# %d/%d unit assertions failed" % (FAILED, RUN), file=sys.stderr)
        return 1
    print("# %d unit assertions passed" % RUN, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
