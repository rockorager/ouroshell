# Ouroshell

Ouroshell is a Lua desktop shell built on the
[Ourokit](https://github.com/rockorager/ourokit) runtime.

The shell provides a 40px top bar on every output, with that output's clickable
workspaces on the left and local date/time on the right. Workspace names sort
by their leading number, then alphabetically; hidden workspaces are omitted.
Active workspaces have a blue background and urgent workspaces use red text.
The workspace list scrolls horizontally when space is tight, leaving room for
the clock.

The clock follows Keywork's format (`Thu Sep 10  04:32 PM`) and refreshes at the
next minute boundary. Ourokit owns the Wayland connection, rendering, event
loop, Lua VM, and application lifecycle; this repository contains only Lua.

## Run

Build Ourokit, then run Ouroshell from this directory. This bar requires
[Ourokit's per-output panel support](https://github.com/rockorager/ourokit/commit/b2ee04beda0877f28284cbb3d3d6499487be64d3)
or later: `ouro.time`, `ouro.date`, `ouro.spawn`, edge-to-edge layer content,
`outputs = "all"` declarations, and `workspace.outputs` membership. Rebuild
Ourokit rather than using an older installed `ouroctl`.

```sh
cd ~/repos/ourokit
zig build -Doptimize=ReleaseFast

cd ~/repos/ouroshell
../ourokit/zig-out/bin/ouroctl run
```

Pass `--software` to use Ourokit's software renderer. The compositor must
support `wlr-layer-shell`. Workspaces require `ext-workspace-v1`; without it
the bar displays "Workspaces unavailable" and the clock still works.

Bars follow output hotplug automatically. Workspaces are matched by their
protocol group membership, not their names or numeric labels, so identically
named workspaces on different outputs remain separate activation targets.
Unassigned workspaces are not shown on any output's bar.

While Ouroshell is running, reload source changes transactionally with:

```sh
../ourokit/zig-out/bin/ouroctl reload dev.ouro.shell
```

The application's empty `actions` table enables Ourokit's runtime control
interface, including status and source reload.

## Check and preview

Run the Lua behavior checks (requires a standalone Lua interpreter):

```sh
lua tests/bar.lua
```

Preview active, urgent, narrow, unavailable, and empty states on a Wayland
compositor. The fixture clock is fixed; workspace buttons update the selection:

```sh
../ourokit/zig-out/bin/ouroctl run src/preview.lua --software
```

## Layout

- `ouro.json` declares the application identity and entrypoint.
- `src/application.lua` owns the workspace connection, clock task, and panel.
- `src/bar.lua` renders workspace state and time.
- `src/preview.lua` supplies interactive visual fixtures.
