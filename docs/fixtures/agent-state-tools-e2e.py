#!/usr/bin/env python3
"""The agent's files-and-state tools, end to end (Fork/MCP/StateTools.swift,
FileChooser.swift, NetLog.swift).

November 2026 hill-climb: agents had no way to upload a file, save a PDF,
find a download, see the page's requests, read a cookie, or reach history,
bookmarks and spaces. Each tool here, in a background tab of the agent's own,
with the user's tab left where it was:

  1. browser_file_upload — the Playwright order (click, then upload), the
     armed order (upload, then click), bad paths refused, and cancel.
  2. browser_pdf_save — a long page saved as a PDF of several pages.
  3. browser_downloads — a clicked download listed, finished, with its path.
  4. browser_network_requests — a fetch GET (200), a POST and a 404, with
     method and status.
  5. browser_cookies — an HttpOnly cookie listed with its value hidden, then
     shown once the site is shared with agents; set refuses a foreign
     domain; delete of an HttpOnly cookie refused without access.
  6. browser_history, browser_bookmarks — the visit found; a bookmark added
     once, then found.
  7. browser_spaces — listed; the agent's tab moved to another space and
     still answering; the user's tab refused.
  8. The CLI verbs (copper pdf, downloads, upload, back, scroll, wait,
     hover, select) reach the same tools.

A fresh SEARCH_PROBE world of the development build, headless, pages from a
local server: no network, no real Copper world touched. Ports: MCP on
$MCP_PORT (default 4185), pages on $PAGE_PORT (default 4186). Run from a
logged-in GUI session (over ssh:
`launchctl asuser $(id -u) python3 docs/fixtures/agent-state-tools-e2e.py`).

    ./build.sh && docs/fixtures/agent-state-tools-e2e.py [--app build/Copper.app]
"""
import http.server
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]
app = os.path.abspath(args[args.index("--app") + 1]) if "--app" in args else os.path.join(root, "build/Copper.app")
binary = os.path.join(app, "Contents/MacOS/Copper")
world = f"statetools-{os.getpid()}"
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({world})")
domain = f"com.collinrijock.copper.test.{world}"
mcp_port = int(os.environ.get("MCP_PORT", "4185"))
page_port = int(os.environ.get("PAGE_PORT", "4186"))
site = f"http://127.0.0.1:{page_port}"
tmp = tempfile.mkdtemp(prefix="state-tools-")
log = os.path.join(tmp, "copper.log")
token = os.urandom(16).hex()
proc = None


def store_folder():
    # Store.probeStore(1): FNV-1a of the world's name in the store's identifier.
    h = 2166136261
    for byte in world.encode():
        h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    return os.path.expanduser(f"~/Library/WebKit/com.collinrijock.copper.dev/WebsiteDataStore/"
                              f"5E4C{h >> 16:04X}-{h & 0xFFFF:04X}-4000-8000-000000000001")


def cleanup():
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    plist = os.path.expanduser(f"~/Library/Preferences/{domain}.plist")
    if os.path.exists(plist):
        os.remove(plist)
    shutil.rmtree(folder, ignore_errors=True)
    shutil.rmtree(store_folder(), ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)


def fail(why):
    print(f"FAIL {why}")
    if os.path.exists(log):
        print("".join(open(log, errors="replace").readlines()[-15:]))
    cleanup()
    sys.exit(1)


def expect(cond, why):
    if not cond:
        fail(why)


# --- MCP ------------------------------------------------------------------------
session = None


def call(name, arguments=None, error=False):
    """A tool call; its text. error=True expects isError and returns the text."""
    global session
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments or {}}}).encode()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream", "X-Copper-Agent": "client=state-tools-e2e"}
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(f"http://127.0.0.1:{mcp_port}/mcp", body, headers)
    with urllib.request.urlopen(req, timeout=90) as r:
        session = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode()
    if raw.startswith("event:") or raw.startswith("data:"):
        raw = next(line[5:] for line in raw.splitlines() if line.startswith("data:"))
    result = json.loads(raw)["result"]
    text = "\n".join(c.get("text", "") for c in result["content"] if c["type"] == "text")
    if result.get("isError") != error:
        fail(f"{name} {arguments}: expected {'an error' if error else 'success'}, got: {text[:300]}")
    return text


def ev(js):
    return call("browser_evaluate", {"function": f"() => {js}"})


def until(what, check, seconds=10):
    limit = time.time() + seconds
    while time.time() < limit:
        value = check()
        if value:
            return value
        time.sleep(0.25)
    fail(f"timed out waiting for {what}")


def cli(*words):
    # The CLI is a caller of its own: --tab sends it to the agent's tab, not the user's.
    env = dict(os.environ, SEARCH_PROBE=world, COPPER_AGENT_PORT=str(mcp_port))
    out = subprocess.run([binary, "--cli", "--tab", mine, *words], env=env, capture_output=True, text=True, timeout=90, cwd=tmp)
    return out.returncode, out.stdout + out.stderr


def front():
    """The tab on the user's screen, from the bench."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(os.path.join(folder, "bench.sock"))
        s.sendall(b'{"do":"tabs"}\n')
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            data += chunk
    return next((t["id"] for t in json.loads(data)["tabs"] if t.get("active")), None)


# --- the pages ------------------------------------------------------------------
PAGES = {
    "/home.html": "<!doctype html><title>HC home</title><h1>The user's tab</h1>",
    "/upload.html": """<!doctype html><title>HC upload</title>
<input type=file id=file multiple><select id=pick><option>one</option><option>two</option></select>
<button id=hover onmouseenter="document.title='hovered'">hover me</button>
<script>
window.got = null;
file.addEventListener('change', async () => {
  const f = file.files[0];
  window.got = {names: [...file.files].map(x => x.name), text: f ? await f.text() : null};
});
file.addEventListener('cancel', () => { window.cancelled = true; });
</script>""",
    "/long.html": "<!doctype html><title>HC long page</title>" + "".join(
        f"<p style='height:120px'>Paragraph {i}: the quick brown fox.</p>" for i in range(60)),
    "/dl.html": "<!doctype html><title>HC downloads</title><a id=dl href=/files/hc-report.csv download>report</a>",
    "/net.html": """<!doctype html><title>HC net</title><button id=go>go</button><script>
go.onclick = async () => {
  const a = await fetch('/api/json?from=page'); await a.json();
  await fetch('/api/json', {method: 'POST', body: 'x=1'});
  await fetch('/api/missing');
  window.fetched = 3;
};
</script>""",
    "/cookie.html": "<!doctype html><title>HC cookies</title><p>set</p>",
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, kind="text/html", extra=()):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in PAGES:
            extra = ()
            if path == "/cookie.html":
                extra = (("Set-Cookie", "hc_session=s3cret; Path=/; HttpOnly"), ("Set-Cookie", "hc_plain=visible; Path=/"))
            return self.reply(200, PAGES[path], extra=extra)
        if path == "/files/hc-report.csv":
            return self.reply(200, "a,b\n1,2\n", "text/csv", (("Content-Disposition", "attachment; filename=hc-report.csv"),))
        if path == "/api/json":
            return self.reply(200, '{"answer":42}', "application/json")
        return self.reply(404, "nope", "text/plain")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))
        return self.reply(200, '{"ok":true}', "application/json")


server = http.server.ThreadingHTTPServer(("127.0.0.1", page_port), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

# --- the world: two spaces, the user on a page of their own ----------------------
A, B = "AAAAAAAA-0000-4000-8000-000000000001", "BBBBBBBB-0000-4000-8000-000000000002"
os.makedirs(folder, exist_ok=True)
json.dump({"active": 0, "space": A,
           "spaces": [{"id": A, "name": "Alpha", "hue": 0.1}, {"id": B, "name": "Beta", "hue": 0.6}],
           "tabs": [{"url": f"{site}/home.html", "title": "HC home", "space": A, "saved": True}]},
          open(os.path.join(folder, "session.json"), "w"))
json.dump({"enabled": True, "port": mcp_port, "token": token, "announces": False, "jev": False},
          open(os.path.join(folder, "agent.json"), "w"))
for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("spaces.warm", "-bool", "false")]:
    subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
downloads = os.path.join(folder, "Downloads")  # a test world's own (Preferences.testFolder)

env = dict(os.environ, SEARCH_PROBE=world, SEARCH_HEADLESS="1", SEARCH_MCP_PORT=str(mcp_port))
proc = subprocess.Popen([binary], env=env, stdout=open(log, "w"), stderr=subprocess.STDOUT)


def answering():
    if proc.poll() is not None:
        fail("Copper quit")
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{mcp_port}/health", timeout=2)
        return front() is not None
    except OSError:
        return False


until("Copper's agent server", answering, 40)
user = until("the user's tab", front, 20)

try:
    # 1. Upload ------------------------------------------------------------------
    one = os.path.join(tmp, "hc-upload.txt")
    two = os.path.join(tmp, "hc-second.txt")
    open(one, "w").write("hello upload")
    open(two, "w").write("second file")
    call("browser_tabs", {"action": "new", "url": f"{site}/upload.html"})
    said = call("browser_click", {"selector": "#file", "element": "file input"})
    expect("file chooser" in said, f"the click's answer doesn't mention the chooser: {said[-200:]}")
    said = call("browser_file_upload", {"paths": [one]})
    expect("Uploaded hc-upload.txt" in said, said)
    got = until("the page to read the file", lambda: json.loads(ev("JSON.stringify(window.got)") or "null"))
    expect(got == {"names": ["hc-upload.txt"], "text": "hello upload"}, f"page got {got}")
    expect("No file chooser" in call("browser_file_upload", {}), "cancel with nothing open should say so")
    said = call("browser_file_upload", {"paths": [two, one]})
    expect(said.startswith("Armed"), said)
    call("browser_click", {"selector": "#file", "element": "file input"})
    got = until("the armed files", lambda: (lambda g: g if g and g["names"] == ["hc-second.txt", "hc-upload.txt"] else None)(
        json.loads(ev("JSON.stringify(window.got)") or "null")))
    expect("no such file" in call("browser_file_upload", {"paths": [os.path.join(tmp, "nope.txt")]}, error=True), "missing file not refused")
    expect("absolute" in call("browser_file_upload", {"paths": ["hc-upload.txt"]}, error=True), "relative path not refused")
    call("browser_click", {"selector": "#file", "element": "file input"})
    expect("Cancelled" in call("browser_file_upload", {}), "cancel not answered")
    expect(front() == user, "the user's tab changed")
    print("ok 1 upload: click-then-upload, armed, bad paths refused, cancel")

    # 2. PDF ---------------------------------------------------------------------
    call("browser_navigate", {"url": f"{site}/long.html"})
    pdf = os.path.join(tmp, "hc.pdf")
    said = call("browser_pdf_save", {"filename": pdf})
    pages = int(re.search(r"a (\d+)-page PDF", said).group(1))
    expect(open(pdf, "rb").read(5) == b"%PDF-" and pages >= 2, f"{said}")
    said = call("browser_pdf_save", {})
    expect(downloads in said and os.path.exists(os.path.join(downloads, "HC long page.pdf")), said)
    print(f"ok 2 pdf: {pages} pages, and one into the downloads folder")

    # 3. Downloads ---------------------------------------------------------------
    call("browser_navigate", {"url": f"{site}/dl.html"})
    expect("No downloads" in call("browser_downloads"), "a fresh tab listed downloads")
    call("browser_click", {"selector": "#dl", "element": "report link"})
    said = call("browser_downloads", {"wait": 10})
    m = re.search(r"hc-report.*? — finished, .*? → (\S.*?) \(from", said)
    expect(m and os.path.exists(m.group(1)), f"download not listed as finished with a path: {said}")
    print(f"ok 3 downloads: {m.group(1)}")

    # 4. Network -----------------------------------------------------------------
    call("browser_navigate", {"url": f"{site}/net.html"})
    call("browser_click", {"selector": "#go", "element": "go"})
    until("the fetches", lambda: ev("window.fetched") == "3")
    said = call("browser_network_requests")
    for line in [f"[GET] {site}/api/json?from=page => [200]", f"[POST] {site}/api/json => [200]", f"[GET] {site}/api/missing => [404]"]:
        expect(line in said, f"missing {line!r} in:\n{said}")
    print("ok 4 network: GET 200, POST 200, 404 — " + said.splitlines()[1])

    # 5. Cookies -----------------------------------------------------------------
    call("browser_navigate", {"url": f"{site}/cookie.html"})
    said = call("browser_cookies")
    expect("hc_session=(hidden" in said and "s3cret" not in said and "hc_plain=visible" in said, said)
    call("browser_cookies", {"action": "set", "name": "hc_new", "value": "1"})
    expect("hc_new=1" in ev("document.cookie"), "set cookie not visible to the page")
    expect("not " in call("browser_cookies", {"action": "set", "name": "x", "value": "1", "domain": "evil.test"}, error=True), "foreign domain allowed")
    expect("Agent access" in call("browser_cookies", {"action": "delete", "name": "hc_session"}, error=True), "HttpOnly delete allowed without access")
    expect("Deleted 1" in call("browser_cookies", {"action": "delete", "name": "hc_plain"}), "plain delete")
    subprocess.run(["defaults", "write", domain, "agent.credentials.shareAll", "-bool", "true"], check=True)
    until("the HttpOnly value with access", lambda: "hc_session=s3cret" in call("browser_cookies", {"name": "hc_session"}))
    subprocess.run(["defaults", "write", domain, "agent.credentials.shareAll", "-bool", "false"], check=True)
    print("ok 5 cookies: HttpOnly hidden then shown with access; foreign domain and HttpOnly delete refused")

    # 6. History + bookmarks -----------------------------------------------------
    said = call("browser_history", {"query": "HC long"})
    expect(f"{site}/long.html" in said, said)
    call("browser_navigate", {"url": f"{site}/long.html"})
    expect("Bookmarked" in call("browser_bookmarks", {"action": "add"}), "bookmark add")
    expect("Already" in call("browser_bookmarks", {"action": "add"}), "bookmark added twice")
    expect("HC long page" in call("browser_bookmarks", {"action": "search", "query": "long"}), "bookmark not found")
    print("ok 6 history found; bookmark added once and found")

    # 7. Spaces ------------------------------------------------------------------
    said = call("browser_spaces", {"action": "list"})
    expect("Alpha" in said and "Beta" in said and "holds your tab" in said, said)
    expect("Moved" in call("browser_spaces", {"action": "move", "space": "Beta"}), "move")
    said = call("browser_spaces")
    expect(re.search(r"Beta .*holds your tab", said), said)
    expect("HC long page" in ev("document.title"), "the moved tab stopped answering")
    expect("of your own" in call("browser_spaces", {"action": "move", "space": "Beta", "tab": user[:8]}, error=True), "moved the user's tab")
    expect(front() == user, "the user's tab changed")
    print("ok 7 spaces: listed, own tab moved and still answering, the user's tab refused")

    # 8. CLI verbs ---------------------------------------------------------------
    said = call("browser_navigate", {"url": f"{site}/upload.html"})
    mine = re.search(r"- Tab: ([0-9a-f]{8})", said).group(1)
    code, out = cli("pdf", "cli.pdf")
    expect(code == 0 and os.path.exists(os.path.join(tmp, "cli.pdf")), f"copper pdf: {out}")
    code, out = cli("upload", "hc-upload.txt")  # relative to the shell's folder
    expect(code == 0 and "Armed" in out, f"copper upload: {out}")
    code, out = cli("upload", "--cancel")
    expect(code == 0 and "Disarmed" in out, f"copper upload --cancel: {out}")
    snap = call("browser_snapshot", {"interactive": True})
    ref = re.search(r'combobox[^\n]*\[ref=(e\d+)\]', snap)
    expect(ref, f"no combobox ref in {snap[:300]}")
    code, out = cli("select", ref.group(1), "two")
    expect(code == 0 and ev("document.querySelector('#pick').value") == "two", f"copper select: {out}")
    code, out = cli("hover", "--selector", "#hover")
    expect(code == 0, f"copper hover: {out}")
    for words in [("scroll", "200"), ("wait", "--time", "0.2"), ("downloads",), ("back",), ("forward",)]:
        code, out = cli(*words)
        expect(code == 0, f"copper {' '.join(words)}: {out}")
    print("ok 8 CLI: pdf, upload, select, hover, scroll, wait, downloads, back, forward")
    print("PASS")
finally:
    cleanup()
