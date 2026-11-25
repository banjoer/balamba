#!/usr/bin/env bash
# balamba — tmux engine (part 4): server, session, 3-column windows, tabs,
# launching, width management, runtime capture and restore.
#
# Contract: docs/architecture.md §10, §13, §14, §15 and docs/spikes.md
# "Restore algorithm".  State is only ever touched through the
# balamba_state_* API from lib/common.sh.
#
# Private tmux convention
# -----------------------
# Every command targets the private socket with `-L "$BALAMBA_SOCKET"` even
# when we run from inside a client.  `$TMUX` is never trusted here because a
# user may run a balamba command from their own tmux server; `-L` always points
# at ours.
#
# Window layout
# -------------
# Live pane index 0 is the tree chrome, indices 1..N are content panes (state
# indices 0..N-1) and the last live pane is the git chrome.  Cheap shell
# commands mark chrome with the pane option @balamba_chrome=tree|git and keep
# it alive with remain-on-exit; the pane-died hook respawns it.
#
# Config / environment overrides
# ------------------------------
#   BALAMBA_PYTHON          python for the shipped UI panes (default python3)
#   BALAMBA_TREE_COMMAND    full tree-pane shell-command (overrides the default)
#   BALAMBA_GIT_COMMAND     full git-pane shell-command
#   BALAMBA_SESSION_WIDTH   detached session width in columns (default 200)
#   BALAMBA_SESSION_HEIGHT  detached session height in rows (default 50)
#   restore_stagger / BALAMBA_RESTORE_STAGGER
#                           seconds between agent launches on restore (default 1)
# Agent launch commands come from the config's BALAMBA_AGENT_COMMAND table.

_BALAMBA_TMUX_SESSION=balamba

# ---------------------------------------------------------------------------
# tmux plumbing
# ---------------------------------------------------------------------------

# One entry point for every tmux call: always the private socket.
_tmux() {
  command tmux -L "$BALAMBA_SOCKET" "$@"
}

# `new-session` is the command that starts a cold server.  A bare
# `start-server` exits immediately when there is no session, so the server that
# actually survives must be the one started by new-session: pass -f here or the
# private server runs with the user's/default tmux config (wrong prefix, no
# mouse, no monitor-activity).
_tmux_new_session() {
  local -a conf=()
  if [[ -n ${BALAMBA_TMUX_CONF-} && -f $BALAMBA_TMUX_CONF ]]; then
    conf=(-f "$BALAMBA_TMUX_CONF")
  fi
  _tmux "${conf[@]}" new-session "$@"
}

_tmux_session_exists() {
  _tmux has-session -t "$_BALAMBA_TMUX_SESSION" >/dev/null 2>&1
}

_tmux_server_responsive() {
  _tmux list-sessions >/dev/null 2>&1
}

# Quote a value for a tmux command string (which has sh-like quoting).
_tmux_dq() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

_tmux_session_size() {
  _TMUX_COLS=${BALAMBA_SESSION_WIDTH:-200}
  _TMUX_ROWS=${BALAMBA_SESSION_HEIGHT:-50}
  [[ $_TMUX_COLS =~ ^[0-9]+$ ]] && ((_TMUX_COLS >= 20)) || _TMUX_COLS=200
  [[ $_TMUX_ROWS =~ ^[0-9]+$ ]] && ((_TMUX_ROWS >= 5)) || _TMUX_ROWS=50
}

# Full shell-command for a chrome pane.
_tmux_chrome_command() {
  local which=$1 cmd=""
  case $which in
    tree) cmd=${BALAMBA_TREE_COMMAND-} ;;
    git) cmd=${BALAMBA_GIT_COMMAND-} ;;
  esac
  if [[ -n $cmd ]]; then
    printf '%s\n' "$cmd"
    return 0
  fi
  local py=${BALAMBA_PYTHON:-python3}
  printf '%q %q %s\n' "$py" "$BALAMBA_ROOT/pane/ui.py" "$which"
}

# Launch command for one content pane.  <kind> is shell|agent; resume=1 picks
# BALAMBA_AGENT_RESUME (restore) instead of BALAMBA_AGENT_COMMAND (create).
_tmux_pane_command() {
  local kind=$1 agent=${2-} session=${3-} dir=${4-} resume=${5:-0}
  if [[ $kind == agent && -n $session ]]; then
    local tmpl=""
    if ((resume)); then
      tmpl=${BALAMBA_AGENT_RESUME[$agent]-}
      if [[ -z $tmpl && -n ${default_agent-} ]]; then
        tmpl=${BALAMBA_AGENT_RESUME[$default_agent]-}
      fi
    fi
    [[ -n $tmpl ]] || tmpl=${BALAMBA_AGENT_COMMAND[$agent]-}
    if [[ -z $tmpl && -n ${default_agent-} ]]; then
      tmpl=${BALAMBA_AGENT_COMMAND[$default_agent]-}
    fi
    if [[ -z $tmpl ]]; then
      tmpl='opencode --session {{session}}'
    fi
    local qs qd
    qs=$(printf '%q' "$session")
    qd=$(printf '%q' "$dir")
    tmpl=${tmpl//\{\{session\}\}/$qs}
    tmpl=${tmpl//\{\{dir\}\}/$qd}
    printf '%s\n' "$tmpl"
    return 0
  fi
  printf '%q\n' "${SHELL:-/bin/sh}"
}

# ---------------------------------------------------------------------------
# Hook helper script
# ---------------------------------------------------------------------------
# tmux hooks run outside this shell, so they need a small executable that
# sources the libs with the right environment.  It lives in the runtime dir
# (not in the repository) and is rewritten on every server_up.
_tmux_write_hook_script() {
  local path="$BALAMBA_RUNTIME/tmux-hook.sh"
  mkdir -p -- "$BALAMBA_RUNTIME" 2>/dev/null || return 0
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'exec >/dev/null 2>&1'
    printf 'export BALAMBA_ROOT=%q\n' "$BALAMBA_ROOT"
    printf 'export BALAMBA_SOCKET=%q\n' "$BALAMBA_SOCKET"
    printf 'export BALAMBA_STATE=%q\n' "$BALAMBA_STATE"
    printf 'export BALAMBA_CONFIG=%q\n' "$BALAMBA_CONFIG"
    printf 'export BALAMBA_RUNTIME=%q\n' "$BALAMBA_RUNTIME"
    printf 'export BALAMBA_TMUX_CONF=%q\n' "${BALAMBA_TMUX_CONF-}"
    printf '%s\n' '. "$BALAMBA_ROOT/lib/common.sh"'
    printf '%s\n' '. "$BALAMBA_ROOT/lib/tmux.sh"'
    printf '%s\n' 'case ${1-} in'
    printf '%s\n' '  save)    tmux_save_runtime ;;'
    printf '%s\n' '  widths)  shift; tmux_assert_widths "${1-}" ;;'
    printf '%s\n' '  nudge)   shift; tmux_nudge_window "${1-}" ;;'
    printf '%s\n' '  respawn) tmux_respawn_dead_chrome ;;'
    printf '%s\n' 'esac'
  } >"$path" 2>/dev/null || return 0
  chmod 700 "$path" 2>/dev/null || true
  printf '%s\n' "$path"
}

# Install our hooks without clobbering unrelated hooks.  Fixed array indices
# (80-82) make the install idempotent: a later call replaces the same slots.
_tmux_install_hooks() {
  local script
  script=$(_tmux_write_hook_script)
  [[ -n $script ]] || return 0

  local qsaved qwidth qrespawn qnudge
  qsaved=$(_tmux_dq "$script save")
  qwidth=$(_tmux_dq "$script widths")
  qrespawn=$(_tmux_dq "$script respawn")
  qnudge=$(_tmux_dq "$script nudge")

  _tmux set-hook -g 'client-detached[80]' "run-shell -b $qsaved" >/dev/null 2>&1 || true
  _tmux set-hook -g 'window-resized[80]' "run-shell -b $qwidth #{window_id}" >/dev/null 2>&1 || true
  _tmux set-hook -g 'pane-died[80]' "run-shell -b $qrespawn" >/dev/null 2>&1 || true
  # A pane in a window that becomes active receives no focus event (spike 4),
  # so the git pane would otherwise wait up to idle_refresh for fresh status.
  # Nudge its own focus handler as soon as the window is switched to; same on
  # attach, when the client becomes visible.
  _tmux set-hook -g 'session-window-changed[81]' \
    "run-shell -b $qnudge #{window_id}" >/dev/null 2>&1 || true
  _tmux set-hook -g 'client-attached[81]' "run-shell -b $qnudge" >/dev/null 2>&1 || true
  # Mouse border drags do not fire window-resized (spike 4); once the drag
  # ends, reassert the configured sidebar widths.
  _tmux bind-key -T root MouseDragEnd1Border \
    "run-shell -b $qwidth #{window_id}" >/dev/null 2>&1 || true
  return 0
}

# Mirror config into @balamba_* and (re)install hooks.  Requires a server that
# actually has a session; an empty tmux server does not survive.
_tmux_apply_server_config() {
  balamba_config_to_tmux -L "$BALAMBA_SOCKET" >/dev/null 2>&1 || return 1
  _tmux_install_hooks
  return 0
}

# ---------------------------------------------------------------------------
# 10.1 tmux_server_up
# ---------------------------------------------------------------------------
tmux_server_up() {
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_require_cmd tmux

  if _tmux_server_responsive; then
    _tmux_apply_server_config || true
    return 0
  fi

  local sock
  sock=$(balamba_tmux_socket_path)
  if ! _tmux -f "$BALAMBA_TMUX_CONF" start-server >/dev/null 2>&1; then
    # Spike risk 3: a killed server leaves its socket behind; unlink and retry
    # exactly once.
    [[ -n $sock ]] && rm -f -- "$sock"
    if ! _tmux -f "$BALAMBA_TMUX_CONF" start-server >/dev/null 2>&1; then
      balamba_die "could not start the balamba tmux server (socket $sock)"
    fi
  fi
  # No sessions means the server exits immediately; the config is applied
  # again as soon as the first session exists.
  if _tmux_server_responsive; then
    _tmux_apply_server_config || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Sessions and windows
# ---------------------------------------------------------------------------

# Create session balamba with one fresh window (a `sleep` placeholder process
# that the caller replaces).  Retries once after unlinking a stale socket.
_tmux_session_new_with_window() {
  local name=$1 cwd=$2
  _tmux_session_size
  if ! _tmux_new_session -d -s "$_BALAMBA_TMUX_SESSION" -n "$name" \
    -x "$_TMUX_COLS" -y "$_TMUX_ROWS" -c "$cwd" 'sleep 300' \
    >/dev/null 2>&1; then
    if _tmux_session_exists; then
      # A concurrent caller won the race; reuse it.
      :
    else
      rm -f -- "$(balamba_tmux_socket_path)"
      _tmux_new_session -d -s "$_BALAMBA_TMUX_SESSION" -n "$name" \
        -x "$_TMUX_COLS" -y "$_TMUX_ROWS" -c "$cwd" 'sleep 300' \
        >/dev/null 2>&1 || \
        balamba_die "could not create tmux session $_BALAMBA_TMUX_SESSION"
    fi
  fi
  _tmux_apply_server_config || true
  _TMUX_SESSION_FIRST_WINDOW=$(
    _tmux display -p -t "$_BALAMBA_TMUX_SESSION:" '#{window_id}' 2>/dev/null || true)
  [[ -n $_TMUX_SESSION_FIRST_WINDOW ]] || \
    balamba_die "tmux session $_BALAMBA_TMUX_SESSION has no window"
}

# A placeholder window exists only when there is no project/context to show.
# It runs the real chrome plus one shell so the empty UI is usable and both
# sidebar widths are independently settable (a 2-pane window cannot hold both).
_tmux_new_placeholder_window() {
  local win
  win=$(_tmux new-window -d -P -F '#{window_id}' -t "$_BALAMBA_TMUX_SESSION:" \
    -n "$_BALAMBA_TMUX_SESSION" -c "$HOME" 'sleep 300' 2>/dev/null) || return 1

  _tmux set-option -w -t "$win" @balamba_placeholder 1 >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_tab '' >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_context '' >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_project '' >/dev/null 2>&1 || true

  _FW_CONTENT_COUNT=1
  _FW_LAYOUT=""
  _FW_ACTIVE_PANE=0
  _FW_CWDS=("$HOME")
  _FW_LAUNCHED=(shell)
  _FW_AGENT=""
  _FW_SESSION=""
  _FW_RESUME=0
  _tmux_fill_window "$win" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_placeholder 1 >/dev/null 2>&1 || true
  tmux_assert_widths "$win" >/dev/null 2>&1 || true
  printf '%s\n' "$win"
}

_tmux_new_placeholder_session() {
  _tmux_session_size
  if ! _tmux_new_session -d -s "$_BALAMBA_TMUX_SESSION" \
    -n "$_BALAMBA_TMUX_SESSION" -x "$_TMUX_COLS" -y "$_TMUX_ROWS" \
    -c "$HOME" 'sleep 300' >/dev/null 2>&1; then
    rm -f -- "$(balamba_tmux_socket_path)"
    _tmux_new_session -d -s "$_BALAMBA_TMUX_SESSION" \
      -n "$_BALAMBA_TMUX_SESSION" -x "$_TMUX_COLS" -y "$_TMUX_ROWS" \
      -c "$HOME" 'sleep 300' >/dev/null 2>&1 || \
      balamba_die "could not create tmux session $_BALAMBA_TMUX_SESSION"
  fi
  _tmux_apply_server_config || true

  local win
  win=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:" '#{window_id}' 2>/dev/null || true)
  [[ -n $win ]] || balamba_die "tmux session $_BALAMBA_TMUX_SESSION has no window"

  _tmux set-option -w -t "$win" @balamba_placeholder 1 >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_tab '' >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_context '' >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_project '' >/dev/null 2>&1 || true

  _FW_CONTENT_COUNT=1
  _FW_LAYOUT=""
  _FW_ACTIVE_PANE=0
  _FW_CWDS=("$HOME")
  _FW_LAUNCHED=(shell)
  _FW_AGENT=""
  _FW_SESSION=""
  _FW_RESUME=0
  _tmux_fill_window "$win" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_placeholder 1 >/dev/null 2>&1 || true
  tmux_assert_widths "$win" >/dev/null 2>&1 || true
}

_tmux_kill_placeholder() {
  local -a rows=()
  local row wid placeholder
  mapfile -t rows < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_id}\t#{@balamba_placeholder}' 2>/dev/null || true)
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r wid placeholder <<<"$row"
    if [[ $placeholder == 1 ]]; then
      _tmux kill-window -t "$wid" >/dev/null 2>&1 || true
    fi
  done
  return 0
}

# Renumber all windows to 0..N-1 in ascending order.  Only called after the
# placeholder is gone, i.e. when we know the session was built from scratch.
_tmux_compact_windows() {
  local -a rows=()
  local row idx wid i=0
  mapfile -t rows < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_index}\t#{window_id}' 2>/dev/null | sort -t $'\t' -k1,1n)
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r idx wid <<<"$row"
    if [[ $idx != "$i" ]]; then
      if ! _tmux move-window -s "$wid" -t "$_BALAMBA_TMUX_SESSION:$i" \
        >/dev/null 2>&1; then
        balamba_warn "could not move window $wid to index $i"
      fi
    fi
    i=$((i + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

# tmux layout checksum: rotate right 1 bit and add each byte (layout_dump).
_tmux_layout_checksum() {
  local s=$1 c=0 i code
  for ((i = 0; i < ${#s}; i++)); do
    printf -v code '%d' "'${s:i:1}"
    c=$(( ((c >> 1) | ((c & 1) << 15)) + code ))
    c=$(( c & 65535 ))
  done
  printf '%04x' "$c"
}

# Number of leaf cells in a layout string (containers have no fourth number).
_tmux_layout_leaf_count() {
  local layout=${1-} n=0
  if [[ -n $layout ]]; then
    n=$(printf '%s' "$layout" | grep -oE '[0-9]+x[0-9]+,[0-9]+,[0-9]+,[0-9]+' 2>/dev/null | wc -l) || n=0
    n=${n//[[:space:]]/}
  fi
  printf '%s\n' "${n:-0}"
}

# Build a layout string: tree | content panes (stacked) | git.
_tmux_equal_layout() {
  local n=$1 w=$2 h=$3 tw=${4:-30} gw=${5:-34}
  ((n >= 1)) || n=1
  ((w >= 10)) || w=10
  ((h >= 3)) || h=3

  local availw=$((w - 2)) # three columns, two separators
  if ((tw + gw + 1 > availw)); then
    tw=$((availw / 2))
    ((tw >= 1)) || tw=1
    gw=$((availw - tw - 1))
    ((gw >= 1)) || gw=1
    while ((tw + gw + 1 > availw && gw > 1)); do gw=$((gw - 1)); done
    while ((tw + gw + 1 > availw && tw > 1)); do tw=$((tw - 1)); done
  fi
  local mw=$((availw - tw - gw))
  ((mw >= 1)) || mw=1

  local availh=$((h - (n - 1)))
  ((availh >= n)) || availh=n
  local base=$((availh / n))
  local rem=$((availh % n))
  local body="" i y=0 ph
  for ((i = 0; i < n; i++)); do
    ph=$base
    ((i < rem)) && ph=$((ph + 1))
    [[ -n $body ]] && body+=","
    body+="${mw}x${ph},$((tw + 1)),${y},$((i + 1))"
    y=$((y + ph + 1))
  done

  local rest
  if ((n == 1)); then
    # A single-child container is accepted by select-layout but tmux 3.4 exits
    # the server when that child is later killed.  Keep one content pane flat.
    rest="${w}x${h},0,0{${tw}x${h},0,0,0,${body},${gw}x${h},$((tw + mw + 2)),0,2}"
  else
    rest="${w}x${h},0,0{${tw}x${h},0,0,0,${mw}x${h},$((tw + 1)),0[${body}],${gw}x${h},$((tw + mw + 2)),0,$((n + 1))}"
  fi
  local cs
  cs=$(_tmux_layout_checksum "$rest")
  printf '%s,%s\n' "$cs" "$rest"
}

# Apply the saved layout when its leaf count matches the live pane count.
# Returns 0 when applied.  Never applies a truncated layout.
_tmux_apply_saved_layout() {
  local win=$1 layout=${2-} total=$3
  [[ -n $layout ]] || return 1
  local leaves
  leaves=$(_tmux_layout_leaf_count "$layout")
  [[ $leaves == "$total" ]] || return 1
  _tmux select-layout -t "$win" "$layout" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Chrome / pane spawning
# ---------------------------------------------------------------------------

_tmux_respawn_chrome_pane() {
  local pane=$1 which=$2 cmd
  cmd=$(_tmux_chrome_command "$which")
  _tmux set-option -p -t "$pane" @balamba_chrome "$which" >/dev/null 2>&1 || true
  _tmux set-option -p -t "$pane" remain-on-exit on >/dev/null 2>&1 || true
  if ! _tmux respawn-pane -k -t "$pane" -c "$BALAMBA_ROOT" \
    -e "BALAMBA_ROOT=$BALAMBA_ROOT" \
    -e "BALAMBA_STATE=$BALAMBA_STATE" \
    -e "BALAMBA_SOCKET=$BALAMBA_SOCKET" \
    -e "BALAMBA_CONFIG=$BALAMBA_CONFIG" \
    -e "BALAMBA_RUNTIME=$BALAMBA_RUNTIME" \
    "$cmd" >/dev/null 2>&1; then
    balamba_warn "could not respawn $which chrome pane $pane"
    return 1
  fi
  return 0
}

_tmux_respawn_content_pane() {
  local pane=$1 cwd=$2 cmd=$3
  if ! _tmux respawn-pane -k -t "$pane" -c "$cwd" \
    -e "BALAMBA_ROOT=$BALAMBA_ROOT" \
    -e "BALAMBA_STATE=$BALAMBA_STATE" \
    -e "BALAMBA_SOCKET=$BALAMBA_SOCKET" \
    -e "BALAMBA_CONFIG=$BALAMBA_CONFIG" \
    -e "BALAMBA_RUNTIME=$BALAMBA_RUNTIME" \
    "$cmd" >/dev/null 2>&1; then
    balamba_warn "could not start pane $pane"
    return 1
  fi
  return 0
}

# Nudge the chrome panes of a window (or the current window when no target is
# given) with a synthetic focus-in event.  pane/ui.py treats that as "refresh
# now", which is how the git pane becomes fresh immediately after a window
# switch without polling every inactive window at 1 Hz.
tmux_nudge_window() {
  local target=${1-}
  _tmux_server_responsive || return 0
  local -a rows=()
  local row pane chrome
  if [[ -n $target ]]; then
    mapfile -t rows < <(_tmux list-panes -t "$target" \
      -F $'#{pane_id}\t#{@balamba_chrome}' 2>/dev/null || true)
  else
    mapfile -t rows < <(_tmux list-panes -t "$_BALAMBA_TMUX_SESSION:" \
      -F $'#{pane_id}\t#{@balamba_chrome}' 2>/dev/null || true)
  fi
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r pane chrome <<<"$row"
    case $chrome in
      tree|git)
        _tmux send-keys -t "$pane" -l $'\x1b[I' >/dev/null 2>&1 || true
        ;;
    esac
  done
  return 0
}

# Respawn every chrome pane that has remain-on-exit'ed (pane-died hook).
# Content panes are intentionally left alone.
tmux_respawn_dead_chrome() {
  balamba_config_load >/dev/null 2>&1 || return 0
  _tmux_server_responsive || return 0
  local -a rows=()
  local row pane dead chrome
  mapfile -t rows < <(_tmux list-panes -a \
    -F $'#{pane_id}\t#{pane_dead}\t#{@balamba_chrome}' 2>/dev/null || true)
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r pane dead chrome <<<"$row"
    [[ $dead == 1 && ($chrome == tree || $chrome == git) ]] || continue
    # Avoid a fork storm if the chrome command fails immediately: give it a
    # few tries, then leave the dead pane visible for debugging.  A restart or
    # a fresh window resets the counter.
    local attempts
    attempts=$(_tmux display -p -t "$pane" '#{@balamba_chrome_attempts}' \
      2>/dev/null || true)
    [[ $attempts =~ ^[0-9]+$ ]] || attempts=0
    if ((attempts >= 8)); then
      continue
    fi
    _tmux set-option -p -t "$pane" @balamba_chrome_attempts "$((attempts + 1))" \
      >/dev/null 2>&1 || true
    _tmux_respawn_chrome_pane "$pane" "$chrome" >/dev/null 2>&1 || true
  done
  return 0
}

# ---------------------------------------------------------------------------
# Window construction
# ---------------------------------------------------------------------------
# Globals read by _tmux_fill_window (all set by the caller):
#   _FW_CONTENT_COUNT  _FW_LAYOUT  _FW_ACTIVE_PANE
#   _FW_CWDS[]         _FW_LAUNCHED[]
#   _FW_AGENT          _FW_SESSION
_FW_CONTENT_COUNT=1
_FW_LAYOUT=""
_FW_ACTIVE_PANE=0
_FW_CWDS=()
_FW_LAUNCHED=()
_FW_AGENT=""
_FW_SESSION=""
_FW_RESUME=0

_TMUX_STAGGER_SECS=0
_TMUX_AGENT_LAUNCHES=0

# Turn a freshly created one-pane window into the 3-column chrome plus content
# panes, then start every pane process.
_tmux_fill_window() {
  local win=$1
  local content_count=$_FW_CONTENT_COUNT
  ((content_count >= 1)) || content_count=1
  local total=$((content_count + 2))
  local i

  # Create the panes as a plain left-to-right line first.  select-layout maps
  # panes by creation order to geometric leaves, so creation order is the same
  # as the desired leaf order: tree, content 0..N-1, git.
  for ((i = 1; i < total; i++)); do
    if ! _tmux split-window -h -t "$win" -c "$BALAMBA_ROOT" 'sleep 300' \
      >/dev/null 2>&1; then
      balamba_warn "could not add pane $i to window $win"
      break
    fi
  done

  local applied=0
  if _tmux_apply_saved_layout "$win" "$_FW_LAYOUT" "$total"; then
    applied=1
  fi
  if ((!applied)); then
    local w h eq
    w=$(_tmux display -p -t "$win" '#{window_width}' 2>/dev/null || printf '80')
    h=$(_tmux display -p -t "$win" '#{window_height}' 2>/dev/null || printf '24')
    eq=$(_tmux_equal_layout "$content_count" "${w:-80}" "${h:-24}" \
      "${tree_width:-30}" "${git_width:-34}")
    if ! _tmux select-layout -t "$win" "$eq" >/dev/null 2>&1; then
      balamba_warn "could not apply the equal-split layout in window $win"
    fi
  fi

  local -a pane_rows=()
  local -a pane_ids=()
  local row idx pane chrome
  mapfile -t pane_rows < <(_tmux list-panes -t "$win" \
    -F $'#{pane_index}\t#{pane_id}' 2>/dev/null | sort -t $'\t' -k1,1n)
  for row in "${pane_rows[@]}"; do
    IFS=$'\t' read -r idx pane <<<"$row"
    pane_ids+=("$pane")
  done
  local live=${#pane_ids[@]}
  if ((live < 2)); then
    balamba_warn "window $win has $live pane(s); cannot build chrome"
    return 1
  fi

  # Tree is live pane 0, git is the last live pane, content is the middle.
  local tree_pane=${pane_ids[0]}
  local git_pane=${pane_ids[$((live - 1))]}
  local content_live=$((live - 2))

  _tmux_respawn_chrome_pane "$tree_pane" tree >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_placeholder '' >/dev/null 2>&1 || true

  local ci pane_idx cwd kind cmd
  for ((ci = 0; ci < content_live; ci++)); do
    pane=${pane_ids[$((ci + 1))]}
    cwd=${_FW_CWDS[$ci]-}
    [[ -n $cwd ]] || cwd=$HOME
    [[ -d $cwd ]] || cwd=$HOME
    kind=${_FW_LAUNCHED[$ci]-shell}
    if [[ $kind == agent && -z ${_FW_SESSION-} ]]; then
      kind=shell
    fi
    cmd=$(_tmux_pane_command "$kind" "${_FW_AGENT-}" "${_FW_SESSION-}" "$cwd" "$_FW_RESUME")
    if [[ $kind == agent && $_TMUX_AGENT_LAUNCHES -gt 0 && $_TMUX_STAGGER_SECS -gt 0 ]]; then
      sleep "$_TMUX_STAGGER_SECS"
    fi
    _tmux_respawn_content_pane "$pane" "$cwd" "$cmd" >/dev/null 2>&1 || true
    if [[ $kind == agent ]]; then
      _TMUX_AGENT_LAUNCHES=$((_TMUX_AGENT_LAUNCHES + 1))
    fi
  done

  _tmux_respawn_chrome_pane "$git_pane" git >/dev/null 2>&1 || true

  local ap=$_FW_ACTIVE_PANE
  [[ $ap =~ ^[0-9]+$ ]] || ap=0
  if ((ap >= 0 && ap < content_live)); then
    _tmux select-pane -t "${pane_ids[$((ap + 1))]}" >/dev/null 2>&1 || true
  elif ((content_live > 0)); then
    _tmux select-pane -t "${pane_ids[1]}" >/dev/null 2>&1 || true
  fi
  return 0
}

# Load _FW_* from a tab JSON document (one tab object).
_tmux_set_fill_globals_from_tab() {
  local json=$1 context=$2 pid=$3
  local tab_id name count layout active kind agent session cwd_fallback

  tab_id=$(jq -r '.id // ""' <<<"$json")
  name=$(jq -r '.name // "tab"' <<<"$json")
  count=$(jq -r '.pane_count // 1' <<<"$json")
  layout=$(jq -r '.layout // ""' <<<"$json")
  active=$(jq -r '.active_pane // 0' <<<"$json")
  kind=$(jq -r '.kind // "shell"' <<<"$json")
  agent=$(jq -r '.agent // ""' <<<"$json")
  session=$(jq -r '.session // ""' <<<"$json")

  [[ $count =~ ^[0-9]+$ ]] || count=1
  ((count >= 1)) || count=1
  [[ $active =~ ^[0-9]+$ ]] || active=0

  cwd_fallback=$(_tmux_context_path "$pid" "$context")
  [[ -n $cwd_fallback && -d $cwd_fallback ]] || cwd_fallback=$HOME

  local -a cwds=() launched=()
  local -a pane_json=()
  mapfile -t pane_json < <(jq -c '.panes[]?' <<<"$json")
  # Restore every saved pane, even if pane_count is stale.  (The geometry
  # guard still uses the resulting live count.)
  ((count >= ${#pane_json[@]})) || count=${#pane_json[@]}
  local i pj pcwd plaunched
  for ((i = 0; i < count; i++)); do
    if ((i < ${#pane_json[@]})); then
      pj=${pane_json[$i]}
      pcwd=$(jq -r '.cwd // ""' <<<"$pj")
      plaunched=$(jq -r '.launched // ""' <<<"$pj")
    else
      pcwd=""
      plaunched=""
    fi
    [[ -n $pcwd && -d $pcwd ]] || pcwd=$cwd_fallback
    [[ $plaunched == agent || $plaunched == shell ]] || plaunched=shell
    cwds+=("$pcwd")
    launched+=("$plaunched")
  done

  _FW_CONTENT_COUNT=$count
  _FW_LAYOUT=$layout
  _FW_ACTIVE_PANE=$active
  _FW_CWDS=("${cwds[@]}")
  _FW_LAUNCHED=("${launched[@]}")
  _FW_AGENT=$agent
  _FW_SESSION=$session
  _FW_RESUME=1
  _TMUX_TAB_NAME=$name
  _TMUX_TAB_ID=$tab_id
  _TMUX_TAB_CONTEXT=$context
  _TMUX_TAB_PID=$pid
}

# Create one window for a saved tab and start its panes.  Sets
# _TMUX_BUILT_WINDOW_ID.  Returns 0 on success.
_tmux_build_window_for_tab() {
  local json=$1 context=$2 pid=$3
  _tmux_set_fill_globals_from_tab "$json" "$context" "$pid"
  local cwd=${_FW_CWDS[0]-$HOME}
  [[ -d $cwd ]] || cwd=$HOME

  local win
  win=$(_tmux new-window -d -P -F '#{window_id}' -t "$_BALAMBA_TMUX_SESSION:" \
    -n "$_TMUX_TAB_NAME" -c "$cwd" 'sleep 300' 2>/dev/null) || {
    balamba_warn "could not create a window for tab $_TMUX_TAB_ID"
    return 1
  }
  _TMUX_BUILT_WINDOW_ID=$win

  _tmux set-option -w -t "$win" @balamba_tab "$_TMUX_TAB_ID" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_context "$context" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_project "$pid" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_placeholder '' >/dev/null 2>&1 || true

  _tmux_fill_window "$win" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
_tmux_state_b64_decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null || true
}

# pid for a context.  "proj" resolves to the active (or first) project.
_tmux_context_pid() {
  local context=$1
  if [[ $context == proj ]]; then
    local pid
    pid=$(balamba_state_get '.active.project // empty')
    if [[ -z $pid ]]; then
      pid=$(balamba_state_get '.projects[0].id // empty')
      if [[ -n $pid ]]; then
        balamba_state_update \
          '.active.project = $p | .active.context = "proj" | .active.window = 0' \
          --arg p "$pid" >/dev/null 2>&1 || true
      fi
    fi
    printf '%s\n' "$pid"
    return 0
  fi
  local tid=${context#task:}
  balamba_state_get \
    '.projects[] | select(any(.tasks[]?; .id == $tid)) | .id' --arg tid "$tid" \
    2>/dev/null | head -n1
}

# Validate project/context and set _TMUX_CTX_* globals: PID CWD BRANCH TASK_ID
# and MISSING (1 when the project checkout or task worktree is not a directory).
# Public entry points that would launch a process decide whether that is fatal;
# internal context rebuilding may fall back to $HOME.
_TMUX_CTX_MISSING=0
_TMUX_ALLOW_MISSING_PATH=0
_tmux_resolve_context() {
  local pid=$1 context=$2
  _TMUX_CTX_PID=$pid
  _TMUX_CTX_CWD=""
  _TMUX_CTX_BRANCH=""
  _TMUX_CTX_TASK_ID=""
  _TMUX_CTX_MISSING=0

  local n
  n=$(balamba_state_get \
    '[.projects[] | select(.id == $pid)] | length' --arg pid "$pid" 2>/dev/null) || n=0
  ((n > 0)) || balamba_die "unknown project: $pid"

  if [[ $context == proj ]]; then
    _TMUX_CTX_CWD=$(balamba_state_get \
      '.projects[] | select(.id == $pid) | .path' --arg pid "$pid")
    if [[ -z $_TMUX_CTX_CWD || ! -d $_TMUX_CTX_CWD ]]; then
      _TMUX_CTX_MISSING=1
    fi
    if command -v git >/dev/null 2>&1 && [[ -d $_TMUX_CTX_CWD ]]; then
      _TMUX_CTX_BRANCH=$(git -C "$_TMUX_CTX_CWD" rev-parse --abbrev-ref HEAD \
        2>/dev/null || true)
      [[ $_TMUX_CTX_BRANCH == HEAD ]] && _TMUX_CTX_BRANCH=""
    fi
    return 0
  fi

  if [[ $context != task:* || -z ${context#task:} ]]; then
    balamba_die "invalid context: $context (expected proj or task:<task-id>)"
  fi
  local tid=${context#task:}
  _TMUX_CTX_TASK_ID=$tid
  n=$(balamba_state_get \
    '[.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid)] | length' \
    --arg pid "$pid" --arg tid "$tid" 2>/dev/null) || n=0
  ((n > 0)) || balamba_die "unknown task: $tid (project $pid)"
  _TMUX_CTX_CWD=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .path' \
    --arg pid "$pid" --arg tid "$tid")
  if [[ -z $_TMUX_CTX_CWD || ! -d $_TMUX_CTX_CWD ]]; then
    _TMUX_CTX_MISSING=1
  fi
  _TMUX_CTX_BRANCH=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .branch' \
    --arg pid "$pid" --arg tid "$tid")
  return 0
}

# Path for a context, without validating it (used for fallback cwds).
_tmux_context_path() {
  local pid=$1 context=$2
  if [[ $context == proj ]]; then
    balamba_state_get '.projects[] | select(.id == $pid) | .path' --arg pid "$pid" \
      2>/dev/null || true
  else
    balamba_state_get \
      '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $t) | .path' \
      --arg pid "$pid" --arg t "${context#task:}" 2>/dev/null || true
  fi
}

# Baseline64 rows for the tabs of one context, ordered by saved window.
_tmux_context_tabs_b64() {
  local pid=$1 context=$2 filter
  if [[ $context == proj ]]; then
    filter='.projects[] | select(.id == $pid) | .tabs[]? | @base64'
  else
    filter='.projects[] | select(.id == $pid) | .tasks[]? | select(.id == $tid) | .tabs[]? | @base64'
  fi
  balamba_state_get "$filter" --arg pid "$pid" --arg tid "${context#task:}" \
    2>/dev/null || true
}

# Every tab in state as base64 JSON: {pid, context, tab}, sorted by window.
_tmux_all_tabs_b64() {
  balamba_state_get '
    [ .projects[] | .id as $p
      | ((.tabs[]? | {pid:$p, context:"proj", tab:.}),
         (.tasks[]? | .id as $t
          | .tabs[]? | {pid:$p, context:("task:" + $t), tab:.})) ]
    | sort_by(.tab.window)
    | .[]
    | @base64' 2>/dev/null || true
}

# Owner of a tab id: prints "<project-id>\t<context>" (or nothing).
_tmux_tab_owner() {
  local tab=$1
  balamba_state_get '
    .projects[] | .id as $p
    | ((.tabs[]? | select(.id == $t) | [$p, "proj"] | @tsv),
       (.tasks[]? | .id as $tk | .tabs[]? | select(.id == $t)
        | [$p, ("task:" + $tk)] | @tsv))
  ' --arg t "$tab" 2>/dev/null | head -n1
}

_tmux_set_global_context() {
  local pid=$1 context=$2 branch=${3-}
  _tmux set-option -g @balamba_context "$context" >/dev/null 2>&1 || true
  if [[ -z $branch ]]; then
    branch=$(_tmux_branch_for "$pid" "$context")
  fi
  _tmux set-option -g @balamba_git_branch "$branch" >/dev/null 2>&1 || true
}

_tmux_branch_for() {
  local pid=$1 context=$2 path branch=""
  path=$(_tmux_context_path "$pid" "$context")
  if [[ $context == task:* ]]; then
    branch=$(balamba_state_get \
      '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $t) | .branch' \
      --arg pid "$pid" --arg t "${context#task:}" 2>/dev/null || true)
  elif command -v git >/dev/null 2>&1 && [[ -n $path && -d $path ]]; then
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ $branch == HEAD ]] && branch=""
  fi
  printf '%s\n' "$branch"
}

# ---------------------------------------------------------------------------
# Window lookup / selection
# ---------------------------------------------------------------------------
_tmux_window_id_for_tab() {
  local tab=$1 row wid wtab
  while IFS=$'\t' read -r wid wtab; do
    if [[ $wtab == "$tab" ]]; then
      printf '%s\n' "$wid"
      return 0
    fi
  done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_id}\t#{@balamba_tab}' 2>/dev/null || true)
  return 1
}

_tmux_window_index_for_tab() {
  local tab=$1 row idx wtab
  while IFS=$'\t' read -r idx wtab; do
    if [[ $wtab == "$tab" ]]; then
      printf '%s\n' "$idx"
      return 0
    fi
  done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_index}\t#{@balamba_tab}' 2>/dev/null || true)
  return 1
}

_tmux_window_exists_index() {
  local idx=$1 row found=1
  while IFS= read -r row; do
    if [[ $row == "$idx" ]]; then
      found=0
      break
    fi
  done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F '#{window_index}' 2>/dev/null || true)
  return "$found"
}

# Tab id of the window at a live index (empty when it is not a balamba tab).
_tmux_tab_for_window_index() {
  local want=$1 idx tab
  while IFS=$'\t' read -r idx tab; do
    if [[ $idx == "$want" && -n $tab ]]; then
      printf '%s\n' "$tab"
      return 0
    fi
  done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_index}\t#{@balamba_tab}' 2>/dev/null || true)
  return 1
}

# Content pane ids of a window in live index order.  Chrome is filtered out.
_tmux_content_pane_ids() {
  local win=$1 row idx pane chrome
  while IFS=$'\t' read -r idx pane chrome; do
    [[ -n $pane ]] || continue
    [[ $chrome == tree || $chrome == git ]] && continue
    printf '%s\n' "$pane"
  done < <(_tmux list-panes -t "$win" \
    -F $'#{pane_index}\t#{pane_id}\t#{@balamba_chrome}' 2>/dev/null |
    sort -t $'\t' -k1,1n)
}

_tmux_select_content_pane() {
  local win=$1 index=$2
  [[ $index =~ ^[0-9]+$ ]] || index=0
  local -a ids=()
  mapfile -t ids < <(_tmux_content_pane_ids "$win")
  ((${#ids[@]} > index)) || return 1
  _tmux select-pane -t "${ids[$index]}" >/dev/null 2>&1 || return 1
  return 0
}

# Short human label for an adopted pane: the live command basename, without
# arguments.  The live command is already a basename in practice, but a saved
# value may not be, so normalise anyway.
_tmux_pane_label() {
  local cmd=${1-}
  cmd=${cmd##*/}
  cmd=${cmd%%[[:space:]]*}
  cmd=${cmd//[[:space:]]/}
  [[ -n $cmd ]] || cmd=shell
  printf '%s\n' "$cmd"
}

# ---------------------------------------------------------------------------
# 10.10 tmux_sync_panes [context]
# ---------------------------------------------------------------------------
# Materialise the live tmux pane set into state.  Live tmux is the source of
# truth for each balamba window (identified by @balamba_tab):
#   * content panes are everything except the @balamba_chrome tree/git panes;
#   * content index = position in live pane order (live index - 1);
#   * panes that vanished are dropped, new ones are adopted as "shell";
#   * window index, pane_count, active_pane and layout are recomputed.
# Tabs of contexts that have no live window at all are left alone: they are
# simply not built in this session yet.  A window whose last content pane died
# is killed and its tab removed.
#
# The write is debounced with a fingerprint of the desired pane set in
# $BALAMBA_RUNTIME/panes.fingerprint, so repeated polls are cheap and do not
# spam state.json.  Safe and silent when the server is down.
tmux_sync_panes() {
  (($# <= 1)) || balamba_die "usage: tmux_sync_panes [proj|task:<task-id>]"
  local scope=${1-}
  balamba_config_load >/dev/null 2>&1 || true
  if [[ ! -f $BALAMBA_STATE ]]; then
    balamba_state_init || return 2
  fi
  _tmux_server_responsive || return 0

  local -A live_idx=() live_win=() live_name=() live_layout=()
  local -A live_ctx_seen=()
  local -a live_tabs=()
  local widx winid wname wctx wpid wtab wlayout
  while IFS=$'\t' read -r widx winid wname wlayout wtab wctx wpid; do
    [[ -n $wtab ]] || continue
    [[ $widx =~ ^[0-9]+$ ]] || continue
    live_ctx_seen[$wctx]=1
    if [[ -n $scope && $wctx != "$scope" ]]; then
      continue
    fi
    [[ -n ${live_win[$wtab]+x} ]] && continue
    live_idx[$wtab]=$widx
    live_win[$wtab]=$winid
    live_name[$wtab]=$wname
    live_layout[$wtab]=$wlayout
    live_tabs+=("$wtab")
  done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_index}\t#{window_id}\t#{window_name}\t#{window_layout}\t#{@balamba_tab}\t#{@balamba_context}\t#{@balamba_project}' \
    2>/dev/null || true)

  # State tabs, keyed by id (with their context and current window).
  local -A state_tab=() state_ctx=() state_win=()
  local -a state_tabs=()
  local b64 obj stid sctx swin
  while IFS= read -r b64; do
    [[ -n $b64 ]] || continue
    obj=$(_tmux_state_b64_decode "$b64")
    [[ -n $obj ]] || continue
    stid=$(jq -r '.tab.id // ""' <<<"$obj")
    [[ -n $stid ]] || continue
    sctx=$(jq -r '.context // "proj"' <<<"$obj")
    swin=$(jq -r '.tab.window // 0' <<<"$obj")
    state_tab[$stid]=$obj
    state_ctx[$stid]=$sctx
    state_win[$stid]=$swin
    state_tabs+=("$stid")
  done < <(_tmux_all_tabs_b64)

  local -a entries=() removed=()
  local -A remove_win=() live_ids=()
  local tabid
  for tabid in "${live_tabs[@]}"; do
    obj=${state_tab[$tabid]-}
    # A window tagged with an unknown tab id is not ours to adopt.
    [[ -n $obj ]] || continue
    live_ids[$tabid]=1
    winid=${live_win[$tabid]}
    obj=$(jq -c '.tab' <<<"$obj")

    local -a pane_rows=()
    local prow pidx pid chrome pactive pcwd pcmd pdead
    mapfile -t pane_rows < <(_tmux list-panes -t "$winid" \
      -F $'#{pane_index}\t#{pane_id}\t#{pane_active}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_dead}\t#{@balamba_chrome}' \
      2>/dev/null | sort -t $'\t' -k1,1n)

    local -a p_cwd=() p_cmd=() p_active=()
    local count=0
    for prow in "${pane_rows[@]}"; do
      IFS=$'\t' read -r pidx pid pactive pcwd pcmd pdead chrome <<<"$prow"
      [[ $chrome == tree || $chrome == git ]] && continue
      p_cwd[$count]=$pcwd
      p_cmd[$count]=$pcmd
      p_active[$count]=$pactive
      count=$((count + 1))
    done

    if ((count == 0)); then
      # No content pane left: the tab is dead even though chrome remains.
      _tmux kill-window -t "$winid" >/dev/null 2>&1 || true
      removed+=("$tabid")
      remove_win[$tabid]=${state_win[$tabid]-0}
      continue
    fi

    local -a old_rows=()
    mapfile -t old_rows < <(jq -r \
      '.panes[]? | [(.launched // ""), (.name // ""), (.cwd // ""), (.live_command // "")] | join("\u001f")' \
      <<<"$obj")
    local old_n=${#old_rows[@]}
    local -a old_launched=() old_name=() old_cwd=() old_cmd=()
    local i orow ol on oc ocmd
    for ((i = 0; i < old_n; i++)); do
      orow=${old_rows[$i]}
      IFS=$'\x1f' read -r ol on oc ocmd <<<"$orow"
      old_launched[$i]=$ol
      old_name[$i]=$on
      old_cwd[$i]=$oc
      old_cmd[$i]=$ocmd
    done

    local old_active
    old_active=$(jq -r '.active_pane // 0' <<<"$obj")
    [[ $old_active =~ ^[0-9]+$ ]] || old_active=0
    local old_tab_name
    old_tab_name=$(jq -r '.name // ""' <<<"$obj")

    # Reserve the names of panes that survive this index so adopted panes get
    # a numeric suffix instead of colliding.
    local -A used=()
    for ((i = 0; i < count && i < old_n; i++)); do
      [[ -n ${old_name[$i]} ]] && used[${old_name[$i]}]=1
    done

    local -a pane_objs=()
    local active_index="" launched name cwd cmd active n base
    for ((i = 0; i < count; i++)); do
      launched=shell
      name=""
      if ((i < old_n)); then
        if [[ ${old_launched[$i]} == agent || ${old_launched[$i]} == shell ]]; then
          launched=${old_launched[$i]}
        fi
        name=${old_name[$i]}
      fi
      cwd=${p_cwd[$i]-}
      [[ -n $cwd ]] || cwd=${old_cwd[$i]-}
      [[ -n $cwd ]] || cwd=$HOME
      cmd=${p_cmd[$i]-}
      [[ -n $cmd ]] || cmd=${old_cmd[$i]-}
      active=false
      [[ ${p_active[$i]-0} == 1 ]] && active=true
      [[ $active == true ]] && active_index=$i

      if [[ -z $name ]]; then
        base=$(_tmux_pane_label "$cmd")
        name=$base
        n=2
        while [[ -n ${used[$name]+x} ]]; do
          name="$base $n"
          n=$((n + 1))
        done
        used[$name]=1
      fi

      pane_objs+=("$(jq -nc \
        --argjson index "$i" --arg cwd "$cwd" --arg launched "$launched" \
        --arg name "$name" --arg live_command "$cmd" --argjson active "$active" \
        '{index:$index,cwd:$cwd,launched:$launched,name:$name,
          live_command:$live_command,active:$active}')")
    done

    local active_pane=$old_active
    [[ -n $active_index ]] && active_pane=$active_index
    ((active_pane < count)) || active_pane=$((count - 1))
    ((active_pane >= 0)) || active_pane=0

    local panes_json new_name new_layout
    panes_json=$(printf '%s\n' "${pane_objs[@]}" | jq -s -c '.')
    new_name=${live_name[$tabid]}
    [[ -n $new_name ]] || new_name=$old_tab_name
    new_layout=${live_layout[$tabid]}
    [[ -n $new_layout ]] || new_layout=$(jq -r '.layout // ""' <<<"$obj")

    entries+=("$(jq -nc \
      --arg id "$tabid" --arg name "$new_name" --arg layout "$new_layout" \
      --argjson window "${live_idx[$tabid]}" \
      --argjson pane_count "$count" --argjson active_pane "$active_pane" \
      --argjson panes "$panes_json" \
      '{id:$id,name:$name,window:$window,pane_count:$pane_count,
        layout:$layout,active_pane:$active_pane,panes:$panes}')")
  done

  # Tabs of a context that is live in this session but whose window vanished
  # were closed by the user (or by the zero-content rule above): drop them.
  for stid in "${state_tabs[@]}"; do
    [[ -n ${live_ids[$stid]+x} ]] && continue
    [[ -n $scope && ${state_ctx[$stid]} != "$scope" ]] && continue
    [[ -n ${live_ctx_seen[${state_ctx[$stid]}]+x} ]] || continue
    removed+=("$stid")
    remove_win[$stid]=${state_win[$stid]-0}
  done

  ((${#entries[@]} || ${#removed[@]})) || return 0

  local entries_json removed_json
  if ((${#entries[@]})); then
    entries_json=$(printf '%s\n' "${entries[@]}" | jq -s -c 'sort_by(.id)')
  else
    entries_json='[]'
  fi
  if ((${#removed[@]})); then
    removed_json=$(printf '%s\n' "${removed[@]}" | jq -R . | jq -s -c 'unique')
  else
    removed_json='[]'
  fi

  local fingerprint payload fp fpfile
  payload=$(jq -nc --arg scope "$scope" \
    --argjson entries "$entries_json" --argjson removed "$removed_json" \
    '{scope:$scope,entries:$entries,removed:$removed}')
  fp=$(printf '%s' "$payload" | cksum | tr -d ' \n')
  fpfile="$BALAMBA_RUNTIME/panes.fingerprint"
  if [[ -s $fpfile && -f $BALAMBA_STATE && $(<"$fpfile") == "$fp" ]]; then
    return 0
  fi

  local entries_map
  entries_map=$(jq -nc --argjson e "$entries_json" \
    '$e | map({key:.id,value:.}) | from_entries')

  balamba_state_update '
    def upd:
      . as $t
      | ($m[$t.id] // null) as $v
      | if $v == null then $t
        else $t
          | .window = $v.window
          | .name = (if $v.name == "" then $t.name else $v.name end)
          | .pane_count = $v.pane_count
          | .layout = (if $v.layout == "" then $t.layout else $v.layout end)
          | .active_pane = $v.active_pane
          | .panes = $v.panes
        end;
    .projects |= map(
      .tabs |= (map(upd) | map(select(.id as $i | $removed | index($i) | not)) | sort_by(.window))
      | .tasks |= map(
          .tabs |= (map(upd) | map(select(.id as $i | $removed | index($i) | not)) | sort_by(.window))))
  ' --argjson m "$entries_map" --argjson removed "$removed_json"

  mkdir -p -- "$BALAMBA_RUNTIME" 2>/dev/null || true
  printf '%s\n' "$fp" >"$fpfile" 2>/dev/null || true

  # If the active window was one of the removed ones, follow the first
  # surviving tab of the active context instead of leaving a dangling index.
  local apid actx awin first_win was_removed=0 r
  apid=$(balamba_state_get '.active.project // empty')
  actx=$(balamba_state_get '.active.context // empty')
  awin=$(balamba_state_get '.active.window // 0')
  if [[ -n $apid && -n $actx && -n $awin ]]; then
    for r in "${!remove_win[@]}"; do
      [[ ${remove_win[$r]} == "$awin" ]] && was_removed=1
    done
    if ((was_removed)); then
      if [[ $actx == proj ]]; then
        first_win=$(balamba_state_get '
          .projects[] | select(.id==$p) | .tabs | sort_by(.window) | .[0].window // empty
        ' --arg p "$apid" 2>/dev/null || true)
      else
        first_win=$(balamba_state_get '
          .projects[] | select(.id==$p) | .tasks[] | select(.id==$t)
          | .tabs | sort_by(.window) | .[0].window // empty
        ' --arg p "$apid" --arg t "${actx#task:}" 2>/dev/null || true)
      fi
      if [[ $first_win =~ ^[0-9]+$ ]]; then
        balamba_state_update '.active.window = $w' --argjson w "$first_win" \
          >/dev/null 2>&1 || true
      fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 10.11 tmux_activate_pane
# ---------------------------------------------------------------------------
# Focus one content pane of a tab.  Content indices are 0-based; live tmux
# index = content index + 1 (tree chrome is live 0).
tmux_activate_pane() {
  (($# == 4)) || \
    balamba_die "usage: tmux_activate_pane <project-id> <context> <tab-id> <pane-index>"
  local pid=$1 context=$2 tab=$3 index=$4
  if [[ ! $index =~ ^[0-9]+$ ]]; then
    balamba_warn "pane index must be a non-negative integer (got '$index')"
    return 2
  fi
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  _tmux_resolve_context "$pid" "$context"
  tmux_server_up

  local n
  n=$(balamba_state_get '
    .projects[] | select(.id == $p)
    | (if $c == "proj" then .tabs else (.tasks[] | select(.id == $t) | .tabs) end)
    | map(select(.id == $tab)) | length
  ' --arg p "$pid" --arg c "$context" --arg t "${context#task:}" \
    --arg tab "$tab" 2>/dev/null || printf '0')
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if ((n == 0)); then
    balamba_die "unknown tab: $tab (context $context of project $pid)"
  fi

  local winidx
  if ! winidx=$(_tmux_window_index_for_tab "$tab"); then
    local _prev_allow=$_TMUX_ALLOW_MISSING_PATH
    _TMUX_ALLOW_MISSING_PATH=1
    _tmux_build_context_windows "$pid" "$context" >/dev/null 2>&1 || true
    _TMUX_ALLOW_MISSING_PATH=$_prev_allow
    winidx=$(_tmux_window_index_for_tab "$tab" || true)
  fi
  if [[ -z $winidx ]]; then
    balamba_warn "tab $tab has no live window in $context"
    return 2
  fi

  local winid
  winid=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:$winidx" '#{window_id}' \
    2>/dev/null || true)
  [[ -n $winid ]] || {
    balamba_warn "tab $tab has no live window in $context"
    return 2
  }

  _tmux_show_window "$winidx"
  _tmux_set_global_context "$pid" "$context" "$_TMUX_CTX_BRANCH"
  balamba_state_update '
    .active.project = $p | .active.context = $c | .active.window = $w
  ' --arg p "$pid" --arg c "$context" --argjson w "$winidx"

  tmux_assert_widths "$winid" >/dev/null 2>&1 || true

  local -a ids=()
  mapfile -t ids < <(_tmux_content_pane_ids "$winid")
  if ((index >= ${#ids[@]})); then
    # The pane may have been closed between the click and this call.
    tmux_sync_panes "$context" >/dev/null 2>&1 || true
    mapfile -t ids < <(_tmux_content_pane_ids "$winid")
  fi
  if ((index >= ${#ids[@]})); then
    balamba_warn "pane $index no longer exists in tab $tab ($context); state was re-synced"
    return 2
  fi

  if ! _tmux select-pane -t "${ids[$index]}" >/dev/null 2>&1; then
    balamba_warn "could not select pane $index in tab $tab ($context)"
    return 2
  fi

  balamba_state_update '
    .projects |= map(
      .tabs |= map(if .id == $tab then
        .active_pane = $i | .panes |= map(.active = (.index == $i))
        else . end)
      | .tasks |= map(.tabs |= map(if .id == $tab then
          .active_pane = $i | .panes |= map(.active = (.index == $i))
          else . end)))
  ' --arg tab "$tab" --argjson i "$index" >/dev/null 2>&1 || true

  tmux_assert_widths "$winid" >/dev/null 2>&1 || true
  return 0
}

# Make a window visible: switch the current client when possible, otherwise
# select it in the session.
_tmux_show_window() {
  local idx=$1
  local switched=0
  if [[ -n ${TMUX:-} ]]; then
    if _tmux switch-client -t "$_BALAMBA_TMUX_SESSION:$idx" >/dev/null 2>&1; then
      switched=1
    fi
  fi
  if ((!switched)); then
    local client
    client=$(_tmux list-clients -F '#{client_name}' 2>/dev/null | head -n1 || true)
    if [[ -n $client ]]; then
      _tmux switch-client -c "$client" -t "$_BALAMBA_TMUX_SESSION:$idx" \
        >/dev/null 2>&1 || true
    fi
  fi
  _tmux select-window -t "$_BALAMBA_TMUX_SESSION:$idx" >/dev/null 2>&1 || true
}

# Update state tab windows from live @balamba_tab options for one context.
_tmux_update_context_windows() {
  local pid=$1 context=$2
  local -a rows=()
  local row idx tab
  mapfile -t rows < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{@balamba_tab}\t#{window_index}' 2>/dev/null || true)
  local -a pairs=()
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tab idx <<<"$row"
    [[ -n $tab && -n $idx ]] || continue
    pairs+=("$tab=$idx")
  done
  ((${#pairs[@]})) || return 0

  local map="{}" pair
  for pair in "${pairs[@]}"; do
    map=$(jq -c --arg k "${pair%%=*}" --argjson v "${pair#*=}" \
      '. + {($k): $v}' <<<"$map")
  done

  # Remember which tab was active at the old index so active.window can follow
  # the compaction.
  local active_pid active_ctx active_win active_tab=""
  active_pid=$(balamba_state_get '.active.project // empty')
  active_ctx=$(balamba_state_get '.active.context // empty')
  active_win=$(balamba_state_get '.active.window // 0')
  if [[ $active_pid == "$pid" && $active_ctx == "$context" ]]; then
    if [[ $context == proj ]]; then
      active_tab=$(balamba_state_get '
        .projects[] | select(.id == $pid) | .tabs[]?
        | select(.window == $w) | .id' --arg pid "$pid" --argjson w "$active_win" \
        2>/dev/null | head -n1 || true)
    else
      active_tab=$(balamba_state_get '
        .projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid)
        | .tabs[]? | select(.window == $w) | .id' \
        --arg pid "$pid" --arg tid "${context#task:}" --argjson w "$active_win" \
        2>/dev/null | head -n1 || true)
    fi
  fi

  if [[ $context == proj ]]; then
    balamba_state_update '
      .projects |= map(if .id == $pid then
        .tabs |= map(if ($m[.id] // null) != null then .window = $m[.id] else . end)
        else . end)
    ' --arg pid "$pid" --argjson m "$map" >/dev/null 2>&1 || true
  else
    balamba_state_update '
      .projects |= map(if .id == $pid then
        .tasks |= map(if .id == $tid then
          .tabs |= map(if ($m[.id] // null) != null then .window = $m[.id] else . end)
          else . end)
        else . end)
    ' --arg pid "$pid" --arg tid "${context#task:}" --argjson m "$map" \
      >/dev/null 2>&1 || true
  fi

  if [[ -n $active_tab ]]; then
    local neww
    neww=$(jq -r --arg t "$active_tab" '.[$t] // empty' <<<"$map" 2>/dev/null || true)
    if [[ $neww =~ ^[0-9]+$ ]]; then
      balamba_state_update '.active.window = $w' --argjson w "$neww" \
        >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Tab creation
# ---------------------------------------------------------------------------
# Create a tab window for <pid>/<context>.  If do_activate=1 the new window is
# made active.  Sets _TMUX_CREATED_TAB_ID.
_tmux_create_tab() {
  local pid=$1 context=$2 kind=$3 do_activate=${4:-1}
  _tmux_resolve_context "$pid" "$context"
  if ((_TMUX_CTX_MISSING && !_TMUX_ALLOW_MISSING_PATH)); then
    balamba_die "cannot open a tab in $context: path is missing (${_TMUX_CTX_CWD:-<empty>})"
  fi

  local cwd=$_TMUX_CTX_CWD
  [[ -n $cwd && -d $cwd ]] || cwd=$HOME

  local tab_id session="" agent="" label=""
  tab_id=$(balamba_tab_id)
  if [[ $kind == agent ]]; then
    agent=${default_agent:-opencode}
    session=$(balamba_ses_id)
    label=${BALAMBA_AGENT_LABEL[$agent]-$agent}
    [[ -n $label ]] || label=$agent
  fi

  local n name
  if [[ $context == proj ]]; then
    n=$(balamba_state_get \
      '.projects[] | select(.id == $pid) | [.tabs[]? | select(.kind == $k)] | length' \
      --arg pid "$pid" --arg k "$kind" 2>/dev/null || printf '0')
  else
    n=$(balamba_state_get \
      '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | [.tabs[]? | select(.kind == $k)] | length' \
      --arg pid "$pid" --arg tid "${context#task:}" --arg k "$kind" 2>/dev/null || printf '0')
  fi
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if [[ $kind == agent ]]; then
    name="$label $((n + 1))"
  else
    name="shell $((n + 1))"
  fi

  local win placeholder_only=0
  if ! _tmux_session_exists; then
    _tmux_session_new_with_window "$name" "$cwd"
    win=$_TMUX_SESSION_FIRST_WINDOW
  else
    local total placeholders
    total=$(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" -F '#{window_id}' \
      2>/dev/null | wc -l)
    placeholders=$(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
      -F '#{@balamba_placeholder}' 2>/dev/null | grep -cx '1' || true)
    total=${total//[[:space:]]/}
    if [[ $placeholders == 1 && $total == 1 ]]; then
      placeholder_only=1
    fi
    win=$(_tmux new-window -d -P -F '#{window_id}' -t "$_BALAMBA_TMUX_SESSION:" \
      -n "$name" -c "$cwd" 'sleep 300' 2>/dev/null) || \
      balamba_die "could not create a tmux window for tab $tab_id"
    if ((placeholder_only)); then
      _tmux_kill_placeholder
      local cur
      cur=$(_tmux display -p -t "$win" '#{window_index}' 2>/dev/null || true)
      if [[ -n $cur && $cur != 0 ]]; then
        _tmux move-window -s "$win" -t "$_BALAMBA_TMUX_SESSION:0" \
          >/dev/null 2>&1 || true
      fi
    fi
  fi

  _tmux set-option -w -t "$win" @balamba_tab "$tab_id" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_context "$context" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_project "$pid" >/dev/null 2>&1 || true
  _tmux set-option -w -t "$win" @balamba_placeholder '' >/dev/null 2>&1 || true

  local launched
  if [[ $kind == agent ]]; then launched=agent; else launched=shell; fi

  _FW_CONTENT_COUNT=1
  _FW_LAYOUT=""
  _FW_ACTIVE_PANE=0
  _FW_CWDS=("$cwd")
  _FW_LAUNCHED=("$launched")
  _FW_AGENT=$agent
  _FW_SESSION=$session
  _FW_RESUME=0
  _tmux_fill_window "$win" >/dev/null 2>&1 || true

  local final_index layout
  final_index=$(_tmux display -p -t "$win" '#{window_index}' 2>/dev/null || printf '0')
  layout=$(_tmux display -p -t "$win" '#{window_layout}' 2>/dev/null || true)

  local tab_json pane_name
  if [[ $kind == agent ]]; then
    pane_name=${label:-$agent}
    tab_json=$(jq -nc \
      --arg id "$tab_id" --arg name "$name" --arg agent "$agent" \
      --arg session "$session" --argjson window "$final_index" \
      --arg layout "$layout" --arg cwd "$cwd" --arg pname "$pane_name" \
      '{id:$id,name:$name,kind:"agent",agent:$agent,session:$session,
        window:$window,pane_count:1,layout:$layout,active_pane:0,
        panes:[{index:0,cwd:$cwd,launched:"agent",name:$pname,
                live_command:"",active:true}]}')
  else
    pane_name=$(_tmux_pane_label "${SHELL:-/bin/sh}")
    tab_json=$(jq -nc \
      --arg id "$tab_id" --arg name "$name" --argjson window "$final_index" \
      --arg layout "$layout" --arg cwd "$cwd" --arg pname "$pane_name" \
      '{id:$id,name:$name,kind:"shell",agent:null,session:null,
        window:$window,pane_count:1,layout:$layout,active_pane:0,
        panes:[{index:0,cwd:$cwd,launched:"shell",name:$pname,
                live_command:"",active:true}]}')
  fi

  if [[ $context == proj ]]; then
    balamba_state_update '
      .projects |= map(if .id == $pid then .tabs += [$tab] else . end)
    ' --arg pid "$pid" --argjson tab "$tab_json" || return 2
  else
    balamba_state_update '
      .projects |= map(if .id == $pid then
        .tasks |= map(if .id == $tid then .tabs += [$tab] else . end)
        else . end)
    ' --arg pid "$pid" --arg tid "${context#task:}" --argjson tab "$tab_json" || return 2
  fi

  _TMUX_CREATED_TAB_ID=$tab_id
  _TMUX_CREATED_WINDOW_INDEX=$final_index

  if ((do_activate)); then
    tmux_activate "$pid" "$context" "$final_index" >/dev/null 2>&1 || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 10.5 tmux_open_tab
# ---------------------------------------------------------------------------
tmux_open_tab() {
  (($# == 3)) || balamba_die "usage: tmux_open_tab <project-id> <context> <shell|agent>"
  local pid=$1 context=$2 kind=$3
  case $kind in
    shell|agent) ;;
    *) balamba_warn "kind must be 'shell' or 'agent' (got '$kind')"; return 1 ;;
  esac
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  tmux_server_up

  _TMUX_CREATED_TAB_ID=""
  _tmux_create_tab "$pid" "$context" "$kind" 1 || {
    balamba_warn "could not open a tab in $context"
    return 2
  }
  printf '%s\n' "$_TMUX_CREATED_TAB_ID"
  return 0
}

# ---------------------------------------------------------------------------
# 10.4 tmux_build_context
# ---------------------------------------------------------------------------
_tmux_build_context_windows() {
  local pid=$1 context=$2
  local -a rows=()
  local b64 json tab_id win
  mapfile -t rows < <(_tmux_context_tabs_b64 "$pid" "$context")
  local count=0
  for b64 in "${rows[@]}"; do
    [[ -n $b64 ]] || continue
    json=$(_tmux_state_b64_decode "$b64")
    [[ -n $json ]] || continue
    tab_id=$(jq -r '.id // ""' <<<"$json")
    [[ -n $tab_id ]] || continue
    count=$((count + 1))
    if _tmux_window_id_for_tab "$tab_id" >/dev/null; then
      continue
    fi
    _tmux_build_window_for_tab "$json" "$context" "$pid" || \
      balamba_warn "could not rebuild tab $tab_id"
  done

  if ((count == 0)); then
    # Empty context: exactly one shell tab on first activation.  A project
    # whose checkout disappeared can still show an empty workspace (cwd=$HOME);
    # explicit open_tab/activate calls are the ones that refuse.
    local _prev_allow=$_TMUX_ALLOW_MISSING_PATH
    _TMUX_ALLOW_MISSING_PATH=1
    if ! _tmux_create_tab "$pid" "$context" shell 0; then
      _TMUX_ALLOW_MISSING_PATH=$_prev_allow
      return 2
    fi
    _TMUX_ALLOW_MISSING_PATH=$_prev_allow
  fi
  return 0
}

# Select the remembered window of a context (or its first tab).
_tmux_select_context_window() {
  local pid=$1 context=$2
  local target="" active_pid active_ctx active_win tabid idx

  active_pid=$(balamba_state_get '.active.project // empty')
  active_ctx=$(balamba_state_get '.active.context // empty')
  active_win=$(balamba_state_get '.active.window // 0')
  if [[ $active_pid == "$pid" && $active_ctx == "$context" && $active_win =~ ^[0-9]+$ ]]; then
    if _tmux_window_exists_index "$active_win"; then
      target=$active_win
    fi
  fi

  if [[ -z $target ]]; then
    local -a rows=()
    local b64 json w
    mapfile -t rows < <(_tmux_context_tabs_b64 "$pid" "$context")
    for b64 in "${rows[@]}"; do
      [[ -n $b64 ]] || continue
      json=$(_tmux_state_b64_decode "$b64")
      tabid=$(jq -r '.id // ""' <<<"$json")
      [[ -n $tabid ]] || continue
      if w=$(_tmux_window_index_for_tab "$tabid"); then
        target=$w
        break
      fi
    done
  fi
  [[ -n $target ]] || return 1

  _tmux_show_window "$target"

  local tabid2 ap
  tabid2=$(_tmux_tab_for_window_index "$target" || true)
  if [[ -n $tabid2 ]]; then
    ap=$(balamba_state_get '
      .projects[] as $p
      | (($p.tabs[]?, ($p.tasks[]? | .tabs[]?)) | select(.id == $t) | .active_pane)[0] // 0
    ' --arg t "$tabid2" 2>/dev/null || true)
    [[ $ap =~ ^[0-9]+$ ]] || ap=0
    local winid
    winid=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:$target" '#{window_id}' \
      2>/dev/null || true)
    [[ -n $winid ]] && _tmux_select_content_pane "$winid" "$ap" >/dev/null 2>&1 || true
  fi
  # Keep state's active.window in step when this is the active context.
  if [[ $active_pid == "$pid" && $active_ctx == "$context" ]]; then
    local live_idx
    live_idx=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:$target" '#{window_index}' \
      2>/dev/null || true)
    if [[ -n $live_idx ]]; then
      balamba_state_update '.active.window = $w' --argjson w "$live_idx" \
        >/dev/null 2>&1 || true
    fi
  fi
  tmux_assert_widths "$_BALAMBA_TMUX_SESSION:$target" >/dev/null 2>&1 || true
  return 0
}

tmux_build_context() {
  (($# == 1)) || balamba_die "usage: tmux_build_context <proj|task:<task-id>>"
  local context=$1
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init

  local pid
  pid=$(_tmux_context_pid "$context")
  [[ -n $pid ]] || balamba_die "unknown context: $context"
  tmux_server_up
  _tmux_resolve_context "$pid" "$context"

  local created=0
  if ! _tmux_session_exists; then
    _tmux_new_placeholder_session
    created=1
  else
    _tmux_apply_server_config || true
  fi

  _tmux_build_context_windows "$pid" "$context" || return 2

  _tmux_kill_placeholder
  if ((created)); then
    _tmux_compact_windows
    _tmux_update_context_windows "$pid" "$context"
  fi

  _tmux_select_context_window "$pid" "$context" || true
  return 0
}

# ---------------------------------------------------------------------------
# 10.3 tmux_ensure_session
# ---------------------------------------------------------------------------
tmux_ensure_session() {
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  tmux_server_up

  local created=0 pid context
  pid=$(_tmux_context_pid proj)
  if [[ -n $pid ]]; then
    context=$(balamba_state_get '.active.context // "proj"')
    # The active context must belong to the active project; otherwise fall
    # back to its project context.
    if [[ $context == task:* ]]; then
      if [[ $(_tmux_context_pid "$context") != "$pid" ]]; then
        context=proj
      fi
    elif [[ $context != proj ]]; then
      context=proj
    fi
  fi

  if ! _tmux_session_exists; then
    _tmux_new_placeholder_session
    created=1
  else
    _tmux_apply_server_config || true
  fi

  if [[ -n $pid ]]; then
    [[ -n $context ]] || context=proj
    _tmux_build_context_windows "$pid" "$context" || return 2
    _tmux_kill_placeholder
    if ((created)); then
      _tmux_compact_windows
      _tmux_update_context_windows "$pid" "$context"
    fi
    _tmux_select_context_window "$pid" "$context" || true
    _tmux_set_global_context "$pid" "$context"
  else
    # No projects: keep the empty placeholder UI.
    _tmux set-option -g @balamba_context '' >/dev/null 2>&1 || true
    _tmux set-option -g @balamba_git_branch '' >/dev/null 2>&1 || true
    tmux_assert_widths >/dev/null 2>&1 || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 10.9 tmux_activate
# ---------------------------------------------------------------------------
tmux_activate() {
  (($# == 2 || $# == 3)) || \
    balamba_die "usage: tmux_activate <project-id> <proj|task:<task-id>> [window]"
  local pid=$1 context=$2 requested=${3-}
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  _tmux_resolve_context "$pid" "$context"
  if ((_TMUX_CTX_MISSING)); then
    balamba_die "cannot activate $context: path is missing (${_TMUX_CTX_CWD:-<empty>})"
  fi
  tmux_server_up

  local created=0
  if ! _tmux_session_exists; then
    _tmux_new_placeholder_session
    created=1
  else
    _tmux_apply_server_config || true
  fi

  _tmux_build_context_windows "$pid" "$context" || return 2
  _tmux_kill_placeholder
  if ((created)); then
    _tmux_compact_windows
    _tmux_update_context_windows "$pid" "$context"
  fi

  local target=""
  if [[ -n $requested ]]; then
    if [[ $requested =~ ^[0-9]+$ ]] && _tmux_window_exists_index "$requested"; then
      local rpid rctx
      rpid=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:$requested" '#{@balamba_project}' \
        2>/dev/null || true)
      rctx=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:$requested" '#{@balamba_context}' \
        2>/dev/null || true)
      if [[ $rpid == "$pid" && $rctx == "$context" ]]; then
        target=$requested
      fi
    fi
  fi
  if [[ -z $target ]]; then
    local active_pid active_ctx active_win
    active_pid=$(balamba_state_get '.active.project // empty')
    active_ctx=$(balamba_state_get '.active.context // empty')
    active_win=$(balamba_state_get '.active.window // 0')
    if [[ $active_pid == "$pid" && $active_ctx == "$context" &&
      $active_win =~ ^[0-9]+$ ]] && _tmux_window_exists_index "$active_win"; then
      target=$active_win
    fi
  fi
  if [[ -z $target ]]; then
    # First live window of this context, in state order.
    local -a rows=()
    local b64 json tabid w
    mapfile -t rows < <(_tmux_context_tabs_b64 "$pid" "$context")
    for b64 in "${rows[@]}"; do
      [[ -n $b64 ]] || continue
      json=$(_tmux_state_b64_decode "$b64")
      tabid=$(jq -r '.id // ""' <<<"$json")
      [[ -n $tabid ]] || continue
      if w=$(_tmux_window_index_for_tab "$tabid"); then
        target=$w
        break
      fi
    done
  fi
  [[ -n $target ]] || balamba_die "context $context has no window"

  balamba_state_update '
    .active.project = $pid | .active.context = $context | .active.window = $window
  ' --arg pid "$pid" --arg context "$context" --argjson window "$target"

  _tmux_set_global_context "$pid" "$context" "$_TMUX_CTX_BRANCH"
  _tmux_show_window "$target"

  local tabid ap winid
  tabid=$(_tmux_tab_for_window_index "$target" || true)
  if [[ -n $tabid ]]; then
    ap=$(balamba_state_get '
      .projects[] as $p
      | (($p.tabs[]?, ($p.tasks[]? | .tabs[]?)) | select(.id == $t) | .active_pane)[0] // 0
    ' --arg t "$tabid" 2>/dev/null || true)
    [[ $ap =~ ^[0-9]+$ ]] || ap=0
    winid=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:$target" '#{window_id}' \
      2>/dev/null || true)
    [[ -n $winid ]] && _tmux_select_content_pane "$winid" "$ap" >/dev/null 2>&1 || true
  fi
  tmux_assert_widths "$_BALAMBA_TMUX_SESSION:$target" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# 10.7 tmux_assert_widths
# ---------------------------------------------------------------------------
tmux_assert_widths() {
  local target=${1-}
  balamba_config_load >/dev/null 2>&1 || true
  local tw=${tree_width:-30}
  local gw=${git_width:-34}
  [[ $tw =~ ^[0-9]+$ ]] || tw=30
  [[ $gw =~ ^[0-9]+$ ]] || gw=34
  _tmux_server_responsive || return 0

  local -a rows=()
  local row pane chrome
  if [[ -n $target ]]; then
    mapfile -t rows < <(_tmux list-panes -t "$target" \
      -F $'#{pane_id}\t#{@balamba_chrome}' 2>/dev/null || true)
  elif [[ -n ${TMUX_PANE:-} ]]; then
    mapfile -t rows < <(_tmux list-panes -t "$TMUX_PANE" \
      -F $'#{pane_id}\t#{@balamba_chrome}' 2>/dev/null || true)
  else
    mapfile -t rows < <(_tmux list-panes -t "$_BALAMBA_TMUX_SESSION:" \
      -F $'#{pane_id}\t#{@balamba_chrome}' 2>/dev/null || true)
  fi

  local tree_pane="" git_pane=""
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r pane chrome <<<"$row"
    case $chrome in
      tree) tree_pane=$pane ;;
      git) git_pane=$pane ;;
      *) continue ;;
    esac
    # An explicit width assertion (attach/activation) is also the moment to
    # give a previously failing chrome pane another chance.
    _tmux set-option -p -t "$pane" @balamba_chrome_attempts 0 >/dev/null 2>&1 || true
  done
  [[ -n $tree_pane || -n $git_pane ]] || return 0

  [[ -n $tree_pane ]] && \
    _tmux resize-pane -t "$tree_pane" -x "$tw" >/dev/null 2>&1 || true
  [[ -n $git_pane ]] && \
    _tmux resize-pane -t "$git_pane" -x "$gw" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# 10.8 tmux_save_runtime
# ---------------------------------------------------------------------------
tmux_save_runtime() {
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  _tmux_session_exists || return 0

  # One reconciliation path for manual splits, adopted panes and closed
  # windows.  It is debounced internally, so calling save on detach/poll is
  # cheap when nothing changed.
  tmux_sync_panes || return 2

  local -a win_rows=()
  local row widx winid wname wtab wctx
  mapfile -t win_rows < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_index}\t#{window_id}\t#{window_name}\t#{@balamba_context}\t#{@balamba_tab}' \
    2>/dev/null || true)

  # Current window: our own pane when inside a pane, else the session's
  # current window (set by select-window even while detached).
  local current_index=""
  if [[ -n ${TMUX_PANE:-} ]]; then
    current_index=$(_tmux display -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null || true)
  fi
  if [[ -z $current_index ]]; then
    current_index=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:" '#{window_index}' \
      2>/dev/null || true)
  fi

  local active_json='null'
  if [[ $current_index =~ ^[0-9]+$ ]]; then
    local cur_tab=""
    for row in "${win_rows[@]}"; do
      IFS=$'\t' read -r widx winid wname wctx wtab <<<"$row"
      if [[ $widx == "$current_index" && -n $wtab ]]; then
        cur_tab=$wtab
        break
      fi
    done
    if [[ -n $cur_tab ]]; then
      local owner owner_pid owner_ctx
      owner=$(_tmux_tab_owner "$cur_tab")
      if [[ -n $owner ]]; then
        IFS=$'\t' read -r owner_pid owner_ctx <<<"$owner"
        active_json=$(jq -nc \
          --arg project "$owner_pid" --arg context "$owner_ctx" \
          --argjson window "$current_index" \
          '{project:$project,context:$context,window:$window}')
      fi
    fi
  fi

  if [[ $active_json != null ]]; then
    balamba_state_update '
      .active.project = $active.project
      | .active.context = $active.context
      | .active.window = $active.window
    ' --argjson active "$active_json"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 10.2 tmux_attach
# ---------------------------------------------------------------------------
tmux_attach() {
  (($# == 0)) || balamba_die "usage: tmux_attach"
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  if [[ -z ${TMUX:-} && ! -t 0 && ! -t 1 ]]; then
    # Headless invocation (cron, tests, a pipe): there is nothing to attach,
    # and building a workspace only to throw it away would be misleading.
    balamba_warn "attach is not available without an interactive terminal"
    return 2
  fi
  tmux_server_up

  if _tmux_session_exists; then
    tmux_ensure_session
  else
    tmux_restore
  fi

  local rc=0
  if [[ -n ${TMUX:-} ]] && \
    [[ -n $(_tmux list-clients -F '#{client_name}' 2>/dev/null | head -n1 || true) ]]; then
    _tmux switch-client -t "$_BALAMBA_TMUX_SESSION" || rc=$?
  else
    _tmux attach-session -t "$_BALAMBA_TMUX_SESSION" || rc=$?
  fi

  # The client size is known now; tmux rescales each window layout on attach.
  local cur
  cur=$(_tmux display -p -t "$_BALAMBA_TMUX_SESSION:" '#{window_index}' 2>/dev/null || true)
  if [[ -n $cur ]]; then
    tmux_assert_widths "$_BALAMBA_TMUX_SESSION:$cur" >/dev/null 2>&1 || true
  else
    tmux_assert_widths >/dev/null 2>&1 || true
  fi
  if ((rc != 0)); then
    balamba_warn "could not attach to the balamba tmux session"
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Optional removal helpers (called by bin/balamba / part 5)
# ---------------------------------------------------------------------------
_tmux_kill_windows_matching() {
  local field=$1 value=$2
  _tmux_session_exists || return 0
  local -a rows=()
  local row widx winid val
  mapfile -t rows < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_index}\t#{window_id}\t'"#{${field}}" 2>/dev/null || true)
  local -a ids=()
  local total=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r widx winid val <<<"$row"
    total=$((total + 1))
    if [[ $val == "$value" ]]; then
      ids+=("$winid")
    fi
  done
  ((${#ids[@]})) || return 0

  # Never let removing the last window take the session/server down.
  if ((${#ids[@]} == total)); then
    _tmux_new_placeholder_window >/dev/null 2>&1 || true
  fi
  local id
  for id in "${ids[@]}"; do
    _tmux kill-window -t "$id" >/dev/null 2>&1 || true
  done
  return 0
}

tmux_remove_context() {
  (($# == 2)) || balamba_die "usage: tmux_remove_context <project-id> <context>"
  balamba_config_load >/dev/null 2>&1 || true
  local pid=$1 context=$2
  _tmux_session_exists || return 0
  local -a rows=()
  local row winid wpid wctx
  mapfile -t rows < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_id}\t#{@balamba_project}\t#{@balamba_context}' \
    2>/dev/null || true)
  local -a ids=()
  local total=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r winid wpid wctx <<<"$row"
    total=$((total + 1))
    if [[ $wpid == "$pid" && $wctx == "$context" ]]; then
      ids+=("$winid")
    fi
  done
  ((${#ids[@]})) || return 0
  if ((${#ids[@]} == total)); then
    _tmux_new_placeholder_window >/dev/null 2>&1 || true
  fi
  local id
  for id in "${ids[@]}"; do
    _tmux kill-window -t "$id" >/dev/null 2>&1 || true
  done
  return 0
}

tmux_remove_project() {
  (($# == 1)) || balamba_die "usage: tmux_remove_project <project-id>"
  balamba_config_load >/dev/null 2>&1 || true
  _tmux_session_exists || return 0
  _tmux_kill_windows_matching @balamba_project "$1"
  return 0
}

# ---------------------------------------------------------------------------
# 10.6 tmux_restore
# ---------------------------------------------------------------------------
# Reconciliation policy: tasks whose worktree path is no longer a directory
# are dropped from state (with a warning), matching architecture.md §5.2.
# Unknown directories are never adopted.  A missing project checkout is only
# warned about: its tabs fall back to $HOME so the rest of the workspace still
# restores.
_tmux_reconcile_state() {
  local -a task_rows=()
  mapfile -t task_rows < <(balamba_state_get '
    [ .projects[] | .id as $p | .tasks[]?
      | {pid:$p, tid:.id, path:.path} ] | .[] | @base64' 2>/dev/null || true)

  local -a missing=()
  local b64 obj tid path
  for b64 in "${task_rows[@]}"; do
    [[ -n $b64 ]] || continue
    obj=$(_tmux_state_b64_decode "$b64")
    [[ -n $obj ]] || continue
    tid=$(jq -r '.tid // ""' <<<"$obj")
    path=$(jq -r '.path // ""' <<<"$obj")
    [[ -n $tid ]] || continue
    if [[ -z $path || ! -d $path ]]; then
      balamba_warn "task $tid has no worktree at ${path:-<empty>}; dropping it from state"
      missing+=("$tid")
    fi
  done

  # Warn (but keep) projects whose checkout is gone.
  local -a project_rows=()
  mapfile -t project_rows < <(balamba_state_get '
    [ .projects[] | {id:.id, path:.path} ] | .[] | @base64' 2>/dev/null || true)
  local pid ppath
  for b64 in "${project_rows[@]}"; do
    [[ -n $b64 ]] || continue
    obj=$(_tmux_state_b64_decode "$b64")
    pid=$(jq -r '.id // ""' <<<"$obj")
    ppath=$(jq -r '.path // ""' <<<"$obj")
    if [[ -n $ppath && ! -d $ppath ]]; then
      balamba_warn "project $pid path is missing: $ppath"
    fi
  done

  ((${#missing[@]})) || return 0
  local missing_json
  missing_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)
  balamba_state_update '
    .projects |= map(.tasks |= map(select(.id as $t | $missing | index($t) | not)))
    | if ((.active.context // "") | startswith("task:"))
        and (.active.context[5:] as $t | ($missing | index($t)) != null)
      then .active.context = "proj" | .active.window = 0
      else . end
  ' --argjson missing "$missing_json" || return 2
  return 0
}

tmux_restore() {
  (($# == 0)) || balamba_die "usage: tmux_restore"
  balamba_config_load || balamba_die "could not load config: $BALAMBA_CONFIG"
  balamba_state_init
  balamba_state_validate >/dev/null 2>&1 || \
    balamba_die "state is corrupt or invalid: $BALAMBA_STATE (refusing to rebuild tmux from it)"

  _tmux_reconcile_state || return 2

  tmux_server_up

  if _tmux_session_exists; then
    # Restore is for a dead server; never duplicate a live workspace.
    tmux_ensure_session
    return 0
  fi

  # Collect every saved tab before touching tmux so a corrupt window map
  # fails loudly instead of half-building.
  local -a all_b64=()
  mapfile -t all_b64 < <(_tmux_all_tabs_b64)

  local -a saved_indices=()
  local b64 json saved
  for b64 in "${all_b64[@]}"; do
    [[ -n $b64 ]] || continue
    json=$(_tmux_state_b64_decode "$b64")
    saved=$(jq -r '.tab.window // -1' <<<"$json")
    [[ $saved =~ ^[0-9]+$ ]] || \
      balamba_die "state has a tab with an invalid window index: ${saved}"
    saved_indices+=("$saved")
  done

  if ((${#saved_indices[@]})); then
    local duplicates
    duplicates=$(printf '%s\n' "${saved_indices[@]}" | sort -n | uniq -d | head -n1)
    if [[ -n $duplicates ]]; then
      balamba_die "state has more than one tab in window $duplicates; refusing to rebuild tmux from it"
    fi
  fi

  _tmux_new_placeholder_session
  _TMUX_STAGGER_SECS=$(_tmux_restore_stagger)
  _TMUX_AGENT_LAUNCHES=0

  if ((${#all_b64[@]} == 0)); then
    # Nothing saved: keep the placeholder (empty tree + git panes).
    _tmux set-option -g @balamba_context '' >/dev/null 2>&1 || true
    _tmux set-option -g @balamba_git_branch '' >/dev/null 2>&1 || true
    tmux_assert_widths >/dev/null 2>&1 || true
    return 0
  fi

  local -a built_pairs=()
  local pid context tab_id win
  for b64 in "${all_b64[@]}"; do
    [[ -n $b64 ]] || continue
    json=$(_tmux_state_b64_decode "$b64")
    [[ -n $json ]] || continue
    pid=$(jq -r '.pid // ""' <<<"$json")
    context=$(jq -r '.context // "proj"' <<<"$json")
    saved=$(jq -r '.tab.window // -1' <<<"$json")
    tab_id=$(jq -r '.tab.id // ""' <<<"$json")
    [[ -n $pid && -n $tab_id ]] || continue
    local tab_json
    tab_json=$(jq -c '.tab' <<<"$json")
    if _tmux_build_window_for_tab "$tab_json" "$context" "$pid" >/dev/null 2>&1; then
      built_pairs+=("$saved"$'\t'"$_TMUX_BUILT_WINDOW_ID")
    else
      balamba_warn "could not restore tab $tab_id"
    fi
  done

  if ((${#built_pairs[@]} == 0)); then
    # Nothing could be rebuilt (all worktrees vanished): keep the empty
    # placeholder rather than leaving a windowless session.
    balamba_warn "no saved tab could be restored; keeping an empty workspace"
    return 0
  fi

  _tmux_kill_placeholder
  _tmux_compact_windows

  # Move windows to their exact saved indices, descending (spike risk 3).
  # After compaction every window is in 0..N-1, so saved targets are free in
  # descending order.
  if ((${#built_pairs[@]})); then
    local pair
    while IFS= read -r pair; do
      [[ -n $pair ]] || continue
      IFS=$'\t' read -r saved win <<<"$pair"
      local cur
      cur=$(_tmux display -p -t "$win" '#{window_index}' 2>/dev/null || true)
      if [[ -n $cur && $cur != "$saved" ]]; then
        if ! _tmux move-window -s "$win" -t "$_BALAMBA_TMUX_SESSION:$saved" \
          >/dev/null 2>&1; then
          balamba_warn "could not move restored window $win to index $saved"
        fi
      fi
    done < <(printf '%s\n' "${built_pairs[@]}" | sort -t $'\t' -k1,1nr)
  fi

  # Choose the active window: the saved active tab when possible, else the
  # first tab of the active context, else any restored window.
  local active_pid active_ctx active_win target="" selected_ctx="" selected_pid=""
  active_pid=$(balamba_state_get '.active.project // empty')
  active_ctx=$(balamba_state_get '.active.context // empty')
  active_win=$(balamba_state_get '.active.window // 0')

  # First pass: the exact saved active window (project + context + index).
  local pair2 swin wpid wctx wsaved
  while IFS=$'\t' read -r swin wpid wctx wsaved; do
    [[ -n $swin ]] || continue
    if [[ $wpid == "$active_pid" && $wctx == "$active_ctx" &&
      $wsaved == "$active_win" ]]; then
      target=$swin
      selected_ctx=$wctx
      selected_pid=$wpid
      break
    fi
  done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
    -F $'#{window_id}\t#{@balamba_project}\t#{@balamba_context}\t#{window_index}' \
    2>/dev/null || true)

  # Second pass: first restored window of the active context.
  if [[ -z $target ]]; then
    while IFS=$'\t' read -r swin wpid wctx wsaved; do
      [[ -n $swin ]] || continue
      if [[ $wpid == "$active_pid" && $wctx == "$active_ctx" ]]; then
        target=$swin
        selected_ctx=$wctx
        selected_pid=$wpid
        break
      fi
    done < <(_tmux list-windows -t "$_BALAMBA_TMUX_SESSION" \
      -F $'#{window_id}\t#{@balamba_project}\t#{@balamba_context}\t#{window_index}' \
      2>/dev/null || true)
  fi

  # Last resort: any restored window, preferring a saved tab over chrome-only.
  if [[ -z $target ]]; then
    local first_saved_wid _first_saved
    IFS=$'\t' read -r _first_saved first_saved_wid <<<"${built_pairs[0]}"
    target=$first_saved_wid
    selected_pid=$(_tmux display -p -t "$target" '#{@balamba_project}' 2>/dev/null || true)
    selected_ctx=$(_tmux display -p -t "$target" '#{@balamba_context}' 2>/dev/null || true)
  fi

  if [[ -n $target ]]; then
    local tidx
    tidx=$(_tmux display -p -t "$target" '#{window_index}' 2>/dev/null || true)
    if [[ -n $tidx ]]; then
      _tmux select-window -t "$_BALAMBA_TMUX_SESSION:$tidx" >/dev/null 2>&1 || true
      if [[ -n $selected_pid && -n $selected_ctx ]]; then
        _tmux_set_global_context "$selected_pid" "$selected_ctx"
        balamba_state_update '
          .active.project = $p | .active.context = $c | .active.window = $w
        ' --arg p "$selected_pid" --arg c "$selected_ctx" --argjson w "$tidx" \
          >/dev/null 2>&1 || true
      else
        _tmux set-option -g @balamba_context "$active_ctx" >/dev/null 2>&1 || true
        if [[ -n $active_pid && -n $active_ctx ]]; then
          _tmux_set_global_context "$active_pid" "$active_ctx"
        fi
      fi
      tmux_assert_widths "$target" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

_tmux_restore_stagger() {
  local s=${restore_stagger:-${BALAMBA_RESTORE_STAGGER:-1}}
  [[ $s =~ ^[0-9]+$ ]] || s=1
  ((s > 60)) && s=60
  printf '%s\n' "$s"
}
