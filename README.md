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

The application's actions table enables Ourokit's runtime control interface,
including status, source reload, and `launcher.toggle`.

## Application launcher

Call `launcher.toggle` on the shell's Ourokit MCP socket to show or dismiss the
centered launcher. It discovers visible XDG desktop applications in a spawned
task, then searches names, generic names, desktop IDs, and keywords. Arrow keys
change selection, Enter launches, Escape dismisses, and results are clickable.

Exec parsing and field-code expansion are delegated to
`ouro.xdg.applications.prepare_launch`; no command is shell-evaluated. Launches
go to Ouro's `run` tool at `$XDG_RUNTIME_DIR/ouro.mcp.sock` as argv. Desktop-entry
working directories are preserved with `env --chdir=DIR -- ...`. Terminal
entries use Monstar's explicit `monstar -e COMMAND ARG...` form. DBus-only
entries without `Exec` are not presented, and `TryExec` is deliberately ignored.

Visibility is a signal read by the reactive `windows()` declaration. The bar
stays mounted while the launcher window comes and goes. Source reload currently
requires the same window ID set: dismiss the launcher before reloading.

Ourokit pins Wayring's destroyed-object dispatch fix, which is required to
close a focused window without losing the shared Wayland connection.

## MCP discovery

Register the shell's runtime tools with the local `ouro-mcp` bridge using the
installed Ourokit runtime. Export generates the schemas without starting a bar:

```sh
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$data_home/ouro/mcp/apps"
ouroctl mcp export ouro.json \
  --output "$data_home/ouro/mcp/apps/dev.ouro.shell.json"
```

Then call the bridge's `reload-tools` tool. Descriptor discovery is explicit;
ordinary tool calls and waiting do not discover new installations. Repeat the
export and reload after changing actions or upgrading Ourokit's runtime tools.

The descriptor exposes `runtime.status`, `runtime.reload`, `runtime.activate`,
and `launcher.toggle`. It does not launch Ouroshell: start it with `ouroctl run`
as above before calling these tools. `runtime.activate` presents the UI of an
already-running application; it does not start an absent process.

## Check and preview

Run the Lua behavior checks (requires a standalone Lua interpreter):

```sh
lua tests/bar.lua
lua tests/launcher.lua
for file in src/*.lua tests/*.lua; do luac -p "$file"; done
```

Preview active, urgent, narrow, unavailable, empty, and populated launcher
states on a Wayland compositor. The fixture clock is fixed; controls remain
interactive:

```sh
../ourokit/zig-out/bin/ouroctl run src/preview.lua --software
```

Run the native integration test with `sway`, `grim`, and `wtype` installed:

```sh
python3 tests/native_launcher.py
```

It starts an isolated headless compositor, creates fixture desktop entries,
and captures launch requests with a fake Ouro endpoint; it does not launch
applications or change the live desktop. Set `OUROSHELL_TEST_ARTIFACTS` to keep
screenshots and logs. It exercises typing, selection beyond the first page,
MCP toggles, dismissal, refocus, source reload, launch errors, and shutdown.

## Layout

- `ouro.json` declares the application identity and entrypoint.
- `src/application.lua` owns the workspace connection, clock task, and panel.
- `src/bar.lua` renders workspace state and time.
- `src/launcher.lua` owns launcher search, state, launch policy, and content.
- `src/preview.lua` supplies interactive visual fixtures.
