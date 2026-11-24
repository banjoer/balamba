#!/usr/bin/env bash
# balamba — git / worktree layer (part 3).
#
# Project validation, project add/remove, worktree task creation and closing,
# the git side-panel status document, and task path computation.
#
# Contract: docs/architecture.md §9.  State is only ever touched through the
# balamba_state_* API from lib/common.sh; this file owns no other state.
#
# Exit codes: 0 success, 1 usage/name/slug/ref, 2 project/state/git failure.
# Public functions print only their documented stdout; diagnostics go to stderr.

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Physical absolute path for an existing directory; 1 otherwise.
_git_canonical_dir() {
  local path=${1-} abs
  [[ -n $path && -d $path ]] || return 1
  abs=$(cd -P -- "$path" 2>/dev/null && pwd) || return 1
  printf '%s\n' "$abs"
}

# Project path from state; prints nothing for an unknown project.
_git_project_path() {
  local pid=${1-}
  balamba_state_get '.projects[] | select(.id == $pid) | .path' --arg pid "$pid"
}

# <dirname(project.path)>/balamba_worktrees/<basename(project.path)>/<slug>
_git_task_path_compute() {
  local ppath=${1%/} slug=$2
  printf '%s/balamba_worktrees/%s/%s\n' \
    "$(dirname -- "$ppath")" "$(basename -- "$ppath")" "$slug"
}

# 0 when a task slug is unavailable: worktree dir occupied, local branch
# exists, or state already has that task id (defensive; normally the first two
# cover it).
_git_task_slug_taken() {
  local pid=$1 ppath=$2 slug=$3 task_path n
  task_path=$(_git_task_path_compute "$ppath" "$slug")
  if [[ -e $task_path || -L $task_path ]]; then
    return 0
  fi
  if git -C "$ppath" show-ref --verify --quiet "refs/heads/$slug" 2>/dev/null; then
    return 0
  fi
  if [[ -f ${BALAMBA_STATE:-} ]]; then
    n=$(balamba_state_get \
      '[.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid)] | length' \
      --arg pid "$pid" --arg tid "t_$slug")
    if [[ $n != 0 ]]; then
      return 0
    fi
  fi
  return 1
}

# Best-effort rollback after a failed task creation.  <created> is 1 when
# `git worktree add` succeeded, so the directory is ours and may be removed
# forcefully; the branch of that slug is ours in either case (collision checks
# ran first), but is only deleted when it exists.
_git_task_rollback() {
  local ppath=$1 task_path=$2 slug=$3 created=$4
  if [[ $created == 1 ]]; then
    if [[ -e $task_path || -L $task_path ]]; then
      git -C "$ppath" worktree remove --force "$task_path" >/dev/null 2>&1 || true
      if [[ -e $task_path || -L $task_path ]]; then
        rm -rf -- "$task_path" >/dev/null 2>&1 || true
      fi
    fi
  fi
  git -C "$ppath" worktree prune >/dev/null 2>&1 || true
  if git -C "$ppath" show-ref --verify --quiet "refs/heads/$slug" 2>/dev/null; then
    # Never delete a branch that another worktree now has checked out (a
    # concurrent creation could have won the race for this slug).
    if ! git -C "$ppath" worktree list --porcelain 2>/dev/null | \
      grep -Fq "branch refs/heads/$slug"; then
      git -C "$ppath" branch -D -- "$slug" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# Warn (stderr) about things the caller should know before dropping a worktree:
# dirty tree, detached HEAD, commits not pushed / not merged.
_git_close_report() {
  local path=$1 branch=$2 base_ref=$3
  local porcelain upstream count

  if porcelain=$(git -C "$path" status --porcelain=v1 2>/dev/null); then
    if [[ -n $porcelain ]]; then
      balamba_warn "task worktree has uncommitted changes: $path"
    fi
  fi

  if ! git -C "$path" symbolic-ref -q HEAD >/dev/null 2>&1; then
    balamba_warn "task worktree has a detached HEAD: $path"
  fi

  if upstream=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    if count=$(git -C "$path" rev-list --count '@{upstream}..HEAD' 2>/dev/null); then
      if [[ $count =~ ^[0-9]+$ ]] && ((count > 0)); then
        balamba_warn "$count commit(s) not pushed to $upstream"
      fi
    fi
  elif [[ -n $base_ref ]] && \
    git -C "$path" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1; then
    if count=$(git -C "$path" rev-list --count "${base_ref}..HEAD" 2>/dev/null); then
      if [[ $count =~ ^[0-9]+$ ]] && ((count > 0)); then
        balamba_warn "$count commit(s) not in $base_ref"
      fi
    fi
  fi

  if [[ -n $branch ]] && [[ -n $base_ref ]] && \
    git -C "$path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && \
    git -C "$path" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1; then
    if ! git -C "$path" merge-base --is-ancestor "$branch" "$base_ref" 2>/dev/null; then
      balamba_warn "branch $branch has commits not merged into $base_ref"
    fi
  fi
  return 0
}

# Task base_ref for a worktree path, else empty.  Tries the canonical path and
# the raw argument so symlinked invocations still match.
_git_base_ref_for_path() {
  local path=$1 raw=$2 base=""
  if [[ -f ${BALAMBA_STATE:-} ]]; then
    base=$(balamba_state_get \
      '[.projects[] | .tasks[]? | select(.path == $path or .path == $raw) | .base_ref][0] // empty' \
      --arg path "$path" --arg raw "$raw" 2>/dev/null) || base=""
  fi
  printf '%s\n' "$base"
}

_git_status_error() {
  local path=$1 msg=$2
  jq -nc --arg path "$path" --arg error "$msg" '{path:$path,error:$error}'
}

# ---------------------------------------------------------------------------
# 9.1 git_project_validate <path>
# ---------------------------------------------------------------------------
# 0 only for the top level of a main checkout; 1 otherwise, with a distinct
# stderr diagnostic.  No stdout, no state access.
git_project_validate() {
  if (($# != 1)); then
    balamba_warn "git_project_validate: expected exactly one path"
    return 1
  fi

  local path=$1 abs bare top

  if [[ ! -e $path ]]; then
    balamba_warn "not a directory: $path"
    return 1
  fi
  if [[ ! -d $path ]]; then
    balamba_warn "not a directory: $path"
    return 1
  fi
  if ! abs=$(_git_canonical_dir "$path"); then
    balamba_warn "cannot resolve path: $path"
    return 1
  fi

  balamba_require_cmd git

  if ! git -C "$abs" rev-parse --git-dir >/dev/null 2>&1; then
    balamba_warn "not a git repository: $path"
    return 1
  fi
  if ! bare=$(git -C "$abs" rev-parse --is-bare-repository 2>/dev/null); then
    balamba_warn "cannot inspect git repository: $path"
    return 1
  fi
  if [[ $bare == true ]]; then
    balamba_warn "is a bare repository, not a main checkout: $path"
    return 1
  fi
  # Linked worktrees and submodules have a .git *file* rather than a directory.
  if [[ -f $abs/.git ]]; then
    balamba_warn "is a linked worktree or submodule, not a main checkout: $path"
    return 1
  fi
  if ! top=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null); then
    balamba_warn "not a git checkout with a working tree: $path"
    return 1
  fi
  if [[ $top != "$abs" ]]; then
    balamba_warn "is not the top level of a git checkout (top level: $top): $path"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 9.2 git_project_add <path>
# ---------------------------------------------------------------------------
# Validates, canonicalizes, appends the project, makes it active.
# Idempotent for a path already present: prints its id, exit 0, state untouched.
# A different path with the same basename (and therefore the same id) is a
# duplicate and exits 2.
git_project_add() {
  if (($# != 1)); then
    balamba_warn "usage: git_project_add <path>"
    return 1
  fi

  local path=$1 abs id name existing_id existing_path project

  balamba_require_cmd git jq
  if ! git_project_validate "$path"; then
    return 1
  fi
  if ! abs=$(_git_canonical_dir "$path"); then
    balamba_warn "cannot resolve path: $path"
    return 1
  fi

  id=$(balamba_project_id "$abs")
  name=$(basename -- "$abs")

  # Same physical path already registered: idempotent success.
  existing_id=$(balamba_state_get \
    '.projects[] | select(.path == $p) | .id' --arg p "$abs")
  if [[ -n $existing_id ]]; then
    printf '%s\n' "$existing_id"
    return 0
  fi

  # A different checkout with the same basename would collide on the id.
  existing_path=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .path' --arg pid "$id")
  if [[ -n $existing_path ]]; then
    balamba_warn "project id already in use: $id (existing path: $existing_path)"
    return 2
  fi

  project=$(jq -nc \
    --arg id "$id" --arg name "$name" --arg path "$abs" \
    '{id:$id,name:$name,path:$path,expanded:true,tabs:[],tasks:[]}')

  if ! balamba_state_update '
      .projects += [$project]
      | .active.project = $pid
      | .active.context = "proj"
      | .active.window = 0
    ' --argjson project "$project" --arg pid "$id"; then
    return 2
  fi

  printf '%s\n' "$id"
}

# ---------------------------------------------------------------------------
# 9.3 git_project_remove <path|id> [--force]
# ---------------------------------------------------------------------------
# Removes the project from state only: never the folder, never worktrees.
# A project that still owns tasks is refused unless --force; with --force the
# tasks are dropped from state as well (their worktrees stay on disk), so no
# task entry is ever orphaned silently.
git_project_remove() {
  local target="" force=0

  if (($# == 0 || $# > 2)); then
    balamba_warn "usage: git_project_remove <path|id> [--force]"
    return 1
  fi
  target=$1
  if (($# == 2)); then
    if [[ $2 == --force ]]; then
      force=1
    else
      balamba_warn "unknown option: $2 (usage: git_project_remove <path|id> [--force])"
      return 1
    fi
  fi
  if [[ $target == --force ]]; then
    balamba_warn "usage: git_project_remove <path|id> [--force]"
    return 1
  fi

  balamba_require_cmd jq
  local pid="" canon="" n

  # Match by project id first.
  if [[ $target == p_* ]]; then
    pid=$(balamba_state_get '.projects[] | select(.id == $t) | .id' --arg t "$target")
  fi

  # Then by path (physical when the directory still exists, raw otherwise).
  if [[ -z $pid ]]; then
    if [[ -d $target ]]; then
      canon=$(_git_canonical_dir "$target" 2>/dev/null) || canon=""
    fi
    if [[ -n $canon ]]; then
      pid=$(balamba_state_get \
        '.projects[] | select(.path == $t or .path == $c) | .id' \
        --arg t "$target" --arg c "$canon")
    else
      pid=$(balamba_state_get '.projects[] | select(.path == $t) | .id' --arg t "$target")
    fi
  fi

  [[ -n $pid ]] || balamba_die "unknown project: $target"

  n=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | (.tasks | length)' --arg pid "$pid")
  if [[ $n != 0 && $force != 1 ]]; then
    balamba_warn "project $pid still has $n task(s); remove them first or pass --force"
    return 2
  fi

  if ! balamba_state_update '
      .projects |= map(select(.id != $pid))
      | if .active.project == $pid then
          (if (.projects | length) > 0 then .projects[0].id else null end) as $next
          | .active.project = $next
          | .active.context = (if $next == null then null else "proj" end)
          | .active.window = 0
        else . end
    ' --arg pid "$pid"; then
    return 2
  fi

  printf '%s\n' "$pid"
}

# ---------------------------------------------------------------------------
# 9.7 git_task_path <project-id> <slug>
# ---------------------------------------------------------------------------
git_task_path() {
  if (($# != 2)); then
    balamba_die "usage: git_task_path <project-id> <slug>"
  fi
  local pid=$1 slug=$2 ppath
  ppath=$(_git_project_path "$pid")
  [[ -n $ppath ]] || balamba_die "unknown project: $pid"
  _git_task_path_compute "$ppath" "$slug"
}

# ---------------------------------------------------------------------------
# 9.4 git_task_create <project-id> <display-name> <ref> <kind>
# ---------------------------------------------------------------------------
git_task_create() {
  if (($# != 4)); then
    balamba_warn "usage: git_task_create <project-id> <display-name> <ref> <kind>"
    return 1
  fi

  local pid=$1 display=$2 ref=$3 kind=$4

  case $kind in
    agent|shell) ;;
    *)
      balamba_warn "kind must be 'agent' or 'shell' (got '$kind')"
      return 1
      ;;
  esac
  if [[ -z $display ]]; then
    balamba_warn "task display name must not be empty"
    return 1
  fi

  balamba_require_cmd git jq

  local ppath
  ppath=$(_git_project_path "$pid")
  if [[ -z $ppath ]]; then
    balamba_warn "unknown project: $pid"
    return 2
  fi

  local base_slug slug name n=1
  base_slug=$(balamba_slugify "$display")
  if [[ -z $base_slug ]]; then
    balamba_warn "task name '$display' has an empty slug"
    return 1
  fi
  if ! git -C "$ppath" check-ref-format --branch "$base_slug" >/dev/null 2>&1; then
    balamba_warn "task name '$display' does not form a valid branch name ('$base_slug')"
    return 1
  fi

  slug=$base_slug
  name=$display
  while _git_task_slug_taken "$pid" "$ppath" "$slug"; do
    n=$((n + 1))
    if ((n > 1000)); then
      balamba_warn "could not find a free task name for '$display'"
      return 2
    fi
    slug="${base_slug}-${n}"
    name="${display}-${n}"
    if ! git -C "$ppath" check-ref-format --branch "$slug" >/dev/null 2>&1; then
      balamba_warn "task name '$display' does not form a valid branch name ('$slug')"
      return 1
    fi
  done

  # The ref must resolve to a commit before any filesystem change.
  local sha
  if ! sha=$(git -C "$ppath" rev-parse --verify --quiet --end-of-options "${ref}^{commit}" 2>/dev/null); then
    balamba_warn "invalid ref in project $pid: '$ref'"
    return 1
  fi
  if [[ -z $sha ]]; then
    balamba_warn "invalid ref in project $pid: '$ref'"
    return 1
  fi

  local task_path
  task_path=$(_git_task_path_compute "$ppath" "$slug")
  if ! mkdir -p -- "$(dirname -- "$task_path")"; then
    balamba_warn "cannot create worktree parent directory: $(dirname -- "$task_path")"
    return 2
  fi

  local add_out
  if ! add_out=$(git -C "$ppath" worktree add --no-track -b "$slug" "$task_path" "$ref" 2>&1); then
    balamba_warn "git worktree add failed: ${add_out//$'\n'/ }"
    _git_task_rollback "$ppath" "$task_path" "$slug" 0
    return 2
  fi

  local created_at task
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  task=$(jq -nc \
    --arg id "t_$slug" --arg name "$name" --arg slug "$slug" \
    --arg path "$task_path" --arg branch "$slug" --arg base_ref "$ref" \
    --arg created_at "$created_at" --arg kind "$kind" \
    '{id:$id,name:$name,slug:$slug,path:$path,branch:$branch,
      base_ref:$base_ref,created_at:$created_at,expanded:false,kind:$kind,
      tabs:[]}')

  if ! balamba_state_update '
      if ([.projects[] | select(.id == $pid)] | length) == 0 then
        error("project \($pid) disappeared")
      else
        .projects |= map(if .id == $pid then .tasks += [$task] else . end)
      end
    ' --arg pid "$pid" --argjson task "$task"; then
    balamba_warn "could not record the task in state; rolled back worktree and branch"
    _git_task_rollback "$ppath" "$task_path" "$slug" 1
    return 2
  fi

  printf '%s\n' "t_$slug"
}

# ---------------------------------------------------------------------------
# 9.5 git_task_close <project-id> <task-id> --force|--keep [--delete-branch]
# ---------------------------------------------------------------------------
# --keep  : plain `git worktree remove` (refuses a dirty/busy worktree).
# --force : `git worktree remove --force`; the caller already confirmed.
# Branch deletion uses `git branch -d` only; an unmerged branch is kept with a
# warning and the close still succeeds.
git_task_close() {
  if (($# < 3 || $# > 4)); then
    balamba_warn "usage: git_task_close <project-id> <task-id> --force|--keep [--delete-branch]"
    return 1
  fi

  local pid=$1 tid=$2
  shift 2
  local mode="" delete_branch=0 arg
  for arg in "$@"; do
    case $arg in
      --force|--keep)
        if [[ -n $mode ]]; then
          balamba_warn "exactly one of --force and --keep is required"
          return 1
        fi
        mode=${arg#--}
        ;;
      --delete-branch)
        delete_branch=1
        ;;
      *)
        balamba_warn "unknown option: $arg"
        return 1
        ;;
    esac
  done
  if [[ -z $mode ]]; then
    balamba_warn "one of --force or --keep is required"
    return 1
  fi

  balamba_require_cmd git jq

  local ppath n task_path branch base_ref
  ppath=$(_git_project_path "$pid")
  [[ -n $ppath ]] || balamba_die "unknown project: $pid"

  n=$(balamba_state_get \
    '[.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid)] | length' \
    --arg pid "$pid" --arg tid "$tid")
  [[ $n != 0 ]] || balamba_die "unknown task: $tid (project $pid)"

  task_path=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .path' \
    --arg pid "$pid" --arg tid "$tid")
  branch=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .branch' \
    --arg pid "$pid" --arg tid "$tid")
  base_ref=$(balamba_state_get \
    '.projects[] | select(.id == $pid) | .tasks[] | select(.id == $tid) | .base_ref' \
    --arg pid "$pid" --arg tid "$tid")

  local out
  if [[ -e $task_path || -L $task_path ]]; then
    _git_close_report "$task_path" "$branch" "$base_ref"
    if [[ $mode == force ]]; then
      if ! out=$(git -C "$ppath" worktree remove --force "$task_path" 2>&1); then
        balamba_warn "git worktree remove --force failed: ${out//$'\n'/ }"
        return 2
      fi
    else
      if ! out=$(git -C "$ppath" worktree remove "$task_path" 2>&1); then
        balamba_warn "git worktree remove failed (worktree is dirty or busy): ${out//$'\n'/ }"
        balamba_warn "use --force after confirming that uncommitted data may be lost"
        return 2
      fi
    fi
  else
    balamba_warn "task worktree already missing: $task_path"
  fi

  if ((delete_branch)) && [[ -n $branch ]]; then
    local bout
    if ! bout=$(git -C "$ppath" branch -d -- "$branch" 2>&1); then
      balamba_warn "kept branch $branch: ${bout//$'\n'/ }"
    fi
  fi

  if [[ -d $ppath ]]; then
    git -C "$ppath" worktree prune >/dev/null 2>&1 || true
  fi

  if ! balamba_state_update '
      .projects |= map(if .id == $pid then .tasks |= map(select(.id != $tid)) else . end)
      | if (.active.project == $pid and .active.context == ("task:" + $tid))
        then (.active.context = "proj" | .active.window = 0)
        else . end
    ' --arg pid "$pid" --arg tid "$tid"; then
    return 2
  fi

  printf '%s\n' "$tid"
}

# ---------------------------------------------------------------------------
# 9.6 git_status_json <path>
# ---------------------------------------------------------------------------
# Always prints one JSON object.  Success: path, branch, head, detached,
# upstream, base_ref, compare_ref, ahead, behind, dirty, files[].  Failure:
# {"path":...,"error":...} and exit 2.  Read-only.
git_status_json() {
  local path=${1-}

  if (($# != 1)) || [[ -z $path ]]; then
    _git_status_error "$path" "usage: git_status_json <path>"
    return 2
  fi

  local canon=$path root
  if [[ -d $path ]]; then
    canon=$(_git_canonical_dir "$path" 2>/dev/null) || canon=$path
  fi

  if ! root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null); then
    _git_status_error "$canon" "not a git checkout: $path"
    return 2
  fi
  root=$(_git_canonical_dir "$root" 2>/dev/null) || root=${root:-$path}

  balamba_require_cmd git jq

  local branch="" head="" detached=false upstream="" base="" cmp=""
  if branch=$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null); then
    :
  else
    branch=""
    detached=true
  fi
  head=$(git -C "$root" rev-parse --verify --quiet HEAD 2>/dev/null) || head=""
  upstream=$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""

  base=$(_git_base_ref_for_path "$canon" "$path")
  if [[ -z $base ]]; then
    balamba_config_load >/dev/null 2>&1 || true
    base=${default_ref:-origin/main}
  fi
  if [[ -n $upstream ]]; then
    cmp=$upstream
  else
    cmp=$base
  fi

  local ahead="" behind="" counts
  if [[ -n $cmp && -n $head ]]; then
    if counts=$(git -C "$root" rev-list --left-right --count "${cmp}...HEAD" 2>/dev/null); then
      behind=${counts%%[[:space:]]*}
      ahead=${counts##*[[:space:]]}
      if [[ ! $behind =~ ^[0-9]+$ ]]; then behind=""; fi
      if [[ ! $ahead =~ ^[0-9]+$ ]]; then ahead=""; fi
    fi
  fi

  # Parse `git status --porcelain=v1 -z`: NUL-separated entries "XY <path>";
  # renames/copies are followed by one extra token, the original path.
  local status_file
  status_file=$(mktemp "${TMPDIR:-/tmp}/balamba-status.XXXXXX") || {
    _git_status_error "$canon" "cannot create a temporary file for git status"
    return 2
  }
  if ! git -C "$root" status --porcelain=v1 -z >"$status_file" 2>/dev/null; then
    rm -f -- "$status_file"
    _git_status_error "$canon" "git status failed in $root"
    return 2
  fi

  local -a file_objs=()
  local entry xy p orig staged unstaged untracked expect_orig=0 obj
  while IFS= read -r -d '' entry; do
    if ((expect_orig)); then
      orig=$entry
      obj=$(jq -nc \
        --arg path "$p" --arg orig "$orig" --arg status "$xy" \
        --argjson staged "$staged" --argjson unstaged "$unstaged" \
        --argjson untracked "$untracked" \
        '{path:$path,orig_path:$orig,status:$status,
          staged:$staged,unstaged:$unstaged,untracked:$untracked}')
      file_objs+=("$obj")
      expect_orig=0
      continue
    fi
    xy=${entry:0:2}
    p=${entry:3}
    staged=false
    unstaged=false
    untracked=false
    if [[ ${xy:0:1} != ' ' && ${xy:0:1} != '?' ]]; then staged=true; fi
    if [[ ${xy:1:1} != ' ' && ${xy:1:1} != '?' ]]; then unstaged=true; fi
    if [[ $xy == '??' ]]; then untracked=true; fi
    if [[ ${xy:0:1} == R || ${xy:0:1} == C ]]; then
      expect_orig=1
      continue
    fi
    obj=$(jq -nc \
      --arg path "$p" --arg status "$xy" \
      --argjson staged "$staged" --argjson unstaged "$unstaged" \
      --argjson untracked "$untracked" \
      '{path:$path,orig_path:null,status:$status,
        staged:$staged,unstaged:$unstaged,untracked:$untracked}')
    file_objs+=("$obj")
  done <"$status_file"
  rm -f -- "$status_file"

  local joined=""
  if ((${#file_objs[@]})); then
    joined=$(IFS=,; printf '%s' "${file_objs[*]}")
  fi

  jq -nc \
    --arg path "$canon" \
    --arg branch "$branch" \
    --arg head "$head" \
    --argjson detached "$detached" \
    --arg upstream "$upstream" \
    --arg base_ref "$base" \
    --arg compare_ref "$cmp" \
    --arg ahead "$ahead" \
    --arg behind "$behind" \
    --argjson files "[$joined]" \
    '{
       path: $path,
       branch: (if $branch == "" then null else $branch end),
       head: (if $head == "" then null else $head end),
       detached: $detached,
       upstream: (if $upstream == "" then null else $upstream end),
       base_ref: $base_ref,
       compare_ref: (if $compare_ref == "" then null else $compare_ref end),
       ahead: (if $ahead == "" then null else ($ahead | tonumber) end),
       behind: (if $behind == "" then null else ($behind | tonumber) end),
       dirty: (($files | length) > 0),
       files: $files
     }'
}
