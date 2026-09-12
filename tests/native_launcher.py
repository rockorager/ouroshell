#!/usr/bin/env python3
"""Exercise the real shell in a disposable headless Sway, never the live desktop.

Requires sibling Ourokit built, sway, grim, and wtype. Optional
OUROSHELL_TEST_ARTIFACTS preserves captures and protocol logs.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT.parent / "ourokit/zig-out/bin/ouroctl"


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
                assert (artifacts / "sway.log").read_text().count("new layer surface: namespace ouroshell-panel ") == 1
                shell.terminate()
                # Ourokit drains on SIGTERM and returns 128 + SIGTERM.
                assert shell.wait(timeout=10) == 143, (artifacts / "shell.log").read_text()
                assert not endpoint.exists(), "control socket survived graceful shutdown"
                print("PASS: native discovery, search, selection beyond first page, argv/cwd, Escape, rapid toggles, refocus, clean exit")
                print(f"Captures: {artifacts}")
            finally:
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
