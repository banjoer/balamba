#!/usr/bin/env bash
# Tests for pane/ui.py (part 6): pure functions plus pty/tmux integration.
#
# Everything runs on the throwaway socket created by test/helpers.sh.  The
# tree tests use a fake bin/balamba that logs argv, so navigation and mouse
# actions can be asserted without any real mutation.  The git tests use a real
# temporary repository and the real CLI (internal status) because that is the
# documented read-only entry point.

set -Eeuo pipefail

# shellcheck source=helpers.sh
. "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=../lib/common.sh
. "$BALAMBA_ROOT/lib/common.sh"

TEST_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UI=$BALAMBA_ROOT/pane/ui.py

CASE=$BALAMBA_TEST_ROOT/ui
mkdir -p -- "$CASE"/{fake/bin,state,work}
FAKE_ROOT=$CASE/fake
FAKE_LOG=$CASE/fake.log
: >"$FAKE_LOG"

cat >"$FAKE_ROOT/bin/balamba" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >>"${BALAMBA_FAKE_LOG}"
exit 0
EOS
chmod +x "$FAKE_ROOT/bin/balamba"

tsess() { tmux -L "$BALAMBA_SOCKET" "$@"; }

# ---------------------------------------------------------------------------
# Pure-function unit tests
# ---------------------------------------------------------------------------
if unit_out=$(python3 "$TEST_DIR/t_ui.py" 2>"$CASE/unit.err"); then
  _pass "ui unit tests: $(wc -l <<<"$unit_out" | tr -d ' ') assertions"
else
  _fail "ui unit tests" "$(tail -n 20 "$CASE/unit.err")"
  printf '%s\n' "$unit_out" | grep '^not ok' | head -20 >&2 || true
fi

# ---------------------------------------------------------------------------
# tmux pane helpers
# ---------------------------------------------------------------------------
start_server() {
  local i sock
  tsess kill-server >/dev/null 2>&1 || true
  # kill-server is asynchronous; a new-session on the old socket can race it.
  for i in $(seq 1 100); do
    tsess has-session >/dev/null 2>&1 || break
    sleep 0.02
  done
  sock=$(balamba_tmux_socket_path)
  for i in 1 2 3; do
    if tmux -L "$BALAMBA_SOCKET" -f "$BALAMBA_ROOT/tmux.conf" \
      new-session -d -s balamba -x 120 -y 40 'sleep 300' >/dev/null 2>&1; then
      break
    fi
    [[ -n $sock ]] && rm -f -- "$sock"
    sleep 0.15
  done
  tsess set -g @balamba_active_refresh 1 >/dev/null 2>&1 || true
  tsess set -g @balamba_idle_refresh 1 >/dev/null 2>&1 || true
  tsess set -g @balamba_git_refresh 1 >/dev/null 2>&1 || true
}

# new_ui_pane <mode> <root> <state> [width] [height]
new_ui_pane() {
  local mode=$1 root=$2 state=$3 width=${4:-40} height=${5:-20} pane
  pane=$(tsess new-window -d -P -F '#{pane_id}' -t balamba: -n "ui-$mode" \
    -c "$BALAMBA_ROOT" \
    -e "BALAMBA_ROOT=$root" \
    -e "BALAMBA_STATE=$state" \
    -e "BALAMBA_FAKE_LOG=$FAKE_LOG" \
    "python3 $UI $mode") || return 1
  tsess resize-window -t "$pane" -x "$width" -y "$height" >/dev/null 2>&1 || true
  printf '%s\n' "$pane"
}

kill_pane() {
  local pane=$1
  [[ -n $pane ]] || return 0
  tsess kill-window -t "$pane" >/dev/null 2>&1 || true
}

capture() { tsess capture-pane -p -t "$1" 2>/dev/null || true; }
capture_e() { tsess capture-pane -p -e -t "$1" 2>/dev/null || true; }

wait_contains() {
  local pane=$1 needle=$2 tries=${3:-200} i text
  for ((i = 0; i < tries; i++)); do
    text=$(capture "$pane")
    [[ $text == *"$needle"* ]] && return 0
    sleep 0.05
  done
  return 1
}

wait_log_contains() {
  local needle=$1 tries=${2:-200} i
  for ((i = 0; i < tries; i++)); do
    grep -Fq -- "$needle" "$FAKE_LOG" && return 0
    sleep 0.05
  done
  return 1
}

# 1-based line number of the reverse-video (selected) row.
reverse_line() {
  local pane=$1
  capture_e "$pane" | awk -v esc=$'\033' '
    index($0, esc "[7m") || index($0, ";7m") { print NR; exit }
  '
}

pane_alive() {
  local pane=$1 dead
  dead=$(tsess display -p -t "$pane" '#{pane_dead}' 2>/dev/null || printf '1')
  [[ $dead == 0 ]]
}

send_literal() {
  local pane=$1 text=$2
  tsess send-keys -t "$pane" -l "$text" >/dev/null 2>&1 || true
}

send_key() {
  local pane=$1 key=$2
  tsess send-keys -t "$pane" "$key" >/dev/null 2>&1 || true
}

send_click() {
  local pane=$1 x=$2 y=$3
  send_literal "$pane" "$(printf '\033[<0;%s;%sM' "$x" "$y")"
  send_literal "$pane" "$(printf '\033[<0;%s;%sm' "$x" "$y")"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
ALPHA=$CASE/proj-alpha
BETA=$CASE/proj-beta
mkdir -p -- "$ALPHA/fix-login" "$BETA"

write_tree_state() {
  local file=$1
  cat >"$file" <<EOF
{"version":1,
 "active":{"project":"p_alpha","context":"task:t_one","window":1},
 "projects":[
  {"id":"p_alpha","name":"alpha","path":"$ALPHA","expanded":true,
   "tabs":[
    {"id":"tty_p1","name":"shell 1","kind":"shell","agent":null,"session":null,
     "window":0,"pane_count":1,"layout":"","active_pane":0,
     "panes":[{"index":0,"cwd":"$ALPHA","launched":"shell"}]}],
   "tasks":[
    {"id":"t_one","name":"Fix login","slug":"fix-login","path":"$ALPHA/fix-login",
     "branch":"fix-login","base_ref":"origin/main",
     "created_at":"2026-01-01T00:00:00Z","expanded":true,
     "tabs":[
      {"id":"tty_t1","name":"shell 2","kind":"shell","agent":null,"session":null,
       "window":1,"pane_count":1,"layout":"","active_pane":0,
       "panes":[{"index":0,"cwd":"$ALPHA/fix-login","launched":"shell"}]}]},
    {"id":"t_two","name":"Docs pass","slug":"docs-pass","path":"$ALPHA/docs-pass",
     "branch":"docs-pass","base_ref":"origin/main",
     "created_at":"2026-01-01T00:00:00Z","expanded":false,"tabs":[]}]},
  {"id":"p_beta","name":"beta","path":"$BETA","expanded":false,"tabs":[],
   "tasks":[
    {"id":"t_b1","name":"Beta work","slug":"beta-work","path":"$BETA/b1",
     "branch":"beta-work","base_ref":"origin/main",
     "created_at":"2026-01-01T00:00:00Z","expanded":false,"tabs":[]}]}]}
EOF
}

write_empty_state() {
  printf '%s\n' '{"version":1,"active":{"project":null,"context":null,"window":0},"projects":[]}' >"$1"
}

start_server
TREE_STATE=$CASE/state/tree.json
write_tree_state "$TREE_STATE"
balamba_state_validate "$TREE_STATE" >/dev/null 2>&1
assert_status 0 "fixture: tree state is valid" balamba_state_validate "$TREE_STATE"

# ---------------------------------------------------------------------------
# Tree rendering: text, order, highlight
# ---------------------------------------------------------------------------
TREE_PANE=$(new_ui_pane tree "$FAKE_ROOT" "$TREE_STATE" 40 16)
tsess select-window -t "$TREE_PANE" >/dev/null 2>&1 || true
sleep 0.2
if wait_contains "$TREE_PANE" "Fix login"; then
  _pass "tree: renders the active task"
else
  _fail "tree: renders the active task" "$(capture "$TREE_PANE")"
fi
TEXT=$(capture "$TREE_PANE")
assert_contains "$TEXT" "alpha" "tree: renders the project"
assert_contains "$TEXT" "shell 1" "tree: renders the project's own terminal"
assert_contains "$TEXT" "shell 2" "tree: renders the expanded task's terminal"
assert_contains "$TEXT" "Docs pass" "tree: renders a collapsed task row"
assert_contains "$TEXT" "beta" "tree: renders other projects"
assert_not_contains "$TEXT" "Beta work" "tree: collapsed project hides its tasks"

assert_eq "3" "$(reverse_line "$TREE_PANE")" \
  "tree: the active task row is selected and reverse-video highlighted"

# Unread marker from window_activity_flag.  Create a real window for tty_p1,
# put it in the background and make it produce output (monitor-activity on).
tsess new-window -d -t balamba: -n unread -c "$CASE" \
  "tmux -L $BALAMBA_SOCKET set-option -w -t \"\$TMUX_PANE\" @balamba_tab tty_p1; printf x; sleep 120" \
  >/dev/null 2>&1 || true
sleep 2.2
TEXT=$(capture "$TREE_PANE")
assert_contains "$TEXT" "●" "tree: unread marker propagated to the parent project"
assert_not_contains "$(capture_e "$TREE_PANE" | sed -n '3p')" "●" \
  "tree: no unread marker on the currently active window"

# ---------------------------------------------------------------------------
# Tree keyboard and mouse actions (fake balamba logs argv)
# ---------------------------------------------------------------------------
: >"$FAKE_LOG"
send_literal "$TREE_PANE" "j"
sleep 0.15
assert_eq "4" "$(reverse_line "$TREE_PANE")" "tree: j moves the selection down"
send_literal "$TREE_PANE" "k"
sleep 0.15
assert_eq "3" "$(reverse_line "$TREE_PANE")" "tree: k moves the selection back"

: >"$FAKE_LOG"
send_key "$TREE_PANE" Enter
if wait_log_contains "internal activate p_alpha task:t_one"; then
  _pass "tree: Enter on a task activates its context"
else
  _fail "tree: Enter on a task activates its context" "$(cat "$FAKE_LOG")"
fi

# First click selects, second click on the same row activates.
: >"$FAKE_LOG"
send_click "$TREE_PANE" 3 1
sleep 0.2
assert_eq "1" "$(reverse_line "$TREE_PANE")" "tree: click selects the project row"
send_click "$TREE_PANE" 3 1
if wait_log_contains "internal activate p_alpha proj"; then
  _pass "tree: clicking the selected project activates its context"
else
  _fail "tree: clicking the selected project activates its context" \
    "$(cat "$FAKE_LOG")"
fi

# Chevron click toggles expand/collapse through the internal verbs.
: >"$FAKE_LOG"
send_click "$TREE_PANE" 1 1
if wait_log_contains "internal collapse p_alpha"; then
  _pass "tree: chevron click collapses the project"
else
  _fail "tree: chevron click collapses the project" "$(cat "$FAKE_LOG")"
fi

# n / t / p / d map to the documented internal verbs.
: >"$FAKE_LOG"
send_literal "$TREE_PANE" "n"
if wait_log_contains "internal new-task"; then
  _pass "tree: n creates a task"
else
  _fail "tree: n creates a task" "$(cat "$FAKE_LOG")"
fi

: >"$FAKE_LOG"
send_literal "$TREE_PANE" "p"
if wait_log_contains "internal add-project"; then
  _pass "tree: p adds a project"
else
  _fail "tree: p adds a project" "$(cat "$FAKE_LOG")"
fi

# t opens a terminal in the selected row's context (activating it first when
# that context is not the active one).
: >"$FAKE_LOG"
send_literal "$TREE_PANE" "t"
if wait_log_contains "internal new-terminal"; then
  _pass "tree: t creates a terminal"
else
  _fail "tree: t creates a terminal" "$(cat "$FAKE_LOG")"
fi

# e asks tmux for an editor popup; with no client tmux may refuse but the app
# must stay alive (the popup is a fire-and-forget tmux action).
send_literal "$TREE_PANE" "e"
sleep 0.2
assert_status 0 "tree: e opens an editor popup without killing the pane" \
  pane_alive "$TREE_PANE"

# Select the task again (project row -> project tab -> task) and press d.
sent=""
for _i in 1 2; do
  send_literal "$TREE_PANE" "j"
  sleep 0.1
done
: >"$FAKE_LOG"
send_literal "$TREE_PANE" "d"
if wait_log_contains "internal close-task p_alpha t_one"; then
  _pass "tree: d closes the selected task"
else
  _fail "tree: d closes the selected task" "$(cat "$FAKE_LOG")"
fi

# Wheel and focus events must not crash or lose the list.
send_literal "$TREE_PANE" "$(printf '\033[<64;5;5M')"
send_literal "$TREE_PANE" "$(printf '\033[<65;5;5M')"
send_literal "$TREE_PANE" "$(printf '\033[I')"
sleep 0.2
assert_contains "$(capture "$TREE_PANE")" "alpha" \
  "tree: wheel and focus events keep the pane usable"
assert_status 0 "tree: pane survives wheel/focus" pane_alive "$TREE_PANE"

# Right-click opens a native menu; with no attached client tmux may refuse,
# but the app must not die (the menu command is fire-and-forget).
send_literal "$TREE_PANE" "$(printf '\033[<2;5;3M')"
sleep 0.2
assert_status 0 "tree: right click does not kill the pane" pane_alive "$TREE_PANE"

# r forces a refresh; q deliberately does nothing.
: >"$FAKE_LOG"
send_literal "$TREE_PANE" "r"
send_literal "$TREE_PANE" "q"
sleep 0.3
assert_status 0 "tree: r/q leave the pane running" pane_alive "$TREE_PANE"
assert_contains "$(capture "$TREE_PANE")" "alpha" "tree: r keeps the content"
assert_eq "" "$(cat "$FAKE_LOG")" "tree: q is a no-op"

kill_pane "$TREE_PANE"

# ---------------------------------------------------------------------------
# Tree: expand/collapse via internal verbs (state changed for real)
# ---------------------------------------------------------------------------
REAL_STATE=$CASE/state/real.json
write_tree_state "$REAL_STATE"
BALAMBA_STATE=$REAL_STATE "$BALAMBA_BIN" internal collapse p_alpha >/dev/null 2>&1
assert_eq "false" \
  "$(BALAMBA_STATE=$REAL_STATE jq -r '.projects[] | select(.id=="p_alpha") | .expanded' "$REAL_STATE")" \
  "internal collapse: project flag changes"
BALAMBA_STATE=$REAL_STATE "$BALAMBA_BIN" internal expand p_alpha >/dev/null 2>&1
assert_eq "true" \
  "$(BALAMBA_STATE=$REAL_STATE jq -r '.projects[] | select(.id=="p_alpha") | .expanded' "$REAL_STATE")" \
  "internal expand: project flag changes"
BALAMBA_STATE=$REAL_STATE "$BALAMBA_BIN" internal collapse p_alpha t_one >/dev/null 2>&1
assert_eq "false" \
  "$(BALAMBA_STATE=$REAL_STATE jq -r '.projects[] | select(.id=="p_alpha") | .tasks[] | select(.id=="t_one") | .expanded' "$REAL_STATE")" \
  "internal collapse: task flag changes"

# ---------------------------------------------------------------------------
# Corrupt / empty / tiny panes
# ---------------------------------------------------------------------------
BAD_STATE=$CASE/state/corrupt.json
printf '{this is not json\n' >"$BAD_STATE"
BAD_PANE=$(new_ui_pane tree "$FAKE_ROOT" "$BAD_STATE" 40 12)
if wait_contains "$BAD_PANE" "state unavailable"; then
  _pass "corrupt state: renders an error instead of crashing"
else
  _fail "corrupt state: renders an error instead of crashing" \
    "$(capture "$BAD_PANE")"
fi
assert_status 0 "corrupt state: pane stays alive" pane_alive "$BAD_PANE"
kill_pane "$BAD_PANE"

EMPTY_STATE=$CASE/state/empty.json
write_empty_state "$EMPTY_STATE"
EMPTY_PANE=$(new_ui_pane tree "$FAKE_ROOT" "$EMPTY_STATE" 30 10)
if wait_contains "$EMPTY_PANE" "no projects"; then
  _pass "empty state: renders a readable hint"
else
  _fail "empty state: renders a readable hint" "$(capture "$EMPTY_PANE")"
fi
assert_status 0 "empty state: pane stays alive" pane_alive "$EMPTY_PANE"
kill_pane "$EMPTY_PANE"

TINY_PANE=$(new_ui_pane tree "$FAKE_ROOT" "$TREE_STATE" 10 6)
sleep 0.4
TEXT=$(capture "$TINY_PANE")
assert_ne "" "$TEXT" "tiny pane: still shows readable output"
assert_status 0 "tiny pane: stays alive at 10 columns" pane_alive "$TINY_PANE"
kill_pane "$TINY_PANE"

# ---------------------------------------------------------------------------
# Git pane: real temporary repository
# ---------------------------------------------------------------------------
GIT_REPO=$CASE/repo
mkdir -p -- "$GIT_REPO"
git -C "$GIT_REPO" init -q -b main
git -C "$GIT_REPO" config user.name "balamba ui test"
git -C "$GIT_REPO" config user.email "ui@balamba.invalid"
git -C "$GIT_REPO" config commit.gpgsign false
printf 'one\n' >"$GIT_REPO/README.md"
printf 'old\n' >"$GIT_REPO/old.txt"
mkdir -p -- "$GIT_REPO/src/deep/nested"
printf 'long\n' >"$GIT_REPO/src/deep/nested/very_long_filename_example.txt"
git -C "$GIT_REPO" add -A
git -C "$GIT_REPO" commit -q -m "initial commit"

# Dirty working tree: modified, staged, renamed, untracked (spaces/unicode).
printf 'two\n' >>"$GIT_REPO/README.md"
printf 'staged\n' >"$GIT_REPO/staged file.txt"
git -C "$GIT_REPO" add "staged file.txt"
git -C "$GIT_REPO" mv old.txt renamed.txt
printf 'new\n' >"$GIT_REPO/new file ü.txt"
printf 'more\n' >>"$GIT_REPO/src/deep/nested/very_long_filename_example.txt"
git -C "$GIT_REPO" add "src/deep/nested/very_long_filename_example.txt"
printf 'tail\n' >>"$GIT_REPO/src/deep/nested/very_long_filename_example.txt"

GIT_STATE=$CASE/state/git.json
cat >"$GIT_STATE" <<EOF
{"version":1,"active":{"project":"p_repo","context":"proj","window":2},
 "projects":[{"id":"p_repo","name":"repo","path":"$GIT_REPO","expanded":true,
  "tabs":[{"id":"tty_g0","name":"shell 1","kind":"shell","agent":null,
   "session":null,"window":2,"pane_count":1,"layout":"","active_pane":0,
   "panes":[{"index":0,"cwd":"$GIT_REPO","launched":"shell"}]}],"tasks":[]}]}
EOF
balamba_state_validate "$GIT_STATE" >/dev/null 2>&1
assert_status 0 "fixture: git state is valid" balamba_state_validate "$GIT_STATE"

GIT_PANE=$(new_ui_pane git "$BALAMBA_ROOT" "$GIT_STATE" 44 20)
tsess select-window -t "$GIT_PANE" >/dev/null 2>&1 || true
if wait_contains "$GIT_PANE" "README.md" 300; then
  _pass "git: dirty repository status is fetched through internal status"
else
  _fail "git: dirty repository status is fetched through internal status" \
    "$(capture "$GIT_PANE")"
fi
GIT_TEXT=$(capture "$GIT_PANE")
assert_contains "$GIT_TEXT" "main" "git: branch line"
assert_contains "$GIT_TEXT" " M README.md" "git: unstaged code and path"
assert_contains "$GIT_TEXT" "A  staged file.txt" "git: staged code and path with a space"
assert_contains "$GIT_TEXT" "?? new file ü.txt" "git: untracked code and unicode path"
assert_contains "$GIT_TEXT" "renamed.txt" "git: rename shows the new path"
assert_contains "$GIT_TEXT" "old.txt" "git: rename shows the original path"
assert_contains "$GIT_TEXT" "very_long_filename_example.txt" \
  "git: long path keeps its filename tail"

# Selected row is reverse-video; j/k move it.
FIRST_REVERSE=$(grep -n '' <<<"$(capture_e "$GIT_PANE")" | awk -v esc=$'\033' '
  index($0, esc "[7m") || index($0, ";7m") { print $1; exit }' | cut -d: -f1)
check_first=${FIRST_REVERSE:-0}
if ((check_first >= 3)); then
  _pass "git: a file row is selected and highlighted"
else
  _fail "git: a file row is selected and highlighted" \
    "reverse line: ${FIRST_REVERSE:-none}"
fi
send_literal "$GIT_PANE" "j"
sleep 0.3
SECOND_REVERSE=$(capture_e "$GIT_PANE" | awk -v esc=$'\033' '
  index($0, esc "[7m") || index($0, ";7m") { print NR; exit }')
assert_ne "$FIRST_REVERSE" "$SECOND_REVERSE" "git: j moves the file selection"
send_literal "$GIT_PANE" "k"
sleep 0.2

# Enter opens the diff popup (no attached client in this harness, so tmux may
# refuse; the pane itself must keep running).
send_key "$GIT_PANE" Enter
sleep 0.2
assert_status 0 "git: Enter on a file does not kill the pane" pane_alive "$GIT_PANE"
send_click "$GIT_PANE" 6 3
sleep 0.2
assert_status 0 "git: clicking a file does not kill the pane" pane_alive "$GIT_PANE"
send_literal "$GIT_PANE" "$(printf '\033[<64;5;5M')"
send_literal "$GIT_PANE" "r"
sleep 0.3
assert_contains "$(capture "$GIT_PANE")" "README.md" \
  "git: wheel and r keep the file list"
kill_pane "$GIT_PANE"

# Clean repository: the pane says clean.
CLEAN_REPO=$CASE/clean
mkdir -p -- "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q -b main
git -C "$CLEAN_REPO" config user.name "balamba ui test"
git -C "$CLEAN_REPO" config user.email "ui@balamba.invalid"
printf 'clean\n' >"$CLEAN_REPO/README.md"
git -C "$CLEAN_REPO" add -A
git -C "$CLEAN_REPO" commit -q -m "clean commit"
CLEAN_STATE=$CASE/state/clean.json
cat >"$CLEAN_STATE" <<EOF
{"version":1,"active":{"project":"p_clean","context":"proj","window":2},
 "projects":[{"id":"p_clean","name":"clean","path":"$CLEAN_REPO","expanded":true,
  "tabs":[{"id":"tty_c0","name":"shell 1","kind":"shell","agent":null,
   "session":null,"window":2,"pane_count":1,"layout":"","active_pane":0,
   "panes":[{"index":0,"cwd":"$CLEAN_REPO","launched":"shell"}]}],"tasks":[]}]}
EOF
CLEAN_PANE=$(new_ui_pane git "$BALAMBA_ROOT" "$CLEAN_STATE" 40 12)
tsess select-window -t "$CLEAN_PANE" >/dev/null 2>&1 || true
if wait_contains "$CLEAN_PANE" "clean" 300; then
  _pass "git: clean repository shows clean"
else
  _fail "git: clean repository shows clean" "$(capture "$CLEAN_PANE")"
fi
kill_pane "$CLEAN_PANE"

# Detached HEAD and a status error.
DETACHED_REPO=$CASE/detached
mkdir -p -- "$DETACHED_REPO"
git -C "$DETACHED_REPO" init -q -b main
git -C "$DETACHED_REPO" config user.name "balamba ui test"
git -C "$DETACHED_REPO" config user.email "ui@balamba.invalid"
printf 'detached\n' >"$DETACHED_REPO/README.md"
git -C "$DETACHED_REPO" add -A
git -C "$DETACHED_REPO" commit -q -m "detached commit"
git -C "$DETACHED_REPO" checkout -q --detach HEAD
DETACHED_STATE=$CASE/state/detached.json
cat >"$DETACHED_STATE" <<EOF
{"version":1,"active":{"project":"p_det","context":"proj","window":2},
 "projects":[{"id":"p_det","name":"detached","path":"$DETACHED_REPO","expanded":true,
  "tabs":[{"id":"tty_d0","name":"shell 1","kind":"shell","agent":null,
   "session":null,"window":2,"pane_count":1,"layout":"","active_pane":0,
   "panes":[{"index":0,"cwd":"$DETACHED_REPO","launched":"shell"}]}],"tasks":[]}]}
EOF
DETACHED_PANE=$(new_ui_pane git "$BALAMBA_ROOT" "$DETACHED_STATE" 40 12)
tsess select-window -t "$DETACHED_PANE" >/dev/null 2>&1 || true
if wait_contains "$DETACHED_PANE" "detached HEAD" 300; then
  _pass "git: detached HEAD is labelled"
else
  _fail "git: detached HEAD is labelled" "$(capture "$DETACHED_PANE")"
fi
kill_pane "$DETACHED_PANE"

ERROR_STATE=$CASE/state/error.json
cat >"$ERROR_STATE" <<EOF
{"version":1,"active":{"project":"p_err","context":"proj","window":2},
 "projects":[{"id":"p_err","name":"err","path":"$CASE/not-a-repo","expanded":true,
  "tabs":[{"id":"tty_e0","name":"shell 1","kind":"shell","agent":null,
   "session":null,"window":2,"pane_count":1,"layout":"","active_pane":0,
   "panes":[{"index":0,"cwd":"$CASE/not-a-repo","launched":"shell"}]}],"tasks":[]}]}
EOF
mkdir -p -- "$CASE/not-a-repo"
ERROR_PANE=$(new_ui_pane git "$BALAMBA_ROOT" "$ERROR_STATE" 44 12)
tsess select-window -t "$ERROR_PANE" >/dev/null 2>&1 || true
if wait_contains "$ERROR_PANE" "not a git checkout" 300; then
  _pass "git: status failure text is shown"
else
  _fail "git: status failure text is shown" "$(capture "$ERROR_PANE")"
fi
assert_status 0 "git: error pane stays alive" pane_alive "$ERROR_PANE"
kill_pane "$ERROR_PANE"

# ---------------------------------------------------------------------------
# Terminal restore on SIGTERM and EOF (real pty)
# ---------------------------------------------------------------------------
PTY_RC=0
PTY_OUT=$CASE/pty.out
python3 - "$UI" "$TREE_STATE" "$FAKE_ROOT" >"$PTY_OUT" 2>&1 <<'PY' || PTY_RC=$?
import os
import pty
import select
import signal
import sys
import time

ui_path, state_path, fake_root = sys.argv[1:4]
env = dict(os.environ)
env.update({
    "BALAMBA_ROOT": fake_root,
    "BALAMBA_STATE": state_path,
    "TERM": "xterm-256color",
})
env.pop("TMUX", None)
env.pop("TMUX_PANE", None)


def read_until(fd, needle, timeout=3.0):
    out = b""
    end = time.time() + timeout
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if needle in out:
                return out, True
    return out, needle in out


def drain(fd, timeout=2.0):
    out = b""
    end = time.time() + timeout
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def run_once(do_eof):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(sys.executable, [sys.executable, ui_path, "tree"], env)
    out, _ok = read_until(fd, b"alpha")
    if do_eof:
        os.close(fd)
        _pid, status = os.waitpid(pid, 0)
        return out, status
    os.kill(pid, signal.SIGTERM)
    out += drain(fd)
    _pid, status = os.waitpid(pid, 0)
    os.close(fd)
    return out, status


sig_out, sig_status = run_once(False)
eof_out, eof_status = run_once(True)

checks = []
checks.append((b"alpha" in sig_out, "pty: tree rendered before SIGTERM"))
checks.append((b"\x1b[?1006l" in sig_out, "pty: mouse mode 1006 disabled on exit"))
checks.append((b"\x1b[?1002l" in sig_out, "pty: mouse mode 1002 disabled on exit"))
checks.append((b"\x1b[?1000l" in sig_out, "pty: mouse mode 1000 disabled on exit"))
checks.append((b"\x1b[?1049l" in sig_out, "pty: alternate screen left on exit"))
tail = sig_out[-400:]
checks.append((tail.rfind(b"\x1b[?1006l") >
               tail.rfind(b"\x1b[?1000h"),
               "pty: shutdown sequences come after the enable sequences"))
checks.append((os.waitstatus_to_exitcode(sig_status) == 0,
               "pty: SIGTERM exits 0"))
checks.append((os.waitstatus_to_exitcode(eof_status) == 0,
               "pty: EOF exits 0"))
for ok, name in checks:
    print(("ok " if ok else "not ok ") + name)
sys.exit(0 if all(ok for ok, _name in checks) else 1)
PY

if ((PTY_RC == 0)); then
  _pass "pty: terminal modes are restored on SIGTERM/EOF"
else
  _fail "pty: terminal modes are restored on SIGTERM/EOF" "$(tail -n 30 "$PTY_OUT")"
fi
# Surface the individual pty checks without double counting them.
grep -c '^ok ' "$PTY_OUT" >/dev/null 2>&1 || true

finish_tests
