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
next minute boundary. Timers stop during suspend, so logind's `PrepareForSleep`
resume signal refreshes and realigns it immediately. Ourokit owns the Wayland connection, rendering, event
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
and running UPower and NetworkManager services, respectively. D-Bus
subscriptions use `close_on_owner_change`, and the launcher uses
`ensure_visible`, `focus_request`, and `ouro.color.with_alpha`. These require
Ourokit [84e44a8](https://github.com/rockorager/ourokit/commit/84e44a8844a1)
or later.
Idle handling additionally requires the native session/authentication work:
`ouro.session.idle`, `outputs`, `power`, `lock`, `ouro.lock_surface`,
`ouro.auth.start`, the masked `ouro.text_input` bound to a conversation, and
`ouro.spawn_app`. These require
Ourokit [66b3e64b27fb](https://github.com/rockorager/ourokit/commit/66b3e64b27fb4f911671d8a8b6c1264d7cb52834)
or later, which the setup script pins. See Ourokit's `docs/session.md` for
the native API contracts and security limits.
Rebuild Ourokit with these APIs rather than using an older installed `ouroctl`.

```sh
cd ~/repos/ourokit
zig build -Doptimize=ReleaseFast

cd ~/repos/ouroshell
../ourokit/zig-out/bin/ouroctl run --mcp
```

Pass `--software` to use Ourokit's software renderer. The compositor must
support `wlr-layer-shell`. Workspaces require `ext-workspace-v1`; without it
the bar displays "Workspaces unavailable" and the clock still works.

Bars follow output hotplug automatically. Workspaces are matched by their
protocol group membership, not their names or numeric labels, so identically
named workspaces on different outputs remain separate activation targets.
Unassigned workspaces are not shown on any output's bar.

For development, stop the managed shell and launch a private development copy.
Use the exact endpoint printed by that process to reload source changes:

```sh
../ourokit/zig-out/bin/ouroctl run --dev
../ourokit/zig-out/bin/ouroctl dev reload "$development_socket"
```

Production `--mcp` exposes only declared actions, including `launcher.toggle`
and `notifications.toggle`. It does not expose status, reload, or activation.
Development endpoints are private per process, not the global launcher socket.

## Install as a systemd user service

Install the matching `ouroctl` in `~/.local/bin`. Validate the native lock and
PAM policy described below before enabling the service. Install the shell in
`~/.local/share/ouroshell`, then install the user unit:

```sh
mkdir -p ~/.local/share/ouroshell ~/.config/systemd/user
cp -r ouro.json src ~/.local/share/ouroshell/
cp systemd/dev.ouro.shell.service ~/.config/systemd/user/
mkdir -p ~/.local/share/dbus-1/services
cp systemd/org.freedesktop.Notifications.service ~/.local/share/dbus-1/services/
systemctl --user daemon-reload
systemctl --user enable --now dev.ouro.shell.service
```

Stop any manually launched shell before starting the service. When upgrading
from socket activation, stop the old service and disable/stop
`dev.ouro.shell.socket` before starting the new service; remove the old socket
unit file. Ourokit no longer adopts systemd listeners.

The service launches the panel and notification daemon directly with `--mcp`.
It owns `$XDG_RUNTIME_DIR/ourokit/apps/dev.ouro.shell` and stops with the graphical
session. Do not run a separate shell process alongside the managed service.
Window and launcher state are not restored after a restart. Graceful shutdown
removes the endpoint. After a forced kill while **unlocked**, remove a stale
endpoint only after confirming no process still owns it, then restart the
service. If the session was locked, follow the recovery procedure below;
restarting Ouroshell does not recover a held compositor lock.

Stop and disable another notification daemon before activating Ouroshell. Only
one service can own `org.freedesktop.Notifications`; Ouroshell retries if another
daemon owns it. The D-Bus descriptor routes notification-triggered startup to
the same systemd service, not a second shell process.

For logs and status:

```sh
systemctl --user status dev.ouro.shell.service
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

System offers Lock screen, Session, Caffeinate (Decaffeinate while active),
and Switch to dark/light theme. Caffeinate pauses inactivity handling; see below
for its scope. The theme action runs `prefer set color-scheme dark|light`, since
prefer's setter is Varlink-only; the shell then follows the portal's change.
It is searchable as `theme`, `dark mode`, and `light mode`.
Session contains Log out, Restart, and Shut down; these actions are also
directly searchable (including `reboot`,
`shutdown`, and `logout`). Each requires confirmation with **Cancel selected by
default**. Actions use fixed requests, never commands derived from search text:

- Lock: acquire a native session lock inside Ouroshell.
- Log out: Ouro's `exit` tool, ending this compositor session rather than all
  sessions belonging to the user.
- Restart: `systemctl reboot`.
- Shut down: `systemctl poweroff`.

No force flags or privilege bypasses are used. Request submission failures stay
visible in the launcher. Ouro's `run` acknowledges process launch, not eventual
exit status: acceptance does not prove the computer restarted. Native locking
waits for the compositor's `locked` event. System policy and inhibitors still
apply to power requests.

Exec parsing and field-code expansion are delegated to
`ouro.xdg.applications.prepare_launch`; no command is shell-evaluated. Launches
go to Ouro's `run` tool at `$XDG_RUNTIME_DIR/ouro.mcp.sock` as argv. Desktop-entry
working directories are preserved with `env --chdir=DIR -- ...`. Terminal
entries use Monstar's explicit `monstar -e COMMAND ARG...` form. DBus-only
entries without `Exec` are not presented, and `TryExec` is deliberately ignored.

The launcher, notification center and notification popup are mutually
exclusive. One `overlay` signal in `src/application.lua` names whichever is
showing, and the reactive `windows()` declaration derives the windows from it.
A notification never replaces the launcher or the open center; it stays in
history instead. The bar stays mounted while overlays come and go. Development reload
accepts structural window changes and resets the launcher's Lua state.

Ourokit pins Wayring's destroyed-object dispatch fix, which is required to
close a focused window without losing the shared Wayland connection.

## Idle, locking, and lid close

Ouroshell owns idle timers, per-output power control, the lock screen and PAM
authentication through Ourokit. No swayidle, swaylock or wlopm processes or
companion units are used. The defaults in `src/config.lua` are:

- **5 minutes idle:** acquire a native session lock.
- **10 minutes idle:** turn all displays off; input turns them on.
- **30 minutes idle:** request suspend through logind.
- **Before suspend:** lock, including when suspend comes from closing the lid.
- **After resume:** turn displays back on. Authentication is still required.
- **Explicit lock:** handle logind's session Lock signal, including the launcher.

Display-off and automatic suspend wait for the compositor's actual `locked`
acknowledgement. Ouroshell holds a logind sleep-delay inhibitor and releases it
only after that acknowledgement when preparing to sleep. Logind bounds this
delay with `InhibitDelayMaxSec`: a failed or slow lock cannot guarantee a secure
resume once that deadline expires. Errors never authorize unlock.

The lock screen covers all outputs, including hotplugged displays, with a
centered credential card and clock. The password field is Ourokit's ordinary
`text_input`, masked and bound to the PAM conversation: it shows PAM's prompt
as a hint while empty and one dot per character, including for echo-on
prompts, and sends the text to PAM natively; credentials never pass through
Lua. Only a successful PAM result for the current lock and authentication
attempt can unlock. Enter submits a response, not an unlock authorization. Escape in the credential field cancels authentication while
keeping the session locked.
Authentication is canceled before sleep and restarted on resume.

The account comes from logind's session identity. `pam_service = "login"` in
`src/config.lua` is a development default, **not a portable approved locker
policy**. Review the machine's PAM service and authentication/account rules
before relying on this locker; configure a dedicated service if appropriate.
Do not accept account or PAM-service names from lock-screen text or MCP input.

**Recovery:** current Ouro remains locked after the acknowledged lock owner
dies and rejects replacement lockers. A shell/service restart cannot recover
that desktop. From a trusted VT or SSH login, identify the affected graphical
session with `loginctl list-sessions`, then terminate that specific session
with `loginctl terminate-session SESSION_ID` and start a fresh graphical login.
This ends its applications and can lose unsaved work. Test access to this
recovery path before testing the locker. Do not reload or restart a locked
shell; Ourokit rejects reload while holding a lock.

Lid-close policy stays with logind (`HandleLidSwitch`, `HandleLidSwitchDocked`,
and `HandleLidSwitchExternalPower` in `logind.conf`). Ouroshell does not override
docked/external-display policy or take a `handle-lid-switch` inhibitor. A lid
close that logind ignores does not itself lock or suspend the desktop.

**Caffeinate** closes Ouroshell's native idle timers, wakes displays and
acquires a logind `idle` block inhibitor over D-Bus for `IdleAction`.
**Decaffeinate** closes the inhibitor FD and creates fresh native idle timers.
It does **not** disable manual locking, lock-before-suspend, lid-close suspend,
or an explicit suspend request. Other applications' inhibitors remain in force.
Logind idle inhibitors are system-wide, so this can affect other sessions too.
The launcher changes its label only after acquisition succeeds; failures stay
visible. Closing the launcher retains the inhibitor. Reloading/stopping the
shell or losing logind releases it and resets the toggle; it is not persisted.

The user service manager must have the session's `WAYLAND_DISPLAY` environment
(import it during compositor startup, before starting the service). The
compositor must advertise `ext-idle-notify-v1`, `ext-session-lock-v1`, and
`wlr-output-power-management-unstable-v1`. Do not run a second idle manager in
parallel. Manually running Ouroshell uses the same policy as the user service.

This is not an audited production locker. Disposable protocol/PAM fixtures
cannot validate physical DPMS, lid policy, actual suspend/resume, the deployed
PAM stack or trusted recovery. Validate those on the target desktop before
enabling automatic locking or depending on lock-before-suspend.

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

The descriptor exposes `launcher.toggle` and `notifications.toggle`. Start the
service (or `ouroctl run --mcp`) before calling these tools. The descriptor
does not launch a process, and production endpoints do not expose development
status/reload or desktop activation.

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
lua tests/clock.lua
lua tests/idle.lua
lua tests/lock.lua
lua tests/launcher.lua
lua tests/appearance.lua
lua tests/battery.lua
lua tests/network.lua
lua tests/notifications.lua
lua tests/notification_service.lua
lua tests/notification_image.lua
for file in src/*.lua tests/*.lua; do luac -p "$file"; done
```

The shell follows the D-Bus Settings portal's `org.freedesktop.appearance`
`color-scheme` live, including custom control colors and the opaque card;
the translucent backdrop stays dark in both themes. Dark (`1`) selects the
dark palette; light (`2`), no preference (`0`), missing settings, and portal
loss use light, matching Ourokit. Portal restarts trigger a fresh read without
polling or clearing launcher state. No ourosettings daemon is required.

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

Popups use a single surface with one image/icon slot in the app header. The
selection follows the notification specification: `image-data`, then
`image-path`, then `app_icon`, then deprecated `icon_data`. The legacy
`image_data` and `image_path` aliases also work; modern spellings win within
each kind. If none supplies an image, the `desktop-entry` hint or a matching
application name can supply a named icon from the installed catalog.

Raw image data accepts RGB/RGBA8 pixels, including padded rows and alpha.
`image-path` and `app_icon` accept a local absolute path, local `file://` URI,
or named icon. A website/PWA notification image takes the place of Chrome's
icon, rather than appearing alongside it. The sender name can still be Chrome.
History shows each notification's selected image beside its title; group
headings show only the application name and count, never a shared site image.
Without image metadata there is no placeholder slot.

This requires Ourokit's `ouro.images.load` API. File reads and decoding run off
the UI thread, with a 4 MiB input limit and maximum dimensions of 1024×1024.
Images are retained as thumbnails up to 128px per side, so history survives
temporary-file deletion. Remote URIs, symlinks, non-regular files, malformed
images and oversized images are ignored without rejecting notification text.

History is one scrollable virtual list, with separate variable-height rows for
app headers and notifications. Group counts cover all retained items. Collapsing
a group removes its message rows; stable row keys preserve the visible scroll
anchor when other messages change. There are no page controls.

The whole surface of a notification with a live default action is clickable,
including its header and padding, without an inner hover highlight. Close and
app-supplied buttons handle their own clicks. Keyboard focus remains visible.
This requires an Ourokit build with content-sized (`height = "auto"`) buttons.

Additional actions appear beside dismiss in the header while the card is hovered
or contains keyboard focus.
A single action appears directly; multiple actions use an Options button that
opens a native Wayland `xdg_popup`, in the application's original order.
Settings is treated like any other action. The menu is anchored to Options,
separate from the card's layout and parent surface, so it cannot grow the card or
be clipped by a virtual history row. The compositor flips or slides it at screen
edges. Tab/Shift+Tab reaches the trigger and menu actions; Enter/Space activates
them.
Escape or an outside click dismisses the menu; history restores focus to
Options, while banners restore their non-focus-stealing keyboard policy.
Moving the pointer into the menu keeps it open. Replacement,
expiry, or removal of the parent closes its menu.

The trigger's horizontal header space is reserved so revealing it does not move
the message. Actions add no footer or extra banner height.
Both banners and history use this behavior. Notification arrival never takes
keyboard focus; only opening Options temporarily enables keyboard interaction
on a banner. This requires Ourokit's `ouro.popup` API and
`on_interaction_change` callback.

Keyboard opening also requires the compositor to accept keyboard-event serials
for `xdg_popup.grab`. Use an Ouro build with keyboard-initiated popup-grab
support. Older pointer-only builds still allow keyboard navigation after
opening a menu with the pointer. The native integration tests run on an
isolated Sway desktop.

Clicking a notification with a default action requests an XDG activation token
from that input event. Ouroshell sends `ActivationToken` to the notifying client
before `ActionInvoked`. The client must consume the token and activate its
window; Ouro switches to that window's workspace, reveals it if minimized and
focuses it. Notifications without a default action have no implicit app-launch
fallback. Expired notifications remain readable but cannot invoke stale actions.

The daemon supports replacement, expiration, critical/resident/transient hints,
and notification closure signals. It advertises plain-text bodies, actions,
`icon-static` and `persistence`, not markup or body-image attachments. History and DND are in memory only.
History is limited to 100 entries, actions to four per notification, and pending
expiry timers to 64. Critical notifications do not expire automatically.

Run the real D-Bus, click, theme and cross-workspace activation checks on a
private headless desktop with Sway, Grim, Python Pillow and PyGObject installed:

```sh
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
python3 tests/native_notifications.py
```

Run the native integration test with `sway`, `grim`, `wtype`, and Python's
Pillow and PyGObject packages installed:

```sh
python3 tests/native_launcher.py
```

The test provides its own Settings portal on a private D-Bus session; it never
changes the desktop's appearance. Pass `--appearance-only` to check live
light/dark/default rendering, startup without a portal, owner loss, and restart
without the keyboard-driven launcher suite.

It starts an isolated headless compositor, creates fixture desktop entries,
and captures launch requests with a fake Ouro endpoint; it does not launch
applications or change the live desktop. Set `OUROSHELL_TEST_ARTIFACTS` to keep
screenshots and logs. It exercises typing, selection beyond the first page,
MCP toggles, dismissal, refocus, source reload, launch errors, safe confirmation
defaults and fixed system requests, resizing, the uniform overlay tint, and the
uncovered bar. Sway verifies the no-blur fallback; real blur needs a compositor
advertising `ext-background-effect-v1`.

The native launcher test also uses a private logind fixture with real D-Bus FD
passing to verify Caffeinate/Decaffeinate, denied requests, inhibitor retention
after dismissal, and release on reload. It never inhibits the host or suspends
it. Lua tests cover logind owner loss and in-flight stale replies. Physical
lid switches, PAM authentication, DPMS, and actual suspend need desktop testing.

The native session integration test requires the matching Ourokit source and
binary. It uses a private wire compositor, test-only PAM library, and private
logind service; it never authenticates against host PAM or suspends the host:

```sh
OUROKIT=/path/to/ourokit OUROCTL=/path/to/ourokit/zig-out/bin/ouroctl \
  /usr/bin/python3 tests/native_session.py
```

It exercises withheld lock acknowledgement, output hotplug, keyboard-driven
PAM prompts, denial/retry, sleep-delay ownership, resume, Caffeinate and
Decaffeinate. Set `OUROSHELL_TEST_ARTIFACTS` to retain compositor-side captures
of the real lock surfaces. Runtime development capture and synthetic input
are disabled for secure credential fields.

Check the systemd units with an installed `~/.local/bin/ouroctl` and an active
graphical session:

```sh
systemd-analyze --user verify systemd/dev.ouro.shell.service
```

The native tests use private development endpoints for diagnostics/reload and
the standard D-Bus application interface for notification activation. They do
not install units or restart the live shell.

## Layout

- `ouro.json` declares the application identity and entrypoint.
- `src/application.lua` wires the services, owns the overlay signal, and declares windows.
- `src/config.lua` holds desktop choices: icon theme, terminal, idle timeouts and PAM service.
- `src/dbus_support.lua` supervises D-Bus sessions: reconnect with backoff, errors, dictionaries.
- `src/appearance.lua` follows the Settings portal's color scheme.
- `src/clock.lua` keeps minute-aligned local time across suspend.
- `src/idle.lua` owns native idle/output power policy and logind sleep/idle inhibitors.
- `src/lock.lua` owns native lock/authentication state and the lock-screen UI.
- `src/catalog.lua` loads the desktop-entry catalog shared by the launcher and notifications.
- `src/bar.lua` renders workspace state and status.
- `src/battery.lua` owns the UPower subscription and battery indicator.
- `src/network.lua` owns the NetworkManager subscription and connectivity indicator.
- `src/launcher.lua` owns launcher search, state, launch policy, and content.
- `src/notifications.lua` implements the `org.freedesktop.Notifications` daemon.
- `src/notification_center.lua` holds notification history and renders cards, popups and the center.
- `src/preview.lua` and `src/notification-preview.lua` supply interactive visual fixtures.
- `tests/fake_ouro.lua` is the shared stand-in for the `ouro` module in Lua tests.
