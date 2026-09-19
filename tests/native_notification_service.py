#!/usr/bin/env python3
"""Real D-Bus notifications and pointer interactions, on a private desktop/bus."""
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time

from PIL import Image, ImageChops
from gi.repository import Gio, GLib
from native_launcher import BINARY, ROOT, call, virtual_pointer, wait_for


def main():
    with tempfile.TemporaryDirectory(prefix="ouroshell-service-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        config = directory / "sway.conf"
        config.write_text("output * mode 1280x800\noutput * bg #608099 solid_color\nseat seat0 fallback true\nseat seat0 xcursor_theme test-invisible 24\nfocus_on_window_activation focus\n")
        data = directory / "data"
        (data / "applications").mkdir(parents=True)
        (data / "icons").mkdir()
        # A transparent Xcursor fixture excludes the software cursor from
        # pixel comparisons without hiding the pointer (which sends leave).
        cursors = data / "icons/test-invisible/cursors"
        cursors.mkdir(parents=True)
        (cursors / "left_ptr").write_bytes(struct.pack("=17I",
            0x72756358, 16, 0x10000, 1, 0xfffd0002, 24, 28,
            36, 0xfffd0002, 24, 1, 1, 1, 0, 0, 0, 0))
        (data / "applications/fixture-chat.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Fixture Chat\nIcon=fixture-chat\nExec=true\n")
        icon = Image.new("RGB", (24, 24), "#df2860")
        icon.paste("#24bacc", (0, 0, 12, 12))
        icon.paste("#29b77b", (12, 12, 24, 24))
        icon.save(data / "icons/fixture-chat.png")
        path_image = Image.new("RGB", (48, 48), "#ffd000")
        path_image.paste("#0055ff", (29, 0, 48, 48))
        path_fixture = directory / "history image #1.png"
        path_image.save(path_fixture)
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, WLR_BACKENDS="headless",
                   XDG_DATA_HOME=str(data),
                   XCURSOR_PATH=str(data / "icons"), XCURSOR_THEME="test-invisible",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman", LIBSEAT_BACKEND="noop",
                   DBUS_SESSION_BUS_ADDRESS=f"unix:path={directory}/bus",
                   DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={directory}/no-system-bus")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("DISPLAY", None)
        processes, pointer = [], None
        with (artifacts / "native.log").open("w") as log, (artifacts / "signals.log").open("w") as signal_log:
            def start(argv, output=log):
                process = subprocess.Popen(argv, env=env, stdout=output, stderr=log)
                processes.append(process)
                return process

            try:
                start(["dbus-daemon", "--session", "--nofork", f"--address={env['DBUS_SESSION_BUS_ADDRESS']}"])
                wait_for((directory / "bus").exists, "private bus missing")
                # Trace at the libwayland server: Ourokit's native wayring
                # client does not implement libwayland's WAYLAND_DEBUG flag.
                env["WAYLAND_DEBUG"] = "server"
                start(["sway", "-c", str(config)])
                del env["WAYLAND_DEBUG"]
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless Sway missing")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                wait_for(lambda: list(directory.glob("sway-ipc.*.sock")), "private IPC missing")
                ipc = str(next(directory.glob("sway-ipc.*.sock")))
                pointer = virtual_pointer(env["WAYLAND_DISPLAY"])
                start(["wtype", "-s", "600000"])  # Keep keyboard capability present.
                time.sleep(.2)
                settings_path = directory / "ouro/settings.mcp.sock"
                start([os.environ["OUROSETTINGS_TEST_BINARY"], "--socket", str(settings_path),
                       "--state", str(directory / "settings.json"), "--idle-ms", "300000"])
                wait_for(settings_path.exists, "private settings missing")
                app = start([str(BINARY), "run", str(ROOT / "ouro.json"), "--software"])
                endpoint = directory / "ourokit/apps/dev.ouro.shell"
                wait_for(endpoint.exists, "shell missing")

                bus = Gio.DBusConnection.new_for_address_sync(env["DBUS_SESSION_BUS_ADDRESS"],
                    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
                received = []
                def receive(connection, sender, path, interface, member, args):
                    received.append((member, args.unpack()))
                    signal_log.write(f"{member} {args.print_(True)}\n")
                    signal_log.flush()
                bus.signal_subscribe("org.freedesktop.Notifications", "org.freedesktop.Notifications", None,
                    "/org/freedesktop/Notifications", None, Gio.DBusSignalFlags.NONE, receive)
                def pump():
                    context = GLib.MainContext.default()
                    while context.pending(): context.iteration(False)

                def method(name, *args):
                    signature = {"Notify": "(susssasa{sv}i)", "CloseNotification": "(u)"}.get(name, "()")
                    if name == "Notify":
                        args = list(args)
                        args[5] = GLib.Variant.parse(GLib.VariantType("as"), args[5], None, None).unpack()
                        args[6] = args[6] if isinstance(args[6], dict) else {}
                    return bus.call_sync("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                        "org.freedesktop.Notifications", name, GLib.Variant(signature, args), None,
                        Gio.DBusCallFlags.NONE, 5000, None)

                time.sleep(1)
                assert "Ouroshell" in method("GetServerInformation").unpack()
                assert "actions" in method("GetCapabilities").unpack()[0]
                time.sleep(.2)

                def notify(title, timeout=0, replaces=0, actions="[]", app_name="Files", body="Your download is ready.",
                           app_icon="folder-download-symbolic", hints=None):
                    reply = method("Notify", app_name, replaces, app_icon, title, body, actions, hints or {}, timeout)
                    return reply.unpack()[0]

                def signal(member, notification_id, value):
                    expected = (member, (notification_id, int(value.split()[1]) if value.startswith("uint32 ") else value.strip("'")))
                    def found():
                        pump()
                        return expected in received
                    wait_for(found, str(expected))

                def hover(x, y):
                    subprocess.run(["swaymsg", "-s", ipc, f"seat seat0 cursor set {x} {y}"], env=env, check=True, stdout=log)
                    time.sleep(.2)

                def click(x, y, leave=True):
                    # Let newly mapped/replaced cards settle, then enter the
                    # target even when successive clicks use the same point.
                    hover(0, 0)
                    hover(x, y)
                    commands = ["seat seat0 cursor press button1", "seat seat0 cursor release button1"]
                    if leave: commands.append("seat seat0 cursor set 0 0")
                    for command in commands:
                        result = json.loads(subprocess.check_output(["swaymsg", "-s", ipc, "-t", "command", command], env=env))
                        assert all(item["success"] for item in result), result
                        time.sleep(.05)
                    time.sleep(.3)

                def popup_geometry():
                    # xdg_popup.configure is in parent-surface coordinates.
                    # Both shell layers are top-right anchored with these
                    # margins; read menu size/placement from the compositor.
                    trace = (artifacts / "native.log").read_text()
                    # libwayland versions use either @ or # before object IDs.
                    events = list(re.finditer(r"xdg_popup[@#](\d+)\.configure\((-?\d+), (-?\d+), (\d+), (\d+)\)", trace))
                    if not events:
                        return None
                    event = events[-1]
                    identity, x, y, width, height = map(int, event.groups())
                    if re.search(rf"xdg_popup[@#]{identity}\.(?:destroy|popup_done)\(", trace[event.end():]):
                        return None
                    return 1280 - 420 - 16 + x, 56 + y, width, height

                def select_menu(index):
                    geometry = popup_geometry()
                    assert geometry, "expected a mapped native xdg_popup"
                    x, y, width, height = geometry
                    click(x + width // 2, y + 5 + 32 * index + 16)

                def keys(*names):
                    # Keep each virtual keyboard alive: removing the current
                    # device makes Sway publish an empty keymap mid-traversal.
                    start(["wtype", "-s", "100", *sum((["-k", name] for name in names), []), "-s", "600000"])
                    time.sleep(.5)

                def banner_sizes():
                    return re.findall(r"zwlr_layer_surface_v1[@#]\d+\.set_size\(420, (\d+)\)",
                                      (artifacts / "native.log").read_text())

                def popup_parent_keyboard():
                    trace = (artifacts / "native.log").read_text()
                    parent = re.findall(r"zwlr_layer_surface_v1[@#](\d+)\.get_popup\(", trace)[-1]
                    return int(re.findall(rf"zwlr_layer_surface_v1[@#]{parent}\.set_keyboard_interactivity\((\d+)\)", trace)[-1])

                def scroll(delta):
                    subprocess.run(["swaymsg", "-s", ipc, "seat seat0 cursor set 1000 450"], env=env,
                                   check=True, stdout=log)
                    time.sleep(.1)
                    # virtual_pointer() creates zwlr_virtual_pointer_v1 as ID 4.
                    payload = struct.pack("=IIi", int(time.monotonic() * 1000) & 0xffffffff, 0, int(delta * 256))
                    pointer.sendall(struct.pack("=II", 4, (20 << 16) | 3) + payload)  # axis
                    pointer.sendall(struct.pack("=II", 4, (8 << 16) | 4))  # frame
                    time.sleep(.3)

                def capture(name):
                    time.sleep(.5)
                    status = call(endpoint, "runtime.status")["structuredContent"]
                    assert app.poll() is None and status["diagnostic"] is None, (status, (artifacts / "native.log").read_text())
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(artifacts / f"{name}.png")], env=env, check=True)
                    with Image.open(artifacts / f"{name}.png") as image:
                        # The private bus has no battery/network: status is bell,
                        # then clock. Find their ink groups across the large gap,
                        # allowing the date's width to vary without fixed clicks.
                        bar = image.convert("RGB").crop((780, 0, 1280, 40))
                        background = Image.new("RGB", bar.size, bar.getpixel((499, 0)))
                        ink = ImageChops.difference(bar, background).convert("L").point(lambda value: 255 if value > 32 else 0)
                        groups = []
                        for x in range(ink.width):
                            if ink.crop((x, 0, x + 1, 40)).getbbox():
                                if not groups or x - groups[-1][1] >= 16:
                                    groups.append([x, x])
                                else:
                                    groups[-1][1] = x
                        assert len(groups) == 2, f"{name}: expected visible bell and clock, got {groups}"
                        left, right = groups[0]
                        assert 8 <= right - left <= 20 and groups[1][1] - groups[1][0] > 100, \
                            f"{name}: bell must be left of clock"
                        assert groups[1][0] - right <= 22, f"{name}: bell adds extra padding before clock"
                    return 780 + (left + right) // 2

                def color_count(image, box, expected, tolerance=18):
                    pixels = image.convert("RGB").crop(box).getdata()
                    return sum(all(abs(pixel[channel] - expected[channel]) <= tolerance for channel in range(3))
                               for pixel in pixels)

                def padded_raw(width, height, rgba_rows):
                    rowstride = width * 4 + 8
                    encoded = bytearray()
                    for y in range(height):
                        encoded.extend(rgba_rows(y))
                        encoded.extend(b"padding!")
                    assert len(encoded) == rowstride * height
                    return GLib.Variant("(iiibiiay)",
                        (width, height, rowstride, True, 8, 4, bytes(encoded)))

                first = notify("Downloading…", timeout=1000)
                assert notify("Download complete", replaces=first, actions="['open', 'Open file']") == first
                bell_x = capture("popup-light")
                time.sleep(1)
                pump()
                assert not any(member == "NotificationClosed" and args[0] == first for member, args in received)
                hover(1000, 112)
                capture("single-action-hover-light")
                with Image.open(artifacts / "popup-light.png") as before, Image.open(artifacts / "single-action-hover-light.png") as after:
                    assert ImageChops.difference(before, after).crop((1100, 152, 1250, 192)).getbbox(), "single action did not reveal"
                    assert not ImageChops.difference(before, after).crop((850, 60, 1250, 150)).getbbox(), "revealing actions moved the message"
                hover(0, 0)
                capture("single-action-hidden-again")
                with Image.open(artifacts / "popup-light.png") as before, Image.open(artifacts / "single-action-hidden-again.png") as after:
                    assert not ImageChops.difference(before, after).crop((844, 56, 1264, 216)).getbbox(), "pointer-only popup retained its action"
                click(1205, 174)
                signal("ActionInvoked", first, "'open'")
                token_index = next(i for i, (member, args) in enumerate(received) if member == "ActivationToken" and args[0] == first)
                action_index = received.index(("ActionInvoked", (first, "open")))
                assert token_index < action_index and received[token_index][1][1], "activation token missing or out of order"
                signal("NotificationClosed", first, "uint32 2")
                expiring = notify("Short-lived popup", timeout=1000)
                click(bell_x, 20)  # Bell opens center, removes popup but not the expiry task.
                signal("NotificationClosed", expiring, "uint32 1")
                capture("center-light")
                click(1214, 170)  # DND on.
                call(endpoint, "notifications.toggle")
                quiet = notify("Quiet delivery", timeout=1000)
                capture("quiet-no-popup")
                with Image.open(artifacts / "quiet-no-popup.png") as image:
                    content = image.convert("RGB").crop((10, 50, 1280, 800))
                    assert not ImageChops.difference(content, Image.new("RGB", content.size, (96, 128, 153))).getbbox(), "DND left a popup visible"
                signal("NotificationClosed", quiet, "uint32 1")
                call(endpoint, "notifications.toggle")
                current = call(settings_path, "settings.get")["structuredContent"]
                call(settings_path, "settings.set_section", arguments={"expected_revision": current["revision"],
                    "section": "appearance", "value": {"color_scheme": "dark"}})
                capture("center-dark-dnd")
                click(1214, 170)
                for index in range(6):
                    notify(f"Download {index + 1} complete", app_name=f"Application {index}",
                           actions="['a', 'Open file', 'b', 'Show folder', 'c', 'Copy path', 'd', 'Archive']",
                           body="A longer notification message. " * 50)
                capture("capacity-dark")
                scroll(700)
                capture("scrolled-history-dark")
                with Image.open(artifacts / "capacity-dark.png") as before, Image.open(artifacts / "scrolled-history-dark.png") as after:
                    assert ImageChops.difference(before, after).crop((860, 250, 1245, 650)).getbbox(), "wheel did not scroll history"
                closed = notify("Client-closed notification")
                method("CloseNotification", closed)
                signal("NotificationClosed", closed, "uint32 3")
                call(endpoint, "notifications.toggle")
                popup = notify("Ready to go", actions="['open', 'Open file']")
                capture("popup-dark")
                method("CloseNotification", popup)
                fixture = directory / "activation.lua"
                fixture.write_text('''local o = require("ouro")
return o.app { id = "dev.ouro.activation-test", actions = {}, run = function() return { windows = {
  o.window { id = "main", title = "Notification activation target", width = 500, height = 300,
    content = function() return o.text { key = "message", text = "Activated from a notification" } end },
} } end }
''')
                start([str(BINARY), "run", str(fixture), "--software"])
                target = directory / "ourokit/apps/dev.ouro.activation-test"
                wait_for(target.exists, "activation target missing")
                time.sleep(.7)
                subprocess.run(["swaymsg", "-s", ipc, '[app_id="dev.ouro.activation-test"] move container to workspace number 2; workspace number 1'], env=env, check=True, stdout=log)
                def focused_target():
                    tree = json.loads(subprocess.check_output(["swaymsg", "-s", ipc, "-t", "get_tree"], env=env))
                    def walk(node):
                        if node.get("app_id") == "dev.ouro.activation-test": return node.get("focused", False)
                        return any(walk(child) for child in node.get("nodes", []) + node.get("floating_nodes", []))
                    return walk(tree)
                assert not focused_target(), "test target wasn't hidden on another workspace"
                actionable = notify("Return to your application", actions="['default', 'Open']", body="Click this notification to focus the existing window on workspace 2.")
                capture("default-action-dark")
                # wlroots requires keyboard focus for activation tokens; Ouro
                # additionally supports pointer-only non-focus-stealing popups.
                call(endpoint, "notifications.toggle")
                capture("default-action-center")
                click(1000, 330)
                signal("ActionInvoked", actionable, "'default'")
                token = next(args[1] for member, args in received if member == "ActivationToken" and args[0] == actionable)
                call(target, "runtime.activate", arguments={"activationToken": token})
                wait_for(focused_target, "notification activation did not focus the target on workspace 2")
                workspaces = json.loads(subprocess.check_output(["swaymsg", "-s", ipc, "-t", "get_workspaces"], env=env))
                assert any(workspace["num"] == 2 and workspace["focused"] for workspace in workspaces), workspaces
                capture("activated-workspace")
                for scheme in ("light", "dark"):
                    current = call(settings_path, "settings.get")["structuredContent"]
                    call(settings_path, "settings.set_section", arguments={"expected_revision": current["revision"],
                        "section": "appearance", "value": {"color_scheme": scheme}})
                    colored = notify("Alex · #design", app_name="Team chat", app_icon="", actions="['default', 'Open']",
                        body="Pushed the latest changes. Take a look when you have a minute.",
                        hints={"desktop-entry": GLib.Variant("s", "fixture-chat")})
                    def icon_ready():
                        # Named icons load asynchronously after the first frame.
                        capture(f"app-icon-{scheme}")
                        with Image.open(artifacts / f"app-icon-{scheme}.png") as image:
                            colors = image.convert("RGB").crop((857, 68, 881, 92)).getcolors(576)
                            return sum(count for count, pixel in colors if max(pixel) - min(pixel) > 80) > 200
                    wait_for(icon_ready, "app icon lost its colors or failed to resolve")
                    subprocess.run(["swaymsg", "-s", ipc, "seat seat0 cursor set 1000 112"], env=env, check=True, stdout=log)
                    capture(f"popup-hover-{scheme}")
                    with Image.open(artifacts / f"app-icon-{scheme}.png") as before, Image.open(artifacts / f"popup-hover-{scheme}.png") as after:
                        assert not ImageChops.difference(before, after).crop((844, 56, 1264, 216)).getbbox(), "notification hover painted an inner box"
                    # The header and outer padding were outside the old message-only button.
                    click(900, 80) if scheme == "light" else click(850, 100)
                    signal("ActionInvoked", colored, "'default'")
                    signal("NotificationClosed", colored, "uint32 2")
                    for action in ("dismiss", "reply"):
                        nested = notify("Separate controls", actions="['default', 'Open', 'reply', 'Reply']")
                        capture(f"nested-{action}-{scheme}")
                        click(1238, 80) if action == "dismiss" else click(1205, 174)
                        signal("NotificationClosed", nested, "uint32 2")
                        invoked = [args[1] for member, args in received if member == "ActionInvoked" and args[0] == nested]
                        assert invoked == ([] if action == "dismiss" else ["reply"]), "nested control also invoked the card"
                    plain = notify("A notification without an icon", app_name="Unknown app", app_icon="", body="Just the message, without a placeholder.")
                    capture(f"no-icon-{scheme}")
                    click(1238, 80)
                    signal("NotificationClosed", plain, "uint32 2")
                    if scheme == "light":
                        subprocess.run(["swaymsg", "-s", ipc,
                            '[app_id="dev.ouro.activation-test"] move container to workspace number 3; workspace number 2'],
                            env=env, check=True, stdout=log)
                        assert not focused_target()
                    keyboard_enters = re.findall(r"wl_keyboard[@#]\d+\.enter\(", (artifacts / "native.log").read_text())
                    menu_id = notify("Alex · #design", app_name="Team chat", app_icon="fixture-chat",
                        actions="['default', 'Open', 'reply', 'Reply', 'settings', 'Settings']")
                    capture(f"options-rest-{scheme}")
                    assert re.findall(r"wl_keyboard[@#]\d+\.enter\(", (artifacts / "native.log").read_text()) == keyboard_enters, "notification arrival stole focus"
                    hover(1000, 112)
                    capture(f"options-hover-{scheme}")
                    sizes = banner_sizes()
                    click(1205, 174, leave=False)
                    capture(f"options-open-{scheme}")
                    geometry = popup_geometry()
                    assert geometry and geometry[2:] == (240, 74), geometry
                    assert popup_parent_keyboard() == 1, "explicitly opening Options must request banner keyboard focus"
                    assert sizes[-1] == "200" and all(size == "200" for size in banner_sizes()[len(sizes):]), "opening Options changed the parent allocation"
                    with Image.open(artifacts / f"options-hover-{scheme}.png") as before, Image.open(artifacts / f"options-open-{scheme}.png") as after:
                        assert not ImageChops.difference(before, after).crop((844, 56, 1264, 150)).getbbox(), "opening Options reflowed the message"
                        with Image.open(artifacts / f"options-rest-{scheme}.png") as rest:
                            edge = (844, 56, 854, 256)
                            assert rest.crop(edge).tobytes() == before.crop(edge).tobytes() == after.crop(edge).tobytes(), \
                                "revealing or opening Options changed the card's outer bounds"
                        assert ImageChops.difference(before, after).crop((geometry[0], 256, geometry[0] + geometry[2], geometry[1] + geometry[3])).getbbox(), \
                            "native menu did not render beyond the parent's 200px allocation"
                    pump()
                    assert not any(member == "ActionInvoked" and args[0] == menu_id for member, args in received), "Options invoked the default action"
                    hover(0, 0)
                    capture(f"options-left-{scheme}")
                    assert popup_geometry() == geometry, "moving outside must not close a native menu"
                    click(0, 400)
                    assert popup_geometry() is None, "outside click did not dismiss native menu"
                    assert popup_parent_keyboard() == 0, "outside dismissal must restore the banner's keyboard policy"
                    click(1205, 174, leave=False)
                    if scheme == "light": select_menu(1)
                    else:
                        keys("Escape")
                        assert popup_geometry() is None, "banner's native menu did not receive Escape"
                        assert popup_parent_keyboard() == 0, "Escape must restore the banner's keyboard policy"
                        click(1205, 174, leave=False)
                        keys("Tab", "Return")
                    signal("ActionInvoked", menu_id, "'settings'")
                    signal("NotificationClosed", menu_id, "uint32 2")
                    invoked = [args[1] for member, args in received if member == "ActionInvoked" and args[0] == menu_id]
                    assert invoked == ["settings"], "menu item also invoked the default action"
                    tokens = [args[1] for member, args in received if member == "ActivationToken" and args[0] == menu_id]
                    assert len(tokens) == 1 and tokens[0], "native menu action lost its activation token"
                    if scheme == "light":
                        call(target, "runtime.activate", arguments={"activationToken": tokens[0]})
                        wait_for(focused_target, "native menu token did not activate the target on workspace 3")
                maximum_menu = notify("Four available actions for a notification with a deliberately long title",
                    body="Choose an action from this notification, whose longer message also fills both available lines.",
                    actions="['a', 'Open file', 'b', 'Show folder', 'c', 'Copy path', 'd', 'Archive']")
                hover(1000, 112)
                click(1205, 218, leave=False)
                capture("options-four-actions-wrapped")
                assert popup_geometry()[2:] == (240, 138)
                select_menu(3)
                signal("ActionInvoked", maximum_menu, "'d'")
                signal("NotificationClosed", maximum_menu, "uint32 2")

                # The same wrapped card on a short output forces flip_y.
                subprocess.run(["swaymsg", "-s", ipc, "output HEADLESS-1 mode 1280x300"], env=env, check=True, stdout=log)
                edge_menu = notify("Four available actions for a notification with a deliberately long title",
                    body="Choose an action from this notification, whose longer message also fills both available lines.",
                    actions="['a', 'Open file', 'b', 'Show folder', 'c', 'Copy path', 'd', 'Archive']")
                click(1205, 218, leave=False)
                capture("options-screen-edge")
                x, y, width, height = popup_geometry()
                assert y < 218 and 0 <= x <= 1280 - width and 0 <= y <= 300 - height, "menu did not flip/slide inside output"
                select_menu(2)
                signal("ActionInvoked", edge_menu, "'c'")
                signal("NotificationClosed", edge_menu, "uint32 2")
                subprocess.run(["swaymsg", "-s", ipc, "output HEADLESS-1 mode 1280x800"], env=env, check=True, stdout=log)

                for removal in ("replacement", "no-actions", "close", "expiry", "parent"):
                    disappearing = notify("Menu lifetime", actions="['a', 'First', 'b', 'Second']", timeout=2200 if removal == "expiry" else 0)
                    click(1205, 174, leave=False)
                    assert popup_geometry(), removal
                    if removal == "replacement":
                        notify("Replacement with the same action keys", replaces=disappearing, actions="['a', 'First', 'b', 'Second']")
                    elif removal == "no-actions":
                        notify("Replacement without actions", replaces=disappearing)
                    elif removal == "close":
                        method("CloseNotification", disappearing)
                    elif removal == "parent":
                        call(endpoint, "notifications.toggle")
                    else:
                        signal("NotificationClosed", disappearing, "uint32 1")
                    wait_for(lambda: popup_geometry() is None, f"{removal} left a stale native menu")
                    pump()
                    assert not any(member == "ActionInvoked" and args[0] == disappearing for member, args in received)
                    if removal == "parent": call(endpoint, "notifications.toggle")
                    if removal in ("replacement", "no-actions", "parent"): method("CloseNotification", disappearing)

                history_action = notify("Clickable history surface", actions="['default', 'Open', 'reply', 'Reply']")
                call(endpoint, "notifications.toggle")
                capture("history-surface")
                subprocess.run(["swaymsg", "-s", ipc, "seat seat0 cursor set 1000 284"], env=env, check=True, stdout=log)
                capture("history-surface-hover")
                with Image.open(artifacts / "history-surface.png") as before, Image.open(artifacts / "history-surface-hover.png") as after:
                    assert not ImageChops.difference(before, after).crop((864, 260, 1244, 330)).getbbox(), "history hover changed the message surface"
                    assert ImageChops.difference(before, after).crop((1130, 334, 1235, 375)).getbbox(), "history action did not reveal"
                click(865, 284)  # Outer card padding, not the title/body.
                signal("ActionInvoked", history_action, "'default'")
                signal("NotificationClosed", history_action, "uint32 2")
                for action in ("dismiss", "reply"):
                    nested = notify("Separate history controls", actions="['default', 'Open', 'reply', 'Reply']")
                    call(endpoint, "notifications.toggle")
                    capture(f"history-nested-{action}")
                    click(1214, 284) if action == "dismiss" else click(1190, 350)
                    signal("NotificationClosed", nested, "uint32 2")
                    invoked = [args[1] for member, args in received if member == "ActionInvoked" and args[0] == nested]
                    assert invoked == ([] if action == "dismiss" else ["reply"]), "history control also invoked the card"
                    if action == "dismiss": call(endpoint, "notifications.toggle")
                keyboard_menu = notify("Keyboard options", actions="['reply', 'Reply', 'settings', 'Settings']")
                call(endpoint, "notifications.toggle")
                time.sleep(.5)
                # Sway 1.7 auto-focuses this on-demand layer, so it cannot
                # exercise an initially unfocused history. Still verify
                # pointer-open dismissal restores focus without hover.
                click(1190, 350, leave=False)
                assert popup_geometry(), "pointer did not open history menu"
                hover(0, 0)
                keys("Escape")
                assert popup_geometry() is None
                keys("Return")
                assert popup_geometry(), "pointer-open history lost Options focus after Escape"
                keys("Escape")
                call(endpoint, "notifications.toggle")
                time.sleep(.3)
                call(endpoint, "notifications.toggle")
                capture("history-options-rest")
                click(1050, 88)
                keys("Tab", "Tab", "Tab", "Tab", "Tab")
                capture("history-options-keyboard-reveal")
                keys("Tab", "Return")
                capture("history-options-keyboard-open")
                assert popup_geometry(), "keyboard Options did not open native menu"
                keys("Escape")
                capture("history-options-keyboard-escape")
                assert popup_geometry() is None, "Escape did not dismiss native menu"
                with Image.open(artifacts / "history-options-rest.png") as rest, \
                     Image.open(artifacts / "history-options-keyboard-reveal.png") as reveal, \
                     Image.open(artifacts / "history-options-keyboard-open.png") as opened, \
                     Image.open(artifacts / "history-options-keyboard-escape.png") as escaped:
                    assert ImageChops.difference(rest, reveal).crop((1120, 334, 1235, 375)).getbbox(), "focus on dismiss did not reveal Options"
                    assert ImageChops.difference(opened, escaped).crop((1120, 375, 1235, 445)).getbbox(), "Escape did not close the menu"
                keys("Return")
                assert popup_geometry(), "Escape did not restore focus to Options"
                keys("Tab", "Return")
                signal("ActionInvoked", keyboard_menu, "'settings'")
                signal("NotificationClosed", keyboard_menu, "uint32 2")
                keyboard_action = notify("Keyboard activation", actions="['default', 'Open']")
                call(endpoint, "notifications.toggle")
                capture("history-before-focus")
                click(1050, 88)  # Focus the layer without invoking a control.
                # Keep this device alive through traversal and activation:
                # replacing virtual keyboards makes Sway emit an empty keymap.
                start(["wtype", "-s", "200", "-k", "Tab", "-k", "Tab", "-k", "Tab", "-k", "Tab", "-k", "Tab",
                       "-s", "3000", "-k", "Return", "-s", "600000"])
                time.sleep(.5)
                capture("history-keyboard-focus")
                with Image.open(artifacts / "history-before-focus.png") as before, Image.open(artifacts / "history-keyboard-focus.png") as after:
                    assert ImageChops.difference(before, after).crop((861, 256, 863, 338)).getbbox(), "card keyboard focus has no visible border"
                signal("ActionInvoked", keyboard_action, "'default'")
                signal("NotificationClosed", keyboard_action, "uint32 2")
                expired = notify("Expired history is not clickable", timeout=200, actions="['default', 'Open']")
                call(endpoint, "notifications.toggle")
                signal("NotificationClosed", expired, "uint32 1")
                capture("history-expired")
                click(865, 284)
                pump()
                assert not any(member == "ActionInvoked" and args[0] == expired for member, args in received), "expired notification invoked an action"
                call(endpoint, "notifications.toggle")

                # Raw image-data is padded deliberately: tightly packed test
                # data would not catch a loader which ignores rowstride. The
                # transparent magenta quadrant also checks that alpha is used.
                current = call(settings_path, "settings.get")["structuredContent"]
                call(settings_path, "settings.set_section", arguments={"expected_revision": current["revision"],
                    "section": "appearance", "value": {"color_scheme": "light"}})
                def raw_row(y):
                    pixels = bytearray()
                    for x in range(48):
                        if y < 24 and x < 31: pixel = (244, 25, 18, 255)
                        elif y < 24: pixel = (20, 210, 55, 255)
                        elif x < 31: pixel = (12, 45, 238, 128)
                        else: pixel = (255, 0, 255, 0)
                        pixels.extend(pixel)
                    return pixels
                raw = notify("Padded RGBA image", app_name="Team chat", app_icon="",
                    hints={
                        # Valid raw data beats a valid path, and the modern key
                        # beats the legacy raw key even though it is later.
                        "image_data": GLib.Variant("(iiibiiay)", (48, 48, 144, False, 8, 3,
                            bytes((255, 208, 0)) * 48 * 48)),
                        "image-path": GLib.Variant("s", path_fixture.as_uri()),
                        "image-data": padded_raw(48, 48, raw_row),
                    })
                capture("image-raw-popup-light")
                with Image.open(artifacts / "image-raw-popup-light.png") as image:
                    popup_box = (857, 68, 881, 92)
                    assert color_count(image, popup_box, (244, 25, 18)) > 80, "modern raw red pixels missing from header"
                    assert color_count(image, popup_box, (20, 210, 55)) > 40, "padded raw row was decoded incorrectly"
                    assert color_count(image, popup_box, (255, 208, 0)) == 0, "legacy raw or competing path won precedence"
                    assert color_count(image, popup_box, (255, 0, 255)) == 0, "transparent raw pixels were rendered opaque"
                    blue = image.convert("RGB").crop(popup_box).getdata()
                    assert sum(b > r + 45 and b > g + 45 and b < 245 for r, g, b in blue) > 80, \
                        "semi-transparent blue pixels did not preserve alpha"
                    assert color_count(image, (844, 96, 1265, 230), (244, 25, 18)) == 0, "second image slot remains"
                method("CloseNotification", raw)

                current = call(settings_path, "settings.get")["structuredContent"]
                call(settings_path, "settings.set_section", arguments={"expected_revision": current["revision"],
                    "section": "appearance", "value": {"color_scheme": "dark"}})
                path_notice = notify("Chrome download image", timeout=800, app_name="Chrome", app_icon="fixture-chat",
                    hints={
                        "desktop-entry": GLib.Variant("s", "fixture-chat"),
                        "image_path": GLib.Variant("s", "/definitely/missing/legacy-image.png"),
                        "image-path": GLib.Variant("s", path_fixture.as_uri()),
                    })
                # Notify must own the encoded image before replying.
                path_fixture.unlink()
                capture("image-path-popup-dark")
                with Image.open(artifacts / "image-path-popup-dark.png") as image:
                    assert color_count(image, (857, 68, 881, 92), (255, 208, 0)) > 180, "image-path did not replace app_icon in header"
                    assert color_count(image, (844, 48, 1265, 230), (223, 40, 96)) == 0, "app icon rendered alongside selected image"
                    assert color_count(image, (844, 96, 1265, 230), (255, 208, 0)) == 0, "second image slot remains"
                call(endpoint, "notifications.toggle")
                signal("NotificationClosed", path_notice, "uint32 1")
                capture("image-path-history-after-unlink-dark")
                with Image.open(artifacts / "image-path-history-after-unlink-dark.png") as image:
                    assert color_count(image, (850, 256, 1255, 410), (255, 208, 0)) > 180, \
                        "history lost copied image bytes after source unlink"
                    assert color_count(image, (850, 210, 1255, 256), (255, 208, 0)) == 0, "group borrowed its newest notification's image"
                call(endpoint, "notifications.toggle")
                for title, bad_path in (("Remote image ignored", "https://example.invalid/image.png"),
                                        ("Missing image ignored", "/definitely/missing/image.png")):
                    broken = notify(title, hints={"image-path": GLib.Variant("s", bad_path)})
                    name = title.lower().replace(" ", "-")
                    capture(name)
                    notify(title, replaces=broken)
                    capture(name + "-plain")
                    with Image.open(artifacts / f"{name}.png") as actual, Image.open(artifacts / f"{name}-plain.png") as plain:
                        assert not ImageChops.difference(actual, plain).crop((844, 48, 1265, 230)).getbbox(), \
                            "invalid image changed the text-only notification"
                    method("CloseNotification", broken)
                named = notify("Named notification image", app_name="Image fixture", app_icon="",
                    hints={"image_path": GLib.Variant("s", "fixture-chat")})
                capture("image-named-popup-dark")
                with Image.open(artifacts / "image-named-popup-dark.png") as image:
                    assert color_count(image, (857, 68, 881, 92), (223, 40, 96)) > 150, \
                        "legacy named image hint did not render the notification image"
                method("CloseNotification", named)

                # A file-backed app_icon must beat deprecated icon_data, while
                # icon_data still works if no modern image or app_icon exists.
                app_icon_file = directory / "app icon.png"
                path_image.save(app_icon_file)
                for name, supplied, expected in (("file-app-icon", app_icon_file.as_uri(), (255, 208, 0)),
                                                 ("deprecated-icon-data", "", (244, 25, 18))):
                    notice = notify(name, app_name="Chrome", app_icon=supplied,
                        hints={"desktop-entry": GLib.Variant("s", "fixture-chat"),
                               "icon_data": padded_raw(48, 48, raw_row)})
                    capture(name)
                    with Image.open(artifacts / f"{name}.png") as image:
                        assert color_count(image, (857, 68, 881, 92), expected) > 80, "single-slot fallback order is wrong"
                    method("CloseNotification", notice)

                oldest = notify("Oldest retained message", app_name="History fixture", body="End of history.",
                                actions="['other', 'Another action', 'inspect', 'Inspect oldest']")
                retained = []
                for index in range(99):
                    retained.append(notify(f"History message {index + 1}", app_name="History fixture",
                        body=("A variable-height notification body. " * (index % 5 + 1)) if index % 3 else ""))
                call(endpoint, "notifications.toggle")
                capture("history-100-top")
                for _ in range(4):
                    scroll(100000)
                capture("history-100-bottom")
                notify("Updated recent message", replaces=retained[50], app_name="History fixture", body="Updated offscreen.")
                capture("history-anchor-retained")
                with Image.open(artifacts / "history-100-bottom.png") as before, Image.open(artifacts / "history-anchor-retained.png") as after:
                    assert not ImageChops.difference(before, after).crop((860, 216, 1247, 671)).getbbox(), \
                        "updating an offscreen message moved the visible scroll anchor"
                click(1180, 634, leave=False)
                capture("history-menu-outside-virtual-row")
                x, y, width, height = popup_geometry()
                assert y + height > 671, "fixture must extend the menu beyond the virtual viewport"
                with Image.open(artifacts / "history-anchor-retained.png") as before, Image.open(artifacts / "history-menu-outside-virtual-row.png") as after:
                    assert ImageChops.difference(before, after).crop((x, 672, x + width, y + height)).getbbox(), \
                        "virtual-list clipping hid the native menu"
                select_menu(1)
                signal("ActionInvoked", oldest, "'inspect'")
                signal("NotificationClosed", oldest, "uint32 2")
                bus.close_sync(None)
                print(f"PASS: notification RPC/signals/tokens, native popup geometry, edge flip, keyboard/outside dismissal, parent lifetime, DND, themes and 100-item history; {artifacts}")
            finally:
                if pointer:
                    pointer.close()
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)


if __name__ == "__main__":
    main()
