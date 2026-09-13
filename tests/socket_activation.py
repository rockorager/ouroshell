#!/usr/bin/env python3
"""Check the shipped units on a private socket in the current systemd user manager.

Requires an active graphical session and installed ouroctl. No windows are
created; only the isolated test service is killed. Temporary units are removed.
"""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def systemctl(*args, check=True):
    return subprocess.run(["systemctl", "--user", *args], check=check,
                          capture_output=True, text=True).stdout.strip()


def status(endpoint):
    params = {"name": "runtime.status", "arguments": {}, "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
    }}
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(8)
        client.connect(str(endpoint))
        client.sendall(json.dumps({"jsonrpc": "2.0", "id": 1,
                                  "method": "tools/call", "params": params}).encode() + b"\n")
        reply = json.loads(client.makefile("rb").readline())
    assert "error" not in reply, reply
    result = reply["result"]
    assert not result.get("isError"), reply
    value = result["structuredContent"]
    assert json.loads(result["content"][0]["text"]) == value
    assert value["applicationId"] == "dev.ouro.shell", value
    assert value["uiActive"] is False, value
    assert value["diagnostic"] is None, value


def main():
    assert systemctl("is-active", "graphical-session.target") == "active"
    with tempfile.TemporaryDirectory(prefix="ouroshell-socket-") as temporary:
        directory = Path(temporary)
        name = directory.name
        endpoint = directory / "shell.sock"
        service = name + ".service"
        listener = name + ".socket"
        socket_unit = (ROOT / "systemd/dev.ouro.shell.socket").read_text().replace(
            "%t/ourokit/apps/dev.ouro.shell", str(endpoint))
        service_unit = (ROOT / "systemd/dev.ouro.shell.service").read_text().replace(
            "%h/.local/share/ouroshell/ouro.json", str(ROOT / "ouro.json"))
        (directory / listener).write_text(socket_unit)
        (directory / service).write_text(service_unit)
        try:
            systemctl("link", "--runtime", str(directory / listener), str(directory / service))
            systemctl("start", listener)
            assert systemctl("show", service, "-p", "MainPID", "--value") == "0"
            inode = endpoint.stat().st_ino
            assert endpoint.stat().st_mode & 0o777 == 0o600
            status(endpoint)
            first_pid = systemctl("show", service, "-p", "MainPID", "--value")
            assert int(first_pid) > 0
            systemctl("kill", "--signal=KILL", "--kill-whom=main", service)
            deadline = time.monotonic() + 10
            while True:
                pid = systemctl("show", service, "-p", "MainPID", "--value")
                if int(pid) > 0 and pid != first_pid:
                    break
                assert time.monotonic() < deadline, "service did not restart after crash"
                time.sleep(.1)
            assert endpoint.stat().st_ino == inode, "crash replaced the systemd-owned socket"
            status(endpoint)
            systemctl("stop", service)
            assert endpoint.stat().st_ino == inode, "service shutdown removed systemd's socket"
            status(endpoint)
            assert int(systemctl("show", service, "-p", "MainPID", "--value")) > 0
            systemctl("stop", listener, service)
            assert not endpoint.exists(), "socket unit did not remove its endpoint on stop"
            print("PASS: on-demand startup, headless status, crash restart, stable listener, reactivation and socket cleanup")
        finally:
            systemctl("stop", listener, service, check=False)
            systemctl("reset-failed", service, check=False)
            systemctl("disable", "--runtime", listener, service, check=False)
            systemctl("daemon-reload")


if __name__ == "__main__":
    main()
