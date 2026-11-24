#!/usr/bin/env bash
# balamba test runner.
#
# Discovers test/t_*.sh, runs each in its own bash process with an isolated
# HOME/XDG and a throwaway tmux socket, and prints a pass/fail summary.
#
#   ./test/run.sh
#   BALAMBA_TEST_KEEP=1 ./test/run.sh   # keep the temp root + server
#
# Exit status: 0 all tests passed, 1 any syntax/test failure.

set -Eeuo pipefail

TEST_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=helpers.sh
. "$TEST_DIR/helpers.sh"

printf '# test root: %s\n' "$BALAMBA_TEST_ROOT"

# ---------------------------------------------------------------------------
# bash -n preflight
# ---------------------------------------------------------------------------
syntax_fail=0
syntax_files=("$BALAMBA_ROOT/bin/balamba")
for f in "$BALAMBA_ROOT"/lib/*.sh "$TEST_DIR"/*.sh; do
  [[ -f $f ]] && syntax_files+=("$f")
done

printf '\n# syntax (bash -n)\n'
for f in "${syntax_files[@]}"; do
  rel=${f#"$BALAMBA_ROOT"/}
  if bash -n "$f" 2>/dev/null; then
    printf 'ok syntax %s\n' "$rel"
  else
    printf 'not ok syntax %s\n' "$rel"
    bash -n "$f" || true
    syntax_fail=1
  fi
done

if ((syntax_fail)); then
  printf '\n# syntax errors; not running tests\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
declare -a failures=()
passed=0
ran=0

for file in "$TEST_DIR"/t_*.sh; do
  [[ -f $file ]] || continue
  ran=$((ran + 1))
  name=$(basename -- "$file")
  printf '\n# %s\n' "$name"

  if bash "$file"; then
    printf 'ok %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok %s\n' "$name"
    failures+=("$name")
  fi
done

printf '\n%d/%d test file(s) passed' "$passed" "$ran"
if ((${#failures[@]} > 0)); then
  printf ', failed: %s\n' "${failures[*]}"
  printf 'hint: BALAMBA_TEST_KEEP=1 %s to keep the temp environment\n' "$0" >&2
  exit 1
fi
printf '\n'
exit 0
