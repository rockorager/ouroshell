#!/usr/bin/env python3
"""Exercise the notification UI preview on an isolated headless desktop."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops
from native_launcher import BINARY, ROOT, call, virtual_pointer, wait_for


def main():
    settings_binary = os.environ["OUROSETTINGS_TEST_BINARY"]
    with tempfile.TemporaryDirectory(prefix="ouroshell-notifications-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        config = directory / "sway.conf"
        config.write_text("output * mode 1280x800\noutput * bg #608099 solid_color\nseat seat0 fallback true\n")
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman", LIBSEAT_BACKEND="noop",
                   DBUS_SESSION_BUS_ADDRESS=f"unix:path={directory}/session-bus",
                   DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={directory}/system-bus")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("DISPLAY", None)
        app = settings = pointer = None
        with (artifacts / "native.log").open("w") as log:
            sway = subprocess.Popen(["sway", "-c", str(config)], env=env, stdout=log, stderr=log)
            try:
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless Sway did not start")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                wait_for(lambda: list(directory.glob("sway-ipc.*.sock")), "missing private Sway IPC socket")
                ipc = str(next(directory.glob("sway-ipc.*.sock")))
                pointer = virtual_pointer(env["WAYLAND_DISPLAY"])
                settings_path = directory / "ouro/settings.mcp.sock"
                settings = subprocess.Popen([settings_binary, "--socket", str(settings_path),
                                             "--state", str(directory / "settings.json"), "--idle-ms", "300000"],
                                            env=env, stdout=log, stderr=log)
                wait_for(settings_path.exists, "private settings did not start")
                app = subprocess.Popen([str(BINARY), "run", str(ROOT / "src/notification-preview.lua"), "--software"],
                                       env=env, stdout=log, stderr=log)
                endpoint = directory / "ourokit/apps/dev.ouro.notifications.preview"
                wait_for(endpoint.exists, "preview did not start")

                def command(text):
                    result = json.loads(subprocess.check_output(["swaymsg", "-s", ipc, "-t", "command", text], env=env))
                    assert all(item["success"] for item in result), result

                def click(x, y):
                    command(f"seat seat0 cursor set {x} {y}")
                    time.sleep(.1)
                    command("seat seat0 cursor press button1")
                    command("seat seat0 cursor release button1")
                    command("seat seat0 cursor set 0 0")
                    time.sleep(.2)

                def capture(name):
                    time.sleep(.7)
                    assert app.poll() is None, (artifacts / "native.log").read_text()
                    status = call(endpoint, "runtime.status")["structuredContent"]
                    assert status["diagnostic"] is None, status
                    path = artifacts / f"{name}.png"
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(path)], env=env, check=True)
                    with Image.open(path) as image:
                        return image.convert("RGB")

                initial = capture("center-light")
                click(1000, 232)
                collapsed = capture("collapsed")
                assert ImageChops.difference(initial, collapsed).crop((860, 250, 1245, 500)).getbbox(), "group did not collapse"
                click(1000, 232)
                expanded = capture("expanded")
                assert initial.crop((860, 250, 1245, 500)).tobytes() == expanded.crop((860, 250, 1245, 500)).tobytes()

                current = call(settings_path, "settings.get")["structuredContent"]
                call(settings_path, "settings.set_section", arguments={"expected_revision": current["revision"],
                     "section": "appearance", "value": {"color_scheme": "dark"}})
                dark = capture("center-dark")
                assert initial.getpixel((850, 400))[0] > 200 and dark.getpixel((850, 400))[0] < 60

                click(1214, 170)
                quiet = capture("quiet")
                click(900, 703)
                suppressed = capture("quiet-delivery")
                assert suppressed.getpixel((850, 400)) == dark.getpixel((850, 400)), "DND hid the center for a popup"
                assert ImageChops.difference(quiet, suppressed).crop((860, 100, 1200, 122)).getbbox(), "DND did not add to history"
                click(1214, 170)
                click(1020, 703)  # Reset the fixture, leaving DND disabled.
                capture("reset")
                click(900, 703)
                popup = capture("popup-dark")
                assert popup.getpixel((850, 400)) == initial.getpixel((500, 400)), "popup retained the full-height panel"
                time.sleep(6)
                expired = capture("expired")
                assert expired.getpixel((850, 400)) == dark.getpixel((850, 400)), "expiry did not restore history"
                click(1200, 655)
                empty = capture("empty-dark")
                assert ImageChops.difference(dark, empty).crop((860, 230, 1240, 580)).getbbox(), "clear did not change history"
                click(1020, 703)
                reset = capture("reset-again")
                assert reset.crop((860, 250, 1245, 500)).tobytes() == dark.crop((860, 250, 1245, 500)).tobytes()
                click(1227, 96)
                assert app.wait(timeout=5) == 0
                print(f"PASS: native notification preview clicks, themes, DND, popup/expiry, clear/reset, and close; captures: {artifacts}")
            finally:
                for process in (app, settings):
                    if process and process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
                if pointer:
                    pointer.close()
                sway.terminate()
                sway.wait(timeout=10)


if __name__ == "__main__":
    main()
