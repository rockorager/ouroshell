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
        config.write_text("output * mode 1280x800\noutput * bg #608099 solid_color\nseat seat0 fallback true\nfocus_on_window_activation focus\n")
        data = directory / "data"
        (data / "applications").mkdir(parents=True)
        (data / "icons").mkdir()
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
                start(["sway", "-c", str(config)])
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

                def click(x, y):
                    for command in (f"seat seat0 cursor set {x} {y}", "seat seat0 cursor press button1",
                                    "seat seat0 cursor release button1", "seat seat0 cursor set 0 0"):
                        result = json.loads(subprocess.check_output(["swaymsg", "-s", ipc, "-t", "command", command], env=env))
                        assert all(item["success"] for item in result), result
                        time.sleep(.05)
                    time.sleep(.3)

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
                click(892, 174)
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
                        click(1238, 80) if action == "dismiss" else click(890, 174)
                        signal("NotificationClosed", nested, "uint32 2")
                        invoked = [args[1] for member, args in received if member == "ActionInvoked" and args[0] == nested]
                        assert invoked == ([] if action == "dismiss" else ["reply"]), "nested control also invoked the card"
                    plain = notify("A notification without an icon", app_name="Unknown app", app_icon="", body="Just the message, without a placeholder.")
                    capture(f"no-icon-{scheme}")
                    click(1238, 80)
                    signal("NotificationClosed", plain, "uint32 2")
                history_action = notify("Clickable history surface", actions="['default', 'Open', 'reply', 'Reply']")
                call(endpoint, "notifications.toggle")
                capture("history-surface")
                subprocess.run(["swaymsg", "-s", ipc, "seat seat0 cursor set 1000 284"], env=env, check=True, stdout=log)
                capture("history-surface-hover")
                with Image.open(artifacts / "history-surface.png") as before, Image.open(artifacts / "history-surface-hover.png") as after:
                    assert not ImageChops.difference(before, after).crop((860, 256, 1248, 384)).getbbox(), "history hover painted an inner box"
                click(865, 284)  # Outer card padding, not the title/body.
                signal("ActionInvoked", history_action, "'default'")
                signal("NotificationClosed", history_action, "uint32 2")
                for action in ("dismiss", "reply"):
                    nested = notify("Separate history controls", actions="['default', 'Open', 'reply', 'Reply']")
                    call(endpoint, "notifications.toggle")
                    capture(f"history-nested-{action}")
                    click(1214, 284) if action == "dismiss" else click(900, 350)
                    signal("NotificationClosed", nested, "uint32 2")
                    invoked = [args[1] for member, args in received if member == "ActionInvoked" and args[0] == nested]
                    assert invoked == ([] if action == "dismiss" else ["reply"]), "history control also invoked the card"
                    if action == "dismiss": call(endpoint, "notifications.toggle")
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
                                actions="['inspect', 'Inspect oldest']")
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
                click(925, 634)
                signal("ActionInvoked", oldest, "'inspect'")
                signal("NotificationClosed", oldest, "uint32 2")
                bus.close_sync(None)
                print(f"PASS: real notification RPC/signals, replacement, actions, expiry after popup removal, bell, DND, scrolling/themes; {artifacts}")
            finally:
                if pointer:
                    pointer.close()
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)


if __name__ == "__main__":
    main()
