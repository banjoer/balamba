#!/usr/bin/env bash
# balamba — shared foundation: paths, config, state, helpers.
#
# This file is sourced by bin/balamba and by the test suite.  It deliberately
# owns *all* state writes; every other lib calls the balamba_state_* API.
#
# Contract details live in docs/architecture.md.  Keep this file and that
# document in sync.

# ---------------------------------------------------------------------------
# Strict mode and one useful error trap
# ---------------------------------------------------------------------------
_balamba_on_error() {
  local status=$1 line=$2 source=$3 command=$4
  trap - ERR
  printf 'balamba: error: command failed (exit %s)\n' "$status" >&2
  printf '  at %s:%s\n' "${source:-?}" "$line" >&2
  printf '  command: %s\n' "$command" >&2
  exit "$status"
}

if [[ ${BALAMBA_STRICT:-1} == 1 ]]; then
  set -Eeuo pipefail
  trap '_balamba_on_error $? "$LINENO" "${BASH_SOURCE[0]:-${0##*/}}" "$BASH_COMMAND"' ERR
fi

# ---------------------------------------------------------------------------
# Path resolution (works when bin/balamba is a symlink)
# ---------------------------------------------------------------------------
_balamba_resolve_path() {
  local target=$1 dir
  while [[ -L $target ]]; do
    dir=$(cd -P -- "$(dirname -- "$target")" && pwd) || return 1
    target=$(readlink -- "$target") || return 1
    [[ $target == /* ]] || target=$dir/$target
  done
  dir=$(cd -P -- "$(dirname -- "$target")" && pwd) || return 1
  printf '%s/%s\n' "${dir%/}" "$(basename -- "$target")"
}

BALAMBA_COMMON_FILE=$(_balamba_resolve_path "${BASH_SOURCE[0]}")
BALAMBA_LIB_DIR=$(cd -P -- "$(dirname -- "$BALAMBA_COMMON_FILE")" && pwd)
: "${BALAMBA_ROOT:=$(cd -P -- "$BALAMBA_LIB_DIR/.." && pwd)}"
: "${BALAMBA_BIN:=$BALAMBA_ROOT/bin/balamba}"
export BALAMBA_ROOT BALAMBA_LIB_DIR BALAMBA_BIN

BALAMBA_VERSION="0.1.0"
BALAMBA_STATE_VERSION=1

: "${HOME:?HOME is not set}"

# XDG-aware, individually overridable.  BALAMBA_RUNTIME is a balamba choice:
# it lives next to state, not in XDG_RUNTIME_DIR, so logs/caches survive reboots.
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${BALAMBA_CONFIG:=$XDG_CONFIG_HOME/balamba/config}"
: "${BALAMBA_STATE:=$XDG_STATE_HOME/balamba/state.json}"
: "${BALAMBA_RUNTIME:=$XDG_STATE_HOME/balamba}"
: "${BALAMBA_SOCKET:=balamba}"
: "${BALAMBA_TMUX_CONF:=$XDG_CONFIG_HOME/balamba/tmux.conf}"

# The shipped tmux.conf is the fallback while the user has not installed one.
if [[ ! -f $BALAMBA_TMUX_CONF && -f $BALAMBA_ROOT/tmux.conf ]]; then
  BALAMBA_TMUX_CONF=$BALAMBA_ROOT/tmux.conf
fi

export XDG_CONFIG_HOME XDG_STATE_HOME
export BALAMBA_CONFIG BALAMBA_STATE BALAMBA_RUNTIME BALAMBA_SOCKET BALAMBA_TMUX_CONF

# Path tmux will use for our private socket.  tmux's own layout is
# ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>.
balamba_tmux_socket_path() {
  printf '%s/tmux-%s/%s\n' "${TMUX_TMPDIR:-/tmp}" "$(id -u)" "$BALAMBA_SOCKET"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# Scalar names are intentionally short and stable: config files and later libs
# refer to $tree_width, $git_width, ... directly.
balamba_config_defaults() {
  tree_width=30
  git_width=34
  active_refresh=1
  idle_refresh=5
  git_refresh=2
  editor=${EDITOR:-vi}
  default_ref=origin/main
  default_agent=opencode
  restore_stagger=${BALAMBA_RESTORE_STAGGER:-1}
  theme=auto
  accent=blue

  declare -gA BALAMBA_AGENT_COMMAND=()
  declare -gA BALAMBA_AGENT_RESUME=()
  declare -gA BALAMBA_AGENT_LABEL=()

  BALAMBA_AGENT_COMMAND[opencode]='opencode --session {{session}}'
  BALAMBA_AGENT_RESUME[opencode]='opencode --session {{session}}'
  BALAMBA_AGENT_LABEL[opencode]='opencode'
  return 0
}

# Load defaults, then the user's sourced-bash config (if present).
# A config that fails to source returns non-zero but never leaves strict mode
# disabled.  Callers that must report instead of die (doctor) run this in a
# subshell.
balamba_config_load() {
  balamba_config_defaults
  [[ -r $BALAMBA_CONFIG ]] || return 0

  local rc=0 had_e=0 had_u=0
  if [[ :$SHELLOPTS: == *:errexit:* ]]; then had_e=1; fi
  if [[ :$SHELLOPTS: == *:nounset:* ]]; then had_u=1; fi
  trap - ERR
  set +eu
  # shellcheck disable=SC1090
  . "$BALAMBA_CONFIG"
  rc=$?
  if ((had_e)); then set -e; fi
  if ((had_u)); then set -u; fi
  if [[ ${BALAMBA_STRICT:-1} == 1 ]]; then
    trap '_balamba_on_error $? "$LINENO" "${BASH_SOURCE[0]:-${0##*/}}" "$BASH_COMMAND"' ERR
  fi
  return "$rc"
}

# Validate the loaded config.  Returns 2 with one problem per line on stderr.
balamba_config_validate() {
  balamba_config_load || {
    printf 'config could not be sourced: %s\n' "$BALAMBA_CONFIG" >&2
    return 2
  }

  local -a bad=()
  local k v
  for k in tree_width git_width active_refresh idle_refresh git_refresh; do
    v=${!k-}
    if [[ ! $v =~ ^[0-9]+$ ]]; then
      bad+=("$k must be an integer (got '$v')")
    fi
  done
  if [[ ${tree_width-} =~ ^[0-9]+$ ]] && (( tree_width < 5 || tree_width > 200 )); then
    bad+=("tree_width must be between 5 and 200 (got $tree_width)")
  fi
  if [[ ${git_width-} =~ ^[0-9]+$ ]] && (( git_width < 5 || git_width > 200 )); then
    bad+=("git_width must be between 5 and 200 (got $git_width)")
  fi
  for k in active_refresh idle_refresh git_refresh; do
    v=${!k-}
    if [[ $v =~ ^[0-9]+$ ]] && (( v < 1 || v > 3600 )); then
      bad+=("$k must be between 1 and 3600 seconds (got $v)")
    fi
  done
  [[ -n ${editor-} ]] || bad+=("editor must not be empty")
  [[ -n ${default_ref-} ]] || bad+=("default_ref must not be empty")
  [[ -n ${default_agent-} ]] || bad+=("default_agent must not be empty")
  case ${theme-} in
    auto|truecolor|256|16) ;;
    *) bad+=("theme must be auto, truecolor, 256 or 16 (got '${theme-}')") ;;
  esac
  case ${accent-} in
    blue|cyan|magenta|yellow) ;;
    *) bad+=("accent must be blue, cyan, magenta or yellow (got '${accent-}')") ;;
  esac
  if [[ ! ${restore_stagger-} =~ ^[0-9]+$ ]]; then
    bad+=("restore_stagger must be an integer (got '${restore_stagger-}')")
  elif (( restore_stagger > 60 )); then
    bad+=("restore_stagger must be between 0 and 60 seconds (got $restore_stagger)")
  fi
  if [[ -n ${default_agent-} && -z ${BALAMBA_AGENT_COMMAND[$default_agent]-} ]]; then
    bad+=("no command template for default_agent '$default_agent'")
  fi

  if ((${#bad[@]})); then
    printf '%s\n' "${bad[@]}" >&2
    return 2
  fi
  return 0
}

# Reflect config into tmux user options so pane/ui.py reads the same values.
# With no arguments this targets our private socket (-L "$BALAMBA_SOCKET").
# Callers that need extra tmux flags pass them verbatim, e.g.
#   balamba_config_to_tmux -L balamba
balamba_config_to_tmux() {
  local -a t=(tmux)
  if (($#)); then
    t+=("$@")
  else
    t+=(-L "$BALAMBA_SOCKET")
  fi
  "${t[@]}" \
    set -g @balamba_tree_width "$tree_width" \; \
    set -g @balamba_git_width "$git_width" \; \
    set -g @balamba_active_refresh "$active_refresh" \; \
    set -g @balamba_idle_refresh "$idle_refresh" \; \
    set -g @balamba_git_refresh "$git_refresh" \; \
    set -g @balamba_editor "$editor" \; \
    set -g @balamba_default_ref "$default_ref" \; \
    set -g @balamba_default_agent "$default_agent" \; \
    set -g @balamba_theme "$theme" \; \
    set -g @balamba_accent "$accent" \; \
    set -g @balamba_root "$BALAMBA_ROOT"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
# The JSON schema is documented in docs/architecture.md.  This jq program is
# the single validation authority; state is never written unless it passes.
BALAMBA_STATE_SCHEMA=$(cat <<'JQ'
def str: type == "string";
def bool: type == "boolean";
def num: type == "number";
def ids_unique: ([.[].id] | length) == ([.[].id] | unique | length);
def tab:
  type == "object"
  and (.id | str) and (.name | str)
  and (.kind == "shell" or .kind == "agent")
  and ((.agent == null) or (.agent | str))
  and ((.session == null) or (.session | str))
  and (.window | num) and (.pane_count | num) and (.layout | str)
  and (.active_pane | num)
  and (.panes | type == "array")
  and all(.panes[];
        type == "object"
        and (.index | num) and (.cwd | str)
        and (.launched == "shell" or .launched == "agent")
        and ((.name == null) or (.name | str))
        and ((.live_command == null) or (.live_command | str))
        and ((.active == null) or (.active | bool)));
def tabs: type == "array" and ids_unique and all(.[]; tab);
def task:
  type == "object"
  and (.id | str) and (.name | str) and (.slug | str)
  and (.path | str) and (.branch | str) and (.base_ref | str)
  and (.created_at | str) and (.expanded | bool)
  and (.tabs | tabs);
def tasks: type == "array" and ids_unique and all(.[]; task);
def project:
  type == "object"
  and (.id | str) and (.name | str) and (.path | str)
  and (.expanded | bool)
  and (.tabs | tabs)
  and (.tasks | tasks);
type == "object"
and (.version == 1)
and (.active | type == "object")
and ((.active.project == null) or (.active.project | str))
and ((.active.context == null) or (.active.context | str))
and ((.active.context == null) or (.active.context | test("^(proj|task:.+)$")))
and (.active.window | num)
and (.projects | type == "array" and ids_unique and all(.[]; project))
JQ
)

balamba_state_empty_json() {
  printf '%s\n' \
    "{\"version\":$BALAMBA_STATE_VERSION,\"active\":{\"project\":null,\"context\":null,\"window\":0},\"projects\":[]}"
}

balamba_need_state() {
  [[ -f $BALAMBA_STATE ]] || \
    balamba_die "no balamba state at $BALAMBA_STATE (start balamba or run 'balamba project add <path>')"
}

# balamba_state_validate [file] -> 0 valid, 2 invalid/missing.  Silent on
# success; one diagnostic on stderr on failure.
balamba_state_validate() {
  local file=${1:-$BALAMBA_STATE}
  local err

  if [[ ! -f $file ]]; then
    printf 'state file not found: %s\n' "$file" >&2
    return 2
  fi

  if ! err=$(jq -e -s 'length == 1' "$file" 2>&1); then
    printf 'state is not valid JSON or not exactly one document: %s\n' "${err:-$file}" >&2
    return 2
  fi

  if ! err=$(jq -e "$BALAMBA_STATE_SCHEMA" "$file" 2>&1 >/dev/null); then
    printf 'state schema invalid (%s): %s\n' "$file" "${err:-validation failed}" >&2
    return 2
  fi
  return 0
}

# Create the state file (and runtime dir) if needed.  An existing invalid file
# is never overwritten.  Safe to call repeatedly and concurrently.
balamba_state_init() {
  local dir lock
  dir=$(dirname -- "$BALAMBA_STATE")
  lock="${BALAMBA_STATE}.lock"
  mkdir -p -- "$dir" "$BALAMBA_RUNTIME"
  balamba_require_cmd jq
  balamba_require_cmd flock

  (
    flock -x 9 || {
      printf 'balamba: error: could not lock %s\n' "$lock" >&2
      exit 2
    }

    if [[ -s $BALAMBA_STATE ]]; then
      if ! balamba_state_validate "$BALAMBA_STATE"; then
        printf 'balamba: error: refusing to overwrite invalid state at %s\n' \
          "$BALAMBA_STATE" >&2
        exit 2
      fi
      exit 0
    fi

    local tmp
    tmp=$(mktemp "$dir/.balamba-state.XXXXXX") || exit 2
    trap 'rm -f -- "$tmp"' EXIT
    balamba_state_empty_json >"$tmp"
    balamba_state_validate "$tmp" || exit 2
    mv -f -- "$tmp" "$BALAMBA_STATE"
    chmod 600 "$BALAMBA_STATE" 2>/dev/null || true
    trap - EXIT
  ) 9>"$lock"
}

# balamba_state_get <jq-filter> [jq-args...]
# Prints jq -r output on stdout.  Creates an empty state if none exists.
balamba_state_get() {
  (($#)) || balamba_die "balamba_state_get: missing jq filter"
  local filter=$1
  shift
  [[ -f $BALAMBA_STATE ]] || balamba_state_init
  jq -r "$@" "$filter" "$BALAMBA_STATE"
}

# balamba_state_update <jq-filter> [jq-args...]
# Atomic read-modify-write under flock.  The original file is untouched if
# jq fails or the result does not validate.
balamba_state_update() {
  (($#)) || balamba_die "balamba_state_update: missing jq filter"
  local filter=$1
  shift

  local dir lock
  dir=$(dirname -- "$BALAMBA_STATE")
  lock="${BALAMBA_STATE}.lock"
  mkdir -p -- "$dir" "$BALAMBA_RUNTIME"
  balamba_require_cmd jq
  balamba_require_cmd flock

  (
    flock -x 9 || {
      printf 'balamba: error: could not lock %s\n' "$lock" >&2
      exit 2
    }

    local tmp
    tmp=$(mktemp "$dir/.balamba-state.XXXXXX") || exit 2
    trap 'rm -f -- "$tmp"' EXIT

    if [[ -s $BALAMBA_STATE ]]; then
      if ! jq -e . "$BALAMBA_STATE" >/dev/null 2>&1; then
        printf 'balamba: error: %s is not valid JSON; refusing to modify it\n' \
          "$BALAMBA_STATE" >&2
        exit 2
      fi
      if ! jq "$@" "$filter" "$BALAMBA_STATE" >"$tmp"; then
        printf 'balamba: error: jq expression failed; state unchanged\n' >&2
        exit 2
      fi
    else
      if ! balamba_state_empty_json | jq "$@" "$filter" >"$tmp"; then
        printf 'balamba: error: jq expression failed; state unchanged\n' >&2
        exit 2
      fi
    fi

    if ! balamba_state_validate "$tmp"; then
      printf 'balamba: error: update produced invalid state; state unchanged\n' >&2
      exit 2
    fi

    mv -f -- "$tmp" "$BALAMBA_STATE"
    chmod 600 "$BALAMBA_STATE" 2>/dev/null || true
    trap - EXIT
  ) 9>"$lock"
}

# Alias kept for readability at call sites that express "set this field".
balamba_state_set() {
  balamba_state_update "$@"
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
balamba_log() {
  printf 'balamba: %s\n' "$*" >&2
}

balamba_warn() {
  printf 'balamba: warning: %s\n' "$*" >&2
}

balamba_die() {
  printf 'balamba: error: %s\n' "$*" >&2
  exit 2
}

balamba_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || balamba_die "required command not found: $c"
  done
}

# Fail clearly when a later part's implementation is not present.
# balamba_require_func <function> <expected-lib> [what]
balamba_require_func() {
  local fn=$1 lib=$2 what=${3:-$1}
  if ! declare -F "$fn" >/dev/null 2>&1; then
    balamba_die "$what is not available in this build: $fn is missing (expected from $lib; that part is not implemented yet)"
  fi
}

# 32 lowercase hex characters.  Prefers the kernel UUID, then uuidgen, then
# python3, then urandom; no dependency is assumed to be present.
balamba_uuid() {
  local u=""
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    u=$(</proc/sys/kernel/random/uuid)
  elif command -v uuidgen >/dev/null 2>&1; then
    u=$(uuidgen)
  elif command -v python3 >/dev/null 2>&1; then
    u=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
  fi
  u=${u//-/}
  u=${u//[[:space:]]/}
  if [[ ! $u =~ ^[0-9a-fA-F]{32}$ ]]; then
    u=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
  printf '%s\n' "${u,,}"
}

# opencode requires session ids to start with "ses"; ses_ + 32 hex.
balamba_ses_id() {
  printf 'ses_%s\n' "$(balamba_uuid)"
}

balamba_tab_id() {
  local u
  u=$(balamba_uuid)
  printf 'tty_%s\n' "${u:0:8}"
}

balamba_project_id() {
  (($#)) || balamba_die "balamba_project_id: missing path"
  printf 'p_%s\n' "$(basename -- "$1")"
}

balamba_task_id() {
  (($#)) || balamba_die "balamba_task_id: missing slug"
  printf 't_%s\n' "$1"
}

# lowercase, spaces -> '-', delete everything outside [a-z0-9._-],
# collapse runs of '-', trim leading/trailing '-'.  Non-ASCII is removed,
# never transliterated (no dependencies).
balamba_slugify() {
  local s=${1-}
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  s=${s// /-}
  s=$(printf '%s' "$s" | LC_ALL=C sed -e 's/[^a-z0-9._-]//g')
  s=$(printf '%s' "$s" | LC_ALL=C sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
  printf '%s\n' "$s"
}
