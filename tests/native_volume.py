#!/usr/bin/env python3
"""Volume keys and hover on private PipeWire/Sway instances, never host audio."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from PIL import Image
from native_launcher import BINARY, ROOT, Portal, call, development_endpoint, pump, virtual_pointer, wait_for, isolated_state


def main():
    with tempfile.TemporaryDirectory(prefix="ouroshell-volume-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROSHELL_TEST_ARTIFACTS", directory / "artifacts"))
        artifacts.mkdir(parents=True, exist_ok=True)
        config = directory / "sway.conf"
        config.write_text("output * mode 1280x800\noutput * bg #608099 solid_color\nseat seat0 fallback true\n"
                          'for_window [app_id="dev.ouro.volume-focus"] floating enable, move position 40 180\n')
        audio_config = directory / "pipewire.conf"
        audio_config.write_text('''
context.properties = { core.daemon = true core.name = pipewire-0 }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-metadata }
  { name = libpipewire-module-spa-node-factory }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-access }
  { name = libpipewire-module-adapter }
]
context.objects = [
  { factory = metadata args = { metadata.name = default } }
  { factory = adapter args = {
      factory.name = support.null-audio-sink node.name = fixture-speakers
      node.description = "Fixture speakers" media.class = Audio/Sink
      audio.position = [ FL FR ]
  } }
]
''')
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
                   PIPEWIRE_REMOTE="pipewire-0", WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
                   WLR_RENDERER="pixman", LIBSEAT_BACKEND="noop",
                   DBUS_SESSION_BUS_ADDRESS=f"unix:path={directory}/bus",
                   DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={directory}/no-system-bus")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("DISPLAY", None)
        processes, portal, pointer = [], None, None
        with (artifacts / "native.log").open("w") as log:
            def start(argv, trace=False):
                process = subprocess.Popen(argv, env=dict(env, WAYLAND_DEBUG="server") if trace else env,
                                           stdout=log, stderr=log)
                processes.append(process)
                return process

            def run(*argv):
                return subprocess.check_output(argv, env=env, text=True, stderr=log)

            try:
                start(["dbus-daemon", "--session", "--nofork", f"--address={env['DBUS_SESSION_BUS_ADDRESS']}"])
                wait_for((directory / "bus").exists, "private session bus missing")
                audio = start(["pipewire", "-c", str(audio_config)])
                wait_for((directory / "pipewire-0").exists, "private PipeWire missing")
                run("pw-metadata", "-n", "default", "0", "default.audio.sink",
                    '{"name":"fixture-speakers"}', "Spa:String:JSON")
                run("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.4")
                start(["sway", "-c", str(config)], trace=True)
                wait_for(lambda: list(directory.glob("wayland-*.lock")), "headless Sway missing")
                env["WAYLAND_DISPLAY"] = str(next(directory.glob("wayland-*.lock")))[:-5]
                wait_for(lambda: list(directory.glob("sway-ipc.*.sock")), "private Sway IPC missing")
                ipc = str(next(directory.glob("sway-ipc.*.sock")))
                pointer = virtual_pointer(env["WAYLAND_DISPLAY"])
                start(["wtype", "-s", "600000"])
                pump(.2)
                portal = Portal(env["DBUS_SESSION_BUS_ADDRESS"], 2)
                app = start([str(BINARY), "run", str(ROOT / "ouro.json"), "--dev", "--software"])
                endpoint = development_endpoint(directory)
                editor = directory / "editor.lua"
                editor.write_text('''local o = require("ouro")
return o.app { id = "dev.ouro.volume-focus", run = function() return { windows = {
  o.window { id = "main", title = "Volume focus fixture", width = 400, height = 240,
    content = function() return o.text_input { key = "editor", label = "Editor", autofocus = true,
      default_text = "Volume changes must not take focus" } end },
} } end }
''')
                start([str(BINARY), "run", str(editor), "--software"])
                pump(1)
                def editor_focused():
                    def find(item):
                        return (item.get("app_id") == "dev.ouro.volume-focus" and item.get("focused")) or any(
                            find(child) for child in item.get("nodes", []) + item.get("floating_nodes", []))
                    return find(json.loads(run("swaymsg", "-s", ipc, "-t", "get_tree")))
                assert editor_focused(), "focus fixture was not focused before the volume test"
                keyboard_enters = re.findall(r"wl_keyboard[@#]\d+\.enter\(", (artifacts / "native.log").read_text())
                assert keyboard_enters, "test requires a real keyboard focus baseline"

                def node(label):
                    windows = call(endpoint, "runtime.inspect")["structuredContent"]["windows"]
                    for window in windows:
                        view = call(endpoint, "runtime.inspect", arguments={"window": window["window"]})["structuredContent"]
                        for item in view["windows"][0]["nodes"]:
                            if item.get("label") == label:
                                return item

                def popup_geometry():
                    trace = (artifacts / "native.log").read_text()
                    events = list(re.finditer(r"xdg_popup[@#](\d+)\.configure\((-?\d+), (-?\d+), (\d+), (\d+)\)", trace))
                    if not events:
                        return None
                    event = events[-1]
                    identity, x, y, width, height = map(int, event.groups())
                    if re.search(rf"xdg_popup[@#]{identity}\.(?:destroy|popup_done)\(", trace[event.end():]):
                        return None
                    return x, y, width, height

                def capture(name):
                    pump(.15)
                    assert app.poll() is None, (artifacts / "native.log").read_text()
                    status = call(endpoint, "runtime.status")["structuredContent"]
                    assert status["diagnostic"] is None, status
                    path = artifacts / f"{name}.png"
                    subprocess.run(["grim", "-o", "HEADLESS-1", str(path)], env=env, check=True)
                    return path

                def pointer_command(command):
                    result = json.loads(run("swaymsg", "-s", ipc, "seat seat0 cursor " + command))
                    assert all(item["success"] for item in result), result

                def hover(x, y, delay=.4):
                    pointer_command(f"set {round(x)} {round(y)}")
                    pump(delay)

                def expect_volume(value):
                    wait_for(lambda: node(f"Volume: {value}%"), f"missing confirmed {value}%")
                    actual = run("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@")
                    assert abs(float(actual.split()[1]) * 100 - value) < .1, actual

                expect_volume(40)
                assert popup_geometry() is None, "initial connection flashed the OSD"
                icon = node("Volume: 40%")
                bounds = icon["bounds"]
                icon_x = bounds["x"] + bounds["width"] / 2
                hover(icon_x, bounds["y"] + bounds["height"] / 2)
                wait_for(popup_geometry, "hover did not open the popup")
                geometry = popup_geometry()
                assert abs(geometry[0] + geometry[2] / 2 - icon_x) <= 2 and geometry[1] >= 40, (
                    "popup is not centered below the volume icon", geometry, icon_x)
                with Image.open(capture("volume-hover-light")) as image:
                    x, y, width, height = geometry
                    assert image.getpixel((x, y)) == image.getpixel((x, y - 1)), (
                        "rounded popup corners must reveal the desktop, not an opaque backdrop")
                level = node("Volume level, 40%")
                assert level and not level.get("range"), "popup must contain a display, not a slider"
                hover(0, 200)
                wait_for(lambda: popup_geometry() is None, "leaving did not close the hover display")

                # Existing compositor wpctl bindings need no shell RPC to show changes.
                run("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+")
                expect_volume(45)
                wait_for(popup_geometry, "external volume key did not open the OSD")
                capture("volume-up-light")
                assert popup_geometry() == geometry, "key feedback moved away from the icon"
                # Put the already-focused editor beneath the passive popup.
                # Clicking bare desktop would legitimately clear keyboard focus.
                run("swaymsg", "-s", ipc, '[app_id="dev.ouro.volume-focus"] move position 850 0')
                hover(geometry[0] + geometry[2] * .75, geometry[1] + geometry[3] * .7, delay=.1)
                before_click = (artifacts / "native.log").stat().st_size
                pointer_command("press button1")
                pointer_command("release button1")
                pump(.1)
                click_trace = (artifacts / "native.log").read_text()[before_click:]
                assert re.search(r"wl_pointer[@#]\d+\.button\(", click_trace), "passive popup swallowed the click"
                assert editor_focused(), "click through the popup failed to reach the editor"
                run("swaymsg", "-s", ipc, '[app_id="dev.ouro.volume-focus"] move position 40 180')
                expect_volume(45)
                pump(1.6)
                assert popup_geometry() is None, "hovering the display must not hold it open"
                hover(0, 200)

                call(endpoint, "volume.down")
                expect_volume(40)
                wait_for(popup_geometry, "shell volume action did not open the OSD")
                for _ in range(5):
                    call(endpoint, "volume.up")
                expect_volume(65)
                capture("volume-repeat-light")
                run("wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1")
                wait_for(lambda: node("Muted (65%)"), "mute state did not update")
                capture("volume-muted-light")
                run("wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0")
                portal.change(1)
                pump(.3)
                call(endpoint, "volume.down")
                expect_volume(60)
                capture("volume-down-dark")

                # A no-op at the limit must still provide key feedback.
                run("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "1.0")
                expect_volume(100)
                pump(1.6)
                assert popup_geometry() is None
                call(endpoint, "volume.up")
                expect_volume(100)
                wait_for(popup_geometry, "100% key press had no feedback")
                capture("volume-limit-dark")
                trace = (artifacts / "native.log").read_text()
                assert not re.search(r"xdg_popup[@#]\d+\.grab\(", trace), "volume feedback grabbed input"
                assert re.findall(r"wl_keyboard[@#]\d+\.enter\(", trace) == keyboard_enters and editor_focused(), (
                    "volume feedback took keyboard focus from the editor")

                audio.terminate()
                audio.wait(timeout=10)
                wait_for(lambda: node("Audio unavailable"), "disconnect left stale audio state")
                wait_for(lambda: popup_geometry() is None, "disconnect left the OSD open")
                capture("volume-unavailable-dark")
                print(f"PASS: native audio, hover/key display anchoring, passive clicks, repeat, limits, mute, themes, expiry, focus and disconnect; {artifacts}")
            finally:
                if portal:
                    portal.close()
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
                if pointer:
                    pointer.close()


if __name__ == "__main__":
    with isolated_state():
        main()
