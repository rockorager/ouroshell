#!/usr/bin/env python3
"""Exercise the real shell in a disposable headless Sway, never the live desktop.

Requires sibling Ourokit built, sway, grim, wtype, and Pillow. Optional
OUROSHELL_TEST_ARTIFACTS preserves captures and protocol logs.
"""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT.parent / "ourokit/zig-out/bin/ouroctl"


def virtual_pointer(display):
    """Keep a pointer device present so Ourokit can bind wl_pointer before clicks.

    Only registry discovery and virtual-pointer creation are needed here;
    Sway's test IPC supplies motion and button events afterward.
    """
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(8)
    client.connect(display)

    def request(object_id, opcode, payload):
        client.sendall(struct.pack("=II", object_id, ((8 + len(payload)) << 16) | opcode) + payload)

    request(1, 1, struct.pack("=I", 2))  # wl_display.get_registry
    try:
        with client.makefile("rb") as events:
            while True:
                object_id, header = struct.unpack("=II", events.read(8))
                payload = events.read((header >> 16) - 8)
                if object_id != 2 or header & 0xffff != 0:
                    continue
                name, length = struct.unpack("=II", payload[:8])
                interface = payload[8:8 + length]
                if interface != b"zwlr_virtual_pointer_manager_v1\0":
                    continue
                encoded = struct.pack("=I", length) + interface + b"\0" * (-length % 4)
                request(2, 0, struct.pack("=I", name) + encoded + struct.pack("=II", 1, 3))
                request(3, 0, struct.pack("=II", 0, 4))  # create_virtual_pointer(null seat)
                return client
    except BaseException:
        client.close()
        raise


def wait_for(check, message):
    for _ in range(150):
        if check():
            return
        time.sleep(.04)
    raise AssertionError(message)


def call(path, name, allow_error=False, arguments=None):
    params = {"name": name, "arguments": arguments or {}, "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {"name": "launcher-test", "version": "1"},
    }}
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(8)
        client.connect(str(path))
        client.sendall(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params}).encode() + b"\n")
        reply = json.loads(client.makefile("rb").readline())
        assert "error" not in reply and (allow_error or not reply["result"].get("isError")), reply
        if name == "launcher.toggle":
            # The action reply precedes native surface creation and autofocus.
            time.sleep(1.2)
        return reply["result"]


def main():
    appearance_only = "--appearance-only" in sys.argv
    if appearance_only:
        assert os.environ.get("OUROSETTINGS_TEST_BINARY"), "--appearance-only requires OUROSETTINGS_TEST_BINARY"
    with tempfile.TemporaryDirectory(prefix="ouroshell-native-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        config = directory / "sway.conf"
        config.write_text("output * mode 1280x800\noutput * bg #608099 solid_color\nseat seat0 fallback true\n")
        data = directory / "data"
        apps = data / "applications"
        apps.mkdir(parents=True)
        for index in range(10):
            (apps / f"fixture-{index}.desktop").write_text(
                f"[Desktop Entry]\nType=Application\nName=Fixture App {index}\n"
                f"Exec=fixture-app-{index} \"argument with spaces\"\nPath=/tmp/fixture work\n")
        # Reproduce the duplicate key shipped in Arch's Chrome desktop file.
        (apps / "google-chrome.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Google Chrome\n"
            "Exec=/usr/bin/google-chrome-stable %U\n"
            "StartupWMClass=Google-chrome\nStartupWMClass=google-chrome\n")
        (apps / "com.google.Chrome.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Google Chrome\n"
            "Exec=hidden-chrome\nNoDisplay=true\n")
        env = dict(os.environ, XDG_RUNTIME_DIR=str(directory), XDG_DATA_HOME=str(data),
                   XDG_DATA_DIRS="/usr/share", WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
                   WLR_RENDERER="pixman", LIBSEAT_BACKEND="noop",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(directory / "system-bus"))
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("DISPLAY", None)
        launches = []
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(directory / "ouro.mcp.sock"))
        listener.listen()
        listener.settimeout(.1)
        stopping = threading.Event()

        def compositor_calls():
            while not stopping.is_set():
                try:
                    client, _ = listener.accept()
                except TimeoutError:
                    continue
                with client:
                    request = json.loads(client.makefile("rb").readline())
                    assert request["method"] == "tools/call", request
                    launches.append(request["params"])
                    result = {"resultType": "complete", "content": [{"type": "text", "text": "{}"}], "structuredContent": {}}
                    if len(launches) == 3:
                        result["isError"] = True
                        result["structuredContent"] = {"error": {"message": "Fixture launch denied"}}
                        result["content"][0]["text"] = json.dumps(result["structuredContent"])
                    client.sendall(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode() + b"\n")

        server = threading.Thread(target=compositor_calls)
        server.start()
        shell = None
        pointer = None
        keyboard = None
        settings = None
        with (artifacts / "sway.log").open("wb") as sway_log, (artifacts / "shell.log").open("wb") as shell_log:
            compositor = subprocess.Popen(["sway", "-c", str(config), "-d"], env=env, stdout=sway_log, stderr=sway_log)
            try:
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless compositor did not start")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                settings_path = directory / "ouro/settings.mcp.sock"

                def set_scheme(scheme):
                    current = call(settings_path, "settings.get")["structuredContent"]
                    call(settings_path, "settings.set_section", arguments={
                        "expected_revision": current["revision"], "section": "appearance",
                        "value": {"color_scheme": scheme},
                    })

                if settings_binary := os.environ.get("OUROSETTINGS_TEST_BINARY"):
                    settings = subprocess.Popen([settings_binary, "--socket", str(settings_path),
                                                 "--state", str(directory / "settings.json"), "--idle-ms", "300000"],
                                                env=env, stdout=shell_log, stderr=shell_log)
                    wait_for(settings_path.exists, "isolated settings daemon did not start")
                    set_scheme("dark")
                # A headless seat otherwise loses keyboard capability between
                # wtype invocations. Keep a device present like a real desktop.
                keyboard = subprocess.Popen(["wtype", "-s", "600000"], env=env)
                time.sleep(.2)
                entry = ROOT / ("src/preview.lua" if appearance_only else "ouro.json")
                shell = subprocess.Popen([str(BINARY), "run", str(entry), "--software"],
                                         env=env, stdout=shell_log, stderr=shell_log)
                endpoint = directory / "ourokit/apps/dev.ouro.shell"
                if not appearance_only:
                    wait_for(endpoint.exists, "shell MCP socket did not appear")

                def capture(name):
                    # Fullscreen software compositing is slower than the small
                    # popup; allow queued input, icon loads, and paint to settle.
                    time.sleep(1.2)
                    assert shell.poll() is None, (artifacts / "shell.log").read_text()
                    path = artifacts / f"{name}.png"
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(path)], env=env, check=True)
                    return path.read_bytes()

                def keys(*arguments):
                    subprocess.run(["wtype", "-s", "200", *arguments, "-s", "100"], env=env, check=True)
                    time.sleep(1.5)

                if appearance_only:
                    capture("preview-dark")
                    set_scheme("light")
                    capture("preview-light")
                    with Image.open(artifacts / "preview-dark.png") as dark, Image.open(artifacts / "preview-light.png") as light:
                        for point in ((20, 400), (1000, 20)):
                            assert dark.getpixel(point)[0] < 60 and light.getpixel(point)[0] > 200, ("theme did not change", point)
                    set_scheme("default")
                    capture("preview-default")
                    set_scheme("dark")
                    capture("preview-dark-again")
                    for before, after in (("light", "default"), ("dark", "dark-again")):
                        with Image.open(artifacts / f"preview-{before}.png") as a, Image.open(artifacts / f"preview-{after}.png") as b:
                            # Omit the blinking input caret, compare the bar,
                            # controls/results and overlay across transitions.
                            for region in ((0, 0, 1280, 40), (0, 175, 1280, 800)):
                                assert a.crop(region).tobytes() == b.crop(region).tobytes(), "theme did not round-trip"
                    assert (artifacts / "sway.log").read_text().count("new layer surface: namespace ouroshell-preview") == 2, "theme change recreated a layer surface"
                    print(f"PASS: live dark/light/default palettes and retained surfaces; captures: {artifacts}")
                    return

                # Geometry specified by the design: 560×620 column centered in
                # the 1280×760 area below the bar; 48px search + 16px gaps.
                left, top, right = 360, 110, 920
                first_row = top + 48 + 16 + 35 + 16 + 18 + 4

                time.sleep(.7)
                baseline = capture("bar")
                call(endpoint, "launcher.toggle")
                capture("launcher")
                with Image.open(artifacts / "launcher.png") as image:
                    line_y = top + 48 + 16 + 32
                    accent = image.getpixel((left + 18, line_y))
                    assert accent != image.getpixel((left + 150, line_y)), "scope underline collapsed"
                    span = 0
                    while span < 100 and image.getpixel((left + span, line_y)) == accent:
                        span += 1
                    assert 40 <= span < 100, ("scope underline must span the padded All label", span)
                assert call(endpoint, "runtime.reload", allow_error=True).get("isError")
                keys("Fixture")
                searched = capture("search")
                assert searched != baseline
                for _ in range(8):
                    keys("-k", "Down")
                capture("scrolled-selection")
                keys("-k", "Up")
                capture("selection-up")
                # The upper five rows must not move when selection moves from
                # the last visible row to the preceding visible row.
                with Image.open(artifacts / "scrolled-selection.png") as before, Image.open(artifacts / "selection-up.png") as after:
                    upper_rows = (left, first_row, right, first_row + 5 * 60)
                    assert before.crop(upper_rows).tobytes() == after.crop(upper_rows).tobytes(), "Up scrolled rows that were already visible"
                    lower_rows = (left, first_row + 5 * 60, right, first_row + 7 * 60)
                    assert before.crop(lower_rows).tobytes() != after.crop(lower_rows).tobytes(), "Up did not move the selection highlight"
                if settings:
                    set_scheme("light")
                    capture("search-light")
                    with Image.open(artifacts / "search-light.png") as light, Image.open(artifacts / "selection-up.png") as dark:
                        assert light.getpixel((20, 400))[0] > 200 and dark.getpixel((20, 400))[0] < 60, "overlay did not follow appearance"
                        assert light.getpixel((1000, 20))[0] > 200 and dark.getpixel((1000, 20))[0] < 60, "bar did not follow appearance"
                    set_scheme("dark")
                    capture("search-dark-again")
                    with Image.open(artifacts / "search-dark-again.png") as after, Image.open(artifacts / "selection-up.png") as before:
                        # Exclude the blinking caret/clock; rows must retain
                        # query filtering, scroll position and selection.
                        area = (left, first_row, right, first_row + 7 * 60)
                        assert before.crop(area).tobytes() == after.crop(area).tobytes(), "retheme changed launcher state"
                keys("-k", "Down")
                keys("-k", "Return")
                wait_for(lambda: launches, "Enter did not launch the selected app")
                assert launches[0]["name"] == "run", launches
                assert launches[0]["arguments"]["argv"] == ["env", "--chdir=/tmp/fixture work", "--", "fixture-app-8", "argument with spaces"], launches
                capture("after-launch")
                call(endpoint, "launcher.toggle")
                keys("-M", "ctrl", "a", "-m", "ctrl", "zzzz-not-an-app")
                capture("empty")
                keys("-k", "Escape")
                capture("dismissed")
                call(endpoint, "runtime.reload")
                for _ in range(8):
                    call(endpoint, "launcher.toggle")
                    call(endpoint, "launcher.toggle")
                assert call(endpoint, "runtime.status")["structuredContent"]["uiActive"]
                # Reopen and type without a click: autofocus must mount again.
                call(endpoint, "launcher.toggle")
                keys("-M", "ctrl", "a", "-m", "ctrl", "Fixture App 2")
                capture("reopened")
                keys("-k", "Return")
                wait_for(lambda: len(launches) == 2, "reopened input did not launch")
                assert launches[1]["arguments"]["argv"][-2] == "fixture-app-2", launches
                time.sleep(.2)
                call(endpoint, "launcher.toggle")
                keys("Fixture App 2")
                keys("-k", "Return")
                wait_for(lambda: len(launches) == 3, "error fixture did not run")
                capture("launch-error")
                keys("-M", "ctrl", "a", "-m", "ctrl", "Google Chrome")
                capture("chrome")
                keys("-k", "Return")
                wait_for(lambda: len(launches) == 4, "Chrome was not discovered or searchable")
                assert launches[3]["arguments"]["argv"] == ["/usr/bin/google-chrome-stable"], launches
                for state in ("launcher", "search", "scrolled-selection", "selection-up", "empty", "reopened", "launch-error", "chrome"):
                    with Image.open(artifacts / "bar.png") as bar, Image.open(artifacts / f"{state}.png") as image:
                        # Full-area tint stops exactly below the bar. Exclude
                        # the live clock when comparing the bar itself.
                        assert bar.crop((0, 0, 1000, 40)).tobytes() == image.crop((0, 0, 1000, 40)).tobytes(), "launcher covered the bar"
                        bounds = ImageChops.difference(bar.convert("RGB"), image.convert("RGB")).crop((0, 40, 1280, 800)).getbbox()
                        assert bounds == (0, 0, 1280, 760), (state, bounds)
                        assert image.getpixel((940, 400)) == image.getpixel((20, 400)) == image.getpixel((640, 60)), "overlay tint is not uniform"
                    with Image.open(artifacts / "launcher.png") as original, Image.open(artifacts / f"{state}.png") as image:
                        # Compare only the pill's top border, not query or caret.
                        border = (left + 40, top, right - 40, top + 2)
                        assert original.crop(border).tobytes() == image.crop(border).tobytes(), f"search moved in {state}"
                # Click unused space at the far right of a result row, not its
                # text, to verify the entire custom-content button activates.
                time.sleep(.2)
                call(endpoint, "launcher.toggle")
                keys("-M", "ctrl", "a", "-m", "ctrl", "Fixture App 4")
                sway_socket = next(directory.glob("sway-ipc.*.sock"))
                pointer = virtual_pointer(env["WAYLAND_DISPLAY"])
                time.sleep(.2)
                for command in (f"cursor set {right - 15} {first_row + 28}", "cursor press button1", "cursor release button1"):
                    subprocess.run(["swaymsg", "-s", str(sway_socket), f"seat seat0 {command}"], env=env, check=True, capture_output=True)
                    time.sleep(.1)
                wait_for(lambda: len(launches) == 5, "clicking row background did not launch")
                assert launches[4]["arguments"]["argv"][-2] == "fixture-app-4", launches

                # The fake endpoint records requests; it never executes these.
                for query, tool, argv in (("reboot", "run", ["systemctl", "reboot"]),
                                          ("shutdown", "run", ["systemctl", "poweroff"]),
                                          ("logout", "exit", None)):
                    count = len(launches)
                    call(endpoint, "launcher.toggle")
                    keys(query, "-k", "Return")
                    capture(f"confirm-{query}")
                    assert len(launches) == count, "search submission bypassed confirmation"
                    keys("-k", "Return")
                    assert len(launches) == count, "confirmation default was destructive"
                    keys("-k", "Return", "-k", "Down", "-k", "Return")
                    wait_for(lambda: len(launches) == count + 1, "confirmed action did not send")
                    assert launches[-1]["name"] == tool, launches[-1]
                    assert launches[-1]["arguments"] == ({"argv": argv} if argv else {}), launches[-1]

                call(endpoint, "launcher.toggle")
                keys("no-such-application")
                subprocess.run(["swaymsg", "-s", str(sway_socket), "output HEADLESS-1 mode 640x480"], check=True, capture_output=True)
                capture("narrow-empty")
                keys("-M", "ctrl", "a", "-m", "ctrl", "Fixture")
                for _ in range(8):
                    keys("-k", "Down")
                capture("narrow-selection")
                keys("-k", "Return")
                wait_for(lambda: len(launches) == 9, "short output lost keyboard selection")
                assert launches[-1]["arguments"]["argv"][-2] == "fixture-app-8"
                assert (artifacts / "sway.log").read_text().count("new layer surface: namespace ouroshell-panel ") == 1
                shell.terminate()
                # Ourokit drains on SIGTERM and returns 128 + SIGTERM.
                assert shell.wait(timeout=10) == 143, (artifacts / "shell.log").read_text()
                assert not endpoint.exists(), "control socket survived graceful shutdown"

                # Render the safe visual fixture too: active/urgent workspaces,
                # real themed application icons, and the session menu state.
                subprocess.run(["swaymsg", "-s", str(sway_socket), "output HEADLESS-1 mode 1280x800"], check=True, capture_output=True)
                shell = subprocess.Popen([str(BINARY), "run", str(ROOT / "src/preview.lua"), "--software"],
                                         env=env, stdout=shell_log, stderr=shell_log)
                time.sleep(1)
                capture("preview")
                keys("-k", "Down", "-k", "Down", "-k", "Down", "-k", "Down", "-k", "Return")
                capture("preview-session")
                keys("-k", "Down", "-k", "Return")
                capture("preview-confirmation")
                keys("-k", "Down", "-k", "Return")
                capture("preview-error")
                keys("-k", "Escape", "-k", "Escape")
                # Return home after the asynchronous themed icons have loaded.
                capture("preview")
                if settings:
                    set_scheme("light")
                    capture("preview-light")
                    set_scheme("dark")
                    capture("preview-dark")
                assert len(launches) == 9, "preview sent a real request"
                print("PASS: native search, uniform overlay tint, uncovered bar, paging, argv/cwd, confirmations, Escape, resize, refocus, clean exit")
                print(f"Captures: {artifacts}")
            finally:
                if pointer:
                    pointer.close()
                if shell and shell.poll() is None:
                    shell.terminate()
                    try:
                        shell.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        shell.kill()
                        shell.wait(timeout=10)
                if keyboard:
                    keyboard.terminate()
                    keyboard.wait(timeout=10)
                if settings:
                    settings.terminate()
                    settings.wait(timeout=10)
                compositor.terminate()
                compositor.wait(timeout=10)
                stopping.set()
                server.join(timeout=2)
                listener.close()


if __name__ == "__main__":
    main()
