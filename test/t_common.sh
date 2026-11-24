#!/usr/bin/env bash
# Tests for lib/common.sh and the part-2 CLI surface.

set -Eeuo pipefail

# shellcheck source=helpers.sh
. "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=../lib/common.sh
. "$BALAMBA_ROOT/lib/common.sh"

# Everything below must start from a clean slate.
rm -rf -- "$BALAMBA_STATE" "$BALAMBA_RUNTIME" "$BALAMBA_CONFIG"
unset EDITOR VISUAL

# ---------------------------------------------------------------------------
# slugify
# ---------------------------------------------------------------------------
assert_eq "fix-login" "$(balamba_slugify 'Fix login')" "slug: spaces to dashes"
assert_eq "fix-login" "$(balamba_slugify '  Fix   Login  ')" "slug: trims and collapses whitespace"
assert_eq "foo-bar" "$(balamba_slugify 'foo---bar')" "slug: collapses dash runs"
assert_eq "foo" "$(balamba_slugify '-foo-')" "slug: trims leading/trailing dashes"
assert_eq "hello-world" "$(balamba_slugify 'Hello, World!')" "slug: strips punctuation"
assert_eq "caf" "$(balamba_slugify 'Café')" "slug: strips non-ASCII"
assert_eq "" "$(balamba_slugify '---')" "slug: all-dashes becomes empty"
assert_eq "a.b_c-d" "$(balamba_slugify 'a.b_c-d')" "slug: keeps [a-z0-9._-]"
assert_eq "upper_case" "$(balamba_slugify 'UPPER_case')" "slug: lowercases ASCII"
assert_eq "fixlogin" "$(balamba_slugify '!!Fix@@Login!!')" "slug: strips other punctuation"

# ---------------------------------------------------------------------------
# id helpers
# ---------------------------------------------------------------------------
local_ses=$(balamba_ses_id)
assert_match '^ses_[0-9a-f]{32}$' "$local_ses" "ses id: ses_ + 32 lowercase hex"
assert_ne "$local_ses" "$(balamba_ses_id)" "ses id: ids are unique"
assert_match '^[0-9a-f]{32}$' "$(balamba_uuid)" "uuid: 32 lowercase hex"
assert_match '^tty_[0-9a-f]{8}$' "$(balamba_tab_id)" "tab id: tty_ + 8 hex"
assert_eq "p_my-project" "$(balamba_project_id /tmp/my-project)" "project id: p_ + basename"
assert_eq "t_fix-login" "$(balamba_task_id fix-login)" "task id: t_ + slug"
unset local_ses

# ---------------------------------------------------------------------------
# state: init, get, update, validation
# ---------------------------------------------------------------------------
balamba_state_init
assert_status 0 "state: init produces a valid file" balamba_state_validate
assert_eq "1" "$(balamba_state_get '.version')" "state: version is 1"
assert_eq "0" "$(balamba_state_get '.projects | length')" "state: projects start empty"
assert_eq "null" "$(balamba_state_get '.active.project')" "state: no active project"
assert_eq "0" "$(balamba_state_get '.active.window')" "state: active window defaults to 0"

p_one=$(jq -nc '{id:"p_one",name:"one",path:"/tmp/one",expanded:true,tabs:[],tasks:[]}')
assert_status 0 "state: update adds a project" \
  balamba_state_update '.projects += [$p]' --argjson p "$p_one"
assert_eq "1" "$(balamba_state_get '.projects | length')" "state: project landed"
assert_eq "p_one" "$(balamba_state_get '.projects[0].id')" "state: get reads updated value"

# concurrent writers must both land
p_two=$(jq -nc '{id:"p_two",name:"two",path:"/tmp/two",expanded:false,tabs:[],tasks:[]}')
p_three=$(jq -nc '{id:"p_three",name:"three",path:"/tmp/three",expanded:false,tabs:[],tasks:[]}')
( balamba_state_update '.projects += [$p]' --argjson p "$p_two" ) >/dev/null 2>&1 &
w1=$!
( balamba_state_update '.projects += [$p]' --argjson p "$p_three" ) >/dev/null 2>&1 &
w2=$!
wait "$w1" || true
wait "$w2" || true
assert_eq "3" "$(balamba_state_get '.projects | length')" "state: concurrent updates both landed"
assert_contains "$(balamba_state_get '.projects[].id')" "p_two" "state: concurrent id p_two present"
assert_contains "$(balamba_state_get '.projects[].id')" "p_three" "state: concurrent id p_three present"

# failed expressions must not touch the file
before=$(jq -S . "$BALAMBA_STATE")
assert_status 2 "state: invalid jq expression fails" balamba_state_update '.projects |= '
after=$(jq -S . "$BALAMBA_STATE")
assert_eq "$before" "$after" "state: invalid jq leaves the state byte-equivalent"

before=$(jq -S . "$BALAMBA_STATE")
assert_status 2 "state: schema-invalid update fails" balamba_state_update '.version = 2'
after=$(jq -S . "$BALAMBA_STATE")
assert_eq "$before" "$after" "state: schema failure leaves state unchanged"
assert_eq "1" "$(balamba_state_get '.version')" "state: version still 1"

# update bootstraps a missing state file
rm -f -- "$BALAMBA_STATE"
assert_status 0 "state: update creates a missing state" balamba_state_update '.active.window = 2'
assert_eq "2" "$(balamba_state_get '.active.window')" "state: missing-state update landed"

assert_status 0 "state: state_set alias works" balamba_state_set '.active.window = 3'
assert_eq "3" "$(balamba_state_get '.active.window')" "state: state_set alias landed"

bad_state=$(new_tmpdir)/bad.json
printf '{"version":2,"active":{},"projects":[]}\n' >"$bad_state"
assert_status 2 "state: validate rejects a wrong version" balamba_state_validate "$bad_state"
printf 'not json\n' >"$bad_state"
assert_status 2 "state: validate rejects malformed JSON" balamba_state_validate "$bad_state"
printf '{"version":1,"active":{"project":null,"context":null,"window":0},"projects":[]}\n' >"$bad_state"
assert_status 0 "state: validate accepts a minimal valid file" balamba_state_validate "$bad_state"

# ---------------------------------------------------------------------------
# git fixture factory (used by later parts' tests, sanity-checked here)
# ---------------------------------------------------------------------------
fixture_repo=$(make_git_repo "$(new_tmpdir)/repo" origin)
assert_eq "main" "$(git -C "$fixture_repo" rev-parse --abbrev-ref HEAD)" \
  "fixtures: repo is on main"
assert_eq "$fixture_repo" "$(git -C "$fixture_repo" rev-parse --show-toplevel)" \
  "fixtures: repo path is its toplevel"
assert_ok "fixtures: origin/main exists" git -C "$fixture_repo" rev-parse --verify origin/main

# ---------------------------------------------------------------------------
# config: defaults and overrides
# ---------------------------------------------------------------------------
balamba_config_load
assert_eq "30" "$tree_width" "config: default tree_width"
assert_eq "34" "$git_width" "config: default git_width"
assert_eq "1" "$active_refresh" "config: default active_refresh"
assert_eq "5" "$idle_refresh" "config: default idle_refresh"
assert_eq "2" "$git_refresh" "config: default git_refresh"
assert_eq "vi" "$editor" "config: default editor falls back to vi"
assert_eq "origin/main" "$default_ref" "config: default_ref"
assert_eq "opencode" "$default_agent" "config: default agent"
assert_eq "1" "$restore_stagger" "config: default restore_stagger"
assert_eq "opencode --session {{session}}" \
  "${BALAMBA_AGENT_COMMAND[opencode]-}" "config: opencode command template"
assert_eq "opencode --session {{session}}" \
  "${BALAMBA_AGENT_RESUME[opencode]-}" "config: opencode resume template"
assert_status 0 "config: defaults validate" balamba_config_validate

mkdir -p -- "$(dirname -- "$BALAMBA_CONFIG")"
cat >"$BALAMBA_CONFIG" <<'CFG'
tree_width=45
git_width=25
active_refresh=2
idle_refresh=7
git_refresh=3
editor=nano
default_ref=main
default_agent=custom
BALAMBA_AGENT_COMMAND[custom]='custom --session {{session}}'
BALAMBA_AGENT_RESUME[custom]='custom --resume {{session}}'
BALAMBA_AGENT_LABEL[custom]='custom'
CFG
balamba_config_load
assert_eq "45" "$tree_width" "config: override tree_width"
assert_eq "25" "$git_width" "config: override git_width"
assert_eq "nano" "$editor" "config: override editor"
assert_eq "main" "$default_ref" "config: override default_ref"
assert_eq "custom" "$default_agent" "config: override default_agent"
assert_eq "custom --resume {{session}}" \
  "${BALAMBA_AGENT_RESUME[custom]-}" "config: custom agent resume template"
assert_status 0 "config: overrides validate" balamba_config_validate

printf 'tree_width=wide\n' >"$BALAMBA_CONFIG"
assert_status 2 "config: non-numeric width is rejected" balamba_config_validate
printf 'restore_stagger=lots\n' >"$BALAMBA_CONFIG"
assert_status 2 "config: non-numeric restore_stagger is rejected" balamba_config_validate
printf 'restore_stagger=99\n' >"$BALAMBA_CONFIG"
assert_status 2 "config: restore_stagger above 60 is rejected" balamba_config_validate
printf 'tree_width=wide\n' >"$BALAMBA_CONFIG"
bad_doctor_out=""
bad_doctor_rc=0
bad_doctor_out=$("$BALAMBA_BIN" doctor 2>&1) || bad_doctor_rc=$?
assert_eq "2" "$bad_doctor_rc" "doctor: invalid config is a hard failure"
assert_contains "$bad_doctor_out" "config" "doctor: invalid config is reported"

printf 'tree_width=30\nthis is not bash((\n' >"$BALAMBA_CONFIG"
assert_status 2 "config: syntax error is rejected" balamba_config_validate

rm -f -- "$BALAMBA_CONFIG"
balamba_config_load
assert_eq "30" "$tree_width" "config: reload restores defaults"

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
balamba_state_init
doctor_out=""
doctor_rc=0
doctor_out=$("$BALAMBA_BIN" doctor 2>&1) || doctor_rc=$?
assert_eq "0" "$doctor_rc" "doctor: exits 0 when the environment is complete"
assert_contains "$doctor_out" "bash" "doctor: reports bash"
assert_contains "$doctor_out" "tmux" "doctor: reports tmux"
assert_contains "$doctor_out" "python3" "doctor: reports python3"
assert_contains "$doctor_out" "jq" "doctor: reports jq"
assert_contains "$doctor_out" "git" "doctor: reports git"
assert_contains "$doctor_out" "state" "doctor: reports state"
assert_contains "$doctor_out" "server" "doctor: reports the server/socket"
if grep -q '^fail' <<<"$doctor_out"; then
  _fail "doctor: no hard failures" "$doctor_out"
else
  _pass "doctor: no hard failures"
fi

# A clean XDG environment with no state/config must still report sensibly.
fresh_root=$(new_tmpdir)
fresh_out=""
fresh_rc=0
fresh_out=$(env -u BALAMBA_CONFIG -u BALAMBA_STATE -u BALAMBA_RUNTIME -u BALAMBA_SOCKET \
  XDG_CONFIG_HOME="$fresh_root/config" \
  XDG_STATE_HOME="$fresh_root/state" \
  "$BALAMBA_BIN" doctor 2>&1) || fresh_rc=$?
assert_eq "0" "$fresh_rc" "doctor: exits 0 with no state or config"
assert_contains "$fresh_out" "not created yet" "doctor: reports missing state without failing"
assert_contains "$fresh_out" "defaults" "doctor: reports default config without failing"
if [[ -e "$fresh_root/state/balamba/state.json" ]]; then
  _fail "doctor: does not create state" "state appeared at $fresh_root/state/balamba/state.json"
else
  _pass "doctor: does not create state"
fi

# ---------------------------------------------------------------------------
# CLI basics
# ---------------------------------------------------------------------------
version_out=$(run_balamba version)
assert_match '^balamba [0-9]+\.[0-9]+\.[0-9]+$' "$version_out" "cli: version format"
assert_status 1 "cli: version rejects arguments" "$BALAMBA_BIN" version extra
assert_status 1 "cli: unknown command is a usage error" "$BALAMBA_BIN" bogus
assert_status 1 "cli: unknown project subcommand is a usage error" "$BALAMBA_BIN" project bogus
assert_status 1 "cli: attach rejects arguments" "$BALAMBA_BIN" attach extra

# A symlinked entry point must resolve the install root from its real path.
link_dir=$(new_tmpdir)
ln -s -- "$BALAMBA_BIN" "$link_dir/balamba"
assert_eq "$version_out" "$("$link_dir/balamba" version)" \
  "cli: symlinked entry point resolves its root"

# list commands work without any git/tmux implementation
list_out=$(run_balamba project list)
assert_contains "$list_out" "no projects" "cli: project list on an empty state"
list_out=$(run_balamba task list)
assert_contains "$list_out" "no tasks" "cli: task list on an empty state"

# missing-implementation behaviour is clear and non-zero
attach_out=""
attach_rc=0
attach_out=$("$BALAMBA_BIN" attach 2>&1) || attach_rc=$?
assert_eq "2" "$attach_rc" "cli: attach without lib/tmux.sh exits 2"
assert_contains "$attach_out" "not available" "cli: attach explains the missing implementation"

# internal verbs that are implemented (state-only) work today
demo_project=$(jq -nc '{
  id:"p_demo", name:"demo", path:"/tmp/demo", expanded:false, tabs:[],
  tasks:[{id:"t_demo",name:"Demo",slug:"demo",path:"/tmp/demo-wt",
          branch:"demo",base_ref:"origin/main",
          created_at:"2026-01-01T00:00:00Z",expanded:false,tabs:[]}]
}')
balamba_state_update \
  '.projects += [$p] | .active.project = "p_demo" | .active.context = "proj"' \
  --argjson p "$demo_project"
assert_ok "internal: expand a project" "$BALAMBA_BIN" internal expand p_demo
assert_eq "true" "$(balamba_state_get '.projects[0].expanded')" "internal: project expanded"
assert_ok "internal: collapse a project" "$BALAMBA_BIN" internal collapse p_demo
assert_eq "false" "$(balamba_state_get '.projects[0].expanded')" "internal: project collapsed"
assert_ok "internal: expand a task" "$BALAMBA_BIN" internal expand p_demo t_demo
assert_eq "true" "$(balamba_state_get '.projects[0].tasks[0].expanded')" "internal: task expanded"
assert_status 2 "internal: unknown project is a state error" \
  "$BALAMBA_BIN" internal expand p_missing
assert_status 2 "internal: new-task without lib/task.sh exits 2" \
  "$BALAMBA_BIN" internal new-task
assert_status 2 "internal: add-project without its flow exits 2" \
  "$BALAMBA_BIN" internal add-project
assert_status 2 "internal: activate without lib/tmux.sh exits 2" \
  "$BALAMBA_BIN" internal activate p_demo proj

# ---------------------------------------------------------------------------
# tmux.conf parses and sets the documented defaults
# ---------------------------------------------------------------------------
if command -v tmux >/dev/null 2>&1; then
  tmux -L "$BALAMBA_SOCKET" kill-server >/dev/null 2>&1 || true
  tmux_started=0
  if tmux -L "$BALAMBA_SOCKET" -f "$BALAMBA_ROOT/tmux.conf" \
    new-session -d -s smoke >/dev/null 2>&1; then
    tmux_started=1
    _pass "tmux.conf: starts a server without errors"
  else
    _fail "tmux.conf: starts a server without errors"
  fi

  if ((tmux_started)); then
    show() { tmux -L "$BALAMBA_SOCKET" show -gv "$1"; }
    assert_eq "C-a" "$(show prefix)" "tmux.conf: prefix is C-a"
    assert_eq "on" "$(show mouse)" "tmux.conf: mouse on"
    assert_eq "on" "$(show monitor-activity)" "tmux.conf: monitor-activity on"
    assert_eq "off" "$(show visual-activity)" "tmux.conf: visual-activity off"
    assert_eq "on" "$(show focus-events)" "tmux.conf: focus-events on"
    assert_eq "latest" "$(show window-size)" "tmux.conf: window-size latest"
    assert_eq "off" "$(show renumber-windows)" "tmux.conf: renumber-windows off"
    assert_eq "0" "$(show base-index)" "tmux.conf: base-index 0"
    assert_eq "50000" "$(show history-limit)" "tmux.conf: history-limit"
    assert_eq "tmux-256color" "$(show default-terminal)" "tmux.conf: default-terminal"
    assert_eq "0" "$(show escape-time)" "tmux.conf: escape-time 0"
    assert_eq "bottom" "$(show status-position)" "tmux.conf: status at the bottom"
    assert_eq "off" "$(show pane-border-status)" "tmux.conf: no pane-border-status"
    assert_eq "30" "$(show @balamba_tree_width)" "tmux.conf: tree width default"
    assert_eq "34" "$(show @balamba_git_width)" "tmux.conf: git width default"
    assert_contains "$(show status-left)" "balamba" "tmux.conf: status-left names balamba"
    assert_contains "$(show window-status-format)" "window_activity_flag" \
      "tmux.conf: activity marker in window format"
    assert_contains "$(show window-status-current-format)" "bold" \
      "tmux.conf: active window is bold"
    assert_contains "$(tmux -L "$BALAMBA_SOCKET" list-keys -T prefix N)" "internal new-task" \
      "tmux.conf: C-a N delegates to internal new-task"
    assert_contains "$(tmux -L "$BALAMBA_SOCKET" list-keys -T prefix P)" "internal add-project" \
      "tmux.conf: C-a P delegates to internal add-project"
    assert_contains "$(tmux -L "$BALAMBA_SOCKET" list-keys -T prefix T)" "internal new-terminal" \
      "tmux.conf: C-a T delegates to internal new-terminal"

    # config mirroring updates live options
    tree_width=37
    git_width=29
    assert_status 0 "tmux: config reflected into options" balamba_config_to_tmux
    assert_eq "37" "$(show @balamba_tree_width)" "tmux: mirrored tree width"
    assert_eq "29" "$(show @balamba_git_width)" "tmux: mirrored git width"
    assert_eq "$BALAMBA_ROOT" "$(show @balamba_root)" "tmux: mirrored install root"

    tmux -L "$BALAMBA_SOCKET" kill-server >/dev/null 2>&1 || true
  fi
else
  _fail "tmux: available for config tests"
fi

finish_tests
