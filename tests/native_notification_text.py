#!/usr/bin/env python3
"""Exercise notification text on a private desktop and D-Bus session."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from gi.repository import Gio, GLib
from native_launcher import BINARY, ROOT, call, wait_for


def main():
    with tempfile.TemporaryDirectory(prefix="ouroshell-text-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        config = directory / "sway.conf"
        config.write_text("output * mode 1280x800\noutput * bg #608099 solid_color\nseat seat0 fallback true\n")
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman", LIBSEAT_BACKEND="noop",
                   DBUS_SESSION_BUS_ADDRESS=f"unix:path={directory}/bus",
                   DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={directory}/no-system-bus")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("DISPLAY", None)
        processes = []
        with (artifacts / "native.log").open("w") as log:
            def start(argv):
                process = subprocess.Popen(argv, env=env, stdout=log, stderr=log)
                processes.append(process)
                return process

            try:
                start(["dbus-daemon", "--session", "--nofork", f"--address={env['DBUS_SESSION_BUS_ADDRESS']}"])
                wait_for((directory / "bus").exists, "private bus missing")
                start(["sway", "-c", str(config)])
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless Sway missing")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                app = start([str(BINARY), "run", str(ROOT / "ouro.json")])
                endpoint = directory / "ourokit/apps/dev.ouro.shell"
                wait_for(endpoint.exists, "shell missing")
                bus = Gio.DBusConnection.new_for_address_sync(env["DBUS_SESSION_BUS_ADDRESS"],
                    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
                time.sleep(1)
                bodies = [
                    "Hello 👋 a notification with emoji 🚀",
                    "Skin tones and joined emoji: 👋🏽 👩🏽‍🚀 🇨🇭",
                    "Workflow ci from <@U1234567890> failed on branch main. Commit: <https://github.com/example/project/commit/0123456789abcdef0123456789abcdef01234567>. Check details: <https://github.com/example/project/actions/runs/12345678901>",
                    "A plain notification message.",
                    "First line\nSecond line",
                    "First line\n\nThird line",
                    "A message with a trailing newline.\n",
                    "A reply in #engineering: https://example.com/a/long/path?query=notification",
                    "<b>Someone</b>: A message with &amp; markup.",
                    "A longer notification message. " * 50,
                    "A message\twith tabs\rand carriage returns.",
                    "Hello\u2028world\u2029next paragraph",
                    "مرحبا hello שלום world",
                ]
                for index, body in enumerate(bodies):
                    print(f"Rendering case {index}: {body[:70]!r}", flush=True)
                    reply = bus.call_sync("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                        "org.freedesktop.Notifications", "Notify",
                        GLib.Variant("(susssasa{sv}i)", ("Slack", 0, "", "Alex (Engineering)",
                            body, ["default", "Open"], {"desktop-entry": GLib.Variant("s", "slack")}, 0)),
                        None, Gio.DBusCallFlags.NONE, 5000, None)
                    time.sleep(.4)
                    assert app.poll() is None, (artifacts / "native.log").read_text()
                    status = call(endpoint, "runtime.status")["structuredContent"]
                    assert status["diagnostic"] is None, status
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(artifacts / f"text-{index}.png")], env=env, check=True)
                    if index in (0, 2):
                        call(endpoint, "notifications.toggle")
                        time.sleep(.4)
                        status = call(endpoint, "runtime.status")["structuredContent"]
                        assert status["diagnostic"] is None, status
                        subprocess.run(["grim", "-o", "HEADLESS-1", str(artifacts / f"center-{index}.png")], env=env, check=True)
                        call(endpoint, "notifications.toggle")
                    bus.call_sync("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                        "org.freedesktop.Notifications", "CloseNotification", GLib.Variant("(u)", reply.unpack()),
                        None, Gio.DBusCallFlags.NONE, 5000, None)
                bus.close_sync(None)
                print(f"PASS: notification text; {artifacts}")
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)


if __name__ == "__main__":
    main()
