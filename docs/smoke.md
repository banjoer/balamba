# balamba smoke test (manual, ~10 minutes)

Run this on a machine with tmux, git, jq, python3 and (optionally) opencode.
Everything below uses the dedicated `balamba` socket. Use a throwaway git repo
with an `origin/main` so you can delete it afterwards.

```sh
# Terminal 1
cd /path/to/balamba
ln -s "$PWD/bin/balamba" ~/.local/bin/balamba   # skip if already installed
balamba doctor

# Throwaway fixture
tmp=$(mktemp -d /tmp/balamba-smoke.XXXXXX)
mkdir -p "$tmp/repo one"
git -C "$tmp/repo one" init -q -b main
git -C "$tmp/repo one" config user.name smoke
git -C "$tmp/repo one" config user.email smoke@example.invalid
printf 'hello\n' >"$tmp/repo one/README.md"
git -C "$tmp/repo one" add README.md
git -C "$tmp/repo one" commit -q -m initial
git init -q --bare -b main "$tmp/repo one.origin.git"
git -C "$tmp/repo one" remote add origin "$tmp/repo one.origin.git"
git -C "$tmp/repo one" push -q -u origin main
```

## 1. First run (empty state)

```sh
balamba
```

Expect: one window with tree (left), a shell (middle), git (right); the tree
says `no projects — press p`. No crash. `C-a d` returns to the shell.

## 2. Add a project with a space in its path

Press `p`, type the fixture path exactly (`/tmp/.../repo one`), Enter.

Expect: tree shows `repo one`; a shell tab opens in the checkout; the tree is
about 30 columns and git about 34 (or your configured values); there are three
columns. Hint: `tmux -L balamba list-panes -t balamba: -F '#{pane_width} #{@balamba_chrome}'`
should show the tree/git widths.

## 3. Create a task

Focus the tree, press `n`:

1. `task name:` → `Fix Login`, Enter.
2. `create from:` is prefilled exactly `origin/main`; press Enter.
3. Menu → `shell` (`s`).

Expect:

```sh
ls "$(dirname "$tmp/repo one")/balamba_worktrees/repo one/fix-login"
git -C "$tmp/repo one" branch --list fix-login
git -C "$tmp/repo one" rev-parse --abbrev-ref --symbolic-full-name 'fix-login@{upstream}'
# the last command must fail: no upstream
```

The tab opens with cwd = the worktree; the git pane header shows `fix-login`.

## 4. Git pane and diff popup

```sh
printf 'changed\n' >>"$(dirname "$tmp/repo one")/balamba_worktrees/repo one/fix-login/README.md"
```

Within ~2 seconds the git pane lists ` M README.md`. Press Enter on that row
(or click it): a popup shows the diff. Quit the pager with `q`. While the
tree/git reports the mouse, text selection needs `C-a [` (copy-mode) or your
terminal's Shift+drag.

## 5. Split, tab switching and unread dots

In a content pane press `C-a %` (side-by-side split); run `printf 'split\n'`.
Create another terminal with `C-a T` → `shell`. In the new tab run
`sleep 2; printf 'unread\n'`, then immediately switch to the first tab with
`C-a <tab-number>`.

Expect: a yellow `●` appears on the background tab row (and its task/project
parents) within a couple of seconds. Visiting that tab (`C-a <number>`) clears
its dot; the parent dot clears when no child tab remains unread.

## 6. Restore after a server kill

Detach (`C-a d`, which also saves on the client-detached hook), then:

```sh
tmux -L balamba kill-server
balamba
```

Expect: same tab order and count, content split geometry (within ~2 columns),
per-pane cwd, active window and active content pane restored. The tree ~30 and
git ~34 widths are reasserted after attach. Scrollback and non-shell/agent
processes are not restored; tabs whose worktree was deleted by hand disappear
with a warning.

## 7. Close a task (warnings, Cancel, two confirmations)

Make the task dirty and unmerged, and detach HEAD:

```sh
wt="$(dirname "$tmp/repo one")/balamba_worktrees/repo one/fix-login"
printf 'dirty\n' >"$wt/dirty.txt"
git -C "$wt" add dirty.txt
git -C "$wt" -c user.name=smoke -c user.email=smoke@example.invalid commit -q -m work
git -C "$wt" checkout -q --detach
```

Select the task row and press `d`.

Expect the dialog to name `detached HEAD`, uncommitted changes, the unmerged
branch and unpushed commits (the title is fitted so tmux does not drop it).
`Cancel` (`q`) keeps everything. `d` → `Continue` (`c`) asks a second time;
only then press `y`. After confirming:

```sh
test ! -e "$wt"                                  # worktree gone
git -C "$tmp/repo one" show-ref --verify refs/heads/fix-login  # branch kept
jq '.projects[0].tasks | length' ~/.local/state/balamba/state.json  # 0
```

## 8. Agent tab

Press `n`, name `Agent Smoke`, accept `origin/main`, choose `agent` (`a`).
Wait 3–7 seconds. Expect an opencode TUI in a tab whose cwd is the task
worktree. Confirm without sending a message:

```sh
jq -r '.projects[] | .tasks[] | .tabs[] | select(.kind=="agent") | .session,
       .panes[0].cwd' ~/.local/state/balamba/state.json
# find the pane pid:
tmux -L balamba list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_path}'
ps -o args= -p <pane-pid>       # contains: opencode --session ses_<32 hex>
```

Do **not** send a message just for the automated test; that costs tokens.

## 9. opencode resume check (the one check automated tests skip)

This is the only place a token is spent; do it manually, once.

1. In the agent tab, send one trivial message: `Reply with exactly: ok`.
2. Wait for the answer, then quit opencode with double `C-c` (this exits the
   TUI; it does not close the tmux tab).
3. Record the id:

   ```sh
   sid=$(jq -r '.projects[] | .tasks[] | .tabs[] | select(.kind=="agent") | .session' \
     ~/.local/state/balamba/state.json)
   echo "$sid"
   opencode session list --format json | jq '.[] | select(.id=="'"$sid"'")'
   ```

4. Restart the server and balamba:

   ```sh
   tmux -L balamba kill-server
   balamba
   ```

5. Open the agent tab again. Expect the same conversation/title to come back,
   and `opencode session list` still contains exactly `$sid`.

## What to include in a bug report

Please include, with paths redacted if needed:

```sh
balamba --version
balamba doctor
tmux -V
python3 --version
uname -a
```

and the state/screen evidence:

```sh
# state file (source of truth; the layout/context fields matter)
jq . ~/.local/state/balamba/state.json

# visible panes
tmux -L balamba list-windows -t balamba -F \
  '#{window_index} #{window_name} #{@balamba_context} #{window_activity_flag}'
tmux -L balamba list-panes -a -F \
  '#{window_index} #{pane_index} #{pane_id} #{@balamba_chrome} #{pane_active} #{pane_current_path}'

# screen of the affected pane (repeat for tree/git/content as needed)
tmux -L balamba capture-pane -p -t <pane-id>
```

Also: exact keys pressed, expected vs actual, whether a second client was
attached, terminal emulator/version, and anything in `opencode service status`.
