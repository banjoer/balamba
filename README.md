# balamba

A tmux-based, keyboard-first coding workspace: **projects → tasks (git
worktrees) → terminals**, with resume across restarts.

balamba owns a **dedicated tmux server** on the socket `balamba`. It never
attaches to or modifies your normal tmux server. Every command in this document
that touches tmux uses `tmux -L balamba`; a bare `tmux` command still means the
user's usual server.

```
┌──────────────┬────────────────────────────┬─────────────────┐
│ tree   (~30) │ tab content (splits)       │ git      (~34)  │
│ projects     │                            │ branch, ahead   │
│  └ tasks     │                            │ changed files   │
│     └ terms  │                            │                 │
└──────────────┴────────────────────────────┴─────────────────┘
  status bar (bottom): balamba · <context>            [tab] [tab]
```

One tmux session `balamba`; each terminal tab is a tmux window; splits inside a
tab are native tmux panes. The tree and git panes are replicated per window and
are implicit (they never appear in state).

## Requirements

- Linux or another tmux-capable Unix
- `bash` >= 4.2, `tmux` >= 3.0 (tested on 3.4), `python3` >= 3.8 (stdlib only)
- `git`, `jq`, `flock`
- `opencode` for agent tabs (optional; shell tabs work without it)

## Install

From a clone of this repository:

```sh
ln -s "$PWD/bin/balamba" ~/.local/bin/balamba
# alternative: export PATH="$PWD/bin:$PATH"
balamba doctor
balamba            # first run: create the workspace and attach
```

`bin/balamba` is symlink-safe and resolves the install root from its real path.
Put the repository anywhere; no `pip`, no packages.

`balamba doctor` prints one line per check and exits 2 only on hard failures
(missing tools, invalid config/state). A stopped opencode service is a warning.

## Quick start

1. **Add a project.** Start `balamba`, then press `p` in the tree and type the
   path to a git main checkout (spaces are fine). Enter. A shell tab appears in
   the project's checkout. You can also do this from a shell:

   ```sh
   balamba project add /path/to/repo
   ```

2. **Create a task.** Focus the tree and press `n`:
   - `task name:` → e.g. `Fix Login`
   - `create from:` → prefilled `origin/main`; Enter accepts
   - choose `shell` (or `agent`)

   balamba creates `../balamba_worktrees/<repo>/fix-login`, branch `fix-login`,
   and opens the first terminal there. The new branch is created with
   `--no-track`, so it has **no upstream** and a stray `git push` will not
   target main.

3. **Work.** Edit files in the task worktree. The right-hand git pane lists the
   branch, ahead/behind and changed files; Enter on a file opens a diff popup.
   Use native tmux splits (`C-a %`, `C-a "`).

4. **Open another terminal.** Press `C-a T` (or `t` in the tree) and choose
   `agent` or `shell`. You can also attach a second client from another
   terminal with `tmux -L balamba attach -t balamba`.

5. **Close a task.** Select the task row and press `d`. balamba warns about a
   dirty worktree, detached HEAD and unmerged commits. `Cancel` does nothing;
   `Continue` asks one more time. Confirming removes the worktree and keeps the
   branch unless you explicitly choose “delete branch too”.

## Keys

Prefix is `C-a` (rebindable in `tmux.conf`).

### App / tmux bindings (work from any pane)

| Key | Action |
|---|---|
| `C-a N` | new task (same flow as tree `n`) |
| `C-a P` | add project |
| `C-a T` | new terminal (`agent` / `shell` menu) |
| `C-a d` | detach this client |
| `C-a r` | redraw the client |
| `C-a [` | enter copy-mode (see mouse caveat below) |
| `C-a %`, `C-a "` | split content horizontally / vertically |
| `C-a 1..9`, `C-a n/p` | select tab/window |

### Tree keys (when the tree pane is focused)

| Key | Action |
|---|---|
| `j` / `k`, arrows | move selection |
| `g` / `G`, Home/End | top / bottom |
| `h` / `l`, Left/Right | collapse/expand, or move to parent/first child |
| `Enter` | activate the selected project/task/tab |
| `n` | new task in the selected project |
| `t` | new terminal in the selected project/task |
| `d` | close the selected task (dialog) |
| `e` | open the selected worktree in the editor |
| `p` | add project |
| `r` | force a refresh (also redraw data) |
| `q` | no-op (reserved) |

### Git pane keys

| Key | Action |
|---|---|
| `j` / `k`, arrows | move file selection |
| `g` / `G`, Home/End | top / bottom |
| `PgUp` / `PgDn` | page |
| `Enter` | open the diff popup for the selected file |
| `r` | force a status refresh |

### Mouse

`mouse on` is required for click-to-focus and border drags. With the tree/git
pane reporting SGR mouse events:

- click a row to select; click the already-selected row to activate;
- click a chevron to expand/collapse;
- right-click opens the pane's own menu;
- wheel scrolls the pane's list in-app;
- **text selection needs `C-a [` (copy-mode)**, or your outer terminal's
  Shift+drag; tmux does not implement a Shift bypass while a pane reports the
  mouse. Wheel in the tree/git is handled by the app, not tmux.

## Restore semantics

`balamba` attaches if the server is running (nothing is restored). If the
server is gone (detach+quit, crash, reboot) it rebuilds from
`~/.local/state/balamba/state.json`:

Restored: windows/tab order, content pane counts, saved split geometry when the
pane count matches, per-pane cwd, the active window, the active content pane,
and the two sidebar widths (reasserted after attach). Agents are relaunched
with the same `ses_…` id, staggered by `restore_stagger` seconds.

Not restored: scrollback, running processes other than shells/agents (vim and
dev servers become a plain shell in the saved cwd), tmux copy-mode state, and
unread/activity flags (server memory only). A shell tab whose worktree was
removed by hand is dropped from state with a warning at startup; unknown
directories are never adopted.

## Close semantics

`d` on a task:

1. warns if the worktree is dirty, if HEAD is detached, and if the branch has
   commits not merged into its base ref (and unpushed commits when an upstream
   exists);
2. `Cancel` changes nothing; `Continue` opens a second confirmation;
3. confirming kills the task's windows, runs `git worktree remove` (with
   `--force` only after the second confirmation), and removes the task from
   state;
4. the **branch is kept by default**. If you opt into “delete branch too”,
   balamba runs `git branch -d`, so an unmerged branch is never silently
   dropped. No commits, pushes or merges are ever performed by balamba.

## Configuration

Config is a sourced bash file at `~/.config/balamba/config` (or
`$XDG_CONFIG_HOME/balamba/config`). It is loaded fresh for shell work and
mirrored into tmux `@balamba_*` options for the Python panes. Missing config =
defaults.

```bash
# all keys and their defaults
tree_width=30
git_width=34
active_refresh=1          # seconds; active-window tree poll
idle_refresh=5            # seconds; inactive-window activation checks
git_refresh=2             # seconds; active-window git status poll
editor="${EDITOR:-vi}"    # popup editor for tree e
default_ref="origin/main" # prefilled “create from”
default_agent=opencode
restore_stagger=1         # seconds between agent launches on restore (0 = off)
```

Widths must be 5–200; refresh values 1–3600; `restore_stagger` 0–60.
`balamba doctor` validates the config. The tmux mirror is:

```
@balamba_tree_width   @balamba_git_width  @balamba_active_refresh
@balamba_idle_refresh @balamba_git_refresh @balamba_editor
@balamba_default_ref  @balamba_default_agent @balamba_root
```

Runtime options `@balamba_context` and `@balamba_git_branch` are display values
written by activation, not user config.

Internal tmux options (do not edit by hand): `@balamba_tab` (tab id on a
window), `@balamba_project`, `@balamba_context`, `@balamba_git_branch`,
`@balamba_placeholder` (temporary empty-workspace window), `@balamba_chrome`
(`tree`/`git` on a chrome pane) and `@balamba_chrome_attempts` (respawn
throttle).

### Plugging in another agent

Agents are bash associative arrays keyed by agent name. `{{session}}` and
`{{dir}}` are replaced by the launcher; the command is started with the tab's
cwd.

```bash
default_agent=myagent
BALAMBA_AGENT_COMMAND[myagent]='myagent --session {{session}}'
BALAMBA_AGENT_RESUME[myagent]='myagent --resume {{session}}'
BALAMBA_AGENT_LABEL[myagent]='myagent'
```

The shipped agent is **opencode**:

```bash
BALAMBA_AGENT_COMMAND[opencode]='opencode --session {{session}}'
BALAMBA_AGENT_RESUME[opencode]='opencode --session {{session}}'
BALAMBA_AGENT_LABEL[opencode]='opencode'
```

`COMMAND` runs when a tab is first created; `RESUME` runs when balamba rebuilds
a tab after the server is gone. If `RESUME` is empty, `COMMAND` is used for both.
opencode needs the same flag in both cases because it materialises a session on
the first message; the tab is usable before that first message. A third-party
agent may reject the `ses_…` id scheme or need a different create/continue
command. Set both templates, test the resume path yourself, and do not assume
balamba implements an agent protocol or token accounting.

## Troubleshooting

- **Stale socket / server won't start.** `balamba doctor` reports the socket
  state. `tmux -L balamba kill-server` stops only balamba. If the socket file is
  stale and no server is running, `balamba` unlinks it and retries once; as a
  last resort remove `${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/balamba` while no
  balamba process is running. Never use `tmux kill-server` without `-L`.
- **Something looks broken.** Run `balamba doctor`. It checks bash/tmux/python,
  jq/git/flock, config syntax/ranges, state validity, missing project/task
  paths, opencode and the private server/socket. Warnings do not fail the
  command; hard failures exit 2.
- **“opencode service” is stopped.** Agent tabs still launch; opencode may
  start its per-user service on demand. Check with `opencode service status`.
  A down service is deliberately only a doctor warning.
- **A chrome pane is blank.** Press `r` in that pane, or switch windows (`C-a
  n/p`) to give it a fresh poll; the server respawns chrome panes whose
  `remain-on-exit` process died. `C-a r` redraws the client. If the tree says
  “state unavailable”, inspect `balamba doctor` before editing anything.
- **Reset state safely.** Detach all clients, `tmux -L balamba kill-server`,
  then move `~/.local/state/balamba/state.json` out of the way (do not edit it
  in place) and relaunch `balamba`. Worktrees and branches are untouched;
  re-add projects with `balamba project add <path>`.

## Limitations / deferred

- No custom tab strip beyond the tmux status bar; tabs are native windows.
- No desktop/bell notifications or agent-status plugin; unread is tmux
  `window_activity_flag` only.
- No PR, merge or push automation, and no staging/commit UI (read-only git
  panel).
- Only the agent launcher template; arbitrary agents are not guaranteed to
  support the `ses_…` id scheme.
- No search/filter in the tree or git list.
- One private server/session; it is not a general tmux replacement.

## Development

Run the whole suite (bash syntax checks + all tests) from the repository root:

```sh
./test/run.sh
BALAMBA_TEST_KEEP=1 ./test/run.sh   # keep the isolated env and test server
```

Each test file runs in its own process with a throwaway `HOME`/XDG tree, its own
`TMUX_TMPDIR` and a socket named `balamba-test-$$`. The suite never touches the
user's tmux server; `BALAMBA_TEST_KEEP=1` preserves the temp root (and the test
socket) for inspection.

`test/t_e2e.sh` is the end-to-end journey: it attaches a real `bin/balamba`
client under a 120x40 pty, drives prompts/menus/prefix keys/tree keys, and
asserts with `tmux -L <test-socket> capture-pane` and tmux queries. It uses a
fake `less` to capture diff-popup input and deliberately never sends a model
message to opencode (no token spend). `test/e2e_driver.py` contains the pty
driver; `test/helpers.sh` owns isolation and fixtures.

Contracts live in `docs/architecture.md` (state schema, CLI, lib APIs, UI
behaviour), with spike evidence in `docs/spikes.md`; `docs/smoke.md` is the
10-minute manual checklist.

### Refresh policy

Measured on this repository's test environment (tmux 3.4, 8 windows = 16 chrome
panes, 120×40): **≈6% of one core total** (Python UI panes + tmux server) with
`active_refresh=1`, `idle_refresh=5`, `git_refresh=2` (`pidstat`, 20 s average;
approximate, machine-dependent).

- the active window's tree polls every `active_refresh` (1 s);
- inactive tree panes only check activation every `idle_refresh` (5 s) using
  one `list-windows` call, not one process per window;
- the git pane polls every `git_refresh` (2 s) only while its window is active;
- switching to a window fires a `session-window-changed`/`client-attached` hook
  that sends a synthetic focus-in to its tree/git panes, so git status is fresh
  immediately instead of waiting up to `idle_refresh`;
- a completed mouse border drag (`MouseDragEnd1Border`) reasserts the configured
  sidebar widths.

For comparison, the naive policy (every chrome pane polling at 1 Hz) measured
about 24% of one core in `docs/spikes.md`.
