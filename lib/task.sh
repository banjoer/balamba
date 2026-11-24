#!/usr/bin/env bash
# balamba — task and terminal flows (part 5).
#
# Two layers:
#
#   * non-interactive core (task_create_and_open, terminal_open,
#     project_add_and_open, task_close, task_assess) — no prompts, usable from
#     tests and from the interactive flows;
#   * interactive tmux flows (task_new_flow, task_close_flow,
#     terminal_new_flow, project_add_flow, project_remove_flow) — only tmux
#     native UI (command-prompt, display-menu, display-message).
#
# Contract: docs/architecture.md §11.  State is only touched through the
# balamba_state_* API; git and tmux work is delegated to lib/git.sh and
# lib/tmux.sh.
#
# Quoting model
# -------------
# Free text from command-prompt is *never* interpolated into a shell command.
# The prompt template writes it into the tmux global environment with the
# quoted replacement ("%1%", which tmux escapes for its parser).  Menu items
# run fixed helper commands; those helpers read the values from the environment
# inherited from tmux.  All paths embedded in generated helper commands go
# through POSIX single-quote escaping, and every tmux command string has '#' 
# doubled so user data is not treated as a format.
#
# Non-interactive test/continuation hooks (environment):
#   BALAMBA_FLOW_NAME    task display name (with BALAMBA_FLOW_KIND)
#   BALAMBA_FLOW_REF     ref to create the task from
#   BALAMBA_FLOW_KIND    "agent" or "shell"; presence makes a flow non-interactive
#   BALAMBA_FLOW_PROJECT project id for the task/terminal continuation
#   BALAMBA_FLOW_CONTEXT context ("proj" or "task:<id>") for a terminal continuation
#   BALAMBA_FLOW_PATH    project path for project_add_flow
#   BALAMBA_FLOW_CLOSE_CONFIRM=1  close without dialogs
#   BALAMBA_FLOW_DELETE_BRANCH=1  with CLOSE_CONFIRM, pass --delete-branch
#   BALAMBA_FLOW_PROJECT_REMOVE_CONFIRM=1  remove a project without dialogs
# These are internal continuation hooks; tests use the same names.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# A POSIX sh single-quoted string.  Works for spaces, quotes, '$', backticks
# and newlines; the value is only ever interpreted by sh, never by tmux.
_task_sh_quote() {
  local s=${1-}
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Escape '#' for tmux formats.  Applied to generated tmux command strings and
# to menu titles/labels that may contain user data.
_task_fmt_escape() {
  local s=${1-}
  s=${s//#/##}
  printf '%s' "$s"
}

# Quote a string as a tmux double-quoted command argument.  Unlike the tmux
# library's plain quoting helper, this also escapes '$', which tmux expands
# even inside double quotes.  Tilde needs no escaping inside double quotes.
# Combined with _task_fmt_escape this keeps paths with '$', spaces and quotes
# intact when embedded in generated tmux command strings.
_task_tmux_dq() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//\$/\\\$}
  printf '"%s"' "$s"
}

# Build a fixed shell command that sources the libs in a fresh process and
# calls <function> with the remaining arguments.  Environment is explicit so
# run-shell (which may outlive the invoking CLI with different XDG vars) still
# sees the same state/config/socket.
_task_helper_cmd() {
  local fn=$1
  shift
  local script="" lib a
  for lib in common git tmux task; do
    script+=". $(_task_sh_quote "$BALAMBA_ROOT/lib/$lib.sh"); "
  done
  script+=$fn
  for a in "$@"; do
    script+=" $(_task_sh_quote "$a")"
  done

  local -a envs=(
    "BALAMBA_ROOT=$BALAMBA_ROOT"
    "BALAMBA_BIN=${BALAMBA_BIN:-$BALAMBA_ROOT/bin/balamba}"
    "BALAMBA_STATE=$BALAMBA_STATE"
    "BALAMBA_CONFIG=$BALAMBA_CONFIG"
    "BALAMBA_RUNTIME=$BALAMBA_RUNTIME"
    "BALAMBA_SOCKET=$BALAMBA_SOCKET"
    "BALAMBA_TMUX_CONF=${BALAMBA_TMUX_CONF-}"
    "HOME=${HOME-}"
    "XDG_CONFIG_HOME=${XDG_CONFIG_HOME-}"
    "XDG_STATE_HOME=${XDG_STATE_HOME-}"
  )
  [[ -n ${TMUX_TMPDIR-} ]] && envs+=("TMUX_TMPDIR=$TMUX_TMPDIR")

  printf 'env'
  for a in "${envs[@]}"; do
    printf ' %s' "$(_task_sh_quote "$a")"
  done
  printf ' bash -c %s\n' "$(_task_sh_quote "$script")"
}

# A tmux command string running a task.sh helper in the background.
_task_run_shell_cmd() {
  local helper
  helper=$(_task_helper_cmd "$@")
  helper=${helper%$'\n'}
  printf 'run-shell -b %s' \
    "$(_task_tmux_dq "$(_task_fmt_escape "$helper")")"
}

# A tmux command string that just shows a message.
_task_message_cmd() {
  local msg=$1
  printf 'display-message -d 5000 %s' "$(_task_tmux_dq "$(_task_fmt_escape "$msg")")"
}

_task_notify() {
  local msg=$1 client=${2-}
  local -a args=(display-message -d 5000)
  [[ -n $client ]] && args+=(-c "$client")
  _tmux "${args[@]}" "balamba: $(_task_fmt_escape "$msg")" >/dev/null 2>&1 || true
}

# First attached client on the private socket, or nothing.
_task_client() {
  _tmux list-clients -F '#{client_name}' 2>/dev/null | head -n1 || true
}

# Require an interactive client.  Prints a clear stderr diagnostic and returns
# 2 when detached (run-shell without a client, cron, tests).
_task_require_client() {
  local c
  c=$(_task_client)
  if [[ -z $c ]]; then
    printf 'balamba: error: no attached tmux client for this interactive flow; open balamba in a terminal first\n' >&2
    return 2
  fi
  printf '%s\n' "$c"
}

_task_env_get() {
  local name=$1
  _tmux show-environment -g "$name" 2>/dev/null |
    sed -n "s/^${name}=//p" | head -n1 || true
}

_task_env_set() {
  _tmux set-environment -g "$1" "$2" >/dev/null 2>&1 || true
}

_task_env_unset() {
  local name
  for name in "$@"; do
    _tmux set-environment -g -u "$name" >/dev/null 2>&1 || true
  done
}

_task_cleanup_flow_env() {
  _task_env_unset \
    BALAMBA_FLOW_NAME BALAMBA_FLOW_REF BALAMBA_FLOW_PROJECT \
    BALAMBA_FLOW_CONTEXT BALAMBA_FLOW_PATH BALAMBA_FLOW_DELETE_BRANCH
}

# ---------------------------------------------------------------------------
# Non-interactive core
# ---------------------------------------------------------------------------

# task_create_and_open <project-id> <display-name> <ref> <kind>
# Prints the new task id.  If the worktree was created but the terminal cannot
# be opened/activated, removes any window and closes the task through the git
# layer (worktree + branch + state) so nothing half-created is left behind.
task_create_and_open() {
  (($# == 4)) || balamba_die "usage: task_create_and_open <project-id> <display-name> <ref> <kind>"
  local pid=$1 display=$2 ref=$3 kind=$4

  local tid rc=0
  tid=$(git_task_create "$pid" "$display" "$ref" "$kind") || rc=$?
  if ((rc != 0)); then
    return "$rc"
  fi

  local context="task:$tid" tab
  tab=$(tmux_open_tab "$pid" "$context" "$kind") || rc=$?
  if ((rc != 0)); then
    balamba_warn "could not open a terminal for task $tid; rolling the task back"
    tmux_remove_context "$pid" "$context" >/dev/null 2>&1 || true
    local close_rc=0
    git_task_close "$pid" "$tid" --force --delete-branch >/dev/null 2>&1 || close_rc=$?
    if ((close_rc != 0)); then
      balamba_warn "rollback could not fully close task $tid; inspect state and git worktree list"
    fi
    return 2
  fi

  rc=0
  tmux_activate "$pid" "$context" || rc=$?
  if ((rc != 0)); then
    balamba_warn "could not activate task $tid; rolling the task back"
    tmux_remove_context "$pid" "$context" >/dev/null 2>&1 || true
    local close_rc=0
    git_task_close "$pid" "$tid" --force --delete-branch >/dev/null 2>&1 || close_rc=$?
    if ((close_rc != 0)); then
      balamba_warn "rollback could not fully close task $tid; inspect state and git worktree list"
    fi
    return 2
  fi

  printf '%s\n' "$tid"
}

# terminal_open <project-id> <context> <kind>
# Prints the new tab id.
terminal_open() {
  (($# == 3)) || balamba_die "usage: terminal_open <project-id> <context> <kind>"
  local pid=$1 context=$2 kind=$3 tab rc=0

  tab=$(tmux_open_tab "$pid" "$context" "$kind") || rc=$?
  if ((rc != 0)); then
    return "$rc"
  fi

  rc=0
  tmux_activate "$pid" "$context" || rc=$?
  if ((rc != 0)); then
    balamba_warn "opened tab $tab but could not activate context $context"
    return 2
  fi
  printf '%s\n' "$tab"
}

# project_add_and_open <path>
# Prints the new project id.  Ensures the server/session exists and that the
# project's "proj" context has a shell tab (tmux_ensure_session does that for
# an empty context; the explicit check covers a lost window).
project_add_and_open() {
  (($# == 1)) || balamba_die "usage: project_add_and_open <path>"
  local path=$1 pid rc=0
  pid=$(git_project_add "$path") || rc=$?
  if ((rc != 0)); then
    return "$rc"
  fi

  tmux_server_up || return 2
  tmux_ensure_session || {
    balamba_warn "project $pid was added, but the tmux workspace could not be built"
    return 2
  }

  local n
  n=$(balamba_state_get \
    '.projects[] | select(.id == $p) | (.tabs | length)' --arg p "$pid" 2>/dev/null || printf '0')
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if ((n == 0)); then
    terminal_open "$pid" proj shell >/dev/null || return 2
  fi

  tmux_activate "$pid" proj || return 2
  printf '%s\n' "$pid"
}

# task_close <project-id> <task-id> [--delete-branch]
# Kills the task's windows first (the caller has confirmed), then closes the
# task through git.  Prints the closed task id.
task_close() {
  (($# == 2 || $# == 3)) || \
    balamba_die "usage: task_close <project-id> <task-id> [--delete-branch]"
  local pid=$1 tid=$2 delete_branch=0
  if (($# == 3)); then
    if [[ $3 == --delete-branch ]]; then
      delete_branch=1
    else
      balamba_warn "unknown option: $3 (usage: task_close <project-id> <task-id> [--delete-branch])"
      return 1
    fi
  fi

  local context="task:$tid"
  tmux_remove_context "$pid" "$context" >/dev/null 2>&1 || \
    balamba_warn "could not kill every window for task $tid"

  local -a opts=(--force)
  ((delete_branch)) && opts+=(--delete-branch)

  local out rc=0
  out=$(git_task_close "$pid" "$tid" "${opts[@]}") || rc=$?
  if ((rc != 0)); then
    balamba_warn "task $tid was not removed: its windows are gone but the worktree and state entry were kept; inspect and retry (for example: git worktree remove --force <path>)"
    return 2
  fi
  printf '%s\n' "$out"
}

# task_assess <project-id> <task-id>
# Prints exactly one JSON object describing what the close dialog must warn
# about.  Read-only; no prompts.
task_assess() {
  (($# == 2)) || balamba_die "usage: task_assess <project-id> <task-id>"
  local pid=$1 tid=$2

  balamba_require_cmd git jq
  balamba_config_load >/dev/null 2>&1 || true

  local n
  n=$(balamba_state_get \
    '[.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid)] | length' \
    --arg pid "$pid" --arg tid "$tid" 2>/dev/null || printf '0')
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if ((n == 0)); then
    balamba_warn "unknown task: $tid (project $pid)"
    return 2
  fi

  local path branch base_ref exists=0
  path=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .path' \
    --arg pid "$pid" --arg tid "$tid")
  branch=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .branch' \
    --arg pid "$pid" --arg tid "$tid")
  base_ref=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .base_ref' \
    --arg pid "$pid" --arg tid "$tid")
  [[ -d $path ]] && exists=1

  local status='null'
  if ((exists)); then
    status=$(git_status_json "$path" 2>/dev/null) || status='null'
  fi

  local unmerged=false
  if ((exists)) && [[ -n $branch && -n $base_ref ]] && \
    git -C "$path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && \
    git -C "$path" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1; then
    if ! git -C "$path" merge-base --is-ancestor "$branch" "$base_ref" 2>/dev/null; then
      unmerged=true
    fi
  fi

  local windows=0
  if declare -F _tmux_session_exists >/dev/null 2>&1 && _tmux_session_exists; then
    windows=$(_tmux list-windows -t "${_BALAMBA_TMUX_SESSION:-balamba}" \
      -F $'#{@balamba_project}\t#{@balamba_context}' 2>/dev/null |
      awk -F '\t' -v p="$pid" -v c="task:$tid" '$1 == p && $2 == c { n++ } END { print n + 0 }')
  fi
  [[ $windows =~ ^[0-9]+$ ]] || windows=0

  jq -nc \
    --arg project "$pid" --arg task "$tid" \
    --arg branch "$branch" --arg worktree "$path" \
    --arg base_ref "$base_ref" \
    --argjson exists "$exists" --argjson unmerged "$unmerged" \
    --argjson windows "$windows" --argjson status "$status" \
    '{
       project: $project,
       task: $task,
       branch: (if $branch == "" then null else $branch end),
       worktree: $worktree,
       exists: ($exists == 1),
       dirty: ($status.dirty // false),
       dirty_count: (($status.files // []) | length),
       detached: ($status.detached // false),
       unmerged: $unmerged,
       unpushed: ($status.ahead // 0),
       base_ref: $base_ref,
       compare_ref: ($status.compare_ref // null),
       windows: $windows
     }'
}

# One-line human summary of task_assess output.
_task_assess_summary() {
  local json=$1
  jq -r '
    [ (if .detached then "detached HEAD" else empty end),
      (if .dirty then "uncommitted changes (\(.dirty_count) file(s))" else empty end),
      (if .unmerged then "branch not merged into \(.base_ref)" else empty end),
      (if ((.unpushed // 0) > 0) then "\(.unpushed) unpushed commit(s)" else empty end)
    ] | if length == 0 then "clean" else join("; ") end
  ' <<<"$json"
}

# ---------------------------------------------------------------------------
# Interactive menu helpers
# ---------------------------------------------------------------------------

_task_menu() {
  local client=$1 title=$2
  shift 2
  local -a args=(display-menu -c "$client" -T "$(_task_fmt_escape "$title")")
  args+=("$@")
  if ! _tmux "${args[@]}" >/dev/null 2>&1; then
    balamba_warn "could not display a menu on client $client"
    return 2
  fi
  return 0
}

_task_kind_menu() {
  local mode=$1 pid=$2 context=$3 client=$4
  balamba_config_load >/dev/null 2>&1 || true
  local agent=${default_agent:-opencode}
  local label=${BALAMBA_AGENT_LABEL[$agent]-$agent}
  [[ -n $label ]] || label=$agent

  local -a agent_cmd shell_cmd
  if [[ $mode == task ]]; then
    agent_cmd=(_task_new_kind_selected "$pid" agent)
    shell_cmd=(_task_new_kind_selected "$pid" shell)
  else
    agent_cmd=(_task_terminal_kind_selected "$pid" "$context" agent)
    shell_cmd=(_task_terminal_kind_selected "$pid" "$context" shell)
  fi

  _task_menu "$client" "new terminal: agent or shell" \
    "$(_task_fmt_escape "$label")" "a" "$(_task_run_shell_cmd "${agent_cmd[@]}")" \
    "shell" "s" "$(_task_run_shell_cmd "${shell_cmd[@]}")" \
    "Cancel" "q" "$(_task_message_cmd "cancelled")"
}

_task_new_kind_menu() {
  local pid=$1 client=$2
  _task_kind_menu task "$pid" "" "$client"
}

# Continuation after the kind menu.  Free text comes from the tmux environment.
_task_new_kind_selected() {
  local pid=$1 kind=$2
  local name=${BALAMBA_FLOW_NAME-} ref=${BALAMBA_FLOW_REF-}
  [[ -n ${BALAMBA_FLOW_PROJECT-} ]] && pid=$BALAMBA_FLOW_PROJECT
  _task_cleanup_flow_env

  if [[ -z $name ]]; then
    printf 'balamba: error: task name is empty; nothing created\n' >&2
    _task_notify "new task cancelled: empty name"
    return 2
  fi
  if [[ -z $ref ]]; then
    balamba_config_load >/dev/null 2>&1 || true
    ref=${default_ref:-origin/main}
  fi

  local out rc=0
  out=$(task_create_and_open "$pid" "$name" "$ref" "$kind") || rc=$?
  if ((rc == 0)); then
    _task_notify "created task $out"
  else
    _task_notify "could not create task; see messages"
  fi
  return "$rc"
}

_task_terminal_kind_selected() {
  local pid=$1 context=$2 kind=$3
  [[ -n ${BALAMBA_FLOW_PROJECT-} ]] && pid=$BALAMBA_FLOW_PROJECT
  [[ -n ${BALAMBA_FLOW_CONTEXT-} ]] && context=$BALAMBA_FLOW_CONTEXT
  _task_cleanup_flow_env

  local out rc=0
  out=$(terminal_open "$pid" "$context" "$kind") || rc=$?
  if ((rc == 0)); then
    _task_notify "opened terminal $out"
  else
    _task_notify "could not open terminal; see messages"
  fi
  return "$rc"
}

_task_project_add_selected() {
  local path=${BALAMBA_FLOW_PATH-}
  _task_cleanup_flow_env
  if [[ -z $path ]]; then
    printf 'balamba: error: project path is empty; nothing added\n' >&2
    _task_notify "add project cancelled: empty path"
    return 2
  fi

  local out rc=0
  out=$(project_add_and_open "$path") || rc=$?
  if ((rc == 0)); then
    _task_notify "added project $out"
  else
    _task_notify "could not add project: $(basename -- "$path")"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# 11.1 task_new_flow <project-id>
# ---------------------------------------------------------------------------
task_new_flow() {
  (($# == 1)) || balamba_die "usage: task_new_flow <project-id>"
  local pid=$1

  # Continuation (menu choice) or test hook.
  if [[ -n ${BALAMBA_FLOW_KIND-} ]]; then
    local name=${BALAMBA_FLOW_NAME-} ref=${BALAMBA_FLOW_REF-}
    local kind=$BALAMBA_FLOW_KIND
    if [[ -n ${BALAMBA_FLOW_PROJECT-} ]]; then
      pid=$BALAMBA_FLOW_PROJECT
    fi
    _task_cleanup_flow_env
    if [[ -z $name ]]; then
      printf 'balamba: error: BALAMBA_FLOW_NAME is empty; nothing created\n' >&2
      return 2
    fi
    if [[ -z $ref ]]; then
      balamba_config_load >/dev/null 2>&1 || true
      ref=${default_ref:-origin/main}
    fi
    local out rc=0
    out=$(task_create_and_open "$pid" "$name" "$ref" "$kind") || rc=$?
    ((rc == 0)) && printf '%s\n' "$out"
    return "$rc"
  fi

  local client
  client=$(_task_require_client) || return $?

  balamba_config_load >/dev/null 2>&1 || true
  local start_ref=${default_ref:-origin/main}
  _task_env_unset BALAMBA_FLOW_NAME BALAMBA_FLOW_REF BALAMBA_FLOW_PROJECT
  _task_env_set BALAMBA_FLOW_PROJECT "$pid"

  local template
  template="set-environment -g BALAMBA_FLOW_NAME $(_task_tmux_dq '%1%') ; "
  template+="set-environment -g BALAMBA_FLOW_REF $(_task_tmux_dq '%2%') ; "
  template+="run-shell -b $(_task_tmux_dq "$(_task_fmt_escape "$(_task_helper_cmd _task_new_kind_menu "$pid" "$client")")")"

  _tmux command-prompt -t "$client" \
    -p "task name:,create from:" -I ",$start_ref" "$template" >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# 11.2 task_close_flow <project-id> <task-id>
# ---------------------------------------------------------------------------
task_close_flow() {
  (($# == 2)) || balamba_die "usage: task_close_flow <project-id> <task-id>"
  local pid=$1 tid=$2

  # Test/continuation hook: skip all dialogs.
  if [[ ${BALAMBA_FLOW_CLOSE_CONFIRM-} == 1 ]]; then
    local -a opts=()
    [[ ${BALAMBA_FLOW_DELETE_BRANCH-0} == 1 ]] && opts+=(--delete-branch)
    _task_cleanup_flow_env
    task_close "$pid" "$tid" "${opts[@]}"
    return $?
  fi

  local client
  client=$(_task_require_client) || return $?

  local json
  json=$(task_assess "$pid" "$tid") || return $?
  _task_env_set BALAMBA_FLOW_DELETE_BRANCH 0
  _task_close_menu "$pid" "$tid" "$client" "$json"
}

_task_close_menu() {
  local pid=$1 tid=$2 client=$3 json=$4
  local summary toggle
  summary=$(_task_assess_summary "$json")
  if [[ $(_task_env_get BALAMBA_FLOW_DELETE_BRANCH) == 1 ]]; then
    toggle="delete branch too: yes"
  else
    toggle="delete branch too: no"
  fi

  _task_menu "$client" "close $tid? $summary" \
    "Continue" "c" "$(_task_run_shell_cmd _task_close_confirm "$pid" "$tid" "$client")" \
    "$toggle" "b" "$(_task_run_shell_cmd _task_close_toggle "$pid" "$tid" "$client")" \
    "Cancel" "q" "$(_task_message_cmd "close cancelled")"
}

_task_close_toggle() {
  local pid=$1 tid=$2 client=$3
  local cur
  cur=$(_task_env_get BALAMBA_FLOW_DELETE_BRANCH)
  if [[ $cur == 1 ]]; then
    _task_env_set BALAMBA_FLOW_DELETE_BRANCH 0
  else
    _task_env_set BALAMBA_FLOW_DELETE_BRANCH 1
  fi

  local json
  json=$(task_assess "$pid" "$tid") || return $?
  _task_close_menu "$pid" "$tid" "$client" "$json"
}

_task_close_confirm() {
  local pid=$1 tid=$2 client=$3
  local json path branch delete_note
  json=$(task_assess "$pid" "$tid") || return $?
  path=$(jq -r '.worktree // ""' <<<"$json")
  branch=$(jq -r '.branch // ""' <<<"$json")
  if [[ $(_task_env_get BALAMBA_FLOW_DELETE_BRANCH) == 1 ]]; then
    delete_note="branch $branch will be deleted if merged"
  else
    delete_note="branch $branch will be kept"
  fi

  _task_menu "$client" "delete worktree $path? $delete_note" \
    "Delete worktree and close" "y" "$(_task_run_shell_cmd _task_close_do "$pid" "$tid")" \
    "Cancel" "q" "$(_task_message_cmd "close cancelled")"
}

_task_close_do() {
  local pid=$1 tid=$2
  local delete_branch=0
  [[ ${BALAMBA_FLOW_DELETE_BRANCH-} == 1 ]] && delete_branch=1
  _task_cleanup_flow_env

  local -a opts=()
  ((delete_branch)) && opts+=(--delete-branch)
  local rc=0
  task_close "$pid" "$tid" "${opts[@]}" >/dev/null || rc=$?
  if ((rc == 0)); then
    _task_notify "closed task $tid"
  else
    _task_notify "could not close task $tid; see messages"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# 11.3 terminal_new_flow <project-id> <context>
# ---------------------------------------------------------------------------
terminal_new_flow() {
  (($# == 2)) || balamba_die "usage: terminal_new_flow <project-id> <context>"
  local pid=$1 context=$2

  if [[ -n ${BALAMBA_FLOW_KIND-} ]]; then
    local kind=$BALAMBA_FLOW_KIND
    [[ -n ${BALAMBA_FLOW_PROJECT-} ]] && pid=$BALAMBA_FLOW_PROJECT
    [[ -n ${BALAMBA_FLOW_CONTEXT-} ]] && context=$BALAMBA_FLOW_CONTEXT
    _task_cleanup_flow_env
    local out rc=0
    out=$(terminal_open "$pid" "$context" "$kind") || rc=$?
    ((rc == 0)) && printf '%s\n' "$out"
    return "$rc"
  fi

  local client
  client=$(_task_require_client) || return $?
  _task_env_unset BALAMBA_FLOW_PROJECT BALAMBA_FLOW_CONTEXT
  _task_env_set BALAMBA_FLOW_PROJECT "$pid"
  _task_env_set BALAMBA_FLOW_CONTEXT "$context"
  _task_kind_menu terminal "$pid" "$context" "$client"
}

# ---------------------------------------------------------------------------
# 11.4 project_add_flow / project_remove_flow
# ---------------------------------------------------------------------------
project_add_flow() {
  (($# == 0)) || balamba_die "usage: project_add_flow"

  if [[ -n ${BALAMBA_FLOW_PATH-} ]]; then
    local path=$BALAMBA_FLOW_PATH
    _task_cleanup_flow_env
    local out rc=0
    out=$(project_add_and_open "$path") || rc=$?
    if ((rc == 0)); then
      printf '%s\n' "$out"
    fi
    return "$rc"
  fi

  local client
  client=$(_task_require_client) || return $?
  _task_env_unset BALAMBA_FLOW_PATH

  local template
  template="set-environment -g BALAMBA_FLOW_PATH $(_task_tmux_dq '%1%') ; "
  template+="run-shell -b $(_task_tmux_dq "$(_task_fmt_escape "$(_task_helper_cmd _task_project_add_selected)")")"

  _tmux command-prompt -t "$client" -p "project path:" -I "" "$template" >/dev/null 2>&1
  return 0
}

# Resolve a project id from an id or path (best effort; the git layer is the
# authority when the removal actually runs).
_task_project_id_for() {
  local target=${1-}
  if [[ -z $target ]]; then
    balamba_state_get '.active.project // empty'
    return 0
  fi
  if [[ $target == p_* ]]; then
    printf '%s\n' "$target"
    return 0
  fi
  if [[ -d $target ]]; then
    local canon
    canon=$(cd -P -- "$target" 2>/dev/null && pwd) || canon=""
    [[ -n $canon ]] && target=$canon
  fi
  balamba_state_get '.projects[] | select(.path == $t) | .id' --arg t "$target" 2>/dev/null |
    head -n1 || true
}

project_remove_flow() {
  (($# <= 1)) || balamba_die "usage: project_remove_flow [project-id|path]"
  local target=${1-}
  local pid
  pid=$(_task_project_id_for "$target")
  if [[ -z $pid ]]; then
    printf 'balamba: error: unknown project: %s\n' "${target:-<active>}" >&2
    return 2
  fi

  if [[ ${BALAMBA_FLOW_PROJECT_REMOVE_CONFIRM-} == 1 ]]; then
    _task_cleanup_flow_env
    local out rc=0
    out=$(git_project_remove "$pid" --force) || rc=$?
    if ((rc == 0)); then
      if declare -F tmux_remove_project >/dev/null 2>&1; then
        tmux_remove_project "$out" >/dev/null 2>&1 || true
      fi
      printf '%s\n' "$out"
    fi
    return "$rc"
  fi

  local client
  client=$(_task_require_client) || return $?

  local ntasks
  ntasks=$(balamba_state_get \
    '.projects[] | select(.id == $p) | (.tasks | length)' --arg p "$pid" 2>/dev/null || printf '0')
  [[ $ntasks =~ ^[0-9]+$ ]] || ntasks=0
  local warning=""
  ((ntasks > 0)) && warning=" — $ntasks task(s) will be forgotten (their worktrees stay on disk)"

  _task_menu "$client" "remove project $pid$warning" \
    "Remove project" "y" "$(_task_run_shell_cmd _task_project_remove_do "$pid")" \
    "Cancel" "q" "$(_task_message_cmd "remove cancelled")"
}

_task_project_remove_do() {
  local pid=$1
  _task_cleanup_flow_env
  local out rc=0
  out=$(git_project_remove "$pid" --force) || rc=$?
  if ((rc == 0)); then
    if declare -F tmux_remove_project >/dev/null 2>&1; then
      tmux_remove_project "$out" >/dev/null 2>&1 || true
    fi
    _task_notify "removed project $out"
  else
    _task_notify "could not remove project $pid; see messages"
  fi
  return "$rc"
}
