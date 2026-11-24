#!/usr/bin/env bash
# Tests for lib/task.sh (part 5): non-interactive core, assessments, close,
# quoting, internal verbs and the no-client guard on interactive flows.
#
# Headless: real tmux on the isolated test socket, fake chrome and fake agent
# commands.  Interactive flows are exercised through their documented
# BALAMBA_FLOW_* environment hooks; the real command-prompt/display-menu path is
# covered for the no-client error.

set -Eeuo pipefail

# shellcheck source=helpers.sh
. "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=../lib/common.sh
. "$BALAMBA_ROOT/lib/common.sh"
# shellcheck source=../lib/git.sh
. "$BALAMBA_ROOT/lib/git.sh"
# shellcheck source=../lib/tmux.sh
. "$BALAMBA_ROOT/lib/tmux.sh"
# shellcheck source=../lib/task.sh
. "$BALAMBA_ROOT/lib/task.sh"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock"
rm -rf -- "$BALAMBA_RUNTIME"
rm -f -- "$BALAMBA_CONFIG"

CASE_ROOT=$BALAMBA_TEST_ROOT/cases
mkdir -p -- "$CASE_ROOT"
REPO=$CASE_ROOT/alpha
SPACED_REPO="$CASE_ROOT/proj beta"
make_git_repo "$REPO" origin >/dev/null
make_git_repo "$SPACED_REPO" origin >/dev/null

AGENT_SCRIPT=$BALAMBA_TEST_ROOT/fake-agent.sh
AGENT_LOG=$BALAMBA_TEST_ROOT/fake-agent.log
cat >"$AGENT_SCRIPT" <<'EOS'
#!/usr/bin/env bash
log=$1
shift
{
  printf 'cwd=%s\n' "$PWD"
  printf 'args=%s\n' "$*"
} >>"$log"
exec sleep 900
EOS
chmod +x "$AGENT_SCRIPT"
: >"$AGENT_LOG"

mkdir -p -- "$(dirname -- "$BALAMBA_CONFIG")"
cat >"$BALAMBA_CONFIG" <<EOF
tree_width=21
git_width=17
restore_stagger=0
default_ref=origin/main
default_agent=fakeagent
BALAMBA_AGENT_COMMAND[fakeagent]='$AGENT_SCRIPT $AGENT_LOG --session {{session}}'
BALAMBA_AGENT_RESUME[fakeagent]='$AGENT_SCRIPT $AGENT_LOG --session {{session}}'
BALAMBA_AGENT_LABEL[fakeagent]='fake'
BALAMBA_TREE_COMMAND='sleep 900'
BALAMBA_GIT_COMMAND='sleep 900'
EOF

balamba_state_init

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
capture() {
  CAP_OUT=""
  CAP_ERR=""
  CAP_RC=0
  local errf
  errf=$(mktemp "${TMPDIR:-/tmp}/balamba-task-cap.XXXXXX")
  CAP_OUT=$("$@" 2>"$errf") || CAP_RC=$?
  CAP_ERR=$(<"$errf")
  rm -f -- "$errf"
}

tsess() { tmux -L "$BALAMBA_SOCKET" "$@"; }

_clean_repo_branches() {
  local repo=$1 b
  while IFS= read -r b; do
    [[ -n $b && $b != main ]] || continue
    git -C "$repo" branch -D -- "$b" >/dev/null 2>&1 || true
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
}

reset_all() {
  tsess kill-server >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 100); do
    tsess has-session -t balamba >/dev/null 2>&1 || break
    sleep 0.02
  done
  rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock"
  rm -rf -- "$BALAMBA_RUNTIME" "$CASE_ROOT/balamba_worktrees"
  _clean_repo_branches "$REPO"
  _clean_repo_branches "$SPACED_REPO"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  git -C "$SPACED_REPO" worktree prune >/dev/null 2>&1 || true
  balamba_state_init
  : >"$AGENT_LOG"
}

task_count() {
  balamba_state_get '[.projects[] | .tasks[]?] | length'
}

project_count() {
  balamba_state_get '[.projects[]] | length'
}

task_field() {
  local pid=$1 tid=$2 field=$3
  balamba_state_get "
    .projects[] | select(.id == \$p) | .tasks[] | select(.id == \$t) | .$field
  " --arg p "$pid" --arg t "$tid"
}

task_tabs() {
  balamba_state_get '
    .projects[] | select(.id == $p) | .tasks[] | select(.id == $t) | (.tabs | length)
  ' --arg p "$1" --arg t "$2"
}

project_tabs() {
  balamba_state_get '.projects[] | select(.id == $p) | (.tabs | length)' --arg p "$1"
}

window_for_tab() {
  local tab=$1 idx t
  while IFS=$'\t' read -r idx t; do
    [[ $t == "$tab" ]] && { printf '%s\n' "$idx"; return 0; }
  done < <(tsess list-windows -t balamba -F $'#{window_index}\t#{@balamba_tab}' 2>/dev/null)
  return 1
}

window_id_for_tab() {
  local idx
  idx=$(window_for_tab "$1") || return 1
  tsess display -p -t "balamba:$idx" '#{window_id}'
}

content_ids() {
  local win=$1 idx id chrome
  while IFS=$'\t' read -r idx id chrome; do
    [[ -n $id && -z $chrome ]] || continue
    printf '%s\n' "$id"
  done < <(tsess list-panes -t "$win" \
    -F $'#{pane_index}\t#{pane_id}\t#{@balamba_chrome}' 2>/dev/null | sort -n -k1,1)
}

window_contexts() {
  local pid=$1 context=$2
  tsess list-windows -t balamba -F $'#{@balamba_project}\t#{@balamba_context}' 2>/dev/null |
    grep -Fxc "$pid"$'\t'"$context" || true
}

assert_json() {
  local json=$1 desc=$2
  if jq -e . >/dev/null 2>&1 <<<"$json"; then
    _pass "$desc"
  else
    _fail "$desc" "invalid JSON: ${json:0:200}"
  fi
}

wait_log_lines() {
  local n=$1 i
  for i in $(seq 1 200); do
    [[ $(wc -l <"$AGENT_LOG" 2>/dev/null || printf 0) -ge $n ]] && return 0
    sleep 0.03
  done
  return 1
}

# ---------------------------------------------------------------------------
# task_create_and_open: state, worktree, branch, window, tab, activation
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
assert_eq "p_alpha" "$PID" "create: project id from the checkout basename"

capture task_create_and_open "$PID" "Fix Login" "origin/main" shell
assert_eq "0" "$CAP_RC" "create: shell task succeeds"
TID=$CAP_OUT
assert_eq "t_fix-login" "$TID" "create: task id is t_<slug>"
assert_eq "t_fix-login" "$(balamba_state_get '.projects[] | select(.id == "p_alpha") | .tasks[0].id')" \
  "create: task recorded in state"
assert_eq "Fix Login" "$(task_field "$PID" "$TID" name)" "create: display name preserved"
assert_eq "fix-login" "$(task_field "$PID" "$TID" slug)" "create: slug stored"
assert_eq "origin/main" "$(task_field "$PID" "$TID" base_ref)" "create: base ref stored"
TASK_PATH=$(task_field "$PID" "$TID" path)
assert_eq "$CASE_ROOT/balamba_worktrees/alpha/fix-login" "$TASK_PATH" \
  "create: worktree path follows the convention"
[[ -d $TASK_PATH ]] && _pass "create: worktree exists on disk" || _fail "create: worktree exists on disk"
assert_status 0 "create: branch exists" git -C "$REPO" show-ref --verify --quiet refs/heads/fix-login

assert_eq "1" "$(task_tabs "$PID" "$TID")" "create: one tab recorded"
TAB=$(balamba_state_get '.projects[] | select(.id == "p_alpha") | .tasks[0].tabs[0].id')
assert_match '^tty_[0-9a-f]{8}$' "$TAB" "create: tab id has the tty_ form"
assert_eq "shell" "$(task_field "$PID" "$TID" 'tabs[0].kind')" "create: tab kind is shell"
TAB_WIN=$(window_for_tab "$TAB")
assert_eq "$TAB_WIN" "$(tsess display -p -t balamba: '#{window_index}')" \
  "create: new task window is selected"
assert_eq "task:$TID" "$(tsess display -p -t "balamba:$TAB_WIN" '#{@balamba_context}')" \
  "create: window tagged with the task context"
assert_eq "task:$TID" "$(balamba_state_get '.active.context')" "create: active context is the task"
assert_eq "$TAB_WIN" "$(balamba_state_get '.active.window')" "create: active window recorded"
WINID=$(tsess display -p -t "balamba:$TAB_WIN" '#{window_id}')
FIRST_PANE=$(content_ids "$WINID" | head -n1)
assert_eq "$TASK_PATH" "$(tsess display -p -t "$FIRST_PANE" '#{pane_current_path}')" \
  "create: terminal starts in the worktree"

# agent task records a session and actually launches the configured command
capture task_create_and_open "$PID" "Agent Task" "origin/main" agent
assert_eq "0" "$CAP_RC" "create: agent task succeeds"
ATID=$CAP_OUT
assert_eq "agent" "$(task_field "$PID" "$ATID" 'tabs[0].kind')" "create: agent tab kind"
assert_match '^ses_[0-9a-f]{32}$' "$(task_field "$PID" "$ATID" 'tabs[0].session')" \
  "create: agent session is ses_ + 32 hex"
if wait_log_lines 2; then
  _pass "create: fake agent launched"
else
  _fail "create: fake agent launched" "no argv/cwd lines in $AGENT_LOG"
fi
assert_contains "$(sed -n '1p' "$AGENT_LOG")" "$(task_field "$PID" "$ATID" path)" \
  "create: agent cwd is the task worktree"
assert_contains "$(sed -n '2p' "$AGENT_LOG")" "--session $(task_field "$PID" "$ATID" 'tabs[0].session')" \
  "create: agent argv carries the stored session"

# ---------------------------------------------------------------------------
# Rollback after git_task_create when tmux_open_tab cannot run
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
_orig_open=$(declare -f tmux_open_tab)
tmux_open_tab() { return 2; }

capture task_create_and_open "$PID" "Rollback Task" "origin/main" shell
assert_eq "2" "$CAP_RC" "rollback: creation reports failure"
assert_contains "$CAP_ERR" "rolling the task back" "rollback: reports the rollback"
assert_eq "0" "$(task_count)" "rollback: no task left in state"
ROLLBACK_PATH=$CASE_ROOT/balamba_worktrees/alpha/rollback-task
[[ ! -e $ROLLBACK_PATH ]] && _pass "rollback: worktree removed" || \
  _fail "rollback: worktree removed" "$ROLLBACK_PATH still exists"
if git -C "$REPO" show-ref --verify --quiet refs/heads/rollback-task; then
  _fail "rollback: branch removed" "refs/heads/rollback-task still exists"
else
  _pass "rollback: branch removed"
fi
assert_eq "0" "$(tsess list-windows -t balamba -F '#{@balamba_context}' 2>/dev/null | grep -xc 'task:t_rollback-task' || true)" \
  "rollback: no half-open window"

unset -f tmux_open_tab
eval "$_orig_open"

# ---------------------------------------------------------------------------
# terminal_open in project and task contexts
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
TID=$(task_create_and_open "$PID" "Term Base" "origin/main" shell)

capture terminal_open "$PID" proj shell
assert_eq "0" "$CAP_RC" "terminal: project shell opens"
PTAB=$CAP_OUT
assert_match '^tty_[0-9a-f]{8}$' "$PTAB" "terminal: project tab id printed"
assert_eq "1" "$(project_tabs "$PID")" "terminal: project tab recorded"
PWIN=$(window_id_for_tab "$PTAB")
assert_eq "$REPO" "$(tsess display -p -t "$(content_ids "$PWIN" | head -n1)" '#{pane_current_path}')" \
  "terminal: project shell cwd is the checkout"

capture terminal_open "$PID" "task:$TID" agent
assert_eq "0" "$CAP_RC" "terminal: task agent opens"
TTAB=$CAP_OUT
assert_eq "2" "$(task_tabs "$PID" "$TID")" "terminal: task tab recorded"
TWIN=$(window_id_for_tab "$TTAB")
assert_eq "$(task_field "$PID" "$TID" path)" \
  "$(tsess display -p -t "$(content_ids "$TWIN" | head -n1)" '#{pane_current_path}')" \
  "terminal: task agent cwd is the worktree"
assert_eq "task:$TID" "$(balamba_state_get '.active.context')" "terminal: task context is active"

# ---------------------------------------------------------------------------
# project_add_and_open: path with spaces, shell tab, activation
# ---------------------------------------------------------------------------
capture project_add_and_open "$SPACED_REPO"
assert_eq "0" "$CAP_RC" "project add: open succeeds for a path with spaces"
SPID=$CAP_OUT
assert_eq "p_proj beta" "$SPID" "project add: prints the project id"
assert_eq "$SPACED_REPO" "$(balamba_state_get '.projects[] | select(.id == $p) | .path' --arg p "$SPID")" \
  "project add: state keeps the path verbatim"
assert_eq "1" "$(project_tabs "$SPID")" "project add: a shell tab is created"
SPWIN=$(window_id_for_tab "$(balamba_state_get '.projects[] | select(.id == $p) | .tabs[0].id' --arg p "$SPID")")
assert_eq "$SPACED_REPO" "$(tsess display -p -t "$(content_ids "$SPWIN" | head -n1)" '#{pane_current_path}')" \
  "project add: shell starts in the spaced checkout"
assert_eq "$SPID" "$(balamba_state_get '.active.project')" "project add: new project is active"
assert_eq "proj" "$(balamba_state_get '.active.context')" "project add: active context is proj"

# ---------------------------------------------------------------------------
# task_assess: clean, dirty, unmerged/unpushed, detached
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
TID=$(task_create_and_open "$PID" "Assess Me" "origin/main" shell)
TASK_PATH=$(task_field "$PID" "$TID" path)

JSON=$(task_assess "$PID" "$TID")
assert_json "$JSON" "assess: prints one JSON object"
assert_eq "false" "$(jq -r '.dirty' <<<"$JSON")" "assess: clean tree is not dirty"
assert_eq "0" "$(jq -r '.dirty_count' <<<"$JSON")" "assess: dirty file count is zero"
assert_eq "false" "$(jq -r '.detached' <<<"$JSON")" "assess: not detached"
assert_eq "false" "$(jq -r '.unmerged' <<<"$JSON")" "assess: branch starts merged"
assert_eq "0" "$(jq -r '.unpushed' <<<"$JSON")" "assess: no unpushed commits"
assert_eq "assess-me" "$(jq -r '.branch' <<<"$JSON")" "assess: branch reported"
assert_eq "$TASK_PATH" "$(jq -r '.worktree' <<<"$JSON")" "assess: worktree path reported"
[[ $(jq -r '.windows' <<<"$JSON") -ge 1 ]] && _pass "assess: window count includes the task window" || \
  _fail "assess: window count includes the task window"

printf 'dirty\n' >"$TASK_PATH/dirty.txt"
JSON=$(task_assess "$PID" "$TID")
assert_eq "true" "$(jq -r '.dirty' <<<"$JSON")" "assess: dirty tree detected"
assert_eq "1" "$(jq -r '.dirty_count' <<<"$JSON")" "assess: dirty file count is exact"

git -C "$TASK_PATH" add dirty.txt
git -C "$TASK_PATH" commit -q -m "task work"
JSON=$(task_assess "$PID" "$TID")
assert_eq "false" "$(jq -r '.dirty' <<<"$JSON")" "assess: committed tree is clean"
assert_eq "true" "$(jq -r '.unmerged' <<<"$JSON")" "assess: commit makes the branch unmerged"
[[ $(jq -r '.unpushed' <<<"$JSON") -ge 1 ]] && _pass "assess: unpushed commit counted" || \
  _fail "assess: unpushed commit counted" "$(jq -r '.unpushed' <<<"$JSON")"

git -C "$TASK_PATH" checkout -q --detach
JSON=$(task_assess "$PID" "$TID")
assert_eq "true" "$(jq -r '.detached' <<<"$JSON")" "assess: detached HEAD detected"
assert_eq "assess-me" "$(jq -r '.branch' <<<"$JSON")" "assess: stored branch still reported when detached"

# ---------------------------------------------------------------------------
# task_close: windows killed, worktree gone, state clean
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
TID=$(task_create_and_open "$PID" "Close Me" "origin/main" shell)
TASK_PATH=$(task_field "$PID" "$TID" path)
[[ $(window_contexts "$PID" "task:$TID") -ge 1 ]] && _pass "close: task has a live window" || \
  _fail "close: task has a live window"

capture task_close "$PID" "$TID"
assert_eq "0" "$CAP_RC" "close: succeeds"
assert_eq "$TID" "$CAP_OUT" "close: prints the closed task id"
[[ ! -e $TASK_PATH ]] && _pass "close: worktree removed" || _fail "close: worktree removed"
assert_eq "0" "$(task_count)" "close: task removed from state"
assert_eq "0" "$(window_contexts "$PID" "task:$TID")" "close: task windows killed"
assert_eq "proj" "$(balamba_state_get '.active.context')" "close: active context falls back to proj"
assert_status 0 "close: branch kept by default" git -C "$REPO" show-ref --verify --quiet refs/heads/close-me

# --delete-branch on a merged branch deletes it
TID2=$(task_create_and_open "$PID" "Merged Branch" "origin/main" shell)
capture task_close "$PID" "$TID2" --delete-branch
assert_eq "0" "$CAP_RC" "close: --delete-branch succeeds"
if git -C "$REPO" show-ref --verify --quiet refs/heads/merged-branch; then
  _fail "close: merged branch deleted" "refs/heads/merged-branch still exists"
else
  _pass "close: merged branch deleted"
fi

# --delete-branch on an unmerged branch keeps it and reports why
TID3=$(task_create_and_open "$PID" "Unmerged Branch" "origin/main" shell)
T3PATH=$(task_field "$PID" "$TID3" path)
printf 'more\n' >"$T3PATH/work.txt"
git -C "$T3PATH" add work.txt
git -C "$T3PATH" commit -q -m "unmerged work"
capture task_close "$PID" "$TID3" --delete-branch
assert_eq "0" "$CAP_RC" "close: unmerged --delete-branch still closes"
assert_contains "$CAP_ERR" "kept branch unmerged-branch" "close: warns the unmerged branch was kept"
assert_status 0 "close: unmerged branch still exists" git -C "$REPO" show-ref --verify --quiet refs/heads/unmerged-branch
assert_eq "0" "$(task_count)" "close: unmerged task removed from state"

# ---------------------------------------------------------------------------
# Quoting: task name with spaces, quotes, '$' and unicode; env-hook flow
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
WEIRD="Bob's \"\$HOME\" café"
WEIRD_SLUG=$(balamba_slugify "$WEIRD")
capture task_create_and_open "$PID" "$WEIRD" "origin/main" shell
assert_eq "0" "$CAP_RC" "quoting: weird task name creates"
WTID=$CAP_OUT
assert_eq "t_$WEIRD_SLUG" "$WTID" "quoting: slug id is stable"
assert_eq "$WEIRD" "$(task_field "$PID" "$WTID" name)" "quoting: display name preserved byte-for-byte"
[[ -d $(task_field "$PID" "$WTID" path) ]] && _pass "quoting: worktree created" || \
  _fail "quoting: worktree created"
capture task_close "$PID" "$WTID"
assert_eq "0" "$CAP_RC" "quoting: weird task closes"

# helper command generation survives sh -> bash -> function boundaries
helper_out=$(_task_helper_cmd printf '%s' "$WEIRD")
quoted_out=$(sh -c "$helper_out")
assert_eq "$WEIRD" "$quoted_out" "quoting: generated helper command preserves the value"

# Long menu titles are fitted: tmux 3.4 silently drops a menu wider than the
# client, which used to make the close dialog disappear for a verbose summary.
LONG_TITLE=$(printf 'w%.0s' $(seq 1 200))
FITTED=$(_task_fit_title "$LONG_TITLE")
assert_eq "100" "${#FITTED}" "menu: a too-long title is capped at 100 columns"
assert_eq "…" "${FITTED: -1}" "menu: the capped title ends with an ellipsis"
assert_eq "close #1" "$(_task_fit_title 'close #1' | sed 's/##/#/g')" \
  "menu: normal titles keep their text and format escaping"

# a value quoted for tmux survives tmux's own parser ($ and ~ expand inside
# double quotes, so this is the layer that bit before)
tmux_quote_file=$BALAMBA_TEST_ROOT/tmux-quote.out
tmux_quote_val="spaces '\$HOME' ~ café"
tmux_quote_escaped=$(_task_tmux_dq "$tmux_quote_val")
tmux -L "$BALAMBA_SOCKET" run-shell -b \
  "printf '%s' $tmux_quote_escaped > '$tmux_quote_file'" >/dev/null 2>&1 || true
for _i in $(seq 1 100); do
  [[ -s $tmux_quote_file ]] && break
  sleep 0.02
done
assert_eq "$tmux_quote_val" "$(cat "$tmux_quote_file" 2>/dev/null || true)" \
  "quoting: tmux command quoting preserves \$, ~, spaces and quotes"

# internal new-task via the documented non-interactive environment hook
export BALAMBA_FLOW_NAME="Env Task 'quoted' \$HOME"
export BALAMBA_FLOW_REF="origin/main"
export BALAMBA_FLOW_KIND="shell"
capture run_balamba internal new-task
unset BALAMBA_FLOW_NAME BALAMBA_FLOW_REF BALAMBA_FLOW_KIND
assert_eq "0" "$CAP_RC" "internal new-task: env hook succeeds headless"
assert_eq "t_env-task-quoted-home" "$CAP_OUT" "internal new-task: prints the new task id"
assert_eq "Env Task 'quoted' \$HOME" "$(task_field "$PID" "$CAP_OUT" name)" \
  "internal new-task: quoted name stored verbatim"
ENV_TID=$CAP_OUT

# internal activate from state-provided ids
capture run_balamba internal activate "$PID" proj
assert_eq "0" "$CAP_RC" "internal activate: succeeds"
assert_eq "proj" "$(balamba_state_get '.active.context')" "internal activate: context updated"

# internal new-terminal via the same hook
before_tabs=$(project_tabs "$PID")
export BALAMBA_FLOW_KIND="shell"
capture run_balamba internal new-terminal
unset BALAMBA_FLOW_KIND
assert_eq "0" "$CAP_RC" "internal new-terminal: env hook succeeds headless"
assert_match '^tty_[0-9a-f]{8}$' "$CAP_OUT" "internal new-terminal: prints a tab id"
assert_eq "$((before_tabs + 1))" "$(project_tabs "$PID")" "internal new-terminal: tab recorded"

# internal close-task via the documented confirmation hook
export BALAMBA_FLOW_CLOSE_CONFIRM=1
capture run_balamba internal close-task "$PID" "$ENV_TID"
unset BALAMBA_FLOW_CLOSE_CONFIRM
assert_eq "0" "$CAP_RC" "internal close-task: env hook succeeds"
assert_eq "0" "$(balamba_state_get '
  [.projects[] | select(.id == $p) | .tasks[] | select(.id == $t)] | length
' --arg p "$PID" --arg t "$ENV_TID")" "internal close-task: task removed"

# ---------------------------------------------------------------------------
# project remove --force
# ---------------------------------------------------------------------------
GAMMA=$CASE_ROOT/gamma
make_git_repo "$GAMMA" origin >/dev/null
GPID=$(git_project_add "$GAMMA")
GTID=$(git_task_create "$GPID" "Gamma Task" "origin/main" shell)
GTPATH=$(task_field "$GPID" "$GTID" path)

capture run_balamba project remove "$GPID"
assert_eq "2" "$CAP_RC" "project remove: refuses a project with tasks"
assert_eq "1" "$(balamba_state_get '[.projects[] | select(.id == $p)] | length' --arg p "$GPID")" \
  "project remove: project kept without --force"

capture run_balamba project remove "$GPID" --force
assert_eq "0" "$CAP_RC" "project remove: --force succeeds"
assert_contains "$CAP_OUT" "removed project $GPID" "project remove: prints the project id"
assert_eq "0" "$(balamba_state_get '[.projects[] | select(.id == $p)] | length' --arg p "$GPID")" \
  "project remove: project gone from state"
[[ -d $GTPATH ]] && _pass "project remove: worktree left on disk" || \
  _fail "project remove: worktree left on disk"

# ---------------------------------------------------------------------------
# Internal verbs accept an explicit target (no activate-then-delay race)
# ---------------------------------------------------------------------------
reset_all
P_EXPLICIT=$(git_project_add "$REPO")
P_OTHER=$(git_project_add "$SPACED_REPO")
assert_eq "$P_OTHER" "$(balamba_state_get '.active.project')" \
  "explicit target: the other project is active"
export BALAMBA_FLOW_NAME="Explicit Task"
export BALAMBA_FLOW_REF="origin/main"
export BALAMBA_FLOW_KIND="shell"
capture run_balamba internal new-task "$P_EXPLICIT"
unset BALAMBA_FLOW_NAME BALAMBA_FLOW_REF BALAMBA_FLOW_KIND
assert_eq "0" "$CAP_RC" "explicit target: internal new-task <project> succeeds"
assert_eq "1" "$(balamba_state_get '
  [.projects[] | select(.id == $p) | .tasks[]] | length
' --arg p "$P_EXPLICIT")" "explicit target: task lands in the named project"
assert_eq "0" "$(balamba_state_get '
  [.projects[] | select(.id == $p) | .tasks[]] | length
' --arg p "$P_OTHER")" "explicit target: the active project is untouched"
before_other_tabs=$(project_tabs "$P_OTHER")
export BALAMBA_FLOW_KIND="shell"
capture run_balamba internal new-terminal "$P_EXPLICIT" proj
unset BALAMBA_FLOW_KIND
assert_eq "0" "$CAP_RC" "explicit target: internal new-terminal <pid> <ctx> succeeds"
assert_eq "$before_other_tabs" "$(project_tabs "$P_OTHER")" \
  "explicit target: new-terminal does not touch the active project"

# ---------------------------------------------------------------------------
# Interactive flows fail clearly with no attached client and create nothing
# ---------------------------------------------------------------------------
reset_all
PID=$(git_project_add "$REPO")
assert_eq "0" "$(tsess list-clients -F '#{client_name}' 2>/dev/null | wc -l | tr -d ' ' || true)" \
  "no-client: no clients are attached"

capture task_new_flow "$PID"
assert_eq "2" "$CAP_RC" "no-client: new task exits 2"
assert_contains "$CAP_ERR" "no attached tmux client" "no-client: new task explains why"
assert_eq "0" "$(task_count)" "no-client: new task creates nothing"

capture terminal_new_flow "$PID" proj
assert_eq "2" "$CAP_RC" "no-client: new terminal exits 2"
assert_contains "$CAP_ERR" "no attached tmux client" "no-client: new terminal explains why"
assert_eq "0" "$(project_tabs "$PID")" "no-client: new terminal creates nothing"

capture project_add_flow
assert_eq "2" "$CAP_RC" "no-client: add project exits 2"
assert_contains "$CAP_ERR" "no attached tmux client" "no-client: add project explains why"
assert_eq "1" "$(project_count)" "no-client: add project adds nothing"

NTID=$(git_task_create "$PID" "Detached Close" "origin/main" shell)
NTPATH=$(task_field "$PID" "$NTID" path)
capture task_close_flow "$PID" "$NTID"
assert_eq "2" "$CAP_RC" "no-client: close task exits 2"
assert_contains "$CAP_ERR" "no attached tmux client" "no-client: close task explains why"
assert_eq "1" "$(balamba_state_get '
  [.projects[] | select(.id == $p) | .tasks[] | select(.id == $t)] | length
' --arg p "$PID" --arg t "$NTID")" "no-client: close task leaves the task alone"
[[ -d $NTPATH ]] && _pass "no-client: close task leaves the worktree alone" || \
  _fail "no-client: close task leaves the worktree alone"

finish_tests
