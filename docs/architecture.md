# balamba architecture and contracts

This document is the contract between balamba's parts. **Read it before writing
any part.** Part 2 (this document's author) owns the foundation; parts 3–6 own
`lib/git.sh`, `lib/tmux.sh`, `lib/task.sh` and `pane/ui.py` respectively.

The authority above this file is `SPEC.md` and `docs/spikes.md`; where they
disagree with this document, they win and this document must be fixed.

---

## 1. System shape

```
bin/balamba ──sources──> lib/common.sh   paths, config, state, ids, errors
     │
     ├──sources if present──> lib/git.sh    project/worktree operations
     ├──sources if present──> lib/tmux.sh   server, windows, panes, restore
     └──sources if present──> lib/task.sh   interactive flows
                                   │
                                   └── pane/ui.py (python3, stdlib only)

tmux -L balamba -f <tmux.conf>   one private server, one session `balamba`
~/.config/balamba/config         sourced bash config
~/.local/state/balamba/state.json  source of truth (jq + flock)
```

Rules that never bend:

- Shell scripts own tmux, git and state. Python only renders and sends actions.
- `state.json` is the source of truth; startup reconciles it against git, and
  unknown directories are never adopted silently.
- `lib/common.sh` is the **only** writer of `state.json`.
- The private tmux server is `-L balamba`; never touch the user's default server.
- One tmux session, `balamba`. A tab is a window. Chrome panes (tree, git) are
  implicit and never stored in state.
- No new dependencies: bash, tmux, python3 (stdlib), jq, git, coreutils/flock.

---

## 2. File ownership

| File | Owner | Contents |
|---|---|---|
| `bin/balamba` | part 2 | entry point, dispatch, doctor, non-git commands, internal verbs |
| `lib/common.sh` | part 2 | real-path resolution, config, state API, ids, logging, error trap |
| `tmux.conf` | part 2 | server options, status formats, delegating bindings |
| `docs/architecture.md` | part 2 | this contract |
| `test/run.sh`, `test/helpers.sh`, `test/t_common.sh` | part 2 | foundation test suite |
| `.gitignore` | part 2 | noise only |
| `lib/git.sh` | part 3 | project validation, worktrees, task branches, git status |
| `lib/tmux.sh` | part 4 | server, session, windows/panes, chrome, restore, save, activate |
| `lib/task.sh` | part 5 | new-task / close-task / new-terminal flows |
| `pane/ui.py` | part 6 | tree and git panes |

Later parts must not edit another part's files. `bin/balamba` conditionally
sources `lib/git.sh`, `lib/tmux.sh`, `lib/task.sh`; a missing function produces a
clear "not available in this build" error with exit code 2. Do not replace that
with a silent fallback.

The orchestrator commits; no part runs `git commit` or `git push`.

---

## 3. Runtime paths and environment

`bin/balamba` resolves its own **real** path (symlink-safe), then
`BALAMBA_ROOT` is the repository/install root and `BALAMBA_LIB_DIR` is
`$BALAMBA_ROOT/lib`. Everything below is exported by `lib/common.sh`.

| Variable | Default | Meaning |
|---|---|---|
| `BALAMBA_ROOT` | real path of `bin/../` | install root (not a project path) |
| `BALAMBA_BIN` | `$BALAMBA_ROOT/bin/balamba` | entry point, used by bindings/panes |
| `XDG_CONFIG_HOME` | `$HOME/.config` | XDG base |
| `XDG_STATE_HOME` | `$HOME/.local/state` | XDG base |
| `BALAMBA_CONFIG` | `$XDG_CONFIG_HOME/balamba/config` | sourced bash config |
| `BALAMBA_STATE` | `$XDG_STATE_HOME/balamba/state.json` | JSON state |
| `BALAMBA_RUNTIME` | `$XDG_STATE_HOME/balamba` | runtime dir (logs/temp), created on init |
| `BALAMBA_SOCKET` | `balamba` | tmux socket name (`tmux -L <name>`) |
| `BALAMBA_TMUX_CONF` | `$XDG_CONFIG_HOME/balamba/tmux.conf` | server config; falls back to `$BALAMBA_ROOT/tmux.conf` if the user file is absent |
| `TMUX_TMPDIR` | `/tmp` (tmux default) | tmux socket directory base |

Every variable above can be overridden from the environment. Tests set them to
a throwaway tree. `balamba_tmux_socket_path` prints
`${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<BALAMBA_SOCKET>`.

Required commands: `bash` >= 4.2, `tmux` (tested on 3.4), `python3` >= 3.6,
`jq`, `git`, `flock`. `opencode` is optional at runtime (shell terminals still
work); `doctor` reports its absence as a warning.

---

## 4. Config contract

Config is a **sourced bash file**. Load order is: reset defaults, then source
the file. Unknown assignments are allowed (they are just shell variables).
A config that fails to source must not leave strict mode disabled; the loader
re-enables it.

### 4.1 Scalars

| Variable | Default | Meaning |
|---|---|---|
| `tree_width` | `30` | tree chrome pane width in columns |
| `git_width` | `34` | git chrome pane width in columns |
| `active_refresh` | `1` | seconds between refreshes in the active window |
| `idle_refresh` | `5` | seconds between activation checks in inactive windows |
| `git_refresh` | `2` | seconds between git-pane refreshes while its window is active |
| `editor` | `${EDITOR:-vi}` | editor for `e` / editor popups |
| `default_ref` | `origin/main` | prefilled "create from" ref |
| `default_agent` | `opencode` | agent key used for agent tabs |

Widths must be 5–200; refresh values 1–3600. `balamba_config_validate` reports
each problem on stderr and exits 2.

### 4.2 Agents

Agents are associative arrays, keyed by agent name. `{{session}}` and `{{dir}}`
are replaced literally by the launcher.

```bash
BALAMBA_AGENT_COMMAND[opencode]='opencode --session {{session}}'
BALAMBA_AGENT_RESUME[opencode]='opencode --session {{session}}'
BALAMBA_AGENT_LABEL[opencode]='opencode'
```

Defaults ship only `opencode`. A config may add more:

```bash
default_agent=myagent
BALAMBA_AGENT_COMMAND[myagent]='myagent --session {{session}}'
BALAMBA_AGENT_RESUME[myagent]='myagent --resume {{session}}'
BALAMBA_AGENT_LABEL[myagent]='myagent'
```

Note from the spikes: opencode requires ids beginning with `ses`; balamba
generates `ses_` + 32 hex (`balamba_ses_id`). Use the same command for create
and resume; opencode creates the session on the first message.

Optional agent variables may be added later; keep this table updated if so.

### 4.3 Functions

```bash
balamba_config_defaults      # reset all config vars/arrays to defaults
balamba_config_load          # defaults + source $BALAMBA_CONFIG (0, or source status)
balamba_config_validate      # load + range checks (0 ok, 2 invalid; stderr details)
balamba_config_to_tmux [tmux-args...]
```

`balamba_config_to_tmux` mirrors the static config into tmux user options:

```
@balamba_tree_width  @balamba_git_width  @balamba_active_refresh
@balamba_idle_refresh @balamba_git_refresh @balamba_editor
@balamba_default_ref @balamba_default_agent @balamba_root
```

With no arguments it calls `tmux -L "$BALAMBA_SOCKET"`. Pass explicit tmux
arguments if a different target is needed, but in practice call it **after**
`tmux_server_up` has started the private server. It does not set the runtime
options `@balamba_context` / `@balamba_git_branch`; `tmux_activate` does.

Shell libs call `balamba_config_load` before using config values. The Python
pane **never sources the config**; it reads the mirrored `@balamba_*` options.

---

## 5. State schema

`state.json` is a single JSON document, valid at every observable moment (writes
are tmp-file + validate + atomic rename under `flock`). Version is `1`.

```json
{
  "version": 1,
  "active": {"project": "p_balamba", "context": "task:t_fix-login", "window": 2},
  "projects": [
    {
      "id": "p_balamba",
      "name": "balamba",
      "path": "/home/me/src/balamba",
      "expanded": true,
      "tabs": [
        {
          "id": "tty_ab12cd34",
          "name": "shell 1",
          "kind": "shell",
          "agent": null,
          "session": null,
          "window": 0,
          "pane_count": 1,
          "layout": "",
          "active_pane": 0,
          "panes": [{"index": 0, "cwd": "/home/me/src/balamba", "launched": "shell"}]
        }
      ],
      "tasks": [
        {
          "id": "t_fix-login",
          "name": "Fix login",
          "slug": "fix-login",
          "path": "/home/me/src/balamba_worktrees/balamba/fix-login",
          "branch": "fix-login",
          "base_ref": "origin/main",
          "created_at": "2026-01-01T00:00:00Z",
          "expanded": false,
          "tabs": []
        }
      ]
    }
  ]
}
```

The empty state is exactly:

```json
{"version":1,"active":{"project":null,"context":null,"window":0},"projects":[]}
```

### 5.1 Field meanings

Top level:

- `version`: integer, must be `1`.
- `active.project`: project id or `null`.
- `active.context`: `"proj"` or `"task:<task-id>"` or `null` (also `null` when
  `active.project` is `null`).
- `active.window`: live tmux window index of the active context, integer >= 0.

Project:

- `id`: `p_` + the checkout directory's basename. Duplicate basenames across
  projects are refused (they would produce duplicate ids).
- `name`: display name; for now the basename.
- `path`: absolute path of the **main** git checkout.
- `expanded`: tree UI expansion, persisted.
- `tabs`: scratch terminals owned directly by the project (main checkout).
- `tasks`: worktree tasks.

Task (`t_` + slug, unique per project):

- `id`, `name` (free text, as typed), `slug` (worktree folder + branch).
- `path`: absolute worktree path,
  `<dirname(project.path)>/balamba_worktrees/<basename(project.path)>/<slug>`.
- `branch`: branch created for the task (normally equal to `slug`).
- `base_ref`: the ref the worktree was created from; used for ahead/behind.
- `created_at`: UTC `YYYY-MM-DDTHH:MM:SSZ`.
- `expanded`: tree UI expansion.
- `tabs`: the task's terminals.

Tab (window):

- `id`: `tty_` + 8 lowercase hex (globally unique in practice).
- `name`: display title; tab identity is the id, not the name.
- `kind`: `"shell"` or `"agent"`.
- `agent`: agent key from config for agent tabs, otherwise `null`.
- `session`: `ses_<32 hex>` for agent tabs, otherwise `null`.
- `window`: live tmux window index; unique across all tabs in the session.
- `pane_count`: number of **content** panes (>= 1). Chrome is excluded.
- `layout`: raw tmux `#{window_layout}` for the whole window (chrome included);
  may be `""` before the first save/restore.
- `active_pane`: 0-based **content** pane index (not the live tmux index).
- `panes`: content panes only, in order. `index` is 0-based content-relative,
  `cwd` is absolute, `launched` is `"shell"` or `"agent"`.

### 5.2 Invariants

- Project ids and task ids are unique; task ids are unique within a project;
  tab ids are unique within their owner.
- All paths (`project.path`, `task.path`, pane `cwd`) are absolute.
- `active.context` is `proj` or `task:<id>` and belongs to `active.project`
  whenever `active.project` is non-null.
- Every `tab.panes` index is contiguous `0..pane_count-1`.
- `active_pane < pane_count`.
- State never contains tree/git chrome panes.
- State never contains untracked directories: reconcile at startup removes tasks
  whose worktree is gone (warn on stderr), and never adopts unknown dirs.
- `window` values are a snapshot; they can drift if a human moves windows. The
  next `tmux_save_runtime` rewrites them.

Validation is structural (types, required fields, id uniqueness, context
grammar, one JSON document). It deliberately does not enforce `p_`/`t_` id
prefixes or path-containedness; those are creation-time invariants.

---

## 6. State API (`lib/common.sh`)

```bash
balamba_state_init                    # create dirs + empty valid state; idempotent
balamba_state_get <filter> [jq-args...]     # jq -r, prints result
balamba_state_update <filter> [jq-args...]  # atomic read/modify/validate/mv
balamba_state_set <filter> [jq-args...]     # alias of balamba_state_update
balamba_state_validate [file]         # 0 valid, 2 invalid; stderr diagnostic
balamba_need_state                    # die (exit 2) if the file is missing
```

Behavior:

- `init` creates `dirname($BALAMBA_STATE)` and `$BALAMBA_RUNTIME`. If a valid
  state exists it does nothing. If an invalid state exists it refuses to
  overwrite it (exit 2).
- `get` creates an empty state if none exists, then runs `jq -r "$@" "$filter"`.
  The **filter is the first argument**; jq flags follow. Example:
  `balamba_state_get '.projects[] | select(.id == $pid) | .path' --arg pid p_x`.
- `update` takes an exclusive `flock` on `${BALAMBA_STATE}.lock`, applies
  `jq [args] <filter> <state>` to a temp file in the same directory, validates
  it, then `mv -f` into place with mode `600`. Any failure (bad jq expression,
  zero/multiple documents, schema violation, bad existing JSON) leaves the
  original file untouched and exits 2.
- Extra jq arguments (`--arg`, `--argjson`, ...) are passed through and appear
  **after** the filter in call syntax. `--argjson p "$json"` is the normal way to
  insert a whole object.
- Concurrent panes only ever use `update`; readers see the old or new complete
  file, never a partial one.
- The jq schema program lives in `BALAMBA_STATE_SCHEMA` in `lib/common.sh`.
  Change it there and update §5 in this document together.

Nobody else runs `jq ... > state.json`, uses `>`/`sed` on it, or edits it in
Python. That is the corruption class this API exists to prevent.

---

## 7. Helper API (`lib/common.sh`)

| Function | Contract |
|---|---|
| `balamba_uuid` | stdout: 32 lowercase hex chars, no dashes |
| `balamba_ses_id` | stdout: `ses_` + 32 lowercase hex |
| `balamba_tab_id` | stdout: `tty_` + 8 lowercase hex |
| `balamba_project_id <path>` | stdout: `p_` + basename (no validation) |
| `balamba_task_id <slug>` | stdout: `t_` + slug (no validation) |
| `balamba_slugify <text>` | stdout: lowercased, spaces→`-`, delete all but `[a-z0-9._-]`, collapse/trim `-`; may be empty |
| `balamba_log <msg>` | diagnostic line to stderr, prefix `balamba:` |
| `balamba_warn <msg>` | stderr, prefix `balamba: warning:` |
| `balamba_die <msg>` | stderr `balamba: error:`, exit 2 |
| `balamba_require_cmd <cmd...>` | die (2) if any command is missing |
| `balamba_require_func <fn> <lib> [label]` | die (2) if the shell function is not defined |
| `balamba_tmux_socket_path` | stdout: tmux's socket path for `$BALAMBA_SOCKET` |

Slug semantics are literal: punctuation is **deleted**, not replaced. Thus
`"Hello, World!"` → `hello-world` (the space becomes `-`, the punctuation
vanishes) and `"!!Fix@@Login!!"` → `fixlogin`. Non-ASCII is deleted too, never
transliterated. The result may be empty; callers validate before use.

Strict mode: sourcing `common.sh` applies `set -Eeuo pipefail` and registers a
single ERR trap that prints the failing command, line and source and exits with
the failed status. Set `BALAMBA_STRICT=0` before sourcing only in harness code
that manages its own failure handling. Library code must not rely on `set +e`
around state writes.

---

## 8. CLI contract (`bin/balamba`)

All user-facing output goes to **stdout**; diagnostics/warnings go to **stderr**.
Exit codes: `0` success, `1` usage, `2` environment/state/missing-implementation
error.

| Command | Behavior |
|---|---|
| *(none)* / `attach` | `tmux_attach` from `lib/tmux.sh`; restore if the server is gone |
| `project add <path>` | `git_project_validate`, then `git_project_add`; prints `added project <id>: <path>` |
| `project remove <path|id>` | `git_project_remove`; prints `removed project <id>`; never deletes files |
| `project list` | one line per project: id, name, task count, path; `no projects` when empty |
| `task list [project-id]` | one line per task: `project/task`, name, branch, path; `no tasks` when empty |
| `save` | `tmux_save_runtime`; state must be initialized first |
| `doctor` | standalone environment/state report (below) |
| `version` / `--version` / `-V` | `balamba <semver>` |
| `help` / `--help` / `-h` | usage on stdout, exit 0 |

`project list` and `task list` are implemented with the state API only, so they
work before any git/tmux implementation exists. `task list <project-id>` exits 2
for an unknown project.

### 8.1 Internal verbs

The tmux bindings and `pane/ui.py` call `bin/balamba internal <verb> ...`.
These are not stable user API, but they are the supported mutation surface for
the UI.

| Verb | Args | Delegates to | Notes |
|---|---|---|---|
| `new-task` | — | `task_new_flow <active-project>` | requires `lib/task.sh` |
| `add-project` | — | `project_add_flow` | optional function; required for `C-a P` |
| `new-terminal` | — | `terminal_new_flow <active-project> <active-context>` | requires `lib/task.sh` |
| `close-task` | `<project-id> <task-id>` | `task_close_flow` | requires `lib/task.sh` |
| `activate` | `<project-id> <context> [window]` | `tmux_activate` | requires `lib/tmux.sh` |
| `expand` | `<project-id> [task-id]` | state update | implemented here; no lib needed |
| `collapse` | `<project-id> [task-id]` | state update | implemented here; no lib needed |

Unknown internal verbs are usage errors (1). Missing implementations exit 2 with
a message naming the missing function and expected lib. Do not add new verbs by
editing `bin/balamba` from another part; coordinate with the owner of part 2.

### 8.2 `doctor`

`doctor` never requires state or a server. It prints exactly one line per check:

```
ok    bash               5.2.21(1)-release
warn  opencode service   stopped (agents may start it on demand)
fail  jq                 not found on PATH
```

Checks: bash >= 4.2; tmux presence/version; python3 >= 3.6; jq; git; flock;
opencode version and `opencode service status` (service down is a **warning**);
config syntax/sourcing/range validation; state validity or "not created yet";
existence of project/task paths in a valid state (missing = warning); private
server/socket state (stale socket = warning, cold start = ok).

Hard failures (missing bash-level tools, invalid state, invalid config) exit 2;
warnings never change the exit status.

---

## 9. `lib/git.sh` contract (part 3)

All functions call `balamba_config_load` when they need config, use
`balamba_state_*` for state, and print diagnostics to stderr. "stdout" below is
exact; do not add banners.

### 9.1 `git_project_validate <path>`

- Resolve `path` to an absolute physical path.
- Exit `0` iff `git -C <path> rev-parse --show-toplevel` (resolved) equals the
  resolved path, i.e. it is a **main checkout**.
- A linked worktree / submodule (`.git` is a file) is refused with a warning on
  stderr and exit `1`.
- No stdout. No state access.

### 9.2 `git_project_add <path>`

- Validate as above; on invalid, exit `1`.
- `id = p_` + basename; refuse a duplicate id/basename already in state
  (exit `2`, stderr explains).
- Append a project object with `expanded: true`, empty `tabs`, empty `tasks`.
- Set `active.project = id`, `active.context = "proj"`, `active.window = 0`.
- stdout: exactly the new project id + newline.
- Exit `0`; `1` invalid path; `2` duplicate/state error.
- Ignores any tmux windows; adding a project does not require a server.

### 9.3 `git_project_remove <path|id>`

- Match by project id or by absolute path (real path).
- Remove the project from state. If it was active, set active to the first
  remaining project (`context="proj"`, `window=0`) or to nulls if none.
- Never touches the directory, git data, or worktrees.
- stdout: exactly the removed project id + newline.
- Exit `0`; `2` not found/state error.
- `bin/balamba` calls `tmux_remove_project <id>` after removing the project from
  state, best-effort, **if** lib/tmux.sh defines it (optional), so windows can be
  cleaned up in a tmux-aware build.

### 9.4 `git_task_create <project-id> <display-name> <ref> <kind>`

- `kind` must be `shell` or `agent`; display name non-empty.
- slug = `balamba_slugify <display-name>`; empty → exit `1`.
  Validate with `git check-ref-format --branch <slug>`; invalid → exit `1`.
- Collision (worktree dir exists or local branch `<slug>` exists): try
  `<slug>-2`, `<slug>-3`, …; both slug and display name get the `-N` suffix
  (display name `<original>-N`). Stop at the first free pair.
- Resolve `<ref>` in the project with
  `git rev-parse --verify <ref>^{commit}`; invalid → exit `1`.
- Path: `git_task_path <project-id> <slug>` (see 9.7).
- Run exactly:
  `git worktree add --no-track -b <slug> <path> <ref>` in the project.
  `--no-track` is required. Failure → stderr, exit `2`.
- Append the task object to the project's `tasks` with `created_at` in UTC
  (`date -u +%Y-%m-%dT%H:%M:%SZ`), `expanded:false`, `tabs:[]`.
- Does **not** create tmux windows/tabs; part 5 opens the first tab.
- stdout: exactly the new task id + newline.
- Exit `0`; `1` usage/name/slug/ref; `2` project/state/git failure.

### 9.5 `git_task_close <project-id> <task-id> --force|--keep [--delete-branch]`

- Exactly one of `--force` / `--keep` is required. `--keep` = plain
  `git worktree remove <path>` (refuses dirty trees); `--force` =
  `git worktree remove --force <path>`.
- Unknown project/task → exit `2`.
- `--delete-branch` runs `git branch -d <branch>` in the project path. If git
  refuses (unmerged branch), keep the branch, warn on stderr, and still exit `0`;
  a closed task is never rolled back because a branch was kept.
- Remove the task from state; if it was the active context, fall back to
  `active.context="proj"`, `active.window=0` under the same project.
- Does not kill tmux windows; `task_close_flow` does that before calling.
- stdout: exactly the closed task id + newline.
- Exit `0`; `1` usage; `2` unknown/dirty (with `--keep`)/git/state failure.

### 9.6 `git_status_json <path>`

- Always prints exactly **one JSON object** on stdout (compact is fine).
- Exit `0` on success; `2` on failure, still printing
  `{"path": "...", "error": "..."}`.
- Success object:

```json
{
  "path": "/abs/path",
  "branch": "fix-login",
  "head": "<sha>",
  "detached": false,
  "upstream": "origin/fix-login",
  "base_ref": "origin/main",
  "compare_ref": "origin/main",
  "ahead": 2,
  "behind": 0,
  "dirty": true,
  "files": [
    {"path": "src/a.py", "orig_path": null, "status": " M",
     "staged": false, "unstaged": true, "untracked": false}
  ]
}
```

- `branch` is `null` when detached; `detached` is a boolean. `head` is
  `git rev-parse HEAD`.
- Base ref: if the path matches a task, use that task's `base_ref`; otherwise
  `config.default_ref`. `compare_ref` is the upstream when one is set, else
  `base_ref`. `ahead`/`behind` come from
  `git rev-list --left-right --count <compare_ref>...HEAD` (left = behind,
  right = ahead). If the compare ref cannot be resolved, use `null` numbers and
  add `"error"`-free `"compare_error"` detail if desired; do not fail the whole
  object for it.
- Files come from `git status --porcelain=v1 -z`; `status` is the raw two-char
  `XY`; `staged = X not in " ?"`; `unstaged = Y not in " ?"`;
  `untracked = XY == "??"`; `orig_path` for renames, else `null`. File paths are
  relative to the repository root, exactly as porcelain reports them.
- `dirty = files.length > 0`. Read-only: no index/working-tree mutation.

### 9.7 `git_task_path <project-id> <slug>`

- Does not need to touch the filesystem, but reads state to find the project.
- stdout: `<dirname(project.path)>/balamba_worktrees/<basename(project.path)>/<slug>`
  (absolute, no trailing slash) + newline.
- Exit `0`; `2` unknown project.

Part 3 may add private helpers prefixed `_git_`, but not change these contracts.

---

## 10. `lib/tmux.sh` contract (part 4)

All functions may assume `lib/common.sh` is sourced and must call
`balamba_config_load` before reading config. Unless stated otherwise: stdout is
empty, diagnostics go to stderr, success is `0`, failure is `2`.

| Function | stdout | exit |
|---|---|---|
| `tmux_server_up` | — | 0 / 2 |
| `tmux_attach` | — (tmux draws) | 0 after detach / 2 |
| `tmux_ensure_session` | — | 0 / 2 |
| `tmux_build_context <context>` | — | 0 / 2 (unknown context) |
| `tmux_open_tab <pid> <context> <kind>` | new tab id + `\n` | 0 / 1 bad kind / 2 |
| `tmux_restore` | — | 0 / 2 |
| `tmux_assert_widths` | — | 0 (no-op when no chrome) |
| `tmux_save_runtime` | — | 0 / 2 |
| `tmux_activate <pid> <context> [window]` | — | 0 / 2 |

### 10.1 `tmux_server_up`

- Ensure a server exists at `tmux -L "$BALAMBA_SOCKET"` started with
  `-f "$BALAMBA_TMUX_CONF"`.
- If start/`has-session` fails because of a stale socket, unlink
  `balamba_tmux_socket_path` and retry **once** (spike risk 3).
- Call `balamba_config_to_tmux -L "$BALAMBA_SOCKET"` after the server is up so
  `@balamba_root` and the other options are live before any pane starts.
- Does not create a session (tmux cannot hold an empty one); that is
  `tmux_ensure_session` / `tmux_restore`'s job.
- Idempotent; safe to call on every invocation.

### 10.2 `tmux_attach`

- `tmux_server_up`.
- If session `balamba` does not exist (cold start) → `tmux_restore`; otherwise
  `tmux_ensure_session` for the active context.
- Attach with `tmux -L "$BALAMBA_SOCKET" attach-session -t balamba`. This call
  returns when the client detaches.
- Ensure sidebar widths for the visible window are reasserted once the client
  size is known (use `tmux_assert_widths`, a `client-attached`/`window-resized`
  hook, or an equivalent; do not rely on stored widths).
- Exit `0` after a normal detach; `2` if the server cannot be started/attached.

### 10.3 `tmux_ensure_session`

- Idempotently ensure session `balamba` exists. If it does not, create it with
  the first needed window/tab; if the active context has no tabs, create exactly
  one shell tab (an empty context is never left windowless).
- If the session exists, ensure the active context has its windows built
  (`tmux_build_context`) without duplicating any.
- Used by `tmux_attach`, internal commands and restore.
- No stdout.

### 10.4 `tmux_build_context <context>`

- `<context>` is `proj` or `task:<task-id>`.
- Ensure the windows described by state for that context exist; create only the
  missing ones. Existing windows are never duplicated or rebuilt.
- Unknown project/task/context → exit `2`.
- No stdout. Does not change the active context (that is `tmux_activate`).

### 10.5 `tmux_open_tab <project-id> <context> <kind>`

- `kind` is `shell` or `agent`.
- cwd = `task.path` for `task:<id>`, else `project.path`.
- Create: one content pane plus the two chrome panes; chrome is implicit.
- Agent tab: `agent = config.default_agent`, fresh `balamba_ses_id`, launch from
  `BALAMBA_AGENT_COMMAND[agent]` with `{{session}}`/`{{dir}}` substituted.
- Shell tab: launch `$SHELL` in the cwd.
- Append a tab object to the correct `tabs` array (project or task), record the
  live `window`, `pane_count` (content panes), empty layout or the current layout,
  `active_pane=0`, and one pane entry per content pane.
- Activate the new window (or leave it to the caller? **Contract: activate it**)
  and reassert widths.
- stdout: the new tab id + newline.
- Exit `0`; `1` bad kind; `2` state/tmux failure.

### 10.6 `tmux_restore`

Rebuild the whole UI from state (cold start). Condensed validated recipe:

1. Reconcile: remove tasks whose `path` is no longer a directory (warn);
   ignore unknown dirs. Never adopt.
2. Start the server with `-f "$BALAMBA_TMUX_CONF"`; on stale-socket failure
   unlink and retry once.
3. Create session `balamba` if absent. `new-session -d -s balamba -n <first
   tab>` creates the first window; reuse that window for the first saved tab
   (or kill a placeholder window before rebuilding).
4. For each saved window in ascending index order: create with
   `new-window -d -t balamba: -n <name>` (the trailing colon avoids name/index
   ambiguity), add `pane_count + 1` content/chrome panes with plain splits.
   Apply `select-layout -t <win> '<layout>'` **only** when the live pane count
   (content + 2 chrome) equals the saved leaf count; otherwise use equal splits
   (spikes: fewer panes silently truncates). `select-layout` resizes detached
   windows, so reassert chrome widths after attach.
5. Map `list-panes -F '#{pane_index} #{pane_id}'` sorted by index: new index k =
   saved index k in slot order. `respawn-pane -k -t <pane-id> -c <cwd> <command>`
   for each content pane; chrome panes run `python3 pane/ui.py tree|git`.
6. Restore each window's saved active content pane with `select-pane`
   (`window_layout` carries neither active pane nor active window).
7. Move windows **descending** to their exact saved indices if there are gaps
   (`move-window` fails on occupied indices).
8. `select-window -t balamba:<saved active index>`.
9. Attach, then reassert chrome widths.
10. Agents: staggered launches (~0.5–1 s apart, 3–7 s / ~160 MB each). Shells:
    fresh `$SHELL` in the saved cwd. Unknown programs (vim, dev servers) become
    a plain shell in the saved cwd.

### 10.7 `tmux_assert_widths`

- Reassert `tree_width` and `git_width` for the current window (the caller's
  window when run from a pane; the active window otherwise):
  `resize-pane -t <tree> -x <tree_width>`, same for git. Find chrome by the
  `@balamba_chrome` pane option (`tree`/`git`).
- No-op when no chrome panes are present. No stdout.

### 10.8 `tmux_save_runtime`

- Snapshot live state into `state.json`:
  - per window/tab: live index, name, content pane count, `#{window_layout}`,
    active content pane, per-content-pane `cwd` (`pane_current_path`).
  - active project/context/window.
- Content panes are saved in index order; chrome is skipped. A window with no
  known tab is ignored; a tab with no live window keeps its last saved values.
- Must be safe to call from a pane poll and on detach.
- No stdout. Exit `0`; `2` state/tmux failure.

### 10.9 `tmux_activate <project-id> <context> [window]`

- Validate project/context; `tmux_build_context` if needed.
- Update `active.project`, `active.context`, `active.window` atomically through
  the state API.
- Select the window (given `window` or the context's first tab) and its saved
  active content pane; focus the content pane (not chrome).
- Set `@balamba_context` to `proj`/`task:<id>` and `@balamba_git_branch` to the
  context's branch (read-only display value; empty if unknown).
- Reassert widths when the window becomes visible. No stdout.

### 10.10 Optional functions

Part 4 may define `tmux_remove_project <project-id>` and
`tmux_remove_context <project-id> <context>`; `bin/balamba` calls
`tmux_remove_project` when present. They must be safe no-ops when the server is
down.

Chrome pane convention: set `@balamba_chrome` to `tree` or `git` on the pane,
`remain-on-exit on`, and detect respawns as described in §12.

---

## 11. `lib/task.sh` contract (part 5)

Interactive flows run inside the private server and may use `display-menu`,
`display-popup`, `command-prompt`, or a popup shell. Script stdout stays quiet;
prompts are tmux UI. Cancel is success (`0`); failures are `2`.

### 11.1 `task_new_flow <project-id>`

1. Prompt `task name:` (free text).
2. Prompt `create from:` prefilled with the task's/project's `base_ref`
   (`config.default_ref` initially); any ref accepted by git works.
3. Prompt terminal kind: `agent` or `shell`.
4. `git_task_create <project-id> <name> <ref> <kind>`.
5. `tmux_open_tab <project-id> task:<task-id> <kind>`, then activate/focus it.
6. Errors are shown to the user; cancel at any prompt exits `0`.

### 11.2 `task_close_flow <project-id> <task-id>`

1. Warn if the worktree is dirty and if HEAD is detached.
2. First confirmation (`Cancel` does nothing); second confirmation that the
   worktree will be deleted.
3. Kill the task's windows.
4. `git_task_close <project-id> <task-id> --force` after confirmation (or
   `--keep` if the user chooses the no-force path); add `--delete-branch` only
   when the user opts in (default **off**).
5. Cancel at any point exits `0`; git/state failure exits `2`.

### 11.3 `terminal_new_flow <project-id> <context>`

1. Menu `agent | shell`.
2. `tmux_open_tab <project-id> <context> <kind>`.
3. Activate/focus the new tab. Cancel exits `0`.

### 11.4 `project_add_flow`

Required for `C-a P` / `internal add-project`; owned by part 5. Prompts for a
path, calls `balamba project add <path>` (or the git functions directly), shows
errors, and cancels cleanly. It must work when invoked from a tmux `run-shell`
(no controlling client of its own): locate a client or use a popup that targets
one.

---

## 12. `pane/ui.py` contract (part 6)

Invocation: exactly one argument, `tree` or `git`:

```
python3 pane/ui.py tree
python3 pane/ui.py git
```

Environment provided by part 4:

- `BALAMBA_ROOT`: install root (also `@balamba_root`).
- `BALAMBA_STATE`: state file path (read-only for Python).
- `TMUX_PANE`: the pane's own id (always pass `-t "$TMUX_PANE"` for self queries).
- `TMUX`: set by tmux; plain `tmux` then reaches the private server. Do not add
  `-L`; do not assume the default server.

Read config only through tmux:

```
tmux show -gv @balamba_tree_width
tmux show -gv @balamba_git_width
tmux show -gv @balamba_active_refresh
tmux show -gv @balamba_idle_refresh
tmux show -gv @balamba_git_refresh
tmux show -gv @balamba_editor
tmux show -gv @balamba_default_ref
tmux show -gv @balamba_root
tmux show -gv @balamba_context
tmux show -gv @balamba_git_branch
```

Missing values fall back to the same defaults as §4 (30 / 34 / 1 / 5 / 2 / vi /
origin/main / opencode). Never source the bash config from Python.

### 12.1 State and actions

- Read `BALAMBA_STATE` with `json`. Writes are atomic, so a read sees a complete
  document; if parsing ever fails, render a brief "state unavailable" line and
  retry on the next poll instead of exiting.
- **Never write state.** Mutations call the CLI:

```
$BALAMBA_ROOT/bin/balamba internal activate <project-id> <context> [window]
$BALAMBA_ROOT/bin/balamba internal expand <project-id> [task-id]
$BALAMBA_ROOT/bin/balamba internal collapse <project-id> [task-id]
$BALAMBA_ROOT/bin/balamba internal new-task
$BALAMBA_ROOT/bin/balamba internal add-project
$BALAMBA_ROOT/bin/balamba internal new-terminal
$BALAMBA_ROOT/bin/balamba internal close-task <project-id> <task-id>
```

Use `subprocess.Popen`/`run` without a shell; inherit stdout/stderr only for
error visibility. Do not block the render loop on an interactive flow; launch
and continue polling.

- The git pane is read-only. Clicking a file may run
  `tmux display-popup -E -w 90% -h 80% ... git diff`; staging/commit is out of
  scope.
- Editor (`e`) is `tmux display-popup` running `$editor` in the worktree; it is
  a tmux action, not a state mutation.

### 12.2 Mouse protocol (from `docs/spikes.md`)

- At startup: termios raw mode on stdin, then write
  `ESC[?1000h ESC[?1002h ESC[?1006h`. Do **not** enable `1003` (all-motion);
  the traffic is unnecessary.
- Parse SGR mouse: `ESC [ < b ; x ; y (M|m)`. `M` = press/motion, `m` =
  release. x/y are 1-based pane-local cells; subtract 1 for hit-testing.
  Decode `button = b & 3` (0 left, 2 right), `b & 64` = wheel (64 up, 65 down),
  `b & 32` = motion/drag, `b & 4/8/16` = shift/meta/ctrl.
- Press+release on the same row = click. Right press opens the pane's own menu
  (tmux's menu is suppressed while the pane reports the mouse). Wheel moves the
  viewport/selection by ~3 rows in-app; tmux will not scroll for you.
- With `mouse on` (required for border drags/focus), the first click on a
  non-focused pane both focuses and is delivered, so single-click activation is
  safe. Border drags still belong to tmux. Text selection needs `prefix+[`
  (copy-mode) or the outer terminal's Shift+drag; document that in the UI help.
- In `finally` (normal exit, EOF, SIGINT/SIGTERM/SIGHUP): disable
  `1006`, `1002`, `1000` in that order and restore termios. Never leave the
  user's terminal in raw/mouse mode.

### 12.3 Polling and rendering

- Active window tree pane: refresh about every `@balamba_active_refresh` (1 s).
- Inactive tree panes: no focus event arrives when their window becomes active
  (spike 4). Check `#{window_active}` only every `@balamba_idle_refresh` (5 s),
  and use **one** `tmux list-windows -F '#{window_index} #{window_active} #{window_activity_flag}'`
  per check, not one process per window.
- Git pane: only while its window is active, every `@balamba_git_refresh`
  (2 s), plus on focus (`ESC[I` with `focus-events on` + `ESC[?1004h`).
- Unread dots come from `window_activity_flag` (requires `monitor-activity on`,
  already in `tmux.conf`); do not invent custom unread state.
- The tree renders projects → tasks → tabs. Active project expanded; manual
  expand/collapse lives in state and is changed through `internal expand` /
  `internal collapse`.
- Keep the renderer small and dependency-free. If the pane is narrower than
  ~10 columns or shorter than ~5 rows, draw a minimal hint instead of crashing.

### 12.4 Exit and respawn

Chrome panes are created with `remain-on-exit on` and `@balamba_chrome` set to
`tree` or `git`. `ui.py` exits `0` on EOF/SIGHUP and restores the terminal; it
must not install a self-restart loop. Part 4 respawns a dead chrome pane on the
next activation/refresh when the pane option says `tree`/`git`:

```
tmux respawn-pane -k -t <pane-id> -c "$BALAMBA_ROOT" -e BALAMBA_ROOT=... \
  -e BALAMBA_STATE=... "python3 $BALAMBA_ROOT/pane/ui.py tree"
```

This keeps a crashed pane visible for debugging until the next activation and
avoids fork storms.

---

## 13. Window / tab / pane conventions

- One session `balamba`; private socket `balamba`; config from `tmux.conf`.
- **tab = window.** Tab order = ascending `window` index. `renumber-windows off`
  keeps indices stable; the status bar is the clickable tab strip.
- **Chrome is implicit.** Each window always has:
  `[tree | content panes 0..N-1 | git]` left-to-right. Tree is live pane index 0,
  git is the last live index; content panes are everything between.
  Chrome panes never appear in state and are never counted in `pane_count`.
- State pane indices are **content-relative** (`0..pane_count-1`); live tmux
  index = content index + 1. `active_pane` is content-relative too.
- `layout` is the full window layout string (including chrome). On restore apply
  it only if the live pane count equals `pane_count + 2`; otherwise fall back to
  equal content splits and reassert widths.
- `window` is the live window index snapshot. Windows can be moved by the user;
  the next save updates it. `renumber-windows off` + descending moves on restore
  reproduce gaps exactly.
- Empty context (project/task with no tabs): exactly one shell tab on first
  activation. Never leave an empty window.
- Chrome widths are per-window and drift; reassert after attach, on activation,
  and after a layout restore. `window-resized` does not fire for border drags.
- No `pane-border-status`, no extra toolbars, no per-window status extras.

---

## 14. Naming

| Thing | Rule |
|---|---|
| project id | `p_` + basename of the main checkout path; duplicate basenames refused |
| task id | `t_` + slug; unique per project |
| tab id | `tty_` + 8 lowercase hex |
| opencode session | `ses_` + 32 lowercase hex (opencode requires the `ses` prefix) |
| context | `proj` for scratch/project tabs, `task:<task-id>` for a task |
| agent key | key in `BALAMBA_AGENT_*`; shipped: `opencode` |
| tmux socket | `balamba` (`BALAMBA_SOCKET`) |
| tmux session | `balamba` |
| tmux option prefix | `@balamba_` |
| chrome pane tag | `@balamba_chrome` = `tree` / `git` |

Tab display names are free text (`shell 1`, `opencode 1`, …); identity is the
tab id. Agent session titles in opencode are not authoritative; balamba's tab
names are.

---

## 15. Restore recipe (condensed)

The full validated procedure is §10.6. The essential ordering, from
`docs/spikes.md`:

1. Read state; remove tasks whose worktrees vanished; never adopt unknown dirs.
2. If the server is down, start it; unlink a stale socket and retry once.
3. Create windows in ascending saved order (`new-window -d -t balamba:`).
4. Add panes, then apply the saved layout **only if the pane counts match**
   (fewer panes silently truncates; more panes errors).
5. Respawn panes by sorted `pane_index` mapping, in saved slot order; agents
   with `opencode --session ses_…`, shells with `$SHELL`, both in the saved cwd.
6. Set each window's active pane explicitly; layouts do not carry it.
7. Move windows descending into exact saved indices; select the saved active
   window; attach.
8. Reassert tree/git widths after the client size is known.
9. Stagger agent launches; never fork eight cold TUIs at once.

---

## 16. Testing and part-2 status

`./test/run.sh` creates an isolated `HOME`/XDG tree, a throwaway
`TMUX_TMPDIR`/socket, runs `bash -n` on every shell file, then each
`test/t_*.sh`. It exits non-zero on any failure. `BALAMBA_TEST_KEEP=1` preserves
the temp environment.

Part 2 ships and tests: slug/ids, state init/get/update/validate, concurrent
writers, failed-jq safety, config defaults/overrides/validation, `doctor` with
and without state/config, symlink-safe startup, CLI usage errors, missing-lib
messages, and `tmux.conf` parsing/options/bindings.

What is deliberately left to later parts:

- `lib/git.sh`: project validation/add/remove, worktree create/close, status
  JSON, task paths (§9).
- `lib/tmux.sh`: server, session, build/open/restore/save/activate, widths,
  chrome respawn (§10).
- `lib/task.sh`: new-task/close-task/new-terminal/project-add flows (§11).
- `pane/ui.py`: tree and git renderers, mouse, polling, menus (§12).

`bin/balamba` symptoms while those are absent are intentional: `attach`,
`save`, `new-task`, `new-terminal`, `close-task`, `activate` exit `2` with
"not available in this build"; `project add/remove` likewise; `expand`,
`collapse`, `project list`, `task list`, `doctor`, `version` work today.
