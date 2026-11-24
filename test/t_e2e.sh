#!/usr/bin/env bash
# End-to-end: a real bin/balamba client attached under a pty at 120x40.
#
# Everything runs in the isolated XDG tree and on the throwaway socket created
# by test/helpers.sh.  test/e2e_driver.py owns the pty, drives the actual UI
# (prompts, menus, prefix bindings, tree clicks) and asserts through
# `tmux -L <socket> capture-pane` and tmux queries.
#
# Deliberately skipped here: sending a model message to opencode (token spend).
# Resume identity has unit coverage; the one manual check lives in docs/smoke.md.

set -Eeuo pipefail

# shellcheck source=helpers.sh
. "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CASE=$BALAMBA_TEST_ROOT/e2e
mkdir -p -- "$CASE"

# Only ever touch the test socket, then let the shared helper clean the tree.
e2e_cleanup() {
  if [[ ${BALAMBA_TEST_KEEP:-0} != 1 ]]; then
    tmux -L "${BALAMBA_SOCKET:-balamba}" kill-server >/dev/null 2>&1 || true
  fi
  # Under test/run.sh the shared isolated root is owned by the runner, and
  # removing it here would break every later test file.  Standalone runs use
  # the helper's normal cleanup.
  if [[ ${BALAMBA_TEST_ISOLATED:-0} != 1 ]]; then
    balamba_test_cleanup
  fi
}
trap e2e_cleanup EXIT

REPO=$CASE/proj\ one
make_git_repo "$REPO" origin >/dev/null
export BALAMBA_E2E_REPO=$REPO
export BALAMBA_E2E_CASE=$CASE
export BALAMBA_E2E_TREE_WIDTH=28
export BALAMBA_E2E_GIT_WIDTH=32

export BALAMBA_E2E_DIFF=$CASE/popup.diff
export BALAMBA_E2E_LESS_ARGS=$CASE/popup.args

# A fake pager keeps the diff popup open and records exactly what git produced.
mkdir -p -- "$CASE/bin"
cat >"$CASE/bin/less" <<'EOS'
#!/bin/sh
cat >"${BALAMBA_E2E_DIFF:?}"
printf '%s\n' "$@" >"${BALAMBA_E2E_LESS_ARGS:?}"
cat "${BALAMBA_E2E_DIFF:?}"
sleep 30
EOS
chmod +x "$CASE/bin/less"
export PATH="$CASE/bin:$PATH"

mkdir -p -- "$(dirname -- "$BALAMBA_CONFIG")"
cat >"$BALAMBA_CONFIG" <<'EOF'
tree_width=28
git_width=32
active_refresh=1
idle_refresh=5
git_refresh=2
default_ref=origin/main
restore_stagger=0
editor=vi
EOF

rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock"
rm -rf -- "$BALAMBA_RUNTIME"

E2E_OUT=$CASE/driver.out
rc=0
timeout --signal=TERM --kill-after=5 240 \
  python3 "$TEST_DIR/e2e_driver.py" >"$E2E_OUT" 2>&1 || rc=$?

if ((rc == 0)); then
  _pass "e2e: attached-client journey ($(grep -c '^ok ' "$E2E_OUT" || true) checkpoints)"
else
  _fail "e2e: attached-client journey (exit $rc)" \
    "$(tail -n 60 "$E2E_OUT" 2>/dev/null || true)"
  # The driver prints a screen dump on assertion failure; keep it in the log
  # even when the caller only shows stderr.
  sed -n '1,200p' "$E2E_OUT" >&2 || true
fi

finish_tests
