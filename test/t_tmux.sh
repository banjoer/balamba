#!/usr/bin/env bash
# Tests for lib/tmux.sh (part 4): server/session lifecycle, 3-column tabs,
# launching, widths, runtime capture, restore and reconciliation.
#
# Headless: everything runs on the dedicated test socket from helpers.sh, with
# a fake long-running chrome command and a fake agent that records argv/cwd.
# restore_stagger=0 keeps restore fast.

set -Eeuo pipefail

# shellcheck source=helpers.sh
. "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=../lib/common.sh
. "$BALAMBA_ROOT/lib/common.sh"
# shellcheck source=../lib/tmux.sh
. "$BALAMBA_ROOT/lib/tmux.sh"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock"
rm -rf -- "$BALAMBA_RUNTIME"
rm -f -- "$BALAMBA_CONFIG"

AGENT_SCRIPT=$BALAMBA_TEST_ROOT/fake-agent.sh
AGENT_LOG=$BALAMBA_TEST_ROOT/fake-agent.log
TREE_WIDTH=21
GIT_WIDTH=17

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
tree_width=$TREE_WIDTH
git_width=$GIT_WIDTH
restore_stagger=0
default_agent=fakeagent
BALAMBA_AGENT_COMMAND[fakeagent]='$AGENT_SCRIPT $AGENT_LOG --session {{session}} --dir {{dir}}'
BALAMBA_AGENT_RESUME[fakeagent]='$AGENT_SCRIPT $AGENT_LOG --session {{session}} --dir {{dir}}'
BALAMBA_AGENT_LABEL[fakeagent]='fake'
BALAMBA_TREE_COMMAND='sleep 900'
BALAMBA_GIT_COMMAND='sleep 900'
EOF

balamba_state_init

CASE_ROOT=$BALAMBA_TEST_ROOT/cases
ALPHA="$CASE_ROOT/proj alpha"
BETA="$CASE_ROOT/proj två"
OTHER_CWD="$CASE_ROOT/cwd with space"
TASK_PATH="$CASE_ROOT/task worktree"
mkdir -p -- "$ALPHA" "$BETA" "$OTHER_CWD" "$TASK_PATH"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
capture() {
  CAP_OUT=""
  CAP_ERR=""
  CAP_RC=0
  local errf
  errf=$(mktemp "${TMPDIR:-/tmp}/balamba-tmux-cap.XXXXXX")
  CAP_OUT=$("$@" 2>"$errf") || CAP_RC=$?
  CAP_ERR=$(<"$errf")
  rm -f -- "$errf"
}

reset_all() {
  tmux -L "$BALAMBA_SOCKET" kill-server >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 100); do
    tmux -L "$BALAMBA_SOCKET" has-session -t balamba >/dev/null 2>&1 || break
    sleep 0.02
  done
  rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock" "$AGENT_LOG"
  rm -rf -- "$BALAMBA_RUNTIME"
  balamba_state_init
  : >"$AGENT_LOG"
}

add_project() {
  local id=$1 path=$2 name=$3
  balamba_state_update '
    .projects += [{id:$id,name:$name,path:$path,expanded:true,tabs:[],tasks:[]}]
  ' --arg id "$id" --arg path "$path" --arg name "$name"
}

add_task() {
  local pid=$1 tid=$2 path=$3
  balamba_state_update '
    .projects |= map(if .id == $pid then
      .tasks += [{id:$tid,name:$tid,slug:($tid|sub("^t_";"")),path:$path,
                  branch:"b",base_ref:"main",created_at:"2026-01-01T00:00:00Z",
                  expanded:false,tabs:[]}]
      else . end)
  ' --arg pid "$pid" --arg tid "$tid" --arg path "$path"
}

tsess() { tmux -L "$BALAMBA_SOCKET" "$@"; }

session_count() {
  tsess list-sessions -F '#{session_name}' 2>/dev/null | wc -l | tr -d ' '
}

window_count() {
  tsess list-windows -t balamba -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' '
}

window_for_tab() {
  local tab=$1 idx
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

tab_ids_in_order() {
  tsess list-windows -t balamba -F $'#{window_index}\t#{@balamba_tab}' 2>/dev/null |
    sort -n -k1,1 | awk -F '\t' 'NF > 1 && $2 != "" { printf "%s%s", sep, $2; sep="," }'
}

pane_total() {
  tsess list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' '
}

content_ids() {
  local win=$1 idx id chrome
  while IFS=$'\t' read -r idx id chrome; do
    [[ -n $id && -z $chrome ]] || continue
    printf '%s\n' "$id"
  done < <(tsess list-panes -t "$win" -F $'#{pane_index}\t#{pane_id}\t#{@balamba_chrome}' 2>/dev/null |
    sort -n -k1,1)
}

content_count() {
  local n
  n=$(content_ids "$1" | wc -l | tr -d ' ')
  printf '%s\n' "$n"
}

chrome_width() {
  local win=$1 which=$2
  tsess list-panes -t "$win" -F $'#{@balamba_chrome}\t#{pane_width}' 2>/dev/null |
    awk -F '\t' -v w="$which" '$1 == w {print $2; exit}'
}

content_geometry() {
  local win=$1 idx id chrome w h
  while IFS=$'\t' read -r idx id chrome w h; do
    [[ -z $chrome ]] || continue
    printf '%sx%s,' "$w" "$h"
  done < <(tsess list-panes -t "$win" \
    -F $'#{pane_index}\t#{pane_id}\t#{@balamba_chrome}\t#{pane_width}\t#{pane_height}' \
    2>/dev/null | sort -n -k1,1)
}

content_geometry_list() {
  local win=$1 idx id chrome w h
  while IFS=$'\t' read -r idx id chrome w h; do
    [[ -z $chrome ]] || continue
    printf '%s:%sx%s\n' "$idx" "$w" "$h"
  done < <(tsess list-panes -t "$win" \
    -F $'#{pane_index}\t#{pane_id}\t#{@balamba_chrome}\t#{pane_width}\t#{pane_height}' \
    2>/dev/null | sort -n -k1,1)
}

active_content_index() {
  local win=$1 idx id active chrome c=0 found=-1
  while IFS=$'\t' read -r idx id active chrome; do
    [[ -z $chrome ]] || continue
    if [[ $active == 1 ]]; then found=$c; fi
    c=$((c + 1))
  done < <(tsess list-panes -t "$win" \
    -F $'#{pane_index}\t#{pane_id}\t#{pane_active}\t#{@balamba_chrome}' \
    2>/dev/null | sort -n -k1,1)
  printf '%s\n' "$found"
}

tab_field() {
  local tab=$1 field=$2
  balamba_state_get "
    .projects[] as \$p
    | (\$p.tabs[]?, (\$p.tasks[]? | .tabs[]?))
    | select(.id == \$t) | .$field
  " --arg t "$tab"
}

tabs_of() {
  local pid=$1 context=$2 tid=${2#task:} n
  if [[ $context == proj ]]; then
    n=$(balamba_state_get '.projects[] | select(.id==$p) | (.tabs|length)' \
      --arg p "$pid")
  else
    n=$(balamba_state_get '.projects[] | select(.id==$p) | .tasks[] | select(.id==$t) | (.tabs|length)' \
      --arg p "$pid" --arg t "$tid")
  fi
  printf '%s\n' "$n"
}

wait_until() {
  local i
  for i in $(seq 1 200); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.03
  done
  return 1
}

wait_log_lines() {
  local n=$1
  wait_until bash -c "[[ \$(wc -l <'$AGENT_LOG') -ge $n ]]"
}

content_cwds_joined() {
  local win=$1 id joined=""
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    joined+=$(tsess display -p -t "$id" '#{pane_current_path}')$'\n'
  done < <(content_ids "$win")
  printf '%s' "$joined"
}

snapshot_basic() {
  local idx tab win pc cw ai
  while IFS=$'\t' read -r idx tab; do
    [[ -n $tab ]] || continue
    win=$(tsess display -p -t "balamba:$idx" '#{window_id}')
    pc=$(content_count "$win")
    ai=$(active_content_index "$win")
    cw=$(content_cwds_joined "$win" | tr '\n' ';')
    printf '%s|%s|%s|%s|%s\n' "$idx" "$tab" "$pc" "$cw" "$ai"
  done < <(tsess list-windows -t balamba -F $'#{window_index}\t#{@balamba_tab}' 2>/dev/null |
    sort -n -k1,1)
}

widths_ok() {
  local win=$1
  [[ $(chrome_width "$win" tree) == "$TREE_WIDTH" &&
    $(chrome_width "$win" git) == "$GIT_WIDTH" ]]
}

# ---------------------------------------------------------------------------
# Server / session lifecycle
# ---------------------------------------------------------------------------
reset_all

assert_status 0 "server_up: starts cleanly" tmux_server_up
assert_status 0 "server_up: idempotent" tmux_server_up

assert_status 0 "ensure_session: creates the session" tmux_ensure_session
assert_eq "1" "$(session_count)" "ensure_session: exactly one session"
assert_status 0 "ensure_session: idempotent" tmux_ensure_session
assert_eq "1" "$(session_count)" "ensure_session: still one session"
assert_eq "1" "$(window_count)" "ensure_session: empty workspace has one window"
assert_eq "prefix C-a" "$(tsess show-options -g prefix | sed 's/[[:space:]]*$//')" \
  "cold start: the private server loaded tmux.conf (prefix C-a)"
assert_eq "on" "$(tsess show-options -gv mouse)" \
  "cold start: mouse is on from tmux.conf"
assert_eq "on" "$(tsess show-options -gv monitor-activity)" \
  "cold start: monitor-activity is on from tmux.conf"

# Stale socket: a regular file where the socket belongs must be replaced.
tsess kill-server >/dev/null 2>&1 || true
for _i in $(seq 1 100); do
  tsess has-session -t balamba >/dev/null 2>&1 || break
  sleep 0.02
done
sock=$(balamba_tmux_socket_path)
mkdir -p -- "$(dirname -- "$sock")"
rm -f -- "$sock"
printf 'stale\n' >"$sock"
assert_status 0 "server_up: recovers from a stale socket" tmux_server_up
assert_status 0 "ensure_session: works after stale-socket recovery" tmux_ensure_session
assert_eq "1" "$(session_count)" "stale socket: session exists again"

# ---------------------------------------------------------------------------
# Open tabs: chrome, widths, names, cwd, state, agent launch
# ---------------------------------------------------------------------------
reset_all
add_project p_alpha "$ALPHA" alpha
add_project p_beta "$BETA" beta

assert_status 0 "ensure_session: builds the active context" tmux_ensure_session
assert_eq "1" "$(tabs_of p_alpha proj)" "ensure_session: empty context gets exactly one shell tab"

win=$(window_for_tab "$(tsess list-windows -t balamba -F '#{@balamba_tab}' | head -n1)")
base_panes=$(pane_total "$win")
assert_eq "3" "$base_panes" "tab: tree + content + git panes"
assert_eq "shell 1" "$(tsess display -p -t "$win" '#{window_name}')" "tab: window name from tab title"
assert_eq "$TREE_WIDTH" "$(chrome_width "$win" tree)" "tab: tree width"
assert_eq "$GIT_WIDTH" "$(chrome_width "$win" git)" "tab: git width"
assert_eq "$ALPHA" "$(tsess display -p -t "$(content_ids "$win" | head -n1)" '#{pane_current_path}')" \
  "tab: shell starts in the project cwd (spaces preserved)"

capture tmux_open_tab p_alpha proj shell
assert_eq "0" "$CAP_RC" "open_tab: shell tab succeeds"
shell_tab=$CAP_OUT
assert_match '^tty_[0-9a-f]{8}$' "$shell_tab" "open_tab: prints a tab id"
assert_eq "2" "$(tabs_of p_alpha proj)" "open_tab: tab appended to state"
assert_eq "shell 2" "$(tsess display -p -t "$(window_for_tab "$shell_tab")" '#{window_name}')" \
  "open_tab: second shell gets its own title"
assert_match '^shell$' "$(tab_field "$shell_tab" kind)" "open_tab: state kind is shell"
assert_eq "$ALPHA" "$(balamba_state_get '
  .projects[] as $p
  | ($p.tabs[]?, ($p.tasks[]? | .tabs[]?)) | select(.id == $t)
  | .panes[0].cwd
' --arg t "$shell_tab")" "open_tab: state records the cwd"

capture tmux_open_tab p_alpha proj agent
assert_eq "0" "$CAP_RC" "open_tab: agent tab succeeds"
agent_tab=$CAP_OUT
assert_match '^tty_[0-9a-f]{8}$' "$agent_tab" "open_tab: agent tab id"
assert_eq "agent" "$(tab_field "$agent_tab" kind)" "open_tab: agent kind in state"
agent_ses=$(tab_field "$agent_tab" session)
assert_match '^ses_[0-9a-f]{32}$' "$agent_ses" "open_tab: session is ses_ + 32 hex"
assert_not_contains "$(tab_field "$agent_tab" panes)" "standalone" \
  "open_tab: state never records --standalone"

if wait_log_lines 2; then
  _pass "open_tab: agent process started"
else
  _fail "open_tab: agent process started" "no lines in $AGENT_LOG"
fi
agent_cwd=$(sed -n '1p' "$AGENT_LOG")
agent_args=$(sed -n '2p' "$AGENT_LOG")
assert_contains "$agent_cwd" "$ALPHA" "open_tab: agent cwd is the project path"
assert_contains "$agent_args" "--session $agent_ses" "open_tab: agent argv carries the stored session"
assert_contains "$agent_args" "ses_" "open_tab: agent args carry a ses_ id"
assert_not_contains "$agent_args" "--standalone" "open_tab: agent args have no --standalone"

# Agent create vs resume templates: restore uses BALAMBA_AGENT_RESUME.
_resume_saved=${BALAMBA_AGENT_RESUME[fakeagent]-}
BALAMBA_AGENT_RESUME[fakeagent]='fake-resume --session {{session}} --dir {{dir}}'
assert_eq "fake-resume --session ses_abc --dir /tmp" \
  "$(_tmux_pane_command agent fakeagent ses_abc /tmp 1)" \
  "agent: resume uses BALAMBA_AGENT_RESUME"
assert_eq "$AGENT_SCRIPT $AGENT_LOG --session ses_abc --dir /tmp" \
  "$(_tmux_pane_command agent fakeagent ses_abc /tmp 0)" \
  "agent: create uses BALAMBA_AGENT_COMMAND"
BALAMBA_AGENT_RESUME[fakeagent]=$_resume_saved

# ---------------------------------------------------------------------------
# Context isolation and activation
# ---------------------------------------------------------------------------
capture tmux_open_tab p_beta proj shell
beta_tab=$CAP_OUT
assert_eq "0" "$CAP_RC" "context: beta tab opens"
assert_eq "1" "$(tabs_of p_beta proj)" "context: beta tab landed in its project"
assert_eq "4" "$(tsess list-windows -t balamba -F '#{window_id}' | wc -l | tr -d ' ')" \
  "context: windows are not duplicated across projects"

assert_status 0 "activate: alpha" tmux_activate p_alpha proj
alpha_first_win=$(window_for_tab "$(balamba_state_get '
  .projects[] | select(.id == "p_alpha") | .tabs[0].id')")
assert_eq "$alpha_first_win" "$(tsess display -p -t balamba: '#{window_index}')" \
  "activate: alpha's first tab selected"
assert_eq "p_alpha" "$(tsess display -p -t "balamba:$alpha_first_win" '#{@balamba_project}')" \
  "activate: window tagged with the project"

assert_status 0 "activate: beta" tmux_activate p_beta proj
beta_win=$(window_for_tab "$beta_tab")
assert_eq "$beta_win" "$(tsess display -p -t balamba: '#{window_index}')" \
  "activate: beta window selected"
assert_eq "p_beta" "$(tsess display -p -t "balamba:$beta_win" '#{@balamba_project}')" \
  "activate: beta window tagged with the project"

capture tmux_activate p_alpha task:t_missing
assert_eq "2" "$CAP_RC" "activate: unknown task is an error"

# ---------------------------------------------------------------------------
# save_runtime: split, resize, cwd, layout, active pane, order
# ---------------------------------------------------------------------------
assert_status 0 "save: activate alpha before saving" tmux_activate p_alpha proj
alpha_win=$(window_for_tab "$agent_tab")
alpha_winid=$(tsess display -p -t "balamba:$alpha_win" '#{window_id}')
content1=$(content_ids "$alpha_winid" | sed -n '1p')
tsess split-window -h -t "$content1" -c "$OTHER_CWD" 'sleep 900' >/dev/null 2>&1
# make the new content pane active and give it the spaced cwd
new_content=$(content_ids "$alpha_winid" | tail -n1)
tsess respawn-pane -k -t "$new_content" -c "$OTHER_CWD" 'sleep 900' >/dev/null 2>&1
tsess select-pane -t "$new_content" >/dev/null 2>&1
# Resize the split content area so the saved layout carries real geometry.
tsess resize-pane -t "$new_content" -x 70 >/dev/null 2>&1
assert_eq "2" "$(content_count "$alpha_winid")" "save: content pane split counted"

assert_status 0 "save: tmux_save_runtime succeeds" tmux_save_runtime
assert_eq "2" "$(tab_field "$agent_tab" pane_count)" "save: pane_count is content-only"
saved_layout=$(tab_field "$agent_tab" layout)
live_layout=$(tsess display -p -t "$alpha_winid" '#{window_layout}')
assert_eq "$live_layout" "$saved_layout" "save: layout matches the live window"
assert_eq "1" "$(tab_field "$agent_tab" active_pane)" "save: active pane is content-relative"
assert_eq "$alpha_win" "$(tab_field "$agent_tab" window)" "save: live window index stored"
assert_contains "$(tab_field "$agent_tab" panes)" "\"cwd\": \"$ALPHA\"" \
  "save: first content cwd captured"
assert_contains "$(tab_field "$agent_tab" panes)" "\"cwd\": \"$OTHER_CWD\"" \
  "save: split content cwd captured (spaces preserved)"
assert_status 0 "save: idempotent second save" tmux_save_runtime

# ---------------------------------------------------------------------------
# Restore: capture, kill-server, rebuild, compare
# ---------------------------------------------------------------------------
before_windows=$(window_count)
before_order=$(tab_ids_in_order)
before_active=$(tsess display -p -t balamba: '#{window_index}')
before_snapshot=$(snapshot_basic)
save_geom=""
while IFS=$'\t' read -r idx tab; do
  [[ -n $tab ]] || continue
  wid=$(tsess display -p -t "balamba:$idx" '#{window_id}')
  save_geom+="$tab=$(content_geometry "$wid")"$'\n'
done < <(tsess list-windows -t balamba -F $'#{window_index}\t#{@balamba_tab}' | sort -n -k1,1)
agent_lines_before=$(wc -l <"$AGENT_LOG" | tr -d ' ')
agent_block_before=$(sed -n '1,2p' "$AGENT_LOG")

tsess kill-server >/dev/null 2>&1 || true
for _i in $(seq 1 100); do
  tsess has-session -t balamba >/dev/null 2>&1 || break
  sleep 0.02
done
if tsess has-session -t balamba >/dev/null 2>&1; then
  _fail "restore: server is really dead before restore"
else
  _pass "restore: server is really dead before restore"
fi

assert_status 0 "restore: rebuilds from state" tmux_restore
assert_eq "$before_windows" "$(window_count)" "restore: same window count"
assert_eq "$before_order" "$(tab_ids_in_order)" "restore: same window/tab order"
assert_eq "$before_active" "$(tsess display -p -t balamba: '#{window_index}')" \
  "restore: active window restored"

# Widths are asserted at attach; assert explicitly here (headless test).
while IFS=$'\t' read -r idx tab; do
  [[ -n $tab ]] || continue
  wid=$(tsess display -p -t "balamba:$idx" '#{window_id}')
  tmux_assert_widths "$wid"
  assert_eq "$TREE_WIDTH" "$(chrome_width "$wid" tree)" "restore: tree width for $tab"
  assert_eq "$GIT_WIDTH" "$(chrome_width "$wid" git)" "restore: git width for $tab"
  assert_eq "200x50" "$(tsess display -p -t "$wid" '#{window_width}x#{window_height}')" \
    "restore: window size for $tab"
  assert_eq "$(printf '%s\n' "$save_geom" | grep -F "$tab=" | cut -d= -f2-)" \
    "$(content_geometry "$wid")" "restore: content geometry for $tab"
done < <(tsess list-windows -t balamba -F $'#{window_index}\t#{@balamba_tab}' | sort -n -k1,1)

# cwds: wait for the shell panes to report their start directory.
while IFS=$'\t' read -r idx tab; do
  [[ -n $tab ]] || continue
  wid=$(tsess display -p -t "balamba:$idx" '#{window_id}')
  want=$(printf '%s\n' "$before_snapshot" | awk -F'|' -v t="$tab" '$2 == t {print $4}')
  got=""
  for _i in $(seq 1 100); do
    got=$(content_cwds_joined "$wid" | tr '\n' ';')
    [[ $got == "$want" ]] && break
    sleep 0.03
  done
  assert_eq "$want" "$got" "restore: content cwds for $tab"
done < <(tsess list-windows -t balamba -F $'#{window_index}\t#{@balamba_tab}' | sort -n -k1,1)

assert_eq "$before_snapshot" "$(snapshot_basic)" "restore: pane counts and active panes match"

# The agent relaunches with identical argv and cwd.
if wait_log_lines $((agent_lines_before + 2)); then
  _pass "restore: agent relaunched"
else
  _fail "restore: agent relaunched" "agent log did not grow"
fi
agent_block_after=$(sed -n "$((agent_lines_before + 1)),$((agent_lines_before + 2))p" "$AGENT_LOG")
assert_eq "$agent_block_before" "$agent_block_after" "restore: agent argv and cwd identical"
assert_not_contains "$agent_block_after" "--standalone" "restore: agent relaunch has no --standalone"

# Restore twice must not duplicate windows.
assert_status 0 "restore: second call is a no-op" tmux_restore
assert_eq "$before_windows" "$(window_count)" "restore: no duplicate windows"

# ---------------------------------------------------------------------------
# Pane-count mismatch: never apply a truncated layout
# ---------------------------------------------------------------------------
reset_all
add_project p_alpha "$ALPHA" alpha
tmux_ensure_session
mismatch_tab=$(tsess list-windows -t balamba -F '#{@balamba_tab}' | head -n1)
tmux_save_runtime
layout_before=$(tab_field "$mismatch_tab" layout)
tsess kill-server >/dev/null 2>&1 || true
for _i in $(seq 1 100); do
  tsess has-session -t balamba >/dev/null 2>&1 || break
  sleep 0.02
done
# Tamper: the tab claims 4 content panes while the saved layout has 4 leaves
# (2 content + 2 chrome).  The rebuilt window will have 6 panes, so the layout
# must not be applied.
balamba_state_update '
  .projects |= map(if .id == "p_alpha" then
    .tabs |= map(.pane_count = 4)
    else . end)
'
capture tmux_restore
assert_eq "0" "$CAP_RC" "mismatch: restore does not crash"
mw=$(window_for_tab "$mismatch_tab")
assert_eq "6" "$(pane_total "$mw")" "mismatch: all requested panes were built"
assert_eq "4" "$(content_count "$mw")" "mismatch: content pane count from tampered state"
tmux_assert_widths "$mw"
assert_eq "$TREE_WIDTH" "$(chrome_width "$mw" tree)" "mismatch: widths reasserted after fallback"
assert_eq "$GIT_WIDTH" "$(chrome_width "$mw" git)" "mismatch: git width reasserted after fallback"
assert_ne "$layout_before" "$(tsess display -p -t "$mw" '#{window_layout}')" \
  "mismatch: saved (truncating) layout was not applied"

# ---------------------------------------------------------------------------
# assert_widths after a simulated client resize
# ---------------------------------------------------------------------------
mw=$(window_for_tab "$mismatch_tab")
tsess resize-window -t "$mw" -x 150 -y 40 >/dev/null 2>&1
if wait_until widths_ok "$mw"; then
  _pass "widths: window-resized hook reasserts tree/git widths"
else
  _fail "widths: window-resized hook reasserts tree/git widths" \
    "tree=$(chrome_width "$mw" tree) git=$(chrome_width "$mw" git)"
fi
tree_pane=$(tsess list-panes -t "$mw" -F $'#{@balamba_chrome}\t#{pane_id}' |
  awk -F '\t' '$1 == "tree" {print $2; exit}')
tsess resize-pane -t "$tree_pane" -x 60 >/dev/null 2>&1
assert_eq "60" "$(chrome_width "$mw" tree)" "widths: tree drifted after a manual resize"
assert_status 0 "widths: reassert after resize" tmux_assert_widths "$mw"
assert_eq "$TREE_WIDTH" "$(chrome_width "$mw" tree)" "widths: tree reasserted"
assert_eq "$GIT_WIDTH" "$(chrome_width "$mw" git)" "widths: git reasserted"
nochrome=$(tsess new-window -d -P -F '#{window_id}' -t balamba: -n nochrome 'sleep 60')
assert_status 0 "widths: no-op when a window has no chrome" tmux_assert_widths "$nochrome"
tsess kill-window -t "$nochrome" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# remove_project: only that project's windows go away
# ---------------------------------------------------------------------------
reset_all
add_project p_alpha "$ALPHA" alpha
add_project p_beta "$BETA" beta
tmux_ensure_session
capture tmux_open_tab p_beta proj shell
beta_only_tab=$CAP_OUT
alpha_windows_before=$(tsess list-windows -t balamba -F '#{@balamba_project}' |
  grep -cx 'p_alpha' || true)
beta_windows_before=$(tsess list-windows -t balamba -F '#{@balamba_project}' |
  grep -cx 'p_beta' || true)
assert_eq "1" "$beta_windows_before" "remove: beta has a window before removal"

# bin/balamba removes the state entry first, then calls tmux_remove_project.
balamba_state_update '
  .projects |= map(select(.id != "p_beta"))
  | .active.project = "p_alpha" | .active.context = "proj" | .active.window = 0
'
assert_status 0 "remove: tmux_remove_project succeeds" tmux_remove_project p_beta
assert_eq "0" "$(tsess list-windows -t balamba -F '#{@balamba_project}' | grep -cx 'p_beta' || true)" \
  "remove: beta windows are gone"
assert_eq "$alpha_windows_before" \
  "$(tsess list-windows -t balamba -F '#{@balamba_project}' | grep -cx 'p_alpha' || true)" \
  "remove: alpha windows untouched"
assert_eq "1" "$(session_count)" "remove: the session/server survives"
assert_status 0 "remove: unknown project is a no-op" tmux_remove_project p_nope

# ---------------------------------------------------------------------------
# Reconcile: deleted worktree is skipped, the rest restores
# ---------------------------------------------------------------------------
reset_all
add_project p_alpha "$ALPHA" alpha
add_task p_alpha t_gone "$TASK_PATH"
tmux_ensure_session
capture tmux_open_tab p_alpha task:t_gone shell
gone_tab=$CAP_OUT
assert_eq "0" "$CAP_RC" "reconcile: task tab opens before deletion"
sleep 0.2
tmux_save_runtime
windows_before=$(window_count)
tasks_before=$(balamba_state_get '[.projects[] | .tasks[]?] | length')
tsess kill-server >/dev/null 2>&1 || true
for _i in $(seq 1 100); do
  tsess has-session -t balamba >/dev/null 2>&1 || break
  sleep 0.02
done
rmdir -- "$TASK_PATH"
mkdir -p -- "$CASE_ROOT/unknown directory"
capture tmux_restore
assert_eq "0" "$CAP_RC" "reconcile: restore succeeds with a missing worktree"
assert_contains "$CAP_ERR" "t_gone" "reconcile: warning names the dropped task"
assert_eq "0" "$(balamba_state_get '[.projects[] | .tasks[]?] | length')" \
  "reconcile: missing task dropped from state"
assert_eq "$((windows_before - 1))" "$(window_count)" \
  "reconcile: only the missing task's window is skipped"
assert_eq "0" "$(tsess list-windows -t balamba -F '#{@balamba_context}' | grep -cx 'task:t_gone' || true)" \
  "reconcile: no window for the dropped task remains"
assert_eq "$tasks_before" "1" "reconcile: exactly one task existed before"
assert_eq "1" "$(balamba_state_get '[.projects[] | .tabs[]?] | length')" \
  "reconcile: project tabs are still in state"
assert_eq "1" "$(window_count)" "reconcile: the rest of the workspace restored"

finish_tests
