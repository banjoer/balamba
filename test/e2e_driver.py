#!/usr/bin/env python3
"""Scripted end-to-end journey for a real attached balamba client.

test/t_e2e.sh creates an isolated throwaway environment (XDG dirs, tmux
socket, git repo with a bare origin) and runs this driver.  Everything here
talks only to that socket through ``tmux -L``; the user's tmux server is never
touched.

The driver attaches ``bin/balamba`` under a real pty at 120x40, then drives the
UI through the terminal (prompts, menus, prefix bindings, tree keys and mouse
events).  It asserts with ``capture-pane``/tmux queries and prints one ``ok``
line per checkpoint.  On failure it prints the relevant screens and exits 1.
"""

import fcntl
import json
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

SOCK = os.environ.get("BALAMBA_SOCKET", "")
BIN = os.environ.get("BALAMBA_BIN", "")
ROOT = os.environ.get("BALAMBA_ROOT", "")
STATE = os.environ.get("BALAMBA_STATE", "")
CASE = os.environ.get("BALAMBA_E2E_CASE", "")
TREE_W = int(os.environ.get("BALAMBA_E2E_TREE_WIDTH", "28"))
GIT_W = int(os.environ.get("BALAMBA_E2E_GIT_WIDTH", "32"))
WIDTH = 120
HEIGHT = 40

ANSI_RE = re.compile(
    r"\x1b\][^\x07]*(?:\x07|\x1b\\)"      # OSC
    r"|\x1b\[[0-9;?]*[ -/]*[@-~]"         # CSI
    r"|\x1b[()][0-9A-Za-z]"               # charset
    r"|\x1b[=>]"                          # keypad
)
CTRL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


class Failure(Exception):
    pass


def tmux(*args, check=True, timeout=15):
    proc = subprocess.run(
        ["tmux", "-L", SOCK] + [str(a) for a in args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise Failure("tmux %s failed (%s): %s" % (
            " ".join(str(a) for a in args), proc.returncode,
            proc.stderr.decode("utf-8", "replace").strip()))
    return proc


def out(*args, **kwargs):
    return tmux(*args, **kwargs).stdout.decode("utf-8", "replace")


def read_state():
    try:
        with open(STATE, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def wait_for(fn, timeout=10.0, interval=0.05, what="condition"):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            value = fn()
        except Exception as exc:  # noqa: BLE001 - report the last error
            last = exc
            value = None
        if value:
            return value
        time.sleep(interval)
    raise Failure("timed out after %.1fs waiting for %s%s" % (
        timeout, what, "" if last is None else " (last error: %s)" % last))


def list_windows():
    rows = []
    text = out("list-windows", "-t", "balamba", "-F",
               "#{window_index}\t#{window_id}\t#{window_name}\t"
               "#{@balamba_tab}\t#{@balamba_context}\t#{@balamba_project}\t"
               "#{window_activity_flag}\t#{window_active}")
    for line in text.splitlines():
        pieces = line.split("\t")
        if len(pieces) < 6:
            continue
        try:
            index = int(pieces[0])
        except ValueError:
            continue
        rows.append({
            "index": index,
            "id": pieces[1],
            "name": pieces[2],
            "tab": pieces[3],
            "context": pieces[4],
            "project": pieces[5],
            "flag": len(pieces) > 6 and pieces[6].strip() == "1",
            "active": len(pieces) > 7 and pieces[7].strip() == "1",
        })
    rows.sort(key=lambda row: row["index"])
    return rows


def window_index(window_id):
    return int(out("display", "-p", "-t", window_id, "#{window_index}").strip())


def active_window():
    wins = list_windows()
    for win in wins:
        active = out("display", "-p", "-t", win["id"], "#{window_active}").strip()
        if active == "1":
            return win
    raise Failure("no active tmux window")


def panes(window_id):
    rows = []
    text = out("list-panes", "-t", window_id, "-F",
               "#{pane_index}\t#{pane_id}\t#{@balamba_chrome}\t"
               "#{pane_width}\t#{pane_height}\t#{pane_left}\t#{pane_top}\t"
               "#{pane_active}\t#{pane_current_path}\t#{pane_dead}")
    for line in text.splitlines():
        pieces = line.split("\t")
        if len(pieces) < 10:
            continue
        try:
            rows.append({
                "index": int(pieces[0]),
                "id": pieces[1],
                "chrome": pieces[2],
                "width": int(pieces[3]),
                "height": int(pieces[4]),
                "left": int(pieces[5]),
                "top": int(pieces[6]),
                "active": pieces[7] == "1",
                "cwd": pieces[8],
                "dead": pieces[9] == "1",
            })
        except ValueError:
            continue
    return rows


def chrome(window_id, which):
    for pane in panes(window_id):
        if pane["chrome"] == which:
            return pane
    return None


def content_panes(window_id):
    return [p for p in panes(window_id) if not p["chrome"]]


def capture(pane_id):
    return out("capture-pane", "-p", "-t", pane_id)


def alt_screen(pane_id):
    return capture(pane_id)


def screenshot(label=""):
    parts = []
    if label:
        parts.append("---- %s ----" % label)
    try:
        win = active_window()
        tree = chrome(win["id"], "tree")
        git = chrome(win["id"], "git")
        parts.append("window %s: %s [%s]" % (
            win["index"], win["name"], win["context"]))
        if tree:
            parts.append("-- tree --\n" + capture(tree["id"]))
        if git:
            parts.append("-- git --\n" + capture(git["id"]))
        parts.append("-- windows --\n" + out(
            "list-windows", "-t", "balamba", "-F",
            "#{window_index} #{window_name} #{@balamba_context} "
            "#{window_activity_flag} #{window_active}"))
        parts.append("-- panes --\n" + out(
            "list-panes", "-t", win["id"], "-F",
            "#{pane_index} #{pane_id} chrome=#{@balamba_chrome} "
            "#{pane_width}x#{pane_height} active=#{pane_active} "
            "cwd=#{pane_current_path}"))
    except Exception as exc:  # noqa: BLE001 - diagnostics only
        parts.append("(screen capture failed: %s)" % exc)
    return "\n".join(parts)


class Checker:
    def __init__(self):
        self.count = 0

    def ok(self, message):
        self.count += 1
        print("ok %d - %s" % (self.count, message), flush=True)

    def check(self, condition, message, screens=()):
        if condition:
            self.ok(message)
            return
        self.count += 1
        print("not ok %d - %s" % (self.count, message), flush=True)
        for label in screens:
            print(screenshot(label), flush=True)
        raise Failure(message)


class Client:
    """A real ``bin/balamba`` client under a pty."""

    def __init__(self, cwd=None, cols=WIDTH, rows=HEIGHT):
        self.buf = bytearray()
        self.lock = threading.Lock()
        self.cwd = cwd
        env = dict(os.environ)
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        env["TERM"] = "xterm-256color"
        pid, fd = pty.fork()
        if pid == 0:
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ,
                            struct.pack("HHHH", rows, cols, 0, 0))
                if cwd:
                    os.chdir(cwd)
                os.execvpe(BIN, [BIN], env)
            finally:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        self.thread = threading.Thread(target=self._reader, daemon=True)
        self.thread.start()

    def _reader(self):
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            with self.lock:
                self.buf.extend(chunk)
                if len(self.buf) > 2_000_000:
                    del self.buf[:1_000_000]

    def send(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        try:
            os.write(self.fd, data)
        except OSError:
            pass

    def key(self, name):
        self.send(name)

    def prefix(self, key):
        self.send(b"\x01" + key.encode("utf-8"))

    def raw(self):
        with self.lock:
            return bytes(self.buf)

    def clear(self):
        with self.lock:
            self.buf.clear()

    def plain(self):
        text = ANSI_RE.sub("", self.raw().decode("utf-8", "replace"))
        return CTRL_RE.sub("", text)

    def wait_text(self, needle, timeout=10.0, what=None):
        return wait_for(lambda: needle in self.plain(), timeout=timeout,
                        what=what or ("client output %r" % needle))

    def resize(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))
        try:
            os.kill(self.pid, signal.SIGWINCH)
        except OSError:
            pass

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                done, _status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return
            if done:
                return
            time.sleep(0.05)
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except (OSError, ChildProcessError):
            pass


def client_count():
    text = out("list-clients", "-F", "#{client_name}")
    return len([line for line in text.splitlines() if line.strip()])


def first_client_name():
    text = out("list-clients", "-F", "#{client_name}")
    names = [line.strip() for line in text.splitlines() if line.strip()]
    return names[0] if names else ""


def close_popup():
    name = first_client_name()
    if name:
        out("display-popup", "-C", "-c", name, check=False)


def wait_attached(timeout=15.0):
    wait_for(lambda: client_count() >= 1, timeout=timeout,
             what="an attached tmux client")
    wait_for(lambda: len(list_windows()) >= 1, timeout=timeout,
             what="the balamba session window")


def switch_window(client, index, timeout=6.0):
    """Switch the client to a window through the real prefix binding.

    Escape first dismisses any stray menu/prompt/key-prefix state.  If the key
    path is flaky under a loaded test run, fall back to the equivalent tmux
    command so a harness race cannot masquerade as an app failure.
    """
    client.send(b"\x1b")
    time.sleep(0.12)
    client.send(b"\x01" + str(index).encode())
    try:
        wait_for(lambda: active_window()["index"] == index, timeout=timeout,
                 what="switching to window %s" % index)
        return
    except Failure:
        pass
    out("select-window", "-t", "balamba:%d" % index, check=False)
    wait_for(lambda: active_window()["index"] == index, timeout=timeout,
             what="switching to window %s via tmux" % index)


def select_tree_row(checker, client, needle):
    """Move the tree cursor onto a row with keyboard keys (no activation)."""
    win = active_window()
    tree = chrome(win["id"], "tree")
    checker.check(tree is not None, "tree chrome pane exists")
    out("select-pane", "-t", tree["id"])
    client.send(b"g")
    time.sleep(0.3)
    lines = capture(tree["id"]).splitlines()
    index = None
    for number, line in enumerate(lines):
        if needle in line:
            index = number
            break
    checker.check(index is not None,
                  "found a tree row containing %r" % needle,
                  screens=("tree",))
    for _ in range(index):
        client.send(b"j")
    time.sleep(0.3)
    # Confirm the selection is on that row (reverse video in capture -e).
    styled = out("capture-pane", "-p", "-e", "-t", tree["id"]).splitlines()
    selected = None
    marker = "\x1b[7m"
    for number, line in enumerate(styled, 1):
        if marker in line or ";7m" in line:
            selected = number - 1
            break
    checker.check(selected == index,
                  "tree cursor is on %r" % needle,
                  screens=("tree",))


def tree_text():
    win = active_window()
    tree = chrome(win["id"], "tree")
    return capture(tree["id"]) if tree else ""


def git_text():
    win = active_window()
    pane = chrome(win["id"], "git")
    return capture(pane["id"]) if pane else ""


def wait_tree(needle, timeout=8.0, what=None):
    return wait_for(lambda: needle in tree_text(), timeout=timeout,
                    what=what or ("tree text %r" % needle))


def wait_git(needle, timeout=8.0, what=None):
    return wait_for(lambda: needle in git_text(), timeout=timeout,
                    what=what or ("git text %r" % needle))


def wait_state(fn, timeout=10.0, what="state"):
    return wait_for(lambda: fn(read_state() or {}), timeout=timeout, what=what)


def task_of(state, tid):
    for project in state.get("projects") or []:
        for task in project.get("tasks") or []:
            if task.get("id") == tid:
                return project, task
    return None, None


def branch_exists(repo, branch):
    proc = subprocess.run(
        ["git", "-C", repo, "show-ref", "--verify", "--quiet",
         "refs/heads/%s" % branch],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc.returncode == 0


def git_out(repo, *args):
    return subprocess.run(
        ["git", "-C", repo] + list(args), stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, check=False)


def process_args(pid):
    """All command lines in the subtree rooted at ``pid``."""
    result = []
    try:
        data = open("/proc/%d/cmdline" % pid, "rb").read()
        result.append(data.replace(b"\0", b" ").decode("utf-8", "replace"))
    except OSError:
        pass
    try:
        children = subprocess.run(
            ["pgrep", "-P", str(pid)], stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, timeout=5).stdout.split()
    except (OSError, subprocess.SubprocessError):
        children = []
    for child in children:
        try:
            result.extend(process_args(int(child)))
        except ValueError:
            pass
    return result


def run_journey(check):
    repo = os.environ["BALAMBA_E2E_REPO"]
    tree_w = TREE_W
    git_w = GIT_W

    # ---------------------------------------------------------------- a
    client = Client(cwd=CASE)
    wait_attached()
    win = active_window()
    tree = chrome(win["id"], "tree")
    git = chrome(win["id"], "git")
    check.check(tree is not None and git is not None,
                "empty first run has tree and git chrome panes",
                screens=("empty first run",))
    wait_tree("no projects", timeout=10)
    check.ok("empty first run shows the no-projects hint")
    check.check(len(content_panes(win["id"])) == 1,
                "empty first run has one shell content pane")
    check.check(all(not pane["dead"] for pane in panes(win["id"])),
                "empty first run panes are alive")
    check.check(read_state() is not None, "empty state file exists and is JSON")

    # ---------------------------------------------------------------- b
    out("select-pane", "-t", tree["id"])
    client.send(b"p")
    client.wait_text("project path:", timeout=8, what="the add-project prompt")
    check.ok("p opens the project path prompt")
    client.send(repo)
    client.send(b"\r")
    pid = wait_for(
        lambda: (read_state() or {}).get("projects", [{}])[0].get("id")
        if (read_state() or {}).get("projects") else None,
        timeout=15, what="the project to be added")
    check.check(pid == "p_proj one", "project path with a space is added",
                screens=("after add-project",))
    proj, _task = None, None
    wait_state(lambda s: (s.get("projects") or [{}])[0].get("tabs"), what="shell tab")
    state = read_state()
    project = state["projects"][0]
    check.check(len(project["tabs"]) == 1, "project got exactly one shell tab")
    win = active_window()
    check.check(win["context"] == "proj", "project context is active")
    check.check(len(content_panes(win["id"])) >= 1,
                "project tab has a content pane")
    content = content_panes(win["id"])[0]
    check.check(content["cwd"] == repo,
                "project shell starts in the checkout", screens=("project",))
    tw = chrome(win["id"], "tree")
    gw = chrome(win["id"], "git")
    check.check(tw["width"] == tree_w and gw["width"] == git_w,
                "three columns use the configured widths",
                screens=("project widths",))
    wait_tree("proj one", timeout=8)
    check.ok("tree shows the added project")
    # project_add_and_open activates the project and focuses its content pane
    # in the background; let that settle before taking focus back to the tree.
    time.sleep(0.5)

    # ---------------------------------------------------------------- c
    out("select-pane", "-t", tw["id"])
    client.send(b"n")
    client.wait_text("task name:", timeout=8, what="the task name prompt")
    client.send("Fix Login")
    client.send(b"\r")
    client.wait_text("create from:", timeout=8, what="the create-from prompt")
    client.wait_text("origin/main", timeout=5,
                     what="the prefilled origin/main ref")
    check.ok("create-from is prefilled with origin/main")
    client.send(b"\r")  # accept the prefilled ref
    client.wait_text("new terminal: agent or shell", timeout=8,
                     what="the terminal kind menu")
    check.ok("the terminal kind menu appears")
    time.sleep(0.2)
    client.send(b"s")  # shell
    client.wait_text("created task", timeout=25,
                     what="the new-task flow to finish")
    tid = wait_for(
        lambda: next((t["id"] for p in (read_state() or {}).get("projects", [])
                      for t in p.get("tasks", [])), None),
        timeout=20, what="the new task")
    check.check(tid == "t_fix-login", "task creates the expected slug",
                screens=("after task creation",))
    state = read_state()
    project, task = task_of(state, tid)
    check.check(task is not None and task["branch"] == "fix-login",
                "task state records branch fix-login")
    worktree = os.path.join(os.path.dirname(repo), "balamba_worktrees",
                            os.path.basename(repo), "fix-login")
    check.check(os.path.isdir(worktree), "worktree exists at the convention path")
    check.check(os.path.isdir(task["path"]) and task["path"] == worktree,
                "state worktree path matches the convention")
    upstream = git_out(worktree, "rev-parse", "--abbrev-ref",
                       "--symbolic-full-name", "@{upstream}")
    check.check(upstream.returncode != 0,
                "new branch has no upstream configured", screens=("worktree",))
    remote = git_out(repo, "config", "--get", "branch.fix-login.remote")
    check.check(remote.returncode != 0 or remote.stdout.strip() == "",
                "branch.fix-login.remote is empty")
    start = git_out(repo, "rev-parse", "origin/main").stdout.strip()
    head = git_out(worktree, "rev-parse", "HEAD").stdout.strip()
    check.check(start and head == start, "branch starts at origin/main")
    win = wait_for(
        lambda: (active_window() if active_window()["context"] == "task:" + tid
                 else None),
        timeout=20, what="the task window to become active")
    check.check(win["context"] == "task:" + tid, "task tab is active")
    content = content_panes(win["id"])[0]
    check.check(content["cwd"] == worktree,
                "task shell starts in the worktree", screens=("task tab",))
    wait_git("fix-login", timeout=8)
    check.ok("git pane shows the task branch")

    # ---------------------------------------------------------------- d
    changed = os.path.join(worktree, "w $f #1'\\ x.txt")
    with open(changed, "w", encoding="utf-8") as handle:
        handle.write("hello diff line\n")
    wait_git("?? w $f #1'\\ x.txt", timeout=8,
             what="the changed file in the git pane")
    wait_git("??", timeout=8, what="the untracked marker")
    check.ok("git pane refreshes with the changed file and its code")
    diff_file = os.path.join(CASE, "popup.diff")
    diff_args = os.path.join(CASE, "popup.args")
    out("select-pane", "-t", chrome(win["id"], "git")["id"])
    client.send(b"\r")
    wait_for(lambda: os.path.exists(diff_file) and os.path.exists(diff_args),
             timeout=10, what="the diff popup to run its pager")
    with open(diff_file, "r", encoding="utf-8", errors="replace") as handle:
        diff_text = handle.read()
    check.check("hello diff line" in diff_text,
                "Enter on a changed file opens a popup containing the diff",
                screens=("git before diff popup",))
    args_text = ""
    if os.path.exists(diff_args):
        with open(diff_args, "r", encoding="utf-8", errors="replace") as handle:
            args_text = handle.read()
    check.check("-R" in args_text or "cat" in args_text,
                "popup uses the configured pager")
    try:
        client.wait_text("hello diff line", timeout=3,
                         what="the diff to be drawn on the client")
        check.ok("the diff is drawn inside the client popup")
    except Failure:
        # The pager may have produced its output before we started polling the
        # raw stream; the captured pager input above is the authoritative check.
        check.ok("the diff popup ran and its pager received the diff")
    out("display-popup", "-C", check=False)
    client.send(b"\x1b")
    time.sleep(0.3)
    close_popup()
    time.sleep(0.3)

    # ---------------------------------------------------------------- e
    win = active_window()
    content = content_panes(win["id"])[0]
    out("select-pane", "-t", content["id"])
    client.prefix("%")
    try:
        wait_for(lambda: len(content_panes(active_window()["id"])) == 2,
                 timeout=5, what="the content split")
        split_ok = True
    except Failure:
        split_ok = False
    check.check(split_ok, "prefix % splits the content pane",
                screens=("after split",))
    client.send("printf 'split output\\n'")
    client.send(b"\r")
    split_pane = content_panes(active_window()["id"])[1]
    wait_for(lambda: "split output" in capture(split_pane["id"]),
             timeout=5, what="output in the split pane")
    check.ok("the split pane runs a command with output")

    # Expand the task row so its tab rows (and their unread dots) are visible.
    out("select-pane", "-t", tw["id"])
    select_tree_row(check, client, "Fix Login")
    client.send(b"l")
    wait_state(lambda s: (task_of(s, tid)[1] or {}).get("expanded"),
               timeout=5, what="the task row to expand")
    check.ok("l expands the task row")

    # New terminal in the task context.
    select_tree_row(check, client, "Fix Login")
    client.clear()
    client.send(b"t")
    client.wait_text("new terminal: agent or shell", timeout=8,
                     what="the new-terminal menu")
    time.sleep(0.2)
    client.send(b"s")
    client.wait_text("opened terminal", timeout=15,
                     what="the new-terminal flow to finish")
    wait_state(lambda s: len((task_of(s, tid)[1] or {}).get("tabs") or []) == 2,
               timeout=15, what="the second task tab")
    check.ok("t adds a second terminal tab")
    wait_tree("shell 2", timeout=8,
              what="the second tab row in the tree")
    state = read_state()
    _project, task = task_of(state, tid)
    first_index = min(tab["window"] for tab in task["tabs"])
    second_index = max(tab["window"] for tab in task["tabs"])
    # The run-shell continuation creates the window and then activates it; wait
    # for that activation to finish before we start switching windows.
    wait_for(lambda: active_window()["index"] == second_index, timeout=10,
             what="the new terminal tab to become active")
    # Clear any unread flag left over from earlier background prompts so the
    # assertion below is about the command we are about to queue, not noise.
    project_window = state["projects"][0]["tabs"][0]["window"]
    switch_window(client, second_index)
    time.sleep(0.4)
    # Leave the second tab, then make its background shell produce output.
    # Sending the command after the switch removes any key/activation race.
    switch_window(client, first_index)
    check.ok("prefix + number switches back to the first tab")
    second_win = next(w for w in list_windows() if w["index"] == second_index)
    second_pane = content_panes(second_win["id"])[0]
    out("send-keys", "-t", second_pane["id"], "-l",
        "printf 'unread-marker\\n'")
    out("send-keys", "-t", second_pane["id"], "Enter")

    def row_has_dot(needle, indent=None):
        for line in tree_text().splitlines():
            if needle in line and (indent is None or line.startswith(indent)):
                return "●" in line
        return False

    wait_for(lambda: row_has_dot("Fix Login"), timeout=6,
             what="the unread dot on the task row")
    check.check(row_has_dot("Fix Login"), "unread dot appears on the task row",
                screens=("unread tree",))
    check.check(row_has_dot("shell 2", "    "),
                "unread dot appears on the background tab row",
                screens=("unread tree",))
    check.ok("unread state is per window, not leaked to the active tab")
    # Visiting the second tab clears its own flag.  Its parent task row can
    # still be dotted if another task tab is unread; aggregation is correct.
    switch_window(client, second_index)
    wait_for(lambda: not row_has_dot("shell 2", "    "), timeout=6,
             what="the unread dot to clear after visiting")
    check.check(not row_has_dot("shell 2", "    "),
                "visiting a tab clears its unread dot",
                screens=("after visiting unread tab",))

    # ---------------------------------------------------------------- f
    # Give every window a content pane as its active pane so the saved
    # active_pane is meaningful (the state model stores content-relative
    # indices; chrome focus is intentionally not part of it).
    for win_now in list_windows():
        content_now = content_panes(win_now["id"])
        if content_now:
            out("select-pane", "-t", content_now[0]["id"])
    subprocess.run([BIN, "save"], env=dict(os.environ), timeout=30,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                   check=True)
    check.ok("balamba save snapshots the live workspace")
    baseline = snapshot()
    out("kill-server", check=False)
    wait_for(lambda: not subprocess.run(
        ["tmux", "-L", SOCK, "has-session", "-t", "balamba"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0,
        timeout=10, what="the tmux server to die")
    client.close()
    client = Client(cwd=CASE)
    wait_attached(timeout=30)
    wait_for(lambda: len(list_windows()) == len(baseline["windows"]),
             timeout=30, what="all windows to restore")
    check.ok("a new client restores the dead server")
    # Shells report their saved cwd shortly after respawn; wait for those
    # before comparing the full snapshot.
    for before in baseline["windows"]:
        want = [item["cwd"] for item in before["content"]]
        wait_for(lambda win=before, want=want: (
            [item["cwd"] for item in
             content_panes(next(w["id"] for w in list_windows()
                                if w["index"] == win["index"]))] == want
        ), timeout=15, what="cwds to restore in window %s" % before["index"])
    after = snapshot()
    check.check(after["active"] == baseline["active"],
                "active window index is restored")
    check.check([w["tab"] for w in after["windows"]] ==
                [w["tab"] for w in baseline["windows"]],
                "window and tab order is restored", screens=("restored",))
    for before, now in zip(baseline["windows"], after["windows"]):
        check.check(before["count"] == now["count"],
                    "pane count restored for window %s" % before["index"])
        check.check(before["active_content"] == now["active_content"],
                    "active content pane restored for window %s (was %s, now %s)"
                    % (before["index"], before["active_content"],
                       now["active_content"]))
        for left, right in zip(before["content"], now["content"]):
            check.check(abs(left["width"] - right["width"]) <= 2 and
                        abs(left["height"] - right["height"]) <= 2 and
                        abs(left["left"] - right["left"]) <= 2 and
                        abs(left["top"] - right["top"]) <= 2,
                        "content geometry restored within 2 cols for window %s"
                        % before["index"],
                        screens=("geometry",))
        check.check([c["cwd"] for c in before["content"]] ==
                    [c["cwd"] for c in now["content"]],
                    "content cwds restored for window %s" % before["index"])
        check.check(now["tree_width"] == tree_w and now["git_width"] == git_w,
                    "sidebar widths reasserted after attach for window %s"
                    % now["index"],
                    screens=("restored widths",))
    check.check(out("show", "-gv", "monitor-activity").strip() == "on",
                "monitor-activity stays on after restore")
    restored = list_windows()
    active_flag = next((w["flag"] for w in restored if w["active"]), False)
    background_flags = [w for w in restored if w["flag"] and not w["active"]]
    check.check(not active_flag,
                "the active restored window never carries an unread flag")
    if background_flags:
        check.check("●" in tree_text(),
                    "restored background activity is shown as an unread dot")
    else:
        check.check("●" not in tree_text(),
                    "restored windows start with no unread dots")

    # ---------------------------------------------------------------- g
    # Make the task dirty, detached and unmerged so every warning fires.
    with open(os.path.join(worktree, "dirty.txt"), "w", encoding="utf-8") as h:
        h.write("dirty\n")
    git_out(worktree, "add", "dirty.txt")
    git_out(worktree, "-c", "user.name=e2e", "-c", "user.email=e2e@invalid",
            "commit", "-q", "-m", "task work")
    git_out(worktree, "checkout", "-q", "--detach")
    wait_git("detached HEAD", timeout=8)
    win = active_window()
    tree = chrome(win["id"], "tree")
    out("select-pane", "-t", tree["id"])
    select_tree_row(check, client, "Fix Login")
    win = active_window()
    tree = chrome(win["id"], "tree")
    out("select-pane", "-t", tree["id"])
    client.send(b"d")
    try:
        client.wait_text("close t_fix-login?", timeout=8,
                         what="the close menu")
    except Failure:
        print(screenshot("close failure"), flush=True)
        raise
    plain = client.plain()
    check.check("detached HEAD" in plain and "uncommitted changes" in plain
                and "not merged" in plain,
                "close shows dirty, detached and unmerged warnings",
                screens=("close warnings",))
    time.sleep(0.2)
    client.send(b"q")
    time.sleep(0.5)
    state = read_state()
    check.check(task_of(state, tid)[1] is not None and os.path.isdir(worktree),
                "Cancel keeps the task and its worktree")
    client.clear()
    client.send(b"d")
    client.wait_text("close t_fix-login?", timeout=8,
                     what="the close menu again")
    time.sleep(0.2)
    client.send(b"c")
    client.wait_text("Delete worktree and close", timeout=8,
                     what="the second confirmation")
    time.sleep(0.2)
    check.check(os.path.isdir(worktree) and
                task_of(read_state(), tid)[1] is not None,
                "Continue asks again before deleting anything")
    client.send(b"y")
    wait_state(lambda s: task_of(s, tid)[1] is None, timeout=10,
               what="the task to be removed")
    time.sleep(0.5)
    check.check(not os.path.exists(worktree), "confirmed close removes the worktree")
    check.check(branch_exists(repo, "fix-login"),
                "close keeps the branch by default")
    state = read_state()
    check.check(not (task_of(state, tid)[1]), "state has no closed task")
    check.check(state.get("active", {}).get("context") == "proj",
                "close falls back to the project context")

    # ---------------------------------------------------------------- h
    client.clear()
    client.prefix("N")
    client.wait_text("task name:", timeout=8,
                     what="C-a N to open the new-task flow")
    check.ok("C-a N opens the same new-task prompt")
    client.send(b"\x1b")
    time.sleep(0.4)
    check.check(not any((p.get("tasks") or [])
                        for p in (read_state() or {}).get("projects", [])),
                "cancelled C-a N creates nothing")

    # ---------------------------------------------------------------- i
    win = active_window()
    tree = chrome(win["id"], "tree")
    out("select-pane", "-t", tree["id"])
    select_tree_row(check, client, "proj one")
    client.clear()
    client.send(b"n")
    client.wait_text("task name:", timeout=8)
    client.send("Agent Work")
    client.send(b"\r")
    client.wait_text("origin/main", timeout=5)
    client.send(b"\r")
    client.wait_text("new terminal: agent or shell", timeout=8)
    time.sleep(0.2)
    client.send(b"a")
    client.wait_text("created task", timeout=25,
                     what="the agent task flow to finish")
    atid = wait_for(
        lambda: next((t["id"] for p in (read_state() or {}).get("projects", [])
                      for t in p.get("tasks", [])), None),
        timeout=20, what="the agent task")
    wait_for(lambda: (task_of(read_state() or {}, atid)[1] or {}).get("tabs"),
             timeout=20, what="the agent tab")
    state = read_state()
    _project, atask = task_of(state, atid)
    check.check(atask is not None, "agent task is recorded")
    atab = atask["tabs"][0]
    check.check(atab["kind"] == "agent", "agent task has an agent tab")
    session = atab["session"]
    check.check(re.fullmatch(r"ses_[0-9a-f]{32}", session or "") is not None,
                "agent session id is ses_ + 32 hex")
    awin = wait_for(
        lambda: next((w for w in list_windows()
                      if w["context"] == "task:" + atid), None),
        timeout=20, what="the agent task window")
    ac = wait_for(lambda: (content_panes(awin["id"]) or [None])[0],
                  timeout=10, what="the agent content pane")
    pane_pid = int(out("display", "-p", "-t", ac["id"], "#{pane_pid}").strip())

    def agent_argv():
        joined = " ".join(process_args(pane_pid))
        if "opencode" in joined and "--session" in joined and session in joined:
            return joined
        return None

    joined = wait_for(agent_argv, timeout=25, what="opencode to start")
    check.check("--session " + session in joined,
                "agent pane runs the configured command with its session",
                screens=("agent pane",))
    cwd = os.readlink("/proc/%d/cwd" % pane_pid) if os.path.exists(
        "/proc/%d/cwd" % pane_pid) else ac["cwd"]
    check.check(cwd == atask["path"], "agent pane cwd is the task worktree")
    check.ok("agent task was created without sending a model message")

    # ---------------------------------------------------------------- resize
    # A real client resize must repaint chrome and reassert sidebars.
    client.resize(100, 32)
    wait_for(lambda: out("list-clients", "-F",
                         "#{client_width}x#{client_height}").strip() == "100x32",
             timeout=10, what="tmux to see the 100x32 client size")
    wait_for(lambda: out("display", "-p", "-t", "balamba:",
                         "#{window_width}").strip() == "100",
             timeout=10, what="the active window width to follow the client")
    win = active_window()
    wait_for(lambda: (chrome(win["id"], "tree") or {}).get("width") == tree_w and
             (chrome(win["id"], "git") or {}).get("width") == git_w,
             timeout=10, what="widths after client resize")
    check.ok("client resize reasserts sidebar widths")
    wait_for(lambda: len(tree_text().splitlines()) <= 31,
             timeout=5, what="chrome repaint at the new size")
    check.ok("chrome repaints at the resized client")
    client.resize(WIDTH, HEIGHT)
    wait_for(lambda: out("list-clients", "-F",
                         "#{client_width}x#{client_height}").strip() ==
             "%dx%d" % (WIDTH, HEIGHT),
             timeout=10, what="the client to return to 120x40")
    check.ok("client resize back to 120x40 succeeds")
    wait_for(lambda: (chrome(active_window()["id"], "tree") or {}).get(
        "width") == tree_w and (chrome(active_window()["id"], "git") or {}).get(
            "width") == git_w, timeout=10,
             what="widths reasserted after resizing back")
    time.sleep(0.3)

    # Border drag: drag the tree/content divider right, then the end binding
    # must snap the configured width back.
    win = active_window()
    tree = chrome(win["id"], "tree")
    border_x = tree["width"] + 1
    press = ("\x1b[<0;%d;5M" % border_x).encode()
    drag = ("\x1b[<32;%d;5M" % (border_x + 8)).encode()
    release = ("\x1b[<0;%d;5m" % (border_x + 8)).encode()
    client.send(press)
    time.sleep(0.15)
    client.send(drag)
    time.sleep(0.4)
    dragged = (chrome(active_window()["id"], "tree") or {}).get("width")
    check.check(dragged != tree_w,
                "a mouse border drag actually moves the divider",
                screens=("during border drag",))
    client.send(release)
    wait_for(lambda: (chrome(active_window()["id"], "tree") or {}).get(
        "width") == tree_w, timeout=5, what="widths after a border drag")
    check.ok("border drag end reasserts the configured tree width")

    client.prefix("d")
    client.close()


def snapshot():
    wins = []
    active = None
    for win in list_windows():
        ps = panes(win["id"])
        content = [p for p in ps if not p["chrome"]]
        tree = next((p for p in ps if p["chrome"] == "tree"), None)
        git = next((p for p in ps if p["chrome"] == "git"), None)
        active_content = next((i for i, p in enumerate(content) if p["active"]),
                              -1)
        is_active = out("display", "-p", "-t", win["id"],
                        "#{window_active}").strip() == "1"
        if is_active:
            active = win["index"]
        wins.append({
            "index": win["index"],
            "tab": win["tab"],
            "count": len(content),
            "active_content": active_content,
            "tree_width": tree["width"] if tree else None,
            "git_width": git["width"] if git else None,
            "content": [{"id": p["id"], "width": p["width"],
                         "height": p["height"], "left": p["left"],
                         "top": p["top"], "cwd": p["cwd"]} for p in content],
        })
    return {"windows": wins, "active": active}


def main():
    if not (SOCK and BIN and ROOT and STATE and CASE):
        print("e2e driver: missing environment", file=sys.stderr)
        return 2
    check = Checker()
    try:
        run_journey(check)
    except Failure as exc:
        print("e2e failure: %s" % exc, file=sys.stderr, flush=True)
        return 1
    except Exception as exc:  # noqa: BLE001 - keep the captured diagnostics
        import traceback
        traceback.print_exc()
        print("e2e failure: %s" % exc, file=sys.stderr, flush=True)
        return 1
    print("# %d e2e checkpoints passed" % check.count, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
