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


def call(path, name, allow_error=False):
    params = {"name": name, "arguments": {}, "_meta": {
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
        return reply["result"]


def main():
    with tempfile.TemporaryDirectory(prefix="ouroshell-native-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        config = directory / "sway.conf"
        config.write_text("output * mode 1280x800\noutput * bg #101216 solid_color\nseat seat0 fallback true\n")
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
                   WLR_RENDERER="pixman", LIBSEAT_BACKEND="noop")
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
        with (artifacts / "sway.log").open("wb") as sway_log, (artifacts / "shell.log").open("wb") as shell_log:
            compositor = subprocess.Popen(["sway", "-c", str(config), "-d"], env=env, stdout=sway_log, stderr=sway_log)
            try:
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless compositor did not start")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                shell = subprocess.Popen([str(BINARY), "run", str(ROOT / "ouro.json"), "--software"],
                                         env=env, stdout=shell_log, stderr=shell_log)
                endpoint = directory / "ourokit/apps/dev.ouro.shell"
                wait_for(endpoint.exists, "shell MCP socket did not appear")

                def capture(name):
                    time.sleep(.2)
                    assert shell.poll() is None, (artifacts / "shell.log").read_text()
                    path = artifacts / f"{name}.png"
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(path)], env=env, check=True)
                    return path.read_bytes()

                def keys(*arguments):
                    subprocess.run(["wtype", "-s", "200", *arguments, "-s", "100"], env=env, check=True)
                    time.sleep(.15)

                def search_bounds(name):
                    # The wide blue focus border identifies the input, without
                    # relying on where the layout places it or its text value.
                    with Image.open(artifacts / f"{name}.png") as image:
                        image = image.convert("RGB")
                        edges = []
                        for y in range(image.height):
                            xs = [x for x in range(image.width)
                                  if (lambda r, g, b: b > 150 and b > r + 20 and b > g + 20)(*image.getpixel((x, y)))]
                            if len(xs) > 500:
                                edges.append((min(xs), y, max(xs)))
                    assert len(edges) == 2, (name, edges)
                    assert all(left + right == image.width - 1 for left, _, right in edges), (name, edges)
                    return edges

                time.sleep(.7)
                baseline = capture("bar")
                call(endpoint, "launcher.toggle")
                capture("launcher")
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
                input_bottom = search_bounds("scrolled-selection")[-1][1]
                with Image.open(artifacts / "scrolled-selection.png") as before, Image.open(artifacts / "selection-up.png") as after:
                    upper_rows = (330, input_bottom + 12, 950, input_bottom + 12 + 5 * 48)
                    assert before.crop(upper_rows).tobytes() == after.crop(upper_rows).tobytes(), "Up scrolled rows that were already visible"
                    assert before.crop((330, input_bottom + 12 + 5 * 48, 950, input_bottom + 12 + 7 * 48)).tobytes() != after.crop((330, input_bottom + 12 + 5 * 48, 950, input_bottom + 12 + 7 * 48)).tobytes(), "Up did not move the selection highlight"
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
                keys("-k", "Return")
                wait_for(lambda: len(launches) == 3, "error fixture did not run")
                capture("launch-error")
                keys("-M", "ctrl", "a", "-m", "ctrl", "Google Chrome")
                capture("chrome")
                keys("-k", "Return")
                wait_for(lambda: len(launches) == 4, "Chrome was not discovered or searchable")
                assert launches[3]["arguments"]["argv"] == ["/usr/bin/google-chrome-stable"], launches
                expected_bounds = search_bounds("launcher")
                for state in ("launcher", "search", "scrolled-selection", "selection-up", "empty", "reopened", "launch-error", "chrome"):
                    assert search_bounds(state) == expected_bounds, f"search field moved in {state}"
                    with Image.open(artifacts / "bar.png") as bar, Image.open(artifacts / f"{state}.png") as image:
                        # Exclude the clock; the launcher must be one compact,
                        # centered surface, with no larger painted container.
                        bounds = ImageChops.difference(bar.convert("RGB"), image.convert("RGB")).crop((0, 40, 1280, 800)).getbbox()
                        assert bounds is not None
                        left, top, right, bottom = bounds
                        assert (right - left, bottom - top) == (620, 480), (state, bounds)
                        assert left + right == 1280 and top + bottom == 760, (state, bounds)
                # Click unused space at the far right of a result row, not its
                # text, to verify the entire custom-content button activates.
                time.sleep(.2)
                call(endpoint, "launcher.toggle")
                keys("-M", "ctrl", "a", "-m", "ctrl", "Fixture App 4")
                sway_socket = next(directory.glob("sway-ipc.*.sock"))
                _, bottom, right = expected_bounds[-1]
                pointer = virtual_pointer(env["WAYLAND_DISPLAY"])
                time.sleep(.2)
                for command in (f"cursor set {right - 15} {bottom + 34}", "cursor press button1", "cursor release button1"):
                    subprocess.run(["swaymsg", "-s", str(sway_socket), f"seat seat0 {command}"], env=env, check=True, capture_output=True)
                    time.sleep(.1)
                wait_for(lambda: len(launches) == 5, "clicking row background did not launch")
                assert launches[4]["arguments"]["argv"][-2] == "fixture-app-4", launches
                assert (artifacts / "sway.log").read_text().count("new layer surface: namespace ouroshell-panel ") == 1
                shell.terminate()
                # Ourokit drains on SIGTERM and returns 128 + SIGTERM.
                assert shell.wait(timeout=10) == 143, (artifacts / "shell.log").read_text()
                assert not endpoint.exists(), "control socket survived graceful shutdown"
                print("PASS: native discovery, Chrome, fixed search position, selection beyond first page, argv/cwd, Escape, rapid toggles, refocus, clean exit")
                print(f"Captures: {artifacts}")
            finally:
                if pointer:
                    pointer.close()
                if shell and shell.poll() is None:
                    shell.terminate()
                    shell.wait(timeout=10)
                compositor.terminate()
                compositor.wait(timeout=10)
                stopping.set()
                server.join(timeout=2)
                listener.close()


if __name__ == "__main__":
    main()
