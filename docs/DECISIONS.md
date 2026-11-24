# Decisions and behavior changes

Short log of choices made during the integration pass; contracts stay in
`docs/architecture.md`.

## 2026-11 integration pass

- **Cold start loads `tmux.conf`.** `start-server` exits when there is no session,
  so the surviving server was actually started by the first `new-session` with
  the default config (prefix `C-b`, `mouse off`, `monitor-activity off`). Every
  `new-session` now passes `-f "$BALAMBA_TMUX_CONF"`; regression coverage is in
  `test/t_tmux.sh` and the e2e journey relies on `C-a` + mouse.
- **No activate-then-delay race.** `internal new-task` accepts an optional
  project id and `internal new-terminal` optional project/context. The UI names
  the clicked target directly; the old 0.35 s timer and its pending command
  queue are gone. Regression: `test/t_ui.sh` race block.
- **Activation nudge.** A `session-window-changed` / `client-attached` hook sends
  a synthetic focus-in to the new window's tree/git panes. Git refresh is
  immediate on a switch; idle panes still poll at `idle_refresh`. Measured about
  6% of one core for 8 windows (16 chrome panes) with the default intervals; see
  README.
- **Border drags reassert widths.** `MouseDragEnd1Border` runs the width helper
  because `window-resized` does not fire for border drags.
- **Popup/menu client targeting.** `display-popup`/`display-menu` receive `-c`
  for the client viewing the calling pane (preferring the pane's active client),
  and are skipped when no client is attached. The editor menu item is a direct
  `display-popup` tmux command (the previous `tmux display-popup` shell-out
  could reach the wrong server).
- **Menu titles are fitted to 100 columns.** tmux 3.4 silently refuses a
  `display-menu` wider than the client; a verbose close summary made the whole
  dialog vanish. The summary is truncated with `…`, not dropped.
- **Python minimum is 3.8** (tested on 3.12). `doctor` checks 3.8 and
  `test/t_ui.py` parses `pane/ui.py` with the 3.8 grammar.
- **Agent resume template is used.** `BALAMBA_AGENT_RESUME` is now actually
  honoured by restore/rebuild (empty falls back to `BALAMBA_AGENT_COMMAND`);
  previously only the command template was used.
- `internal status` keeps its documented failure contract for missing/non-repo
  paths (one JSON error object, exit 2); the git pane renders it and stays alive.
  Covered by `test/t_git.sh` and `test/t_ui.sh`.
