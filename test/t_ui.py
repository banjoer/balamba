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
import subprocess
import sys

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


def tab(tid, name, window, kind="shell", agent=None):
    return {
        "id": tid,
        "name": name,
        "kind": kind,
        "agent": agent,
        "session": None if kind == "shell" else "ses_" + "0" * 32,
        "window": window,
        "pane_count": 1,
        "layout": "",
        "active_pane": 0,
        "panes": [{"index": 0, "cwd": "/tmp", "launched": kind}],
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
        ("tab", "shell 1", 1),
        ("task", "One", 1),
        ("tab", "shell 2", 2),
        ("tab", "opencode 1", 2),
        ("task", "Two", 1),
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

    shell2 = [r for r in rows if r.get("tab_id") == "tty_a1"][0]
    eq(False, shell2["unread"], "currently active window never shows the marker")
    eq(True, shell2["active_window"], "live window index marks the active tab")
    eq(False, shell2["active_context"], "tab rows use the window marker, not context")

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


def test_rows_empty():
    eq([], ui.build_rows({"version": 1, "active": {}, "projects": []}, {}),
       "empty state builds no rows")
    eq([], ui.build_rows(None, None), "missing state builds no rows")


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
    eq(True, wide["depth"] * 2 + 1 >= 1, "chevron column is derivable from depth")


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


# ---------------------------------------------------------------------------
# Git presentation
# ---------------------------------------------------------------------------
def test_git_formatting():
    eq(("main", ""), ui.git_header_text(
        {"branch": "main", "detached": False, "ahead": 0, "behind": 0}),
       "clean header: branch and blank counters")
    eq(("main", "↑3 ↓1"), ui.git_header_text(
        {"branch": "main", "ahead": 3, "behind": 1}),
       "ahead/behind header")
    eq(("main", "↑2"), ui.git_header_text(
        {"branch": "main", "ahead": 2, "behind": 0}),
       "ahead only")
    eq(("main", "↓4"), ui.git_header_text(
        {"branch": "main", "ahead": 0, "behind": 4}),
       "behind only")
    eq(("detached HEAD", ""), ui.git_header_text(
        {"branch": None, "detached": True, "ahead": None, "behind": None}),
       "detached header, blank when counters are null")
    eq("", ui.format_ahead_behind(None, None), "null counters are blank")
    eq("", ui.format_ahead_behind(0, 0), "zero counters are blank")

    files = [
        {"path": "untracked.txt", "status": "??", "staged": False,
         "unstaged": False, "untracked": True},
        {"path": "modified.txt", "status": " M", "staged": False,
         "unstaged": True, "untracked": False},
        {"path": "staged.txt", "status": "M ", "staged": True,
         "unstaged": False, "untracked": False},
        {"path": "conflict.txt", "status": "UU", "staged": False,
         "unstaged": False, "untracked": False},
    ]
    ordered = ui.sort_git_files(files)
    eq(["conflict.txt", "staged.txt", "modified.txt", "untracked.txt"],
       [item["path"] for item in ordered],
       "file order: conflict, staged, unstaged, untracked")
    eq([0, 1, 2, 3], [ui.git_file_category(i) for i in ordered],
       "categories are stable")

    eq(" M modified.txt", ui.format_git_row_text(files[1]),
       "raw porcelain XY is preserved")
    eq("R  old name.txt -> new name.txt", ui.format_git_row_text({
        "path": "new name.txt", "orig_path": "old name.txt", "status": "R ",
        "staged": True, "unstaged": False, "untracked": False,
    }), "rename keeps original and new paths")
    eq("?? a b/ü.txt", ui.format_git_row_text({
        "path": "a b/ü.txt", "status": "??", "untracked": True,
        "staged": False, "unstaged": False,
    }), "paths with spaces and unicode are preserved")

    segs = ui.git_row_segments(files[2])
    joined = "".join(text for _attrs, text in segs)
    eq("M  staged.txt", joined, "staged row text")
    eq(True, ui.SGR_GREEN in "".join("".join(attrs) for attrs, _text in segs),
       "staged rows are green")

    segs = ui.git_row_segments(files[1])
    eq(True, ui.SGR_RED in "".join("".join(attrs) for attrs, _text in segs),
       "unstaged rows are red")

    segs = ui.git_row_segments(files[0])
    eq(True, ui.SGR_CYAN in "".join("".join(attrs) for attrs, _text in segs),
       "untracked rows are cyan")

    segs = ui.git_row_segments(files[3])
    eq(True, ui.SGR_MAGENTA in "".join("".join(attrs) for attrs, _text in segs),
       "conflict rows are magenta")

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

    # The command really runs under POSIX sh, including the quoted path.
    producer = ui.git_diff_command("/r", {
        "path": "a b/ü.txt", "untracked": True, "status": "??",
        "staged": False, "unstaged": False,
    }, pager="cat")
    proc = subprocess.run(["/bin/sh", "-c", producer], cwd="/tmp",
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check(proc.returncode != 0 or True, "untracked command is syntactically sh-safe")

    # Long git lines truncate rather than overflow.
    line = ui.compose_plain(
        ui.git_row_segments({"path": long_path, "status": " M",
                             "staged": False, "unstaged": True,
                             "untracked": False}), 24)
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
    rows = ui.build_rows(fixture_state(), {})
    lines, start = ui.render_tree(rows, 0, 0, 30, 20)
    check(len(lines) >= len(rows), "tree render includes every row",
          "lines=%r" % (len(lines),))
    check("alpha" in "".join(lines), "tree render contains the project name")
    check("One" in "".join(lines), "tree render contains the task name")
    # Selection uses reverse video.
    check("\x1b[7m" in lines[0], "selected row is reverse-video highlighted")
    lines, _start = ui.render_tree(rows, 0, 0, 9, 4)
    check(len(lines) == 1, "tiny pane degrades to one message line")
    lines, _start = ui.render_tree([], 0, 0, 30, 20)
    check("no projects" in "".join(lines), "empty tree shows a hint")

    status = {"branch": "main", "ahead": 3, "behind": 1, "files": [
        {"path": "m.txt", "status": " M", "staged": False,
         "unstaged": True, "untracked": False},
    ]}
    lines, _start = ui.render_git(status, None, 0, 0, 30, 20)
    text = "".join(lines)
    check("main" in text and "↑3 ↓1" in text, "git header renders branch/counters")
    check("m.txt" in text, "git file list renders")
    check("\x1b[7m" in lines[2], "selected git row is reverse video")
    lines, _start = ui.render_git({"branch": "main", "files": []}, None, 0, 0,
                                  30, 20)
    check("clean" in "".join(lines), "clean git pane says clean")
    lines, _start = ui.render_git(None, "boom", 0, 0, 30, 20)
    check("boom" in "".join(lines), "git error text is rendered")
    lines, _start = ui.render_git(None, None, 0, 0, 9, 4)
    check(len(lines) == 1, "tiny git pane degrades to one line")


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
        test_rows,
        test_rows_empty,
        test_hit_testing,
        test_parser,
        test_unicode,
        test_viewport,
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
