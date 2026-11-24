#!/usr/bin/env bash
# balamba test helpers: isolated environment, assertions, git fixtures.
#
# Sourced by test/run.sh and by every test/t_*.sh.  It never sources
# lib/common.sh (tests do that explicitly) so run.sh can use the isolation
# helpers without inheriting strict-mode behaviour from the library.

set -Eeuo pipefail

BALAMBA_TEST_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BALAMBA_ROOT=$(cd -P -- "$BALAMBA_TEST_DIR/.." && pwd)
BALAMBA_BIN=$BALAMBA_ROOT/bin/balamba
export BALAMBA_ROOT BALAMBA_BIN

balamba_test_env_init() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/balamba-test.XXXXXX")
  export BALAMBA_TEST_ROOT=$root
  export BALAMBA_TEST_ISOLATED=1

  export HOME="$root/home"
  export XDG_CONFIG_HOME="$root/config"
  export XDG_STATE_HOME="$root/state"
  export XDG_CACHE_HOME="$root/cache"
  export XDG_RUNTIME_DIR="$root/run"
  export BALAMBA_RUNTIME="$root/runtime"
  export BALAMBA_CONFIG="$XDG_CONFIG_HOME/balamba/config"
  export BALAMBA_STATE="$XDG_STATE_HOME/balamba/state.json"
  export BALAMBA_SOCKET="balamba-test-$$"
  export TMUX_TMPDIR="$root/tmux"

  # Make git hermetic: no system/global config, no prompts, no signing.
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$root/gitconfig"
  export GIT_TERMINAL_PROMPT=0

  unset TMUX EDITOR VISUAL BALAMBA_TMUX_CONF BALAMBA_RESTORE_STAGGER 2>/dev/null || true

  mkdir -p -- "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
    "$XDG_RUNTIME_DIR" "$BALAMBA_RUNTIME" "$TMUX_TMPDIR"
  : >"$GIT_CONFIG_GLOBAL"
}

balamba_test_cleanup() {
  local root=${BALAMBA_TEST_ROOT:-}
  [[ -n $root ]] || return 0
  if [[ ${BALAMBA_TEST_KEEP:-0} != 1 ]]; then
    tmux -L "${BALAMBA_SOCKET:-balamba}" kill-server >/dev/null 2>&1 || true
    rm -rf -- "$root"
  fi
}

if [[ ${BALAMBA_TEST_ISOLATED:-0} != 1 ]]; then
  balamba_test_env_init
  trap balamba_test_cleanup EXIT
fi

# ---------------------------------------------------------------------------
# Assertions (TAP-ish; finish_tests sets the process exit status)
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAILED=0

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"
  if [[ -n ${2-} ]]; then
    printf '# %s\n' "$2"
  fi
}

assert_eq() {
  local expected=$1 actual=$2 desc=${3:-values equal}
  if [[ $expected == "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc" "expected: [$(printf '%s' "$expected")] actual: [$(printf '%s' "$actual")]"
  fi
}

assert_ne() {
  local unexpected=$1 actual=$2 desc=${3:-values differ}
  if [[ $unexpected != "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc" "both values were [$(printf '%s' "$actual")]"
  fi
}

assert_match() {
  local pattern=$1 actual=$2 desc=${3:-value matches}
  if [[ $actual =~ $pattern ]]; then
    _pass "$desc"
  else
    _fail "$desc" "[$actual] does not match /$pattern/"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 desc=${3:-value contains substring}
  if [[ $haystack == *"$needle"* ]]; then
    _pass "$desc"
  else
    _fail "$desc" "missing [$needle] in [$(printf '%s' "$haystack" | head -c 400)]"
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 desc=${3:-value omits substring}
  if [[ $haystack != *"$needle"* ]]; then
    _pass "$desc"
  else
    _fail "$desc" "unexpected [$needle] in [$(printf '%s' "$haystack" | head -c 400)]"
  fi
}

# assert_status <expected-exit> <description> <command...>
assert_status() {
  local expected=$1 desc=$2
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc == "$expected" ]]; then
    _pass "$desc (exit $rc)"
  else
    _fail "$desc" "expected exit $expected, got $rc: $*"
  fi
}

# assert_ok <description> <command...>
assert_ok() {
  local desc=$1
  shift
  assert_status 0 "$desc" "$@"
}

# assert_fail <description> <command...>
assert_fail() {
  local desc=$1
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if ((rc != 0)); then
    _pass "$desc (exit $rc)"
  else
    _fail "$desc" "expected non-zero exit, got 0: $*"
  fi
}

finish_tests() {
  if ((TESTS_FAILED > 0)); then
    printf '# %d/%d assertions failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
    exit 1
  fi
  printf '# %d assertions passed\n' "$TESTS_RUN" >&2
  exit 0
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
new_tmpdir() {
  mktemp -d "${BALAMBA_TEST_ROOT:-${TMPDIR:-/tmp}}/case.XXXXXX"
}

# make_git_repo <dir> [origin]
# Creates a repo on branch main with one commit.  With "origin", also creates a
# bare repo next to it, adds it as origin, and pushes main.
make_git_repo() {
  local dir=$1 mode=${2:-}
  mkdir -p -- "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "balamba test"
  git -C "$dir" config user.email "test@balamba.invalid"
  git -C "$dir" config commit.gpgsign false
  printf 'initial\n' >"$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "initial commit"

  if [[ $mode == origin ]]; then
    local bare="${dir}.origin.git"
    git init -q --bare -b main "$bare"
    git -C "$dir" remote add origin "$bare"
    git -C "$dir" push -q -u origin main
  fi
  printf '%s\n' "$dir"
}

run_balamba() {
  "$BALAMBA_BIN" "$@"
}

run_balamba_capture() {
  # Sets the globals CAPTURE_OUT and CAPTURE_RC without tripping errexit.
  CAPTURE_OUT=""
  CAPTURE_RC=0
  CAPTURE_OUT=$("$BALAMBA_BIN" "$@" 2>&1) || CAPTURE_RC=$?
}
