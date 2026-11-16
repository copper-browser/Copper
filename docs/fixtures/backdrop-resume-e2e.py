#!/usr/bin/env python3
"""An animated space's scene carries on from the frame it stopped on (Fork/Backdrop/scene.js),
end to end. Owner, round 7: "a weird visual for gradient backgrounds when you tab in" — the
scene's clock ran on while Copper was behind another app (or idle 30 s), and coming back was a
0.9 s glide through everything missed: six seconds away, six seconds of motion in under one.

  1. A space with a scene (`spaces theme 0 motion ribbons`): the page draws, its clock moves.
  2. `spaces backdrop pause` (as behind another app) for six seconds, then `run` (in front again):
     half a second later the clock is half a second on, not six and a half; so is it after 1.5 s.

The bench says `run` itself rather than leave it to the window (`auto`): a probe's window is
never in front, and a Mac with Reduce Motion on keeps every scene still.

A fresh SEARCH_PROBE world of the development build, headless.

    ./build.sh && docs/fixtures/backdrop-resume-e2e.py [--app build/Copper.app]
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]
app = os.path.abspath(args[args.index("--app") + 1]) if "--app" in args else os.path.join(root, "build/Copper.app")
world = f"backdrop-{os.getpid()}"
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({world})")
domain = f"com.collinrijock.copper.test.{world}"
proc = None


def cleanup():
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    shutil.rmtree(folder, ignore_errors=True)


def fail(why):
    print(f"FAIL {why}")
    cleanup()
    sys.exit(1)


def ask(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(20)
        s.connect(os.path.join(folder, "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while chunk := s.recv(1 << 16):
            data += chunk
    answer = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if answer.get("error"):
        fail(f"{request}: {answer['error']}")
    return answer


def scene():
    rows = [b.get("status") for b in ask({"do": "backdrop"}).get("backdrops", []) if b.get("status")]
    return rows[0] if rows else {}


def until(what, check, seconds=30):
    limit = time.time() + seconds
    while time.time() < limit:
        try:
            if value := check():
                return value
        except OSError:
            pass
        time.sleep(0.25)
    fail(f"timed out waiting for {what}")


with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
for key in ("bench", "welcomed", "sidebar"):
    subprocess.run(["defaults", "write", domain, key, "-bool", "true"], check=True)
env = dict(os.environ, SEARCH_PROBE=world, SEARCH_HEADLESS="1", SEARCH_MCP_PORT=str(port))
proc = subprocess.Popen([os.path.join(app, "Contents/MacOS/Copper")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
until("the bench", lambda: os.path.exists(os.path.join(folder, "bench.sock")) and ask({"do": "tabs"}), 40)

ask({"do": "spaces", "op": "theme", "arg": "0 motion ribbons"})
ask({"do": "spaces", "op": "backdrop", "arg": "run"})
until("the scene to draw", lambda: scene().get("running") and scene().get("frames", 0) > 5, 40)
a = scene()["time"]
time.sleep(1)
b = scene()["time"]
if not 0.5 < b - a < 2:
    fail(f"running, the clock should move a second a second: {a} → {b}")
print(f"ok  1. the scene runs: clock {a:.2f} → {b:.2f} in a second")

ask({"do": "spaces", "op": "backdrop", "arg": "pause"})
until("the scene to stop", lambda: not scene().get("running"), 5)
left = scene()["time"]
time.sleep(6)
ask({"do": "spaces", "op": "backdrop", "arg": "run"})
time.sleep(0.5)
soon = scene()
time.sleep(1)
later = scene()
if not soon.get("running"):
    fail(f"back in front, the scene should run: {soon}")
if soon["time"] - left > 2 or later["time"] - left > 3.5:
    fail(f"six seconds behind another app, and the scene raced to catch up: left at {left:.2f}, "
         f"{soon['time']:.2f} half a second after coming back, {later['time']:.2f} a second later")
print(f"ok  2. back after 6 s: left at {left:.2f}, {soon['time']:.2f} half a second on, {later['time']:.2f} a second after that")
cleanup()
print("PASS backdrop-resume-e2e")
