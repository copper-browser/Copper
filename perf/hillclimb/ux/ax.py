#!/usr/bin/env python3
"""Client for the AX probe (ux/axprobe.swift): a real accessibility client in the GUI session.

    python3 ax.py status      build + start it if needed, then: trusted? screen locked? front app? Reduce Motion?
    python3 ax.py stop        boot it out

The probe is an .app in ~/hc/axprobe (outside the harness copy, which rsync --delete replaces), started as the
LaunchAgent dev.hc.axprobe in gui/UID: launched by launchd it is its own "responsible process", so the
Accessibility grant is the app's (one toggle, NEEDS-COLLIN.md), never sshd's or Terminal's. It is rebuilt only
when axprobe.swift changes: an ad-hoc signature's grant is tied to its code hash, so a rebuild needs the toggle again
(`sudo tccutil reset Accessibility dev.hc.axprobe`, `ax.py stop; ax.py status` re-lists it, then the toggle).
"""
import hashlib, json, os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.expanduser(os.environ.get("HC_AXPROBE", "~/hc/axprobe"))
APP = os.path.join(DIR, "AXProbe.app")
BIN = os.path.join(APP, "Contents", "MacOS", "AXProbe")
SOCK = os.path.join(DIR, "ax.sock")
LABEL = "dev.hc.axprobe"
SRC = os.path.join(HERE, "axprobe.swift")


def build():
    """Build when the source's hash differs from the built one's (never otherwise: that keeps the grant)."""
    want = hashlib.sha256(open(SRC, "rb").read()).hexdigest()[:16]
    stamp = os.path.join(DIR, "SOURCE")
    if os.path.exists(BIN) and os.path.exists(stamp) and open(stamp).read().strip() == want:
        return False
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    with open(os.path.join(APP, "Contents", "Info.plist"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                '<key>CFBundleExecutable</key><string>AXProbe</string>'
                f'<key>CFBundleIdentifier</key><string>{LABEL}</string>'
                '<key>CFBundleName</key><string>HC AX Probe</string><key>CFBundlePackageType</key><string>APPL</string>'
                '<key>LSUIElement</key><true/></dict></plist>')
    subprocess.run(["swiftc", "-O", "-o", BIN, SRC], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", LABEL, APP], check=True)
    open(stamp, "w").write(want + "\n")
    return True


def ask(req, timeout=60):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(SOCK)
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            data += chunk
    return json.loads(data or b"{}")


def running():
    try:
        return "pid" in ask({"do": "status"}, 5)
    except OSError:
        return False


def start():
    """Build if needed, (re)start the LaunchAgent if it isn't answering, → status."""
    rebuilt = build()
    if rebuilt or not running():
        plist = os.path.join(DIR, LABEL + ".plist")
        with open(plist, "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
                    f"<key>Label</key><string>{LABEL}</string><key>KeepAlive</key><false/><key>RunAtLoad</key><true/>"
                    "<key>LimitLoadToSessionType</key><string>Aqua</string>"
                    f"<key>ProgramArguments</key><array><string>{BIN}</string><string>{SOCK}</string></array>"
                    f"<key>StandardErrorPath</key><string>{DIR}/axprobe.log</string></dict></plist>")
        stop()
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", plist], check=True)
        for _ in range(40):
            if running():
                break
            time.sleep(0.25)
    return ask({"do": "status"}, 10)


def stop():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
    for _ in range(40):  # bootout returns before the service is gone; bootstrap fails (5) until it is
        if subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True).returncode:
            return
        time.sleep(0.25)


def why_not(st):
    """'' when the probe can walk a window, else what blocks it (for n/a notes)."""
    why = []
    if not st.get("trusted"):
        why.append("AX probe not trusted yet (System Settings › Privacy & Security › Accessibility › HC AX Probe)")
    if st.get("locked"):
        why.append("the screen is locked (macOS lists no windows to any accessibility client)")
    return "; ".join(why) + ("; see NEEDS-COLLIN.md" if why else "")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "stop":
        stop()
    else:
        st = start()
        st["ready"] = not why_not(st)
        st["blocker"] = why_not(st)
        print(json.dumps(st))
