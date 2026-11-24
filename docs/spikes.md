# Spike results — balamba risks 1–4

Tested on: tmux 3.4, opencode v2.3.2, python3 (stdlib only), Linux, 4 cores.
Throwaway tmux sockets (`-L balamba-*`, `-f /dev/null` so ~/.tmux.conf never interfered), throwaway repos under `/tmp/opencode/balamba-spike`. No production code written.

Verdict summary:

| # | Risk | Verdict |
|---|------|---------|
| 1 | opencode session identity | **Works with caveat** — id must start with `ses`; session materialises only on the first message |
| 2 | mouse forwarding | **Works with caveat** — forwarding is reliable; text selection / wheel need explicit handling |
| 3 | layout restoration | **Works with caveat** — layout is mapped by pane index, not pane id; count must match; active pane/window must be set explicitly |
| 4 | replicated chrome | **Works with caveat** — widths are per-window and drift; polling must be policy-driven |

---

## Risk 1 — opencode session identity

### Tested

1. `opencode --session <plain-uuid>` in a fresh git repo.
2. `opencode --session ses_<32hex>` in the same repo (TUI driven through tmux with `send-keys`), before and after the first message.
3. `opencode session list --format json` from the main checkout, from a linked worktree, and from a second project.
4. Quit + relaunch with the same id; capture the screen to see prior history.
5. `opencode run --session <id>` to create a session non-interactively.
6. Session scoping in a worktree created with `git worktree add`.
7. Process tree / RSS / startup latency of a TUI.

### Results

**The id must start with `ses`.** A plain UUID is rejected before the TUI starts:

```
$ opencode --session 7012137a-1852-45da-941c-bde01f9e3faf
Error: Expected a string starting with "ses"
  at ["sessionID"]
```

`ses_` + `uuid4().hex` (32 hex chars) is accepted and becomes the *exact* session id:

```
$ opencode --session ses_8906e44491c34810b84a665030bc5985   # TUI opens, no error
$ opencode session list --format json
[{"id":"ses_8906e44491c34810b84a665030bc5985",
  "title":"Exact reply request",
  "projectId":"d3127d2cd03e3a116381161bef898e6b94fda92a",
  "directory":"/tmp/opencode/balamba-spike/proj-a"}]
```

**Creation is lazy.** After launching the TUI with a fresh id but *before* sending a message, `session list` is still `[]`. The session row appears only after the first message is sent. Quitting the TUI without a message does not create it.

**Cheapest identity confirmation.** There is no zero-token CLI confirmation:
- `session list` is empty until a message exists.
- `session export <fresh-id>` → `Session not found: <id>`.
- `opencode run --session <id> ""` → `Error: You must provide a message` (client-side, no session created).
- `opencode api POST /api/session` ignores a supplied `id` and creates its own (`ses_b64e…`) in the server's default directory, not the cwd. Unusable for pre-creating an id.

The only reliable check is to send one trivial turn, e.g.:

```
$ opencode run --session ses_57a8… --title spike-run-a "Reply with exactly: ok"
> build · deepseek-v4.1-flash
ok                                          # one tiny request; wall 6.7 s (16.9 s when box was loaded)
$ opencode session list --format json       # now contains the exact id
```

Recommendation: don't pre-verify in `doctor`. Generate the id, pass it to `--session`, and verify lazily from `session list` once the user has typed.

**Resume works.** Double `C-c` exits the TUI; relaunching the same command restores the conversation (title and previous prompt/answer visible in the captured pane). It also resumed when launched from a *linked worktree*, but the footer stayed on the session's stored directory (`…/proj-a:main`), i.e. opencode treats the session's stored `directory` as authoritative, not the launch cwd.

**Scoping is per git project, not per cwd.** A session created in `/tmp/…/proj-a-wt` (a linked worktree) is listed from both the worktree and the main checkout:

```
$ (cd proj-a-wt && opencode session list --format json)
ses_c973e6eb6c1e43268b131010369b610c  /tmp/opencode/balamba-spike/proj-a-wt
ses_57a8cacb435945cabd93a14ee0c4837b  /tmp/opencode/balamba-spike/proj-a
```

Caveat: project identity is computed once and cached. A directory first opened as a non-git dir and later `git init`-ed kept the old project id, so `session list` in it stayed empty while the new session was filed under the new project id. Balamba only adds dirs that are already git checkouts, so this should not bite, but `doctor` should not trust an empty list in a directory whose git status changed.

**Server / process lifecycle.**

```
$ opencode service status
http://127.0.0.1:49374
$ ps -o pid,rss,args -p <tui-pid>       # a TUI has no child server
 642714  161004  …/opencode --session ses_8906…
$ pgrep -af 'opencode serve --service'
3101540 …/opencode serve --service      # one per-user service, up since Nov 22
```

- Every CLI/TUI (`run`, `session list`, TUI) connects to the same long-lived background service; it is per-user, not per-project and not per-cwd.
- A TUI spawns **no** server child. Killing tmux panes therefore leaves no zombies; only the shared service remains (it predates balamba and should be left alone).
- `--standalone` exists and would give each TUI its own private server — do not use it.
- Warm TUI ready-to-prompt: **3.1 s and 5.0 s** in two runs (one earlier run took 7.3 s while a broken MCP server auth attempt added ~1.4 s). `run` took 6.7 s. Expect ~3–7 s per agent pane.
- RSS ≈ **160 MB per TUI**, plus ~650 MB for the shared service. Eight agent tabs ≈ 1.3 GB of TUIs. Restore should stagger agent launches, not fork eight at once.
- Two TUIs on the same session id ran concurrently without an error during the spike, but that state was not exercised for correctness. Keep one pane per session id.
- If the shared service is down, auto-start was **not** tested (stopping it would disrupt the user's live sessions).

### Recommendation

- Generate ids as `ses_` + `uuid.uuid4().hex` (or match opencode's own `ses_…` format); store that string as the terminal's `session_id`.
- Launch exactly `opencode --session "$session_id"` with cwd set to the tab's saved cwd. The same command resumes after a restart; no separate "resume" code path is needed.
- Do not block startup waiting for a session to appear. `session list` is empty until the first message; that is normal.
- Track opencode's own auto-title only if useful for display; balamba should keep its own names in state/tab title (spec already says this).
- `doctor`: check `opencode --version` and `opencode service status`, not session existence.
- Stagger agent launches on restore (~0.5–1 s apart) to avoid eight cold TUIs hammering the shared service.

### Spec impact

**Contradiction:** SPEC says “generated UUID at creation ... `opencode --session <uuid>`”. A bare UUID is rejected by opencode 2.3.2. Amend to “opencode session id, generated as `ses_<32 hex>`”.
Minor: SPEC says “Session titles are not set in opencode”. True that balamba won't set them, but opencode auto-titles from the first message (`Exact reply request`). Harmless; balamba's own name should stay authoritative.

---

## Risk 2 — mouse forwarding into a pane app

### Tested

Minimal Python app (`mouselog.py`) that sets raw mode, writes `ESC[?1000h ESC[?1002h ESC[?1006h`, and logs parsed SGR events. Two injection paths:

1. `tmux send-keys -l` with raw sequences — proves the app parses press/release/right/wheel.
2. A throwaway pty harness (`fakeclient.py`) that runs `tmux -L … attach` under a real pty and writes SGR sequences to the pty master — proves **tmux** forwards events from the terminal into the pane.

Then: click on a non-focused pane, border drag, drag-select in a non-mouse pane, wheel, right click, `mouse off`, Shift-modified events.

### Results

**App parses SGR mouse.** Injected bytes (`11,6` left press/release, right click, wheel) produced:

```
$ tmux -L balamba-spike send-keys -t sp:app -l $'\x1b[<0;11;6M'   # etc.
1795534979.850 READY … 80x24
1795534980.558 MOUSE b=0 x=11 y=6 M
1795534980.567 MOUSE b=0 x=11 y=6 m
1795534980.581 MOUSE b=2 x=25 y=6 M
1795534980.587 MOUSE b=2 x=25 y=6 m
1795534980.595 MOUSE b=64 x=30 y=10 M
```

SGR format: `ESC [ < b ; x ; y (M|m)`; `M` press/motion, `m` release; x/y are **1-based, pane-local** cells.

**tmux mirrors the app's mouse mode and forwards events.** With the app requesting 1000/1002/1006, the outer client received the same enable sequences, and a real press/release injected at terminal cell (11,6) arrived at the app unchanged:

```
$ COLS=80 ROWS=24 python3 fakeclient.py balamba-spike sp:app inject1.txt
client received: ESC[?1000h True  ESC[?1002h True  ESC[?1006h True
app log: MOUSE b=0 x=11 y=6 M / m, b=2 x=25 y=6 M / m, b=64 x=30 y=10 M
```

**Click on a non-focused pane: focuses *and* delivers.** Two side-by-side mouse-enabled panes; left focused; click at terminal x=60, y=10 (right pane starts at column 61):

```
before: %2 left=0  w=40 active=1 | %3 left=41 w=39 active=0
after:  %2 left=0  w=40 active=0 | %3 left=41 w=39 active=1
right app: MOUSE b=0 x=19 y=10 M / m      # x is pane-local (60-41=19)
left app:  nothing
```

tmux's binding does exactly this:

```
bind-key -T root MouseDown1Pane  select-pane -t = \; send-keys -M
bind-key -T root MouseDrag1Pane  if-shell -F "#{||:#{pane_in_mode},#{mouse_any_flag}}" { send-keys -M } { copy-mode -M }
bind-key -T root MouseDown3Pane  if-shell -F -t = "#{||:#{mouse_any_flag},…}" { select-pane -t = ; send-keys -M } { display-menu … }
```

So with `mouse_any_flag=1`, tmux does **not** steal the click; it focuses and forwards. Right-click is also forwarded (verified `b=2`), and tmux's own context menu is suppressed.

**Border drag still works with mouse-enabled panes.** Drag on the divider (x=41) from x=41 to x=61:

```
before: %2 w=40 | %3 w=39
after:  %2 w=60 | %3 w=19      # neither app received the drag
```

**Text selection / copy-mode break when the app reports the mouse.** In a normal pane, drag enters copy-mode and selects; in a mouse-reporting pane the drag goes to the app (`b=32` motion, verified) and tmux does no selection. Wheel is also forwarded (`b=64`), so tmux's copy-mode scrolling does not happen; the app must scroll itself. Conversely, in a pane with no reporting, wheel enters copy-mode and drag selects via `copy-mode -M`.

**`mouse off` does not disable app forwarding.** tmux still requested 1000/1002/1006 from the terminal and forwarded events to the app (because the pane asked). But it disabled tmux's own mouse actions: border drag did nothing, and clicking a non-focused pane delivered the event **without focusing**. `mouse on` is required for click-to-focus and border drags.

**Shift is not an escape hatch inside tmux.** Shift+click/drag (b=4 / b=36) was forwarded to the app like any other event; tmux does not implement a shift-bypass. Text selection while an app reports the mouse must rely on the *outer terminal* (most terminals do local selection on Shift+drag, terminal-dependent — not verifiable from inside tmux) or on `prefix + [` copy-mode.

### Recommendation

In the Python pane (tree/git):

- At startup: raw mode on stdin, then write `ESC[?1000h ESC[?1002h ESC[?1006h`; in `finally`, write `ESC[?1006l ESC[?1002l ESC[?1000l` and restore termios. Do not enable 1003 (all-motion) — unnecessary traffic.
- Parse `ESC[<b;x;y(M|m)` with a small state machine that tolerates partial reads. Decode: `button = b & 3` (0 left, 2 right), `b & 64` = wheel (64 up, 65 down), `b & 32` = motion/drag, `b & 4/8/16` = shift/meta/ctrl. x/y minus 1 → 0-based row for hit-testing.
- Implement click semantics: press+release on the same row = click; motion between = drag (for the tree, a press/release on the same row is enough; ignore drags). Right press (`b&3==2`, no wheel bit) opens your own menu — tmux will not show its menu.
- Implement wheel yourself: move the selection/viewport by ~3 rows per event. tmux will not scroll the pane for you.
- The **first click** on a non-focused pane focuses and is delivered, so single-click activation is safe.
- With `mouse on` (required for border drags + focus), tmux keeps border drags and status-bar clicks; your pane never sees them.
- Text selection: document `prefix + [` (works) and Shift+drag (terminal-level). Do not try to support mouse text selection inside the app while reporting the mouse; if you need copy, implement it in-app or leave a keyboard path.
- Keep `mouse on` globally (spec already assumes this); `mouse off` gives delivery without focus and kills border drags.

### Spec impact

No contradiction. Add an implementation note: right-click menus only work because the app reports the mouse (`mouse_any_flag`); text selection/copy-mode is unavailable in mouse-reporting panes and needs `prefix+[` / Shift+drag.

---

## Risk 3 — layout restoration

### Tested

Built a 120×40 session with 3 windows:
- `tab0`: tree 30 cols, content split vertically 70/30 (54×27 / 54×12), git 34 cols.
- `tab1`: 3 equal columns.
- `tab2`: 5 equal columns.
Captured `#{window_layout}` per window, active pane per window, active window, then `kill -9` the server, rebuilt the same pane counts in order, applied each layout, and compared geometry. Also tested mismatched counts, applying a 120×40 layout to an 80×24 window, attaching a differently sized client, window index gaps, and stale sockets.

### Results

Captured layout for `tab0`:

```
8d97,120x40,0,0{30x40,0,0,1,54x40,31,0[54x27,31,0,0,54x12,31,28,3],34x40,86,0,2}
```

**Pane ids in the string do not matter for mapping.** Applied the same string to a fresh window with 4 panes at different ids/positions; geometry matched the original exactly, and the resulting layout had different ids and a different checksum:

```
before apply: %0 60x40 | %1 29x40 | %2 14x40 | %3 14x40
after apply:  %0 30x40@0,0 | %1 54x27@31,0 | %2 54x12@31,28 | %3 34x40@86,0
layout after: 059e,…{30x40,0,0,0,54x40,31,0[54x27,31,0,1,54x12,31,28,2],34x40,86,0,3}
```

Panes are matched **in pane-index order** to the layout's leaves in geometric order (left→right, top→bottom). After `select-layout`, tmux renumbers `pane_index` to geometric order. Consequence: recreate N panes in the same *slot order* as the saved `list-panes` order; then new pane index *k* = saved pane index *k*.

**If the rebuild order matches the saved order, the layout string is byte-identical.** In the full 3-window rebuild, each captured string re-applied with the same ids/checksum (`059e…` etc.) because fresh servers allocate `%0…` in creation order and we rebuilt in order. Do not depend on that; geometry is the real contract.

**`select-layout` resizes the window to the layout's size.** Applying a 120×40 layout to an 80×24 detached window produced a 120×40 window with the correct panes. On attach with a 100×30 client the window became 100×29 and the layout **scaled proportionally** (tree 30→23, 70/30 → 21/7). So restore-before-attach works, but the configured 30/34 sidebar widths are not preserved; reassert them after attach.

**Pane-count mismatch.**

```
fewer panes (3) : exit 0, silently applies a truncated layout
                  0 30x40@0,0  1 89x27@31,0  2 89x12@31,28        # git column dropped
more panes (5)  : exit 1, "have 5 panes but need 4: <layout>", window unchanged
1 pane          : exit 0, one full-window pane (layout ignored)
```

The "fewer panes" case is dangerous because it succeeds. Check `#{window_panes}` against the saved leaf count (store the count in state) before applying.

**Active pane is not restored by the layout.** `select-layout` keeps whichever pane was active in the new window (the last split), not the saved one. Set it explicitly with `select-pane`. Verified after `select-pane -t <saved-index pane>`.

**Windows / order / active window.**

```
new-window -d -t b:        # trailing colon: fills lowest free index, avoids name ambiguity
move-window -s b:name -t b:5   # place at a free index; target occupied => "index in use: 1"
```

- Use `-t <session>:` when creating; `-t <session>` is ambiguous if a window has that name (observed `create window failed: index 1 in use`).
- Gaps are allowed. Restore exact indices by creating windows in ascending saved order (they get `0..N-1`) then moving **descending** to the saved indices; verified `[0,2,5]` with `2→5` then `1→2`.
- `select-window -t b:<idx>` sets the session's current window while detached, and attach honours it (verified with a 100×30 client). `select-pane` persists per window.

**Dead server / stale socket.** After `kill -9 <server-pid>`, the socket file remains, but:

```
$ tmux -L balamba-e2e has-session
no server running on /tmp/tmux-1000/balamba-e2e     # exit 1
$ tmux -L balamba-e2e -f /dev/null new-session -d …
# exit 0 — tmux replaced the stale socket
```

One earlier attempt hit `server exited unexpectedly` after `kill-server` while the old server was still tearing down; a retry after removing `/tmp/tmux-<uid>/<socket>` worked. Mitigation: if `start-server`/`new-session` fails, unlink the socket path and retry once.

### Restore algorithm (validated end-to-end, 3 windows, exact geometry)

```
1. Read state: per window -> window_index, name, pane_count, window_layout,
   per pane (index order): kind (agent|shell), cwd, command, active flag.
   Save active_window_index and each window's active pane index.
2. If `tmux -L balamba has-session` fails, start a fresh server:
   tmux -L balamba -f ~/.config/balamba/tmux.conf new-session -d -s balamba -n <first tab>
   (if this fails, unlink the stale socket and retry once).
3. For each saved window in ascending index order:
   - create it: new-window -d -t balamba: -n <name>   (first window reuses the session's window)
   - add pane_count-1 panes with plain splits (any geometry; it is about to be replaced)
   - if the new pane count == saved count: select-layout -t <win> '<saved layout>'
     else: fall back (see below)
4. Now `list-panes -F '#{pane_index} #{pane_id}'` (sorted) maps new index k to saved pane k.
   For each pane k: respawn-pane -k -t <pane_id> -c <cwd> <command>
   (agents: opencode --session <id>; shells: $SHELL; anything else: $SHELL in cwd).
5. select-pane -t <new pane id at the saved active index> in each window.
6. Move windows to their exact saved indices, descending (only if indices have gaps).
7. select-window -t balamba:<saved active index>.
8. Attach. After the client size is known, reassert chrome widths:
   resize-pane -t <tree> -x <config.tree_width>; resize-pane -t <git> -x <config.git_width>
   (layout scaling on attach changes absolute widths).
```

Fallback when counts differ: do **not** apply the layout (fewer panes silently truncates). Build by role instead: tree at config width, git at config width, content panes split evenly down the middle column (`split-window -v -l <100/n>%` repeatedly) and `resize-pane` the sidebars. Equal percent splits are sufficient per spec.

### Spec impact

No contradiction, but sharpen the restore bullet: “when the pane count matches” must be an explicit `#{window_panes}` check because a smaller count does not error. Also add “active pane and active window are not in `window_layout`; store and restore them separately” and “reassert sidebar widths after attach”.

---

## Risk 4 — replicated chrome

### Tested

- Three 120×40 windows, each with identical tree/content/git layouts. Widened one window's tree, checked the others; attached a 100×30 client and measured all windows and all tree widths, before/during/after switching.
- 8 Python pollers calling `tmux display -p -t <pane> '#{window_active} #{window_activity_flag} #{window_id}'` at 1 Hz and 0.2 Hz; 2 pollers at 1 Hz. CPU from `os.times()` (self + children).
- `monitor-activity` on/off; output in active vs inactive windows; flag clearing while attached/detached; `alert-activity` hook; `window-resized` hook.
- Pane self-discovery via `$TMUX_PANE` and `$TMUX`; plain `tmux` vs explicit `-t`.
- `focus-events on` + `ESC[?1004h` in a pane; window switches, pane switches, detach.

### Results

**Widths are per-window and drift.**
`window-size` default is `latest`; `window-size manual` is only set by `resize-window` (not by `select-layout`).

```
initial:                     w0 tree 30 | w1 tree 30 | w2 tree 30   (all 120x40)
resize w0 tree -> 45:        w0 tree 45 | w1 tree 30 | w2 tree 30
attach 100x30 client to w0:  w0 100x29, tree 38 | w1 120x40, tree 30 | w2 120x40, tree 30
switch to w1 (client 100x30): w1 100x29, tree 23 | w2 still 120x40
switch to w2:                w2 100x29, tree 23
```

So only the active window resizes to the client; inactive windows keep their size until visited; each visit scales that window's layout, so identical config widths end up as 23/38/etc. tmux has no cross-window layout sync. Border drags in one window also change only that window.

**Polling cost (rough; 4-core box under other load).**

| setup | calls in 20 s | Python self CPU | tmux child CPU | ≈ one core |
|---|---|---|---|---|
| 8 panes @ 1 Hz (naive) | 138 | 0.92 s | 3.81 s | **24 %** |
| 2 panes @ 1 Hz (active only) | 38 | 0.21 s | 0.88 s | **5.5 %** |
| 8 panes @ 0.2 Hz (idle check) | 32 | 0.56 s | 0.25 s | **4 %** |

Sequential single call: ~6–15 ms CPU; under 8-way concurrency the per-call cost inflated to ~27 ms CPU / 122 ms wall. One `list-windows -F` call returns all windows' flags in one shot, so a refresh needs one process, not one per window.

**`window_activity_flag` semantics.**

- `monitor-activity` is **off by default**; without `set -g monitor-activity on` the flag never sets.
- Set when a window that is **not active** produces output — any output, including a single byte with no newline (`printf x` set it). Output in the active window does not set it.
- Cleared when the window becomes active **while a client is attached**; `select-window` while detached did **not** clear it. After detach the flag persists (server memory only; lost on restart).
- Works as the unread marker: `list-windows -F '#{window_index} #{window_name} #{window_activity_flag}'`.
- `alert-activity` hook fires for the right window (`window=@2 idx=2`), so it can trigger an immediate refresh or set a custom `@unread` option if you ever need richer state.

**`window-resized` hook** fires on `resize-window`/client resize with `#{window_id}`/`#{window_width}x#{window_height}`, but **not** on `resize-pane` (border drag). `client-resized` also exists.

**Pane self-discovery.**

```
$TMUX=/tmp/tmux-1000/balamba-chrome,637814,0     # plain `tmux` works without -L
$TMUX_PANE=%11
$ tmux display -p -t "$TMUX_PANE" '#{window_id} idx=#{window_index} active=#{window_active} flag=#{window_activity_flag} pane=#{pane_id}'
win=@2 idx=2 active=0 flag=1 pane=%11
$ tmux display -p '#{window_id}'                  # no -t: WRONG
@0                                                # client's current window
```

Always pass `-t "$TMUX_PANE"` (and rely on `$TMUX`, no `-L`). Without `-t`, a background pane reports the client's current window, not its own.

**Focus events** (`set -g focus-events on`, default off; app writes `ESC[?1004h`) deliver `ESC[I` / `ESC[O` on window switch and detach. But they are pane-level: a non-focused pane in a window that becomes active receives **nothing** (verified with a two-pane window whose focused pane was the right side). They are useful for instant refresh when the tree itself is focused, not as a “my window became active” signal.

### Recommendation

- Keep `set -g window-size latest` (default) and `set -g mouse on`.
- Sidebar policy: after attach and after every window resize/activation, reassert both chrome widths for the visible window:
  `resize-pane -t <tree> -x <config.tree_width>` and `resize-pane -t <git> -x <config.git_width>`.
  Do it from the `window-resized` hook (covers attach/client resize) and on focus/activation (covers switches). For border-drag drift, either bind `MouseDragEnd1Border` to also re-run the reassert, or compare widths during the 1 Hz refresh and correct. A config change should loop over all windows once.
- Polling policy (matches measured costs):
  - Active window's tree pane: one `tmux list-windows -F '#{window_index} #{window_activity_flag} #{window_active}'` every 1 s, then render.
  - Inactive tree panes: poll `#{window_active}` every ~5 s (or block on stdin and wake on `ESC[I` if focused). This is the pragmatic “sleep”; a literal zero-poll sleep cannot notice activation because non-focused panes get no focus event.
  - Git pane: refresh on focus + every 2 s only when its window is active.
  - Content panes are agents and manage themselves.
  - Optional: use `alert-activity` to set `@unread` and/or nudge a refresh; use `session-window-changed` + `tmux wait-for` if you want zero-latency wake-ups without polling. Not needed for v1.
- Set `monitor-activity on` in tmux.conf; consider `visual-activity off` to avoid status-line noise.
- Clear unread state by visiting the window normally (flag clears with a client attached); no custom bookkeeping required.

### Spec impact

- “Sidebar width is a config value applied to every window” is **not automatic** in tmux; it needs the reassert above. This is the main contradiction to flag.
- “Only panes in the active window refresh; the rest sleep” is achievable only with a low-frequency activation check or an explicit signal; non-focused panes do not receive focus events.
- Add `monitor-activity on` to the tmux config; without it `window_activity_flag` never sets.
- “Clicking a pane focuses it (native tmux)” is true only with `mouse on`.

---

## Anything the next agent must know

- opencode session ids are **`ses_…`**, not UUIDs. Generate `ses_` + `uuid4().hex`.
- `opencode --session` is create-on-first-message; no cheap pre-flight. One tiny `run` is the cheapest explicit probe, but you don't need it if you trust the flag (verified).
- The shared `opencode serve --service` is global and long-lived; TUIs have no child server and leave no zombies. `--standalone` would change that — don't use it.
- Budget ~3–7 s and ~160 MB per agent pane; stagger restore launches.
- Mouse: enable 1000+1002+1006, parse SGR; tmux focuses + forwards the first click on a non-focused pane; border drags stay with tmux; text selection and wheel must be handled in-app (or via `prefix+[` / terminal Shift+drag).
- Layout: `select-layout` matches **pane index order** to geometric leaves, ignores the ids in the string, resizes the window to the layout's size, and silently truncates if there are fewer panes — check the count first and set active pane/window separately.
- Chrome widths and active-window resizing are per-window; reassert widths after attach/activation.
- `monitor-activity on` is mandatory for unread flags; the flag clears only when a client views the window.
