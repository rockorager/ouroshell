# Ouroshell

Ouroshell is a Lua desktop shell built on the
[Ourokit](https://github.com/rockorager/ourokit) runtime.

The shell provides a 40px top bar on every output, with that output's clickable
workspaces on the left and network connectivity, battery charge, and local
date/time on the right. Workspace names sort by their leading number, then
alphabetically; hidden workspaces are omitted.
Active workspaces have a rounded blue background and urgent workspaces use red text.
The workspace list scrolls horizontally when space is tight, leaving room for
the clock. The round button at the left opens the global launcher.

The clock follows Keywork's format (`Thu Sep 10  04:32 PM`) and refreshes at the
next minute boundary. Ourokit owns the Wayland connection, rendering, event
loop, Lua VM, and application lifecycle; this repository contains the shell's Lua.

The battery indicator uses UPower's combined display device over `ouro.dbus`
on the system bus. Its symbolic icon follows charge/charging state, with the
icon and percentage turning red for UPower low-battery warnings. It updates
on property signals, hides when absent or unavailable, and reconnects after
service or bus loss. No polling command or subprocess bridge is used.

The network indicator uses NetworkManager over `ouro.dbus`, following the
primary connection and its Wi-Fi access point's signal strength. Ethernet and
mobile connections have distinct icons; captive portals, limited connectivity,
and offline states have explicit labels. Internet status comes from
NetworkManager's connectivity checks, not Wi-Fi association alone. Property
signals keep it current; it hides during service or bus loss and reconnects.
This is a status indicator, not a network picker or connection manager.

## Run

Build Ourokit, then run Ouroshell from this directory. This bar requires
[Ourokit's per-output panel support](https://github.com/rockorager/ourokit/commit/b2ee04beda0877f28284cbb3d3d6499487be64d3)
or later: `ouro.time`, `ouro.date`, `ouro.spawn`, edge-to-edge layer content,
`outputs = "all"` declarations, and `workspace.outputs` membership. The launcher
also requires layer-surface `background`/`background_effect`, styled boxes,
text-input `placeholder`/`label`, `ouro.stack`, and image fill dimensions.
The battery and network indicators require Ourokit's [D-Bus client](https://github.com/rockorager/ourokit/commit/7f7db21c7d05)
and running UPower and NetworkManager services, respectively.
Rebuild Ourokit with these APIs rather than using an older installed `ouroctl`.

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

## Install with systemd socket activation

Install `ouroctl` in `~/.local/bin` and the shell in
`~/.local/share/ouroshell`, then install the user units:

```sh
mkdir -p ~/.local/share/ouroshell ~/.config/systemd/user
cp -r ouro.json src ~/.local/share/ouroshell/
cp systemd/dev.ouro.shell.{socket,service} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dev.ouro.shell.socket
ouroctl activate dev.ouro.shell
```

Stop any manually launched shell before starting the socket unit. Systemd owns
`$XDG_RUNTIME_DIR/ourokit/apps/dev.ouro.shell`, passes its listener to Ourokit,
and keeps it open across service crashes and restarts. Both units stop with the
graphical session; only the socket is enabled at login. Do not run a separate
shell process alongside the managed service.

Connecting starts the process on demand. Catalog and status requests do not
present windows: use `ouroctl activate dev.ouro.shell` (or `runtime.activate`)
to show the bar before using the launcher. `ouroctl run` with the installed
manifest also activates the existing endpoint. After a service restart, activate
the UI again; window and launcher state are not restored automatically.

For logs and status:

```sh
systemctl --user status dev.ouro.shell.socket dev.ouro.shell.service
journalctl --user -u dev.ouro.shell.service
```

## Global launcher

Click the bar's launcher button or call `launcher.toggle` on the shell's Ourokit
MCP socket. An opaque, theme-colored card with rounded corners surrounds the
content. A lighter charcoal face in dark mode, a fine rim, and a soft downward
shadow separate the card from the desktop. The shadow uses a decorative SVG
through Ourokit's image renderer. A uniform dark translucent tint fills the
selected output below the bar in both light and dark mode. Its opacity is
controlled by the alpha channel of `launcher.background` in `src/launcher.lua`
(currently 30%).
Real backdrop blur is requested through `ext-background-effect-v1`; compositors
without it show the tint without blur.

All combines applications and system actions. Its empty-query view shows the
first three applications alphabetically; Apps browses the full catalog. Search
matches application names, generic names, desktop IDs, and keywords. Up/Down
change selection, Enter opens, and Escape goes back or dismisses. Scope buttons
and rows are clickable. Reopening resets the query and any pending confirmation.
Application-provided menu items are not implemented or shown yet.

System offers Lock screen and Session. Session contains Log out, Restart, and
Shut down; these actions are also directly searchable (including `reboot`,
`shutdown`, and `logout`). Each requires confirmation with **Cancel selected by
default**. Actions use fixed requests, never commands derived from search text:

- Lock: `loginctl lock-session auto`, requiring logind and a session lock handler.
- Log out: Ouro's `exit` tool, ending this compositor session rather than all
  sessions belonging to the user.
- Restart: `systemctl reboot`.
- Shut down: `systemctl poweroff`.

No force flags or privilege bypasses are used. Request submission failures stay
visible in the launcher. Ouro's `run` acknowledges process launch, not eventual
exit status: acceptance does not prove the computer restarted or the screen
locked. System policy, inhibitors, and the installed lock handler still apply.

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
and `launcher.toggle`. With the socket unit enabled, calls start the service
on demand; `runtime.activate` then presents its UI. Without socket activation,
start Ouroshell with `ouroctl run` before calling these tools. The descriptor
alone does not launch a process.

## Check and preview

New Amp orbs run `.agents/setup` to install Zig 0.16.0, Rust 1.94.0, Lua,
and the native build/headless-test packages. Setup clones a pinned Ourokit
revision into `../ourokit`, builds its software renderer, and runs the Lua
checks. It reuses dependency caches and refuses to overwrite an existing
sibling checkout with different or uncommitted work. No services start at boot.
Run `.agents/setup` from the repository root to repeat setup manually; in an orb,
use `/usr/bin/python3 tests/native_launcher.py` for the native tests so Python
can find the system-installed Pillow package.

Run the Lua behavior checks (requires a standalone Lua interpreter):

```sh
lua tests/bar.lua
lua tests/launcher.lua
lua tests/appearance.lua
lua tests/battery.lua
lua tests/network.lua
lua tests/notifications.lua
for file in src/*.lua tests/*.lua; do luac -p "$file"; done
```

The bar and launcher follow ourosettings' `appearance.color_scheme` live,
including custom control colors and the opaque card; the translucent backdrop
stays dark in both themes. `default`
uses the light palette, matching Ourokit. Settings outages retain the last
palette and reconnect without clearing launcher state.

Preview the launcher and active/urgent workspaces on a Wayland compositor.
The clock and application catalog are fixtures; search, scopes, confirmations,
and dismissal remain interactive. Every command is intercepted, so this
preview cannot launch applications, lock, log out, or power off:

```sh
../ourokit/zig-out/bin/ouroctl run src/preview.lua --software
```

## Notifications

Ouroshell owns `org.freedesktop.Notifications` through `ouro.dbus`. The bar's bell
opens a right-edge notification center; `notifications.toggle` does the same
through MCP. New notifications show a popup without taking keyboard focus.
Do Not Disturb suppresses popups but keeps history. Both views follow the system
theme and support dismissal, grouped history and app-provided actions.

Popups use a single surface with an app header. Named app icons keep their
original colors; the `desktop-entry` hint selects an installed application's
icon, with the supplied icon or matching app name as fallbacks. Without icon
metadata, the header shows just the app name. Raw image hints and absolute icon
paths are not supported.

History is one scrollable virtual list, with separate variable-height rows for
app headers and notifications. Group counts cover all retained items. Collapsing
a group removes its message rows; stable row keys preserve the visible scroll
anchor when other messages change. There are no page controls.

The whole surface of a notification with a live default action is clickable,
including its header and padding, without an inner hover highlight. Close and
app-supplied buttons handle their own clicks. Keyboard focus remains visible.
This requires an Ourokit build with content-sized (`height = "auto"`) buttons.

Clicking a notification with a default action requests an XDG activation token
from that input event. Ouroshell sends `ActivationToken` to the notifying client
before `ActionInvoked`. The client must consume the token and activate its
window; Ouro switches to that window's workspace, reveals it if minimized and
focuses it. Notifications without a default action have no implicit app-launch
fallback. Expired notifications remain readable but cannot invoke stale actions.

The daemon supports replacement, expiration, critical/resident/transient hints,
and notification closure signals. It advertises plain-text bodies and actions,
not markup or embedded images. History and DND are in memory only. History is
limited to 100 entries, actions to four per notification, and
pending expiry timers to 64. Critical notifications do not expire automatically.

Run the real D-Bus, click, theme and cross-workspace activation checks on a
private headless desktop with Sway, Grim, Python Pillow and PyGObject installed:

```sh
OUROSETTINGS_TEST_BINARY=../ourosettings/zig-out/bin/ourosettings \
  python3 tests/native_notification_service.py
```

There is also a separate, interactive fixture preview. It requires Ourokit's
native `ouro.switch` control for Do Not Disturb:

```sh
../ourokit/zig-out/bin/ouroctl run src/notification-preview.lua
```

It opens a 420px right-edge panel on the compositor-selected output and follows
the system theme. Expand/collapse app groups, dismiss individual samples, or
clear history. **Try a popup** briefly replaces the panel with a sample toast;
after about six seconds it returns to history. Do Not Disturb suppresses sample
popups without discarding history. **Reset preview** restores the fixtures; the
header close button exits the preview. Sample actions only show feedback.

The fixture preview never owns `org.freedesktop.Notifications` or changes the
live daemon. Its clock is app-scoped; production expiration tasks belong to the
D-Bus export scope so removing a popup cannot cancel them.

Run its native pointer, popup, and theme checks on a private headless desktop:

```sh
OUROSETTINGS_TEST_BINARY=../ourosettings/zig-out/bin/ourosettings \
  python3 tests/native_notifications.py
```

Run the native integration test with `sway`, `grim`, `wtype`, and Python's
Pillow package installed:

```sh
python3 tests/native_launcher.py
```

To also test live theme changes against an isolated ourosettings daemon, set
`OUROSETTINGS_TEST_BINARY` to an absolute path to its executable. The test uses
temporary settings and sockets; it never changes the desktop's appearance.
Pass `--appearance-only` to run the light/dark/default rendering checks without
the keyboard-driven launcher suite.

It starts an isolated headless compositor, creates fixture desktop entries,
and captures launch requests with a fake Ouro endpoint; it does not launch
applications or change the live desktop. Set `OUROSHELL_TEST_ARTIFACTS` to keep
screenshots and logs. It exercises typing, selection beyond the first page,
MCP toggles, dismissal, refocus, source reload, launch errors, safe confirmation
defaults and fixed system requests, resizing, the uniform overlay tint, and the
uncovered bar. Sway verifies the no-blur fallback; real blur needs a compositor
advertising `ext-background-effect-v1`.

Check the systemd units with an installed `~/.local/bin/ouroctl` and an active
graphical session:

```sh
systemd-analyze --user verify systemd/dev.ouro.shell.{socket,service}
python3 tests/socket_activation.py
```

The activation test uses temporary units and a private socket, creates no UI,
and kills only its test service. It verifies on-demand startup, crash recovery
without replacing the listener, reactivation after service shutdown, and socket
removal when the socket unit stops. It leaves the live shell untouched.

## Layout

- `ouro.json` declares the application identity and entrypoint.
- `src/application.lua` owns the workspace connection, clock task, and panel.
- `src/bar.lua` renders workspace state and time.
- `src/battery.lua` owns the UPower subscription and battery indicator.
- `src/network.lua` owns the NetworkManager subscription and connectivity indicator.
- `src/launcher.lua` owns launcher search, state, launch policy, and content.
- `src/preview.lua` supplies interactive visual fixtures.
