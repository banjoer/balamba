#!/usr/bin/env bash
# Tests for lib/git.sh: project validation/add/remove, task create/close,
# task paths and the git status document.  Real temp git repositories only.

set -Eeuo pipefail

# shellcheck source=helpers.sh
. "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=../lib/common.sh
. "$BALAMBA_ROOT/lib/common.sh"
# shellcheck source=../lib/git.sh
. "$BALAMBA_ROOT/lib/git.sh"

rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock"
rm -rf -- "$BALAMBA_RUNTIME"
rm -f -- "$BALAMBA_CONFIG"
balamba_state_init

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
CAP_OUT=""
CAP_ERR=""
CAP_RC=0

# Run a command (usually a shell function, in a subshell so balamba_die and
# the ERR trap cannot end this test process) capturing stdout/stderr.
capture() {
  CAP_OUT=""
  CAP_ERR=""
  CAP_RC=0
  local errf
  errf=$(mktemp "${TMPDIR:-/tmp}/balamba-cap.XXXXXX")
  CAP_OUT=$("$@" 2>"$errf") || CAP_RC=$?
  CAP_ERR=$(<"$errf")
  rm -f -- "$errf"
}

reset_state() {
  rm -f -- "$BALAMBA_STATE" "${BALAMBA_STATE}.lock"
  rm -rf -- "$BALAMBA_RUNTIME"
  balamba_state_init
}

task_field() {
  local pid=$1 tid=$2 field=$3
  balamba_state_get \
    ".projects[] | select(.id == \$pid) | .tasks[] | select(.id == \$tid) | .$field" \
    --arg pid "$pid" --arg tid "$tid"
}

task_count() {
  local pid=$1
  balamba_state_get '.projects[] | select(.id == $pid) | (.tasks | length)' \
    --arg pid "$pid"
}

# jq field of a captured status document: status_file_field <json> <path> <field>
status_file_field() {
  local json=$1 path=$2 field=$3
  jq -r --arg p "$path" --arg f "$field" \
    '.files[] | select(.path == $p) | .[$f]' <<<"$json"
}

# ---------------------------------------------------------------------------
# git_project_validate
# ---------------------------------------------------------------------------
repo=$(make_git_repo "$(new_tmpdir)/repo" origin)

capture git_project_validate "$repo"
assert_eq "0" "$CAP_RC" "validate: accepts a main checkout"
assert_eq "" "$CAP_OUT" "validate: no stdout on success"
assert_eq "" "$CAP_ERR" "validate: no stderr on success"

plain=$(new_tmpdir)
capture git_project_validate "$plain"
assert_eq "1" "$CAP_RC" "validate: rejects a non-git directory"
assert_contains "$CAP_ERR" "not a git repository" "validate: names the non-git cause"
assert_eq "" "$CAP_OUT" "validate: no stdout on failure"

mkdir -p "$repo/sub"
capture git_project_validate "$repo/sub"
assert_eq "1" "$CAP_RC" "validate: rejects a subdirectory of a repo"
assert_contains "$CAP_ERR" "not the top level" "validate: names the subdirectory cause"

bare=$(new_tmpdir)/bare.git
git init -q --bare -b main "$bare"
capture git_project_validate "$bare"
assert_eq "1" "$CAP_RC" "validate: rejects a bare repository"
assert_contains "$CAP_ERR" "bare repository" "validate: names the bare-repo cause"

linked=$(new_tmpdir)/linked
git -C "$repo" worktree add -q "$linked" -b linked-check
capture git_project_validate "$linked"
assert_eq "1" "$CAP_RC" "validate: rejects a linked worktree"
assert_contains "$CAP_ERR" "linked worktree" "validate: names the linked-worktree cause"

capture git_project_validate "$(new_tmpdir)/missing"
assert_eq "1" "$CAP_RC" "validate: rejects a missing path"
assert_contains "$CAP_ERR" "not a directory" "validate: names the missing-path cause"

capture git_project_validate
assert_eq "1" "$CAP_RC" "validate: missing argument is a usage error"

# ---------------------------------------------------------------------------
# git_project_add
# ---------------------------------------------------------------------------
reset_state
repo_a=$(make_git_repo "$(new_tmpdir)/one/repo" origin)
repo_b=$(make_git_repo "$(new_tmpdir)/two/repo" origin)

capture git_project_add "$repo_a"
assert_eq "0" "$CAP_RC" "add: succeeds for a main checkout"
assert_eq "p_repo" "$CAP_OUT" "add: prints the new project id"
assert_eq "1" "$(balamba_state_get '.projects | length')" "add: project appended"
assert_eq "p_repo" "$(balamba_state_get '.projects[0].id')" "add: stored id"
assert_eq "$repo_a" "$(balamba_state_get '.projects[0].path')" "add: stored canonical path"
assert_eq "true" "$(balamba_state_get '.projects[0].expanded')" "add: expanded defaults to true"
assert_eq "0" "$(balamba_state_get '.projects[0].tabs | length')" "add: empty tabs"
assert_eq "0" "$(balamba_state_get '.projects[0].tasks | length')" "add: empty tasks"
assert_eq "p_repo" "$(balamba_state_get '.active.project')" "add: becomes the active project"
assert_eq "proj" "$(balamba_state_get '.active.context')" "add: active context is proj"
assert_eq "0" "$(balamba_state_get '.active.window')" "add: active window resets to 0"
assert_status 0 "add: state remains valid" balamba_state_validate

capture git_project_add "$repo_a"
assert_eq "0" "$CAP_RC" "add: adding the same path again is idempotent"
assert_eq "p_repo" "$CAP_OUT" "add: idempotent call returns the existing id"
assert_eq "1" "$(balamba_state_get '.projects | length')" "add: no duplicate project entry"

capture git_project_add "$repo_b"
assert_eq "2" "$CAP_RC" "add: duplicate basename is refused"
assert_contains "$CAP_ERR" "already in use" "add: duplicate basename diagnostic"
assert_eq "1" "$(balamba_state_get '.projects | length')" "add: refused duplicate leaves state alone"
assert_status 0 "add: state valid after duplicate refusal" balamba_state_validate

capture git_project_add "$plain"
assert_eq "1" "$CAP_RC" "add: invalid path exits 1"
assert_eq "1" "$(balamba_state_get '.projects | length')" "add: invalid path adds nothing"

# ---------------------------------------------------------------------------
# git_project_remove
# ---------------------------------------------------------------------------
reset_state
proj_one=$(make_git_repo "$(new_tmpdir)/rm/alpha" origin)
proj_two=$(make_git_repo "$(new_tmpdir)/rm/beta" origin)
git_project_add "$proj_one" >/dev/null
git_project_add "$proj_two" >/dev/null

capture git_project_remove p_beta
assert_eq "0" "$CAP_RC" "remove: succeeds by id"
assert_eq "p_beta" "$CAP_OUT" "remove: prints the removed id"
assert_eq "1" "$(balamba_state_get '.projects | length')" "remove: project dropped from state"
assert_eq "p_alpha" "$(balamba_state_get '.active.project')" "remove: active falls back to the first project"
assert_eq "proj" "$(balamba_state_get '.active.context')" "remove: fallback context is proj"
assert_eq "0" "$(balamba_state_get '.active.window')" "remove: fallback window is 0"
[[ -d $proj_two ]] && _pass "remove: never deletes the project folder" || \
  _fail "remove: never deletes the project folder"

capture git_project_remove "$proj_one"
assert_eq "0" "$CAP_RC" "remove: succeeds by absolute path"
assert_eq "p_alpha" "$CAP_OUT" "remove: path match prints the id"
assert_eq "0" "$(balamba_state_get '.projects | length')" "remove: last project removed"
assert_eq "null" "$(balamba_state_get '.active.project')" "remove: active project cleared"
assert_eq "null" "$(balamba_state_get '.active.context')" "remove: active context cleared"
assert_status 0 "remove: state valid when empty" balamba_state_validate

capture git_project_remove p_missing
assert_eq "2" "$CAP_RC" "remove: unknown project exits 2"
capture git_project_remove
assert_eq "1" "$CAP_RC" "remove: missing argument is a usage error"
capture git_project_remove "$proj_one" --bogus
assert_eq "1" "$CAP_RC" "remove: unknown option is a usage error"

# refuses while tasks exist, unless --force
git_project_add "$proj_one" >/dev/null
tid=$(git_task_create p_alpha "Removable task" main shell)
wt=$(task_field p_alpha "$tid" path)
capture git_project_remove p_alpha
assert_eq "2" "$CAP_RC" "remove: refuses a project with tasks"
assert_contains "$CAP_ERR" "task" "remove: explains the task refusal"
assert_eq "1" "$(balamba_state_get '.projects | length')" "remove: refusal keeps the project"
assert_eq "1" "$(task_count p_alpha)" "remove: refusal keeps the task"

capture git_project_remove p_alpha --force
assert_eq "0" "$CAP_RC" "remove: --force drops a project with tasks"
assert_eq "0" "$(balamba_state_get '.projects | length')" "remove: forced project is gone"
[[ -d $wt ]] && _pass "remove: --force leaves the task worktree on disk" || \
  _fail "remove: --force leaves the task worktree on disk"
assert_status 0 "remove: state valid after forced removal" balamba_state_validate

# ---------------------------------------------------------------------------
# git_task_path
# ---------------------------------------------------------------------------
reset_state
repo=$(make_git_repo "$(new_tmpdir)/tp/repo" origin)
git_project_add "$repo" >/dev/null
capture git_task_path p_repo fix-login
assert_eq "0" "$CAP_RC" "task_path: exits 0 for a known project"
assert_eq "$(dirname -- "$repo")/balamba_worktrees/repo/fix-login" "$CAP_OUT" \
  "task_path: documented layout"
capture git_task_path p_missing fix-login
assert_eq "2" "$CAP_RC" "task_path: unknown project exits 2"
assert_eq "" "$CAP_OUT" "task_path: no stdout for an unknown project"

# ---------------------------------------------------------------------------
# git_task_create
# ---------------------------------------------------------------------------
reset_state
repo=$(make_git_repo "$(new_tmpdir)/tc/repo" origin)
git_project_add "$repo" >/dev/null
base_sha=$(git -C "$repo" rev-parse origin/main)

capture git_task_create p_repo "Fix login" origin/main agent
assert_eq "0" "$CAP_RC" "create: exits 0"
assert_eq "t_fix-login" "$CAP_OUT" "create: prints the task id"
assert_eq "1" "$(task_count p_repo)" "create: task appended to state"
assert_eq "t_fix-login" "$(task_field p_repo t_fix-login id)" "create: stored id"
assert_eq "Fix login" "$(task_field p_repo t_fix-login name)" "create: display name kept as typed"
assert_eq "fix-login" "$(task_field p_repo t_fix-login slug)" "create: slug from display name"
assert_eq "fix-login" "$(task_field p_repo t_fix-login branch)" "create: branch equals slug"
assert_eq "origin/main" "$(task_field p_repo t_fix-login base_ref)" "create: base_ref stored"
assert_eq "agent" "$(task_field p_repo t_fix-login kind)" "create: kind stored"
assert_eq "false" "$(task_field p_repo t_fix-login expanded)" "create: task starts collapsed"
assert_eq "0" "$(balamba_state_get '.projects[0].tasks[0].tabs | length')" "create: no tabs created"
assert_match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  "$(task_field p_repo t_fix-login created_at)" "create: UTC ISO8601 created_at"

wt=$(task_field p_repo t_fix-login path)
assert_eq "$(dirname -- "$repo")/balamba_worktrees/repo/fix-login" "$wt" \
  "create: documented worktree path"
[[ -d $wt ]] && _pass "create: worktree directory exists" || _fail "create: worktree directory exists"
assert_eq "$base_sha" "$(git -C "$wt" rev-parse HEAD)" "create: worktree checked out at the ref commit"
assert_eq "$base_sha" "$(git -C "$repo" rev-parse refs/heads/fix-login)" \
  "create: branch created at the ref commit"
assert_eq "fix-login" "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" "create: worktree is on the task branch"
assert_status 0 "create: task path matches git_task_path" \
  test "$(git_task_path p_repo fix-login)" = "$wt"

capture git -C "$repo" config branch.fix-login.remote
assert_eq "1" "$CAP_RC" "create: --no-track leaves branch.<slug>.remote unset"
assert_eq "" "$CAP_OUT" "create: no remote configured for the task branch"
capture git -C "$repo" config branch.fix-login.merge
assert_eq "1" "$CAP_RC" "create: --no-track leaves branch.<slug>.merge unset"
capture git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
assert_ne "0" "$CAP_RC" "create: no upstream is configured"
assert_status 0 "create: state valid" balamba_state_validate

# collision on folder + branch: suffix both display name and slug
capture git_task_create p_repo "Fix login" main shell
assert_eq "0" "$CAP_RC" "create: collision still succeeds"
assert_eq "t_fix-login-2" "$CAP_OUT" "create: collision suffixes the slug"
assert_eq "Fix login-2" "$(task_field p_repo t_fix-login-2 name)" "create: collision suffixes the display name"
assert_eq "fix-login-2" "$(task_field p_repo t_fix-login-2 branch)" "create: suffixed branch"
[[ -d $(task_field p_repo t_fix-login-2 path) ]] && _pass "create: suffixed worktree exists" || \
  _fail "create: suffixed worktree exists"

capture git_task_create p_repo "Fix login" main shell
assert_eq "t_fix-login-3" "$CAP_OUT" "create: collision keeps counting (-3)"

# branch-only collision
git -C "$repo" branch collide main
capture git_task_create p_repo "collide" main shell
assert_eq "t_collide-2" "$CAP_OUT" "create: existing local branch counts as a collision"

# folder-only collision
mkdir -p "$(dirname -- "$repo")/balamba_worktrees/repo/folderonly"
capture git_task_create p_repo "folderonly" main shell
assert_eq "t_folderonly-2" "$CAP_OUT" "create: existing worktree folder counts as a collision"

# local branch ref
git -C "$repo" branch local-base main
local_sha=$(git -C "$repo" rev-parse local-base)
capture git_task_create p_repo "From local" local-base shell
assert_eq "0" "$CAP_RC" "create: accepts a local branch ref"
assert_eq "$local_sha" "$(git -C "$repo" rev-parse refs/heads/from-local)" \
  "create: local-ref branch starts at that commit"

# invalid ref, invalid kind, empty name, unknown project
before_tasks=$(task_count p_repo)
capture git_task_create p_repo "Bad ref" no-such-ref shell
assert_eq "1" "$CAP_RC" "create: invalid ref exits 1"
assert_contains "$CAP_ERR" "invalid ref" "create: invalid-ref diagnostic"
assert_eq "$before_tasks" "$(task_count p_repo)" "create: invalid ref leaves state unchanged"
if git -C "$repo" show-ref --verify --quiet refs/heads/bad-ref; then
  _fail "create: invalid ref creates no branch"
else
  _pass "create: invalid ref creates no branch"
fi
[[ ! -e $(dirname -- "$repo")/balamba_worktrees/repo/bad-ref ]] && \
  _pass "create: invalid ref creates no worktree" || \
  _fail "create: invalid ref creates no worktree"

capture git_task_create p_repo "Bad kind" main service
assert_eq "1" "$CAP_RC" "create: invalid kind exits 1"
capture git_task_create p_repo "!!" main shell
assert_eq "1" "$CAP_RC" "create: empty slug exits 1"
capture git_task_create p_repo "   " main shell
assert_eq "1" "$CAP_RC" "create: whitespace-only name exits 1"
capture git_task_create p_missing "X" main shell
assert_eq "2" "$CAP_RC" "create: unknown project exits 2"
assert_status 0 "create: state still valid after failures" balamba_state_validate

# rollback when recording the task fails after the worktree was created
reset_state
repo_rb=$(make_git_repo "$(new_tmpdir)/rb/repo" origin)
git_project_add "$repo_rb" >/dev/null
rb_dir=$(new_tmpdir)
cp "$BALAMBA_STATE" "$rb_dir/state.json"
mkdir "$rb_dir/state.json.lock"   # makes the state lock un-openable
saved_state=$BALAMBA_STATE
BALAMBA_STATE="$rb_dir/state.json"
capture git_task_create p_repo "Rollback me" main agent
BALAMBA_STATE=$saved_state
assert_eq "2" "$CAP_RC" "create: state failure exits 2"
assert_contains "$CAP_ERR" "rolled back" "create: reports the rollback"
assert_eq "0" "$(task_count p_repo)" "create: rollback leaves no state entry"
[[ ! -e $(dirname -- "$repo_rb")/balamba_worktrees/repo/rollback-me ]] && \
  _pass "create: rollback removes the worktree" || \
  _fail "create: rollback removes the worktree"
if git -C "$repo_rb" show-ref --verify --quiet refs/heads/rollback-me; then
  _fail "create: rollback deletes the branch"
else
  _pass "create: rollback deletes the branch"
fi
if git -C "$repo_rb" worktree list | grep -q rollback-me; then
  _fail "create: rollback prunes worktree metadata"
else
  _pass "create: rollback prunes worktree metadata"
fi
assert_status 0 "create: state valid after rollback" balamba_state_validate

# ---------------------------------------------------------------------------
# git_task_close
# ---------------------------------------------------------------------------
reset_state
repo=$(make_git_repo "$(new_tmpdir)/cl/repo" origin)
git_project_add "$repo" >/dev/null

# --keep removes a clean worktree and keeps the branch
tid=$(git_task_create p_repo "Keep clean" main shell)
wt=$(task_field p_repo "$tid" path)
capture git_task_close p_repo "$tid" --keep
assert_eq "0" "$CAP_RC" "close: --keep succeeds on a clean worktree"
assert_eq "$tid" "$CAP_OUT" "close: prints the closed task id"
[[ ! -e $wt ]] && _pass "close: worktree removed" || _fail "close: worktree removed"
assert_eq "0" "$(task_count p_repo)" "close: task removed from state"
git -C "$repo" show-ref --verify --quiet refs/heads/keep-clean && \
  _pass "close: default keeps the branch" || _fail "close: default keeps the branch"
assert_status 0 "close: state valid" balamba_state_validate

# --keep refuses a dirty worktree; --force removes it
tid=$(git_task_create p_repo "Dirty one" main shell)
wt=$(task_field p_repo "$tid" path)
printf 'dirty\n' >>"$wt/README.md"
capture git_task_close p_repo "$tid" --keep
assert_eq "2" "$CAP_RC" "close: --keep refuses a dirty worktree"
assert_contains "$CAP_ERR" "uncommitted changes" "close: reports the dirty worktree"
[[ -d $wt ]] && _pass "close: dirty worktree survives --keep" || _fail "close: dirty worktree survives --keep"
assert_eq "1" "$(task_count p_repo)" "close: refused close keeps the state entry"

capture git_task_close p_repo "$tid" --force
assert_eq "0" "$CAP_RC" "close: --force removes a dirty worktree"
[[ ! -e $wt ]] && _pass "close: forced worktree removed" || _fail "close: forced worktree removed"
assert_eq "0" "$(task_count p_repo)" "close: forced task removed from state"

# detached HEAD is reported but does not block --force
tid=$(git_task_create p_repo "Detached" main shell)
wt=$(task_field p_repo "$tid" path)
git -C "$wt" checkout -q --detach
capture git_task_close p_repo "$tid" --force
assert_eq "0" "$CAP_RC" "close: detached HEAD closes with --force"
assert_contains "$CAP_ERR" "detached HEAD" "close: reports the detached HEAD"

# --delete-branch on a merged branch succeeds
tid=$(git_task_create p_repo "Delete merged" main shell)
capture git_task_close p_repo "$tid" --force --delete-branch
assert_eq "0" "$CAP_RC" "close: --delete-branch succeeds for a merged branch"
if git -C "$repo" show-ref --verify --quiet refs/heads/delete-merged; then
  _fail "close: merged branch deleted"
else
  _pass "close: merged branch deleted"
fi

# --delete-branch refuses an unmerged branch but still closes the task
tid=$(git_task_create p_repo "Unmerged work" main shell)
wt=$(task_field p_repo "$tid" path)
printf 'work\n' >"$wt/work.txt"
git -C "$wt" add work.txt
git -C "$wt" commit -q -m "unmerged work"
capture git_task_close p_repo "$tid" --force --delete-branch
assert_eq "0" "$CAP_RC" "close: unmerged branch still closes the task"
assert_contains "$CAP_ERR" "kept branch" "close: reports the kept branch"
assert_contains "$CAP_ERR" "not in main" "close: reports commits not in the base ref"
if git -C "$repo" show-ref --verify --quiet refs/heads/unmerged-work; then
  _pass "close: unmerged branch is kept"
else
  _fail "close: unmerged branch is kept"
fi
assert_eq "0" "$(task_count p_repo)" "close: task removed despite kept branch"

# missing worktree path: prune metadata and drop the state entry
tid=$(git_task_create p_repo "Missing tree" main shell)
wt=$(task_field p_repo "$tid" path)
rm -rf -- "$wt"
capture git_task_close p_repo "$tid" --keep
assert_eq "0" "$CAP_RC" "close: missing worktree still closes"
assert_contains "$CAP_ERR" "already missing" "close: reports the missing worktree"
if git -C "$repo" worktree list | grep -q missing-tree; then
  _fail "close: stale worktree metadata pruned"
else
  _pass "close: stale worktree metadata pruned"
fi

# active context falls back to proj
tid=$(git_task_create p_repo "Active task" main shell)
balamba_state_update \
  '.active.project = "p_repo" | .active.context = ("task:" + $tid) | .active.window = 4' \
  --arg tid "$tid"
capture git_task_close p_repo "$tid" --force
assert_eq "0" "$CAP_RC" "close: active task closes"
assert_eq "proj" "$(balamba_state_get '.active.context')" "close: active context falls back to proj"
assert_eq "0" "$(balamba_state_get '.active.window')" "close: active window resets to 0"

# usage and unknown ids
capture git_task_close p_repo t_nope --force
assert_eq "2" "$CAP_RC" "close: unknown task exits 2"
capture git_task_close p_missing t_nope --force
assert_eq "2" "$CAP_RC" "close: unknown project exits 2"
capture git_task_close p_repo
assert_eq "1" "$CAP_RC" "close: missing mode is a usage error"
capture git_task_close p_repo t_nope --force --keep
assert_eq "1" "$CAP_RC" "close: both modes is a usage error"
capture git_task_close p_repo t_nope --bogus
assert_eq "1" "$CAP_RC" "close: unknown option is a usage error"
assert_status 0 "close: state valid after all closes" balamba_state_validate

# ---------------------------------------------------------------------------
# git_status_json — file states
# ---------------------------------------------------------------------------
reset_state
repo=$(make_git_repo "$(new_tmpdir)/st/repo" origin)
printf 'delete me\n' >"$repo/to-delete.txt"
printf 'rename me\n' >"$repo/to-rename.txt"
git -C "$repo" add to-delete.txt to-rename.txt
git -C "$repo" commit -q -m "extra tracked files"
git -C "$repo" push -q origin main

capture git_status_json "$repo"
assert_eq "0" "$CAP_RC" "status: clean repo exits 0"
assert_eq "main" "$(jq -r '.branch' <<<"$CAP_OUT")" "status: branch name"
assert_eq "false" "$(jq -r '.detached' <<<"$CAP_OUT")" "status: not detached"
assert_eq "origin/main" "$(jq -r '.upstream' <<<"$CAP_OUT")" "status: upstream reported"
assert_eq "origin/main" "$(jq -r '.base_ref' <<<"$CAP_OUT")" "status: default base_ref"
assert_eq "origin/main" "$(jq -r '.compare_ref' <<<"$CAP_OUT")" "status: upstream is the compare ref"
assert_eq "0" "$(jq -r '.ahead' <<<"$CAP_OUT")" "status: clean ahead"
assert_eq "0" "$(jq -r '.behind' <<<"$CAP_OUT")" "status: clean behind"
assert_eq "false" "$(jq -r '.dirty' <<<"$CAP_OUT")" "status: clean is not dirty"
assert_eq "0" "$(jq -r '.files | length' <<<"$CAP_OUT")" "status: no changed files"
assert_eq "1" "$(jq -s 'length' <<<"$CAP_OUT")" "status: exactly one JSON object"
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$(jq -r '.head' <<<"$CAP_OUT")" "status: head sha"
assert_eq "$repo" "$(jq -r '.path' <<<"$CAP_OUT")" "status: canonical path"

# untracked
printf 'u\n' >"$repo/untracked file.txt"
capture git_status_json "$repo"
assert_eq "??" "$(status_file_field "$CAP_OUT" "untracked file.txt" status)" "status: untracked marker"
assert_eq "true" "$(status_file_field "$CAP_OUT" "untracked file.txt" untracked)" "status: untracked flag"
assert_eq "false" "$(status_file_field "$CAP_OUT" "untracked file.txt" staged)" "status: untracked is not staged"
assert_eq "null" "$(status_file_field "$CAP_OUT" "untracked file.txt" orig_path)" "status: untracked has no orig_path"

# staged only
printf 's\n' >"$repo/staged.txt"
git -C "$repo" add staged.txt
capture git_status_json "$repo"
assert_eq "A " "$(status_file_field "$CAP_OUT" staged.txt status)" "status: added marker"
assert_eq "true" "$(status_file_field "$CAP_OUT" staged.txt staged)" "status: added is staged"
assert_eq "false" "$(status_file_field "$CAP_OUT" staged.txt unstaged)" "status: added is not unstaged"

# unstaged only
printf 'more\n' >>"$repo/README.md"
capture git_status_json "$repo"
assert_eq " M" "$(status_file_field "$CAP_OUT" README.md status)" "status: modified marker"
assert_eq "false" "$(status_file_field "$CAP_OUT" README.md staged)" "status: modified is not staged"
assert_eq "true" "$(status_file_field "$CAP_OUT" README.md unstaged)" "status: modified is unstaged"

# staged and unstaged at once
printf 'both\n' >"$repo/both.txt"
git -C "$repo" add both.txt
printf 'again\n' >>"$repo/both.txt"
capture git_status_json "$repo"
assert_eq "AM" "$(status_file_field "$CAP_OUT" both.txt status)" "status: staged+unstaged marker"
assert_eq "true" "$(status_file_field "$CAP_OUT" both.txt staged)" "status: both staged flag"
assert_eq "true" "$(status_file_field "$CAP_OUT" both.txt unstaged)" "status: both unstaged flag"

# deletion
rm -f -- "$repo/to-delete.txt"
capture git_status_json "$repo"
assert_eq " D" "$(status_file_field "$CAP_OUT" to-delete.txt status)" "status: deleted marker"
assert_eq "false" "$(status_file_field "$CAP_OUT" to-delete.txt staged)" "status: deletion is unstaged"

# rename (staged, original path reported)
git -C "$repo" mv to-rename.txt renamed.txt
capture git_status_json "$repo"
assert_eq "R " "$(status_file_field "$CAP_OUT" renamed.txt status)" "status: rename marker"
assert_eq "to-rename.txt" "$(status_file_field "$CAP_OUT" renamed.txt orig_path)" "status: rename keeps orig_path"
assert_eq "true" "$(status_file_field "$CAP_OUT" renamed.txt staged)" "status: rename is staged"
assert_eq "" "$(status_file_field "$CAP_OUT" to-rename.txt status)" "status: rename is not listed under the old path"
assert_eq "true" "$(jq -r '.dirty' <<<"$CAP_OUT")" "status: dirty when files exist"
assert_eq "6" "$(jq -r '.files | length' <<<"$CAP_OUT")" "status: all changed files reported"

# detached HEAD
reset_state
repo=$(make_git_repo "$(new_tmpdir)/det/repo" origin)
detached_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q --detach
capture git_status_json "$repo"
assert_eq "0" "$CAP_RC" "status: detached HEAD still succeeds"
assert_eq "true" "$(jq -r '.detached' <<<"$CAP_OUT")" "status: detached flag"
assert_eq "null" "$(jq -r '.branch' <<<"$CAP_OUT")" "status: detached branch is null"
assert_eq "null" "$(jq -r '.upstream' <<<"$CAP_OUT")" "status: detached has no upstream"
assert_eq "$detached_sha" "$(jq -r '.head' <<<"$CAP_OUT")" "status: detached head sha"
assert_eq "0" "$(jq -r '.ahead' <<<"$CAP_OUT")" "status: detached compares with base_ref"

# no upstream: compare against the stored/default base_ref
reset_state
repo=$(make_git_repo "$(new_tmpdir)/nu/repo" origin)
git -C "$repo" checkout -q -b local-only
mkdir -p "$(dirname -- "$BALAMBA_CONFIG")"
printf 'default_ref=main\n' >"$BALAMBA_CONFIG"
capture git_status_json "$repo"
assert_eq "local-only" "$(jq -r '.branch' <<<"$CAP_OUT")" "status: no-upstream branch name"
assert_eq "null" "$(jq -r '.upstream' <<<"$CAP_OUT")" "status: no upstream is null"
assert_eq "main" "$(jq -r '.base_ref' <<<"$CAP_OUT")" "status: base_ref from config"
assert_eq "main" "$(jq -r '.compare_ref' <<<"$CAP_OUT")" "status: compare_ref falls back to base_ref"
assert_eq "0" "$(jq -r '.ahead' <<<"$CAP_OUT")" "status: no-upstream ahead uses base_ref"
assert_eq "0" "$(jq -r '.behind' <<<"$CAP_OUT")" "status: no-upstream behind uses base_ref"
rm -f -- "$BALAMBA_CONFIG"

# upstream wins over base_ref
reset_state
repo=$(make_git_repo "$(new_tmpdir)/up/repo" origin)
mkdir -p "$(dirname -- "$BALAMBA_CONFIG")"
printf 'default_ref=main\n' >"$BALAMBA_CONFIG"
capture git_status_json "$repo"
assert_eq "main" "$(jq -r '.base_ref' <<<"$CAP_OUT")" "status: project base_ref uses default_ref"
assert_eq "origin/main" "$(jq -r '.compare_ref' <<<"$CAP_OUT")" "status: upstream wins over base_ref"
rm -f -- "$BALAMBA_CONFIG"

# ahead/behind against a task's base_ref
reset_state
repo=$(make_git_repo "$(new_tmpdir)/ab/repo" origin)
git_project_add "$repo" >/dev/null
tid=$(git_task_create p_repo "Ahead task" main agent)
wt=$(task_field p_repo "$tid" path)
for i in 1 2; do
  printf 'c%s\n' "$i" >>"$wt/README.md"
  git -C "$wt" add README.md
  git -C "$wt" commit -q -m "task commit $i"
done
capture git_status_json "$wt"
assert_eq "0" "$CAP_RC" "status: task worktree status succeeds"
assert_eq "ahead-task" "$(jq -r '.branch' <<<"$CAP_OUT")" "status: task branch"
assert_eq "null" "$(jq -r '.upstream' <<<"$CAP_OUT")" "status: task has no upstream"
assert_eq "main" "$(jq -r '.base_ref' <<<"$CAP_OUT")" "status: task base_ref from state"
assert_eq "main" "$(jq -r '.compare_ref' <<<"$CAP_OUT")" "status: task compares with base_ref"
assert_eq "2" "$(jq -r '.ahead' <<<"$CAP_OUT")" "status: ahead counts task commits"
assert_eq "0" "$(jq -r '.behind' <<<"$CAP_OUT")" "status: task not behind yet"
printf 'main moves\n' >"$repo/main-only.txt"
git -C "$repo" add main-only.txt
git -C "$repo" commit -q -m "main moves"
capture git_status_json "$wt"
assert_eq "2" "$(jq -r '.ahead' <<<"$CAP_OUT")" "status: ahead unchanged after main moves"
assert_eq "1" "$(jq -r '.behind' <<<"$CAP_OUT")" "status: behind counts base_ref commits"

# paths with spaces and non-ASCII
reset_state
spaced_repo=$(make_git_repo "$(new_tmpdir)/with space/repo" origin)
printf 'space\n' >"$spaced_repo/a b.txt"
printf 'unicode\n' >"$spaced_repo/héllo wörld.txt"
capture git_status_json "$spaced_repo"
assert_eq "0" "$CAP_RC" "status: repo path with spaces succeeds"
assert_eq "$spaced_repo" "$(jq -r '.path' <<<"$CAP_OUT")" "status: spaced path echoed"
assert_eq "2" "$(jq -r '.files | length' <<<"$CAP_OUT")" "status: spaced/unicode files found"
assert_eq "true" "$(status_file_field "$CAP_OUT" "a b.txt" untracked)" "status: file with space parsed"
assert_eq "true" "$(status_file_field "$CAP_OUT" "héllo wörld.txt" untracked)" "status: unicode file parsed"
assert_eq "??" "$(status_file_field "$CAP_OUT" "a b.txt" status)" "status: spaced file marker"

# failure object
capture git_status_json "$plain"
assert_eq "2" "$CAP_RC" "status: non-repo path exits 2"
assert_eq "1" "$(jq -s 'length' <<<"$CAP_OUT")" "status: exactly one JSON object on failure"
assert_eq "true" "$(jq -r 'has("error")' <<<"$CAP_OUT")" "status: failure object has error"
capture git_status_json "$(new_tmpdir)/nope"
assert_eq "2" "$CAP_RC" "status: missing path exits 2"
assert_eq "true" "$(jq -r 'has("error")' <<<"$CAP_OUT")" "status: missing-path object has error"
capture git_status_json
assert_eq "2" "$CAP_RC" "status: missing argument exits 2"

# ---------------------------------------------------------------------------
# CLI end to end (bin/balamba project add|remove|list, task list)
# ---------------------------------------------------------------------------
reset_state
cli_repo=$(make_git_repo "$(new_tmpdir)/cli/repo" origin)
cli_other=$(make_git_repo "$(new_tmpdir)/cli-other/repo" origin)

capture "$BALAMBA_BIN" project add "$cli_repo"
assert_eq "0" "$CAP_RC" "cli: project add exits 0"
assert_contains "$CAP_OUT" "added project p_repo" "cli: project add prints the id"
assert_contains "$CAP_OUT" "$cli_repo" "cli: project add prints the path"

capture "$BALAMBA_BIN" project add "$cli_repo"
assert_eq "0" "$CAP_RC" "cli: adding the same path is idempotent"
assert_eq "1" "$(balamba_state_get '.projects | length')" "cli: no duplicate project"

capture "$BALAMBA_BIN" project add "$cli_other"
assert_eq "2" "$CAP_RC" "cli: duplicate basename exits 2"

capture "$BALAMBA_BIN" project add "$plain"
assert_eq "2" "$CAP_RC" "cli: invalid project path exits 2"

capture "$BALAMBA_BIN" project list
assert_contains "$CAP_OUT" "p_repo" "cli: project list shows the project"
assert_contains "$CAP_OUT" "$cli_repo" "cli: project list shows the path"

tid=$(git_task_create p_repo "Listed task" main shell)
capture "$BALAMBA_BIN" task list
assert_eq "0" "$CAP_RC" "cli: task list exits 0"
assert_contains "$CAP_OUT" "p_repo/$tid" "cli: task list shows project/task"
assert_contains "$CAP_OUT" "listed-task" "cli: task list shows the branch"

capture "$BALAMBA_BIN" task list p_missing
assert_eq "2" "$CAP_RC" "cli: task list for an unknown project exits 2"

capture "$BALAMBA_BIN" project remove p_repo
assert_eq "2" "$CAP_RC" "cli: remove refuses a project with tasks"

git_task_close p_repo "$tid" --force >/dev/null
capture "$BALAMBA_BIN" project remove "$cli_repo"
assert_eq "0" "$CAP_RC" "cli: project remove exits 0"
assert_contains "$CAP_OUT" "removed project p_repo" "cli: remove prints the removed id"
[[ -d $cli_repo ]] && _pass "cli: remove leaves the folder" || _fail "cli: remove leaves the folder"
assert_eq "0" "$(balamba_state_get '.projects | length')" "cli: project removed from state"

capture "$BALAMBA_BIN" project list
assert_contains "$CAP_OUT" "no projects" "cli: empty project list"

assert_status 0 "state: final state is valid" balamba_state_validate

finish_tests
