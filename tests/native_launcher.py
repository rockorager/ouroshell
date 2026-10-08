#!/usr/bin/env python3
"""Exercise the real shell in a disposable headless Sway, never the live desktop.

Requires sibling Ourokit built, sway, grim, wtype, Pillow, and PyGObject. Optional
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
from gi.repository import Gio, GLib

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROCTL", ROOT.parent / "ourokit/zig-out/bin/ouroctl"))


class Portal:
    service = "org.freedesktop.portal.Desktop"
    path = "/org/freedesktop/portal/desktop"
    interface = "org.freedesktop.portal.Settings"
    namespace = "org.freedesktop.appearance"

    def __init__(self, address, value=1):
        self.value, self.reads = value, 0
        self.bus = Gio.DBusConnection.new_for_address_sync(address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        xml = f"""<node><interface name='{self.interface}'>
          <method name='ReadAll'><arg type='as' direction='in'/><arg type='a{{sa{{sv}}}}' direction='out'/></method>
          <signal name='SettingChanged'><arg type='s'/><arg type='s'/><arg type='v'/></signal>
        </interface></node>"""
        self.registration = self.bus.register_object(self.path,
            Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.read, None, None)
        result = self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "RequestName", GLib.Variant("(su)", (self.service, 4)), None, Gio.DBusCallFlags.NONE, 1000, None)
        assert result.unpack() == (1,)

    def read(self, bus, sender, path, interface, method, parameters, invocation):
        assert method == "ReadAll" and parameters.unpack() == ([self.namespace],)
        self.reads += 1
        invocation.return_value(GLib.Variant("(a{sa{sv}})", ({
            self.namespace: {"color-scheme": GLib.Variant("u", self.value)},
        },)))

    def change(self, value):
        self.value = value
        self.bus.emit_signal(None, self.path, self.interface, "SettingChanged",
            GLib.Variant("(ssv)", (self.namespace, "color-scheme", GLib.Variant("u", value))))
        self.bus.flush_sync(None)

    def close(self):
        self.bus.unregister_object(self.registration)
        self.bus.close_sync(None)


class Logind:
    """Private inhibitor fixture; pipe EOF proves the shell released its FD."""
    def __init__(self, address):
        self.readers = []
        self.delay_readers = []
        self.denied = False
        self.preparing = False
        self.locked_hint = False
        self.suspends = 0
        self.bus = Gio.DBusConnection.new_for_address_sync(address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        xml = """<node><interface name='org.freedesktop.login1.Manager'>
          <method name='Inhibit'><arg type='s' direction='in'/><arg type='s' direction='in'/>
          <arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='h' direction='out'/></method>
          <method name='GetSession'><arg type='s' direction='in'/><arg type='o' direction='out'/></method>
          <method name='Suspend'><arg type='b' direction='in'/></method>
          <property name='PreparingForSleep' type='b' access='read'/>
          <signal name='PrepareForSleep'><arg type='b'/></signal>
        </interface></node>"""
        self.registration = self.bus.register_object("/org/freedesktop/login1",
            Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method,
            lambda *args: GLib.Variant("b", self.preparing), None)
        self.session_path = "/org/freedesktop/login1/session/c7"
        xml = """<node><interface name='org.freedesktop.login1.Session'>
          <property name='Name' type='s' access='read'/>
          <method name='SetLockedHint'><arg type='b' direction='in'/></method>
          <signal name='Lock'/><signal name='Unlock'/>
        </interface></node>"""
        self.session_registration = self.bus.register_object(self.session_path,
            Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method,
            lambda *args: GLib.Variant("s", "fixture-user"), None)
        self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "RequestName", GLib.Variant("(su)", ("org.freedesktop.login1", 4)), None, Gio.DBusCallFlags.NONE, 1000, None)

    def method(self, bus, sender, path, interface, method, parameters, invocation):
        if method == "GetSession":
            assert parameters.unpack() == ("auto",)
            invocation.return_value(GLib.Variant("(o)", (self.session_path,)))
            return
        if method == "SetLockedHint":
            self.locked_hint = parameters.unpack()[0]
            invocation.return_value(GLib.Variant("()", ()))
            return
        if method == "Suspend":
            assert parameters.unpack() == (False,)
            self.suspends += 1
            invocation.return_value(GLib.Variant("()", ()))
            return
        assert method == "Inhibit"
        what, who, why, mode = parameters.unpack()
        assert who == "Ouroshell"
        assert (what, why, mode) in (("idle", "Caffeinated from the launcher", "block"),
                                   ("sleep", "Lock the session before sleep", "delay"))
        if self.denied and what == "idle":
            invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "Fixture inhibitor denied")
            return
        reader, writer = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        (self.readers if what == "idle" else self.delay_readers).append(reader)
        fds = Gio.UnixFDList.new()
        index = fds.append(writer)
        os.close(writer)
        invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), fds)

    def held(self, reader=None):
        try:
            assert os.read(self.readers[-1] if reader is None else reader, 1) == b""
            return False
        except BlockingIOError:
            return True

    def close(self):
        self.bus.unregister_object(self.registration)
        self.bus.unregister_object(self.session_registration)
        self.bus.close_sync(None)
        for reader in self.readers + self.delay_readers:
            os.close(reader)


def pump(seconds):
    end = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while time.monotonic() < end:
        while context.pending():
            context.iteration(False)
        time.sleep(.005)


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


def development_endpoint(directory):
    wait_for(lambda: list((directory / "ourokit/dev").glob("*")), "development endpoint missing")
    endpoints = list((directory / "ourokit/dev").glob("*"))
    assert len(endpoints) == 1, endpoints
    return endpoints[0]


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


def check_frame(image, dark):
    width, height = image.size
    left = (width - min(592, width - 48)) // 2
    top = 40 + (height - 40 - min(652, height - 88)) // 2
    bottom = height - (top - 40)
    center = width // 2
    card = (33, 34, 37) if dark else (255, 255, 255)
    rim = (54, 58, 63) if dark else (217, 217, 224)
    assert image.getpixel((left + 8, top + 100))[:3] == card, "frame must be opaque"
    assert image.getpixel((center, top))[:3] == rim, "frame must have a 1px rim"
    assert image.getpixel((center, top + 1))[:3] == card, "rim must not grow into the content"
    assert image.getpixel((left, top))[:3] not in (card, rim), "frame corner must be rounded"
    # A downward shadow is stronger below than above, then fades outward.
    upper = image.getpixel((center, top - 4))[0]
    lower = image.getpixel((center, bottom + 4))[0]
    outer = image.getpixel((center, bottom + 16))[0]
    assert lower < upper and lower < outer, ("missing, hard-edged or misaligned shadow", upper, lower, outer)


def main():
    appearance_only = "--appearance-only" in sys.argv
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
        portal = None
        logind = None
        bus = None
        with (artifacts / "sway.log").open("wb") as sway_log, (artifacts / "shell.log").open("wb") as shell_log:
            compositor = subprocess.Popen(["sway", "-c", str(config), "-d"], env=env, stdout=sway_log, stderr=sway_log)
            try:
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless compositor did not start")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                # No service directories: absence cannot activate desktop services.
                bus_config = directory / "bus.conf"
                bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=' + temporary +
                    '</listen><policy context="default"><allow send_destination="*"/>'
                    '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
                bus = subprocess.Popen(["dbus-daemon", "--nofork", "--print-address=1", f"--config-file={bus_config}"],
                                       stdout=subprocess.PIPE, stderr=shell_log, text=True)
                address = bus.stdout.readline().strip()
                assert address.startswith("unix:"), address
                env["DBUS_SESSION_BUS_ADDRESS"] = address
                env["DBUS_SYSTEM_BUS_ADDRESS"] = address

                def set_scheme(scheme):
                    portal.change({"default": 0, "dark": 1, "light": 2}[scheme])

                if not appearance_only:
                    portal = Portal(address)
                    logind = Logind(address)
                # A headless seat otherwise loses keyboard capability between
                # wtype invocations. Keep a device present like a real desktop.
                keyboard = subprocess.Popen(["wtype", "-s", "600000"], env=env)
                time.sleep(.2)
                entry = ROOT / ("src/preview.lua" if appearance_only else "ouro.json")
                options = [] if appearance_only else ["--dev"]
                shell = subprocess.Popen([str(BINARY), "run", str(entry), "--software", *options],
                                         env=env, stdout=shell_log, stderr=shell_log)
                if not appearance_only:
                    endpoint = development_endpoint(directory)

                def capture(name):
                    # Fullscreen software compositing is slower than the small
                    # popup; allow queued input, icon loads, and paint to settle.
                    pump(1.2)
                    assert shell.poll() is None, (artifacts / "shell.log").read_text()
                    path = artifacts / f"{name}.png"
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(path)], env=env, check=True)
                    return path.read_bytes()

                def keys(*arguments):
                    subprocess.run(["wtype", "-s", "200", *arguments, "-s", "100"], env=env, check=True)
                    time.sleep(1.5)

                if appearance_only:
                    # The shadow and themed icons decode asynchronously on
                    # first presentation; warm them before round-trip checks.
                    pump(2)
                    capture("preview-no-portal")
                    with Image.open(artifacts / "preview-no-portal.png") as image:
                        check_frame(image, False)
                    portal = Portal(address)
                    capture("preview-dark")
                    assert portal.reads >= 2, "both shell tokens and native theme must read the portal"
                    initial_reads = portal.reads
                    set_scheme("light")
                    capture("preview-light")
                    with Image.open(artifacts / "preview-dark.png") as dark, Image.open(artifacts / "preview-light.png") as light:
                        check_frame(dark, True)
                        check_frame(light, False)
                        assert dark.getpixel((20, 400)) == light.getpixel((20, 400)), "backdrop tint changed with theme"
                        for point in ((350, 400), (1000, 20)):
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
                    assert portal.reads == initial_reads, "live signals must not trigger polling or rereads"
                    portal.close()
                    portal = None
                    capture("preview-owner-lost")
                    with Image.open(artifacts / "preview-owner-lost.png") as image:
                        check_frame(image, False)
                    portal = Portal(address)
                    capture("preview-restarted")
                    with Image.open(artifacts / "preview-restarted.png") as image:
                        check_frame(image, True)
                    assert portal.reads >= 2, "new portal owner was not read"
                    assert (artifacts / "sway.log").read_text().count("new layer surface: namespace ouroshell-preview") == 2, "theme change recreated a layer surface"
                    # Exercise the frame at both clamped dimensions, then
                    # capture a non-default page without executing an action.
                    sway_socket = next(directory.glob("sway-ipc.*.sock"))
                    subprocess.run(["swaymsg", "-s", str(sway_socket), "output HEADLESS-1 mode 500x480"],
                                   check=True, capture_output=True)
                    capture("preview-narrow")
                    with Image.open(artifacts / "preview-narrow.png") as image:
                        check_frame(image, True)
                    keys("reboot", "-k", "Return")
                    capture("preview-narrow-confirmation")
                    with Image.open(artifacts / "preview-narrow-confirmation.png") as image:
                        check_frame(image, True)
                    assert not launches, "preview sent a real request"
                    print(f"PASS: portal absence, live dark/light/default, owner loss/restart, retained surfaces, frame/resize; captures: {artifacts}")
                    return

                # The 592×652 padded frame preserves the centered 560×620
                # content area below the bar; 48px search + 16px gaps.
                left, top, right = 360, 110, 920
                first_row = top + 48 + 16 + 35 + 16 + 18 + 4

                time.sleep(.7)
                baseline = capture("bar")
                call(endpoint, "launcher.toggle")
                capture("launcher")
                with Image.open(artifacts / "launcher.png") as image:
                    backdrop = image.getpixel((20, 400))[:3]
                    # #111113 at 77/255 opacity over the #608099 desktop.
                    expected = tuple(round(bg * 178 / 255 + tint * 77 / 255)
                                     for bg, tint in zip((96, 128, 153), (17, 17, 19)))
                    assert all(abs(a - b) <= 1 for a, b in zip(backdrop, expected)), (backdrop, expected)
                    check_frame(image, True)
                    line_y = top + 48 + 16 + 32
                    accent = image.getpixel((left + 18, line_y))
                    assert accent != image.getpixel((left + 150, line_y)), "scope underline collapsed"
                    span = 0
                    while span < 100 and image.getpixel((left + span, line_y)) == accent:
                        span += 1
                    assert 40 <= span < 100, ("scope underline must span the padded All label", span)
                keys("caffeinate")
                capture("caffeinate")
                keys("-k", "Return")
                pump(1)
                assert len(logind.readers) == 1 and logind.held(), "inhibitor did not survive launcher dismissal"
                call(endpoint, "launcher.toggle")
                keys("idle")
                capture("decaffeinate")
                keys("-k", "Return")
                pump(1)
                assert not logind.held(), "decaffeinate leaked its inhibitor"
                call(endpoint, "launcher.toggle")
                logind.denied = True
                keys("caffeinate", "-k", "Return")
                capture("caffeine-denied")
                assert len(logind.readers) == 1, "denied request acquired an inhibitor"
                logind.denied = False
                keys("-k", "Return")
                pump(1)
                assert len(logind.readers) == 2 and logind.held(), "retry after denial failed"
                # Reload carries chart state: Caffeinate survives as a fresh
                # inhibitor, and the previous generation's FD is released.
                call(endpoint, "runtime.reload")
                pump(1)
                assert len(logind.readers) == 3, "reload did not restore caffeine"
                assert not logind.held(logind.readers[1]) and logind.held(), "reload leaked or lost its inhibitor"

                # Install after startup: opening refreshes the catalog chart in
                # the background and the already-open launcher shows the result.
                def launcher_labels():
                    view = call(endpoint, "runtime.inspect", arguments={"window": "launcher"})["structuredContent"]
                    return [node.get("label") for node in view["windows"][0]["nodes"]]

                late_app = apps / "folio-refresh.desktop"
                late_app.write_text("[Desktop Entry]\nType=Application\nName=Folio Refresh Fixture\nExec=folio-fixture\n")
                call(endpoint, "launcher.toggle")
                keys("Folio Refresh")
                wait_for(lambda: "Folio Refresh Fixture" in launcher_labels(), "new desktop entry did not appear without reload")
                capture("catalog-refreshed")
                keys("-k", "Escape")
                late_app.unlink()
                call(endpoint, "launcher.toggle")
                keys("Folio Refresh")
                wait_for(lambda: "No matches. Try another name or keyword." in launcher_labels(),
                         "removed desktop entry survived catalog refresh")
                keys("-k", "Escape")

                call(endpoint, "launcher.toggle")
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
                if portal:
                    set_scheme("light")
                    capture("search-light")
                    with Image.open(artifacts / "search-light.png") as light, Image.open(artifacts / "selection-up.png") as dark:
                        assert light.getpixel((20, 400)) == dark.getpixel((20, 400)), "backdrop tint changed with theme"
                        assert light.getpixel((350, 400))[:3] == (255, 255, 255), "light card is not opaque"
                        assert dark.getpixel((350, 400))[:3] == (33, 34, 37), "dark card is not opaque"
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
                        assert image.getpixel((1040, 400)) == image.getpixel((20, 400)) == image.getpixel((640, 44)), "overlay tint away from the shadow is not uniform"
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
                # A click outside the card dismisses the launcher (and its tint)
                # without launching anything.
                call(endpoint, "launcher.toggle")
                capture("before-outside-click")
                with Image.open(artifacts / "before-outside-click.png") as image:
                    assert image.convert("RGB").getpixel((200, 600)) != (96, 128, 153), "launcher tint missing"
                for command in ("cursor set 20 400", "cursor press button1", "cursor release button1"):
                    subprocess.run(["swaymsg", "-s", str(sway_socket), f"seat seat0 {command}"], env=env, check=True, capture_output=True)
                    time.sleep(.1)
                capture("outside-click")
                with Image.open(artifacts / "outside-click.png") as image:
                    assert image.convert("RGB").getpixel((200, 600)) == (96, 128, 153), "outside click did not dismiss"
                assert len(launches) == 5, "outside click launched something"

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
                if portal:
                    set_scheme("light")
                    capture("preview-light")
                    set_scheme("dark")
                    capture("preview-dark")
                assert len(launches) == 9, "preview sent a real request"
                print("PASS: native search, opaque rounded card, 30% dark backdrop, uncovered bar, paging, argv/cwd, confirmations, Escape, resize, refocus, clean exit")
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
                if portal:
                    portal.close()
                if logind:
                    logind.close()
                if bus:
                    bus.terminate()
                    bus.wait(timeout=10)
                compositor.terminate()
                compositor.wait(timeout=10)
                stopping.set()
                server.join(timeout=2)
                listener.close()


if __name__ == "__main__":
    main()
