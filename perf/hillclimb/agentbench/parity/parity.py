#!/usr/bin/env python3
"""Golden-request parity: the same DOM through upstream's snapshot.js + choose() and through Copper's
observe + choose; diff the two TypeSafe request bodies, step by step.

No Chrome: upstream's snapshot.js is evaluated inside the Copper tab (its `__jevFast` cache renamed so it
cannot touch Copper's), and upstream's own model.choose() builds the body with its POST captured. Copper's
body is what the probe really sent: its world's jevEndpoint points at the recorder here, which forwards
to TypeSafe and keeps both sides. Each upstream body is also sent to TypeSafe, so the two answers
(operation probabilities) sit side by side.

    AGENTBENCH_JEV_ENDPOINT=http://127.0.0.1:4192/v1/systemone agentbench.sh up <Copper.app>   # probe via the recorder
    parity.py --port 4190 --world hcjev --url http://127.0.0.1:4191/fixture.html?scenario=travel \
        --goal "…" --upstream ~/hc/jev-ultrafast-src --strategy classic --vision off --out DIR [--steps 6]

Standard library only, Python 3.9. Exit 1 when a body differs outside the ALLOWED paths.
"""
import argparse, importlib, json, os, sys, threading, time, types, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from agentbench import Copper  # noqa: E402

REAL = "https://api.typesafe.ai/v1/systemone"
captured = []


class Recorder(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        req = urllib.request.Request(REAL, data=raw, method="POST", headers={
            "Authorization": self.headers.get("Authorization", ""), "Content-Type": "application/json",
            **({"TypeSafe-Danger-Zone-Images": "true"} if self.headers.get("TypeSafe-Danger-Zone-Images") else {})})
        began = time.time()
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                status, out = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, out = e.code, e.read()
        captured.append({"body": json.loads(raw), "status": status, "ms": round((time.time() - began) * 1000),
                         "answer": json.loads(out) if status == 200 else out.decode(errors="replace")[:300],
                         "key": self.headers.get("Authorization", "")})
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def upstream_model(root):
    """upstream's model.py, imported without its package __init__ (which pulls in the Chrome harness)."""
    sys.modules.setdefault("httpx", types.SimpleNamespace(Client=lambda **k: None, HTTPError=Exception))
    pkg = types.ModuleType("jev_ultrafast")
    pkg.__path__ = [os.path.join(root, "jev_ultrafast")]
    sys.modules["jev_ultrafast"] = pkg
    return importlib.import_module("jev_ultrafast.model")


def upstream_body(model, state, goal, history):
    box = {}

    def grab(url, key, body):
        box["body"] = body
        raise RuntimeError("captured")
    model.post_json = grab
    os.environ.setdefault("TYPESAFE_API_KEY", "unused")
    try:
        model.choose(state, goal, history)
    except RuntimeError:
        pass
    return box["body"]


def diff(a, b, path=""):
    """Paths where two JSON values differ: (path, copper, upstream)."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}" if path else k
            if k not in a: out.append((p, "<absent>", b[k]))
            elif k not in b: out.append((p, a[k], "<absent>"))
            else: out += diff(a[k], b[k], p)
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in diff(x, y, f"{path}[{i}]")]
    return [] if a == b else [(path, a, b)]


def short(v, n=110):
    s = json.dumps(v, ensure_ascii=False) if not isinstance(v, str) else v
    return s if len(s) <= n else s[:n] + f"… ({len(s)} chars)"


def ops(answer):
    a = (answer or {}).get("answers", {}) if isinstance(answer, dict) else {}
    op = a.get("operation", {})
    probs = sorted((op.get("probabilities") or {}).items(), key=lambda kv: -kv[1])
    head = a.get((op.get("choice") or "").lower() + "_target", {})
    return op.get("choice"), [(k, round(v, 3)) for k, v in probs[:4]], head.get("choice"), round((head.get("probabilities") or {}).get(head.get("choice"), 0), 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--world", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--goal", required=True)
    ap.add_argument("--upstream", required=True, help="a checkout of browser-use/jev-ultrafast (source only)")
    ap.add_argument("--strategy", default="classic")
    ap.add_argument("--vision", default="off")
    ap.add_argument("--model", default="")
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--recorder-port", type=int, default=4192)
    ap.add_argument("--allow", default="model", help="comma list of body paths allowed to differ")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", a.recorder_port), Recorder)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    model = upstream_model(a.upstream)
    snapshot = open(os.path.join(a.upstream, "jev_ultrafast", "snapshot.js")).read().replace("__jevFast", "__jevUpstream")
    read = "() => (" + snapshot.strip().rstrip(";") + ")"
    copper = Copper(a.world, a.port)
    copper.call("browser_tabs", {"action": "new", "url": a.url})
    time.sleep(1.5)
    allowed = set(a.allow.split(","))
    report, bad = [f"# Parity — strategy {a.strategy}, vision {a.vision}", "", f"Goal: {a.goal}", ""], 0
    try:
        for n in range(1, a.steps + 1):
            state = json.loads(copper.call("browser_evaluate", {"function": read}))
            before = len(captured)
            args = {"goal": a.goal, "strategy": a.strategy, "vision": a.vision}
            if a.model: args["model"] = a.model
            try:
                said = copper.call("jev_step", args)
            except RuntimeError as e:
                said = f"error: {e}"
            mine = captured[before:]
            if not mine:
                report.append(f"## Step {n}: Copper sent nothing ({said[:120]})"); break
            c = mine[0]
            u_body = upstream_body(model, state, a.goal, c["body"]["state"].get("recent_actions", []))
            req = urllib.request.Request(REAL, data=json.dumps(u_body).encode(), method="POST",
                                         headers={"Authorization": c["key"], "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=40) as r:
                u_answer = json.load(r)
            d = [x for x in diff(c["body"], u_body) if x[0] not in allowed]
            bad += len(d)
            with open(os.path.join(a.out, f"{a.strategy}-step{n}.json"), "w") as fh:
                json.dump({"copper": c["body"], "upstream": u_body, "copper_answer": c["answer"], "upstream_answer": u_answer}, fh, indent=1, ensure_ascii=False)
            step_line = next((l for l in said.splitlines() if l[:1].isdigit() or l.startswith("### Run ended")), said.splitlines()[0] if said else "")
            report += [f"## Step {n} — {len(d)} differing path(s), {len(mine)} Copper request(s)", "",
                       f"- Copper did: `{step_line[:140]}`",
                       f"- Jev on Copper's body:   {ops(c['answer'])} · {c['answer'].get('usage', {}).get('input_tokens') if isinstance(c['answer'], dict) else '?'} tok",
                       f"- Jev on upstream's body: {ops(u_answer)} · {u_answer.get('usage', {}).get('input_tokens')} tok", ""]
            report += [f"- `{p}`: copper {short(x)} | upstream {short(y)}" for p, x, y in d[:40]] + [""]
            if "Run ended" in said or said.startswith("error"):
                break
    finally:
        try: copper.call("browser_close", {}, timeout=20)
        except Exception: pass
    report.append(f"Total differing paths outside {sorted(allowed)}: {bad}")
    text = "\n".join(report) + "\n"
    with open(os.path.join(a.out, f"{a.strategy}.md"), "w") as fh:
        fh.write(text)
    print(text)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
