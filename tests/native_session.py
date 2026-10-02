#!/usr/bin/env python3
"""Exercise shell policy and real lock UI on Ourokit's disposable Wayland peer.

Uses test-only PAM, a private logind bus, and compositor SHM captures. Never
connects to the live compositor, loads system PAM, or suspends the machine.
Requires the matching Ourokit source checkout (OUROKIT) and binary (OUROCTL).
"""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
import time

from PIL import Image
from gi.repository import GLib
from native_launcher import ROOT, BINARY, Logind, Portal, call, development_endpoint, pump

KIT = Path(os.environ.get("OUROKIT", ROOT.parent / "ourokit"))
spec = importlib.util.spec_from_file_location("session_peer", KIT / "tests/session_native.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)

SOURCE = r'''
local o = require("ouro")
local idle = require("idle")
local lock = require("lock")
local state
local empty = { type = "object", properties = {}, additionalProperties = false }
return o.app {
  id = "dev.ouro.shell.session-test",
  actions = {
    ["fixture.state"] = {
      description = "Read non-secret state from this disposable test fixture.",
      inputSchema = empty,
      outputSchema = { type = "object", properties = {
        phase = { type = "string" }, prompt = { type = "string" },
        message = { type = "string" }, caffeinated = { type = "boolean" },
      } },
      handler = function()
        local prompt = state.locker.prompt()
        return { phase = state.locker.phase(), prompt = prompt and prompt.text or "",
          message = state.locker.message() or "", caffeinated = state.caffeinated() }
      end,
    },
    ["fixture.caffeine"] = {
      description = "Toggle idle handling in this disposable test fixture.",
      inputSchema = empty, outputSchema = empty,
      handler = function() o.spawn_app(state.toggle); return {} end,
    },
  },
  run = function()
    require("appearance").connect()
    state = idle.connect { dismiss = function() end }
    return { windows = function()
      local window = lock.window(state.locker, function() return "Mon Sep 28  02:27 PM" end)
      return window and { window } or {}
    end }
  end,
}
'''


class Peer(wire.Peer):
    def __init__(self, root):
        super().__init__(root)
        self.sizes = {7: (1280, 800), 8: (1024, 768), 9: (900, 600)}
        self.guard = threading.RLock()
        self.ready = []
        self.delivered = set()
        self.power_modes = {}

    def send(self, obj, event, *values):
        with self.guard:
            if event == "locked":
                self.ready.append(obj)  # The test explicitly controls lock acknowledgement.
                return
            super().send(obj, event, *values)

    def acknowledge(self):
        with self.guard:
            obj = self.ready[-1]
            self.delivered.add(obj)
            super().send(obj, "locked")

    def request(self, obj, opcode, body):
        with self.guard:
            interface, data = self.objects[obj]
            name = self.xml[interface].findall("request")[opcode].attrib["name"]
            if interface == "ext_idle_notifier_v1" and name.startswith("get_"):
                new, timeout, seat = struct.unpack("<III", body)
                assert name == "get_idle_notification" and timeout in (300000, 600000, 1800000)
                self.objects[new] = ("ext_idle_notification_v1", {"timeout": timeout})
                return
            if interface == "zwlr_output_power_manager_v1" and name == "get_output_power":
                new, output = struct.unpack("<II", body)
                self.objects[new] = ("zwlr_output_power_v1", {"output": self.objects[output][1]["global"]})
                self.send(new, "mode", 1)
                return
            if interface == "zwlr_output_power_v1" and name == "set_mode":
                self.power_modes[data["output"]] = struct.unpack("<I", body)[0]
            if interface == "ext_session_lock_manager_v1" and name == "lock":
                new, = struct.unpack("<I", body)
                self.objects[new] = ("ext_session_lock_v1", {"outputs": set(), "mapped": set(), "acknowledged": False})
                self.locks += 1
                return
            if interface == "ext_session_lock_v1" and name == "unlock_and_destroy":
                assert obj in self.delivered, "unlock preceded the actual locked event"
            super().request(obj, opcode, body)
            self.hotplug_at = self.click_at = None  # No automatic fixture input/hotplug.

    def idle(self, milliseconds, event):
        with self.guard:
            notification = next(obj for obj, (kind, data) in self.objects.items()
                                if kind == "ext_idle_notification_v1" and data["timeout"] == milliseconds)
            self.send(notification, event)

    def hotplug(self):
        with self.guard:
            self.send(self.registry, "global_remove", 8)
            self.globals.pop(8)
            self.globals[9] = ("wl_output", 4)
            self.send(self.registry, "global", 9, "wl_output", 4)

    def type(self, text, output=9):
        codes = dict(zip("abcdefghijklmnopqrstuvwxyz", (30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
                                                        49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44)))
        codes.update({"-": 12, "\n": 28, "\x1b": 1})
        with self.guard:
            surface = next(obj for obj, (kind, data) in self.objects.items()
                           if kind == "wl_surface" and data.get("output") == output and data.get("buffer"))
            self.send(self.keyboard, "enter", 400, surface, b"")
            for index, character in enumerate(text):
                self.send(self.keyboard, "key", 401 + index * 2, 50, codes[character], 1)
                self.send(self.keyboard, "key", 402 + index * 2, 51, codes[character], 0)


def main():
    with tempfile.TemporaryDirectory(prefix="ouroshell-session-") as temp:
        directory = Path(temp)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        # Only the isolated child receives this loader path; no real PAM policy
        # or credentials participate in the test.
        subprocess.run(["cc", "-shared", "-fPIC", str(KIT / "tests/pam_fixture.c"),
                        "-o", str(directory / "libpam.so.0")], check=True)
        shutil.copytree(ROOT / "src", directory / "src")
        app = directory / "src/fixture.lua"
        app.write_text(SOURCE)
        bus_config = directory / "bus.conf"
        bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=' + temp +
            '</listen><policy context="default"><allow send_destination="*"/>'
            '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        peer = Peer(directory)
        server = threading.Thread(target=peer.run)
        server.start()
        with (artifacts / "session.log").open("wb") as log:
            bus = subprocess.Popen(["dbus-daemon", "--nofork", "--print-address=1", f"--config-file={bus_config}"],
                                   stdout=subprocess.PIPE, stderr=log, text=True)
            address = bus.stdout.readline().strip()
            logind, portal = Logind(address), Portal(address)
            env = dict(os.environ, XDG_RUNTIME_DIR=temp, WAYLAND_DISPLAY=peer.path,
                       DBUS_SESSION_BUS_ADDRESS=address, DBUS_SYSTEM_BUS_ADDRESS=address,
                       LD_LIBRARY_PATH=temp)
            env.pop("WAYLAND_SOCKET", None)
            process = subprocess.Popen([str(BINARY), "run", str(app), "--software", "--dev"],
                                       env=env, stdout=log, stderr=log)
            try:
                endpoint = development_endpoint(directory)

                def wait(check, message):
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        pump(.05)
                        assert process.poll() is None, (artifacts / "session.log").read_text()
                        assert peer.failure is None, peer.failure
                        if check():
                            return
                    raise AssertionError(message)

                def state():
                    return call(endpoint, "fixture.state")["structuredContent"]

                def capture(name, output="TEST-1"):
                    pump(.3)
                    with peer.guard:
                        width, height, stride, pixels = peer.captures[output]
                    Image.frombytes("RGBA", (width, height), pixels, "raw", "BGRA", stride).save(artifacts / f"{name}.png")

                def prepare(value):
                    logind.preparing = value
                    logind.bus.emit_signal(None, "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                                           "PrepareForSleep", GLib.Variant("(b)", (value,)))
                    logind.bus.flush_sync(None)

                wait(lambda: len(logind.delay_readers) == 1 and len(peer.power_modes) == 2, "session setup failed")
                delay = logind.delay_readers[-1]
                peer.idle(600000, "idled")
                wait(lambda: peer.ready, "lock surfaces did not cover the outputs")
                assert logind.held(delay) and peer.power_modes == {7: 1, 8: 1}
                assert state()["phase"] == "locking" and not state()["prompt"]
                capture("lock-pending")
                peer.acknowledge()
                wait(lambda: state()["prompt"] == "Identity", "native authentication prompt missing")
                wait(lambda: peer.power_modes == {7: 0, 8: 0}, "power-off did not wait for lock-ready")
                peer.idle(600000, "resumed")
                wait(lambda: peer.power_modes == {7: 1, 8: 1}, "input did not restore display power")
                capture("lock-prompt")
                peer.hotplug()
                wait(lambda: "TEST-3" in peer.captures and 9 in peer.power_modes, "hotplugged lock output missing")
                capture("lock-hotplug", "TEST-3")
                peer.type("alice")
                capture("lock-masked", "TEST-3")
                capture("lock-mirrored")
                portal.change(2)
                capture("lock-light", "TEST-3")
                portal.change(1)
                peer.type("\n")
                wait(lambda: state()["prompt"] == "Challenge", "second PAM prompt missing")
                peer.type("wrong\n")
                wait(lambda: "failed" in state()["message"], "denied PAM response did not remain locked")
                assert peer.unlocks == 0
                # A denial restarts authentication; no pointer is needed to retry.
                wait(lambda: state()["prompt"] == "Identity", "denial did not restart authentication")
                assert "failed" in state()["message"], "the new prompt must keep the denial visible"
                capture("lock-denied")
                # Escape clears the field and starts a fresh conversation.
                peer.type("al\x1b")
                wait(lambda: state()["prompt"] == "Identity" and "failed" not in state()["message"],
                     "Escape did not restart authentication")
                peer.idle(1800000, "idled")
                wait(lambda: logind.suspends == 1, "acknowledged idle lock did not permit suspend")
                prepare(True)
                wait(lambda: not logind.held(delay), "sleep delay did not release after the acknowledged lock")
                assert not state()["prompt"] and peer.unlocks == 0
                prepare(False)
                wait(lambda: len(logind.delay_readers) == 2 and state()["prompt"] == "Identity", "resume failed to rearm locking")
                peer.type("alice\n")
                wait(lambda: state()["prompt"] == "Challenge", "resume authentication missing")
                peer.type("test-only-response\n")
                wait(lambda: peer.unlocks == 1 and state()["phase"] == "unlocked", "successful authentication did not unlock")

                call(endpoint, "fixture.caffeine")
                wait(lambda: state()["caffeinated"] and logind.readers, "caffeinate failed")
                wait(lambda: not any(kind == "ext_idle_notification_v1" for kind, _ in peer.objects.values()),
                     "caffeinate left native idle timers active")
                logind.bus.emit_signal(None, logind.session_path, "org.freedesktop.login1.Session", "Lock", None)
                logind.bus.flush_sync(None)
                wait(lambda: len(peer.ready) == 2, "caffeine suppressed explicit session locking")
                delay = logind.delay_readers[-1]
                prepare(True)
                pump(.2)
                assert logind.held(delay), "sleep delay released before the compositor acknowledged locking"
                assert state()["phase"] == "locking" and not state()["prompt"]
                peer.acknowledge()
                wait(lambda: state()["phase"] == "locked" and not logind.held(delay), "lock acknowledgement did not release sleep delay")
                prepare(False)
                wait(lambda: len(logind.delay_readers) == 3 and state()["prompt"] == "Identity", "caffeinated resume failed")
                call(endpoint, "fixture.caffeine")
                wait(lambda: not state()["caffeinated"] and not logind.held(), "decaffeinate leaked inhibitor")
                process.terminate()
                assert process.wait(timeout=10) == 143
                assert peer.unlocks == 1, "shutdown unlocked a held session"
                assert not logind.held(logind.delay_readers[-1]), "shutdown leaked sleep-delay inhibitor"
                print("PASS: native shell idle/power, lock-ready sleep delay, hotplug, masked PAM denial/retry/unlock, caffeine and fail-closed shutdown")
                print(f"Captures: {artifacts}")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=5)
                logind.close(); portal.close()
                bus.terminate(); bus.wait(timeout=5)
                server.join(timeout=10)
                assert not server.is_alive()
                if peer.failure:
                    raise peer.failure


if __name__ == "__main__":
    main()
