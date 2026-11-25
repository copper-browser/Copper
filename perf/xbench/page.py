#!/usr/bin/env python3
"""Writes site/benchmarks/index.html from the measured data, so every number on the page comes from a file:

  site/assets/bench.json         xbench.py report (browsers on one Mac: launch, memory, idle, Speedometer)
  site/assets/agentbench.json    the token run (perf/agentbench/), if it exists
  perf/xbench/polar-2026-11-18/  the Copper vs Polar figures the site may quote (speed, launch, memory)

The page is the subpage template (site/_page-template.html) with its <main> written here; header and footer stay
byte-for-byte the template's. Python stdlib only.

    python3 perf/xbench/page.py            write the page
    python3 perf/xbench/page.py --check    selftest of the formatting helpers
    python3 perf/xbench/page.py --bench B.json --agents A.json --out X.html     a draft from other data
"""
import html
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SITE = os.path.join(ROOT, "site")
sys.path.insert(0, os.path.join(HERE, "polar-2026-11-18"))
import polar  # noqa: E402

REPO = "https://github.com/copper-browser/Copper"
ORDER = ["copper", "safari", "chrome", "ardia", "arc"]
SHORT = {"copper": "Copper", "safari": "Safari", "chrome": "Chrome", "ardia": "Ardia", "arc": "Arc"}
GROUPS = [
    ("launch", "Launch", "From <code>open</code> with the browser closed, as a click on its Dock icon or on a link in another app would start it.",
     ["launch-window", "launch-restore", "launch-link"]),
    ("memory", "Memory", "Everything the browser runs, added up: the app, its helpers, the GPU and network processes and one web process per tab.",
     ["memory-1", "memory-10", "memory-20", "memory-closed"]),
    ("idle", "Idle", "A minute of doing nothing, 30 seconds after the last page loaded; every page runs a one-second timer. With the Mac’s screen locked, Copper and Safari draw nothing here while Chrome and Ardia draw their front tab: read these with <a href=\"#method\">the locked screen</a> in mind.",
     ["idle-cpu-1", "idle-cpu-20", "idle-wakeups-1", "idle-wakeups-20", "idle-power-1", "idle-power-20",
      "idle-cpu-1-steady", "idle-cpu-20-steady", "idle-wakeups-1-steady", "idle-wakeups-20-steady"]),
    ("speed", "Speed", "Speedometer 3.1, Apple, Google and Mozilla’s benchmark of web app responsiveness, served from the same Mac.",
     ["speedometer"]),
]
BETTER = {True: "less is better", False: "more is better"}


def esc(s):
    return html.escape(str(s), quote=True)


def num(v, unit=""):
    if v is None:
        return "–"
    v = float(v)
    text = f"{v:,.0f}" if abs(v) >= 100 else f"{v:.1f}" if abs(v) >= 10 else f"{v:.2f}" if abs(v) >= 1 else f"{v:.2f}"
    if text.endswith(".0") and abs(v) >= 10:
        text = text[:-2]
    return f"{text}{(' ' + unit) if unit and unit not in ('%',) else unit}"


def nbsp(s):
    return s.replace(" ", "&nbsp;")


def day(date):
    import datetime
    d = datetime.date.fromisoformat(date)
    return f"{d.day} {d.strftime('%B')} {d.year}"


def ratio_words(row, copper, best_name, best):
    """How far Copper is from the best on a row it loses, in plain words."""
    a, b = copper["median"], best["median"]
    if not a or not b:
        return ""
    r = (a / b) if row["lowerIsBetter"] else (b / a)
    unit = row["unit"]
    if r >= 10:
        return f"{best_name} {num(b, unit)} against Copper’s {num(a, unit)} ({r:.0f}×)"
    if r >= 1.5:
        return f"{best_name} {num(b, unit)} against Copper’s {num(a, unit)} ({r:.1f}×)"
    return f"{best_name} {num(b, unit)} against Copper’s {num(a, unit)} ({abs(a - b) / b * 100:.0f}%)"


def metric(row, names):
    cells = row["browsers"]
    present = [n for n in ORDER if n in cells]
    top = max(cells[n]["median"] for n in present) or 1
    bars = []
    for n in present:
        c = cells[n]
        cls = ["bar"] + (["us"] if n == "copper" else []) + (["best"] if n == row["best"] else [])
        rng = f"{num(c['min'])}–{num(c['max'])}" if c["n"] > 1 else "one run"
        bars.append(
            f'<li class="{" ".join(cls)}"><span class="who">{esc(names[n])}</span>'
            f'<span class="track"><i style="--v:{c["median"] / top:.4f}"></i></span>'
            f'<b>{nbsp(num(c["median"], row["unit"]))}{"<span class=sr> (best median)</span>" if n == row["best"] else ""}</b>'
            f'<small>{rng}, n={c["n"]}</small></li>')
    missing = [n for n in names if n not in cells]
    note = ""
    if missing:
        note = f'<p class="gap">Not measured: {", ".join(esc(names[n]) for n in missing)} (see <a href="#method">how we measure</a>).</p>'
    return (f'<figure class="metric" id="{esc(row["id"])}"><figcaption><span class="label">{esc(row["label"])}</span>'
            f'<span class="hint">{BETTER[row["lowerIsBetter"]]}</span></figcaption><ul class="bars">{"".join(bars)}</ul>{note}</figure>')


def overlap(a, b):
    return a["min"] <= b["max"] and b["min"] <= a["max"]


def losses(rows, names):
    out = []
    for r in rows:
        c = r["browsers"].get("copper")
        if not c or r["best"] == "copper":
            continue
        best = r["browsers"][r["best"]]
        close = " The ranges overlap, so it’s close." if overlap(c, best) and min(c["n"], best["n"]) > 1 else ""
        out.append(f'<li><a href="#{esc(r["id"])}">{esc(r["label"])}</a>: {esc(ratio_words(r, c, names[r["best"]], best))}.{close}</li>')
    return out


SIDE_NAME = {"copper": "Copper", "ardia": "Ardia", "playwright": "Playwright MCP in Chrome"}


def agent_tables(data):
    """Per agent (and model): its contenders, every task's cells, and totals over the tasks all its contenders
    finished (so the totals compare the same work)."""
    agents = []
    for c in data["contenders"]:
        if (c["agent"], c["model"]) not in agents:
            agents.append((c["agent"], c["model"]))
    out = []
    for agent, model in agents:
        mine = [c for c in data["contenders"] if c["agent"] == agent and c["model"] == model]
        cell = {(x["task"], x["contender"]): x for x in data["cells"] if x.get("runs") and x.get("tokens") is not None}
        common = [t for t in data["tasks"] if all((t["id"], c["id"]) in cell for c in mine)]
        totals = {c["id"]: {"tokens": sum(cell[(t["id"], c["id"])]["tokens"] for t in common),
                            "passes": sum(cell[(t["id"], c["id"])].get("passes", 0) for t in common),
                            "runs": sum(cell[(t["id"], c["id"])]["runs"] for t in common)} for c in mine}
        out.append({"agent": agent, "model": model, "contenders": mine, "cell": cell, "common": common, "totals": totals})
    return out


def agent_losses(data):
    if not data or not data.get("cells"):
        return []
    out = []
    for t in agent_tables(data):
        if not t["common"]:
            continue
        tot = t["totals"]
        copper = next((c for c in t["contenders"] if c["side"] == "copper"), None)
        best = min(t["contenders"], key=lambda c: tot[c["id"]]["tokens"])
        if not copper or best is copper or not tot[best["id"]]["tokens"]:
            continue
        a, b = tot[copper["id"]]["tokens"], tot[best["id"]]["tokens"]
        n = len(t["common"])
        scope = "all eight tasks" if n == len(data["tasks"]) else f"the {n} tasks all three finished"
        out.append(f'<li><a href="#agents">Agent tokens, {esc(t["agent"])}</a>: {esc(SIDE_NAME.get(best["side"], best["side"]))} '
                   f'{b / 1e6:.2f}M against Copper’s {a / 1e6:.2f}M ({a / b:.1f}×) over {scope}.</li>')
    return out


def agents_section(data):
    if not data or not data.get("cells"):
        return ""
    tasks = data["tasks"]
    blocks = []
    for t in agent_tables(data):
        mine, cell, common, totals = t["contenders"], t["cell"], t["common"], t["totals"]
        head = "".join(f'<th scope="col" class="num">{esc(SIDE_NAME.get(c["side"], c["side"]))}</th>' for c in mine)
        body = []
        for task in tasks:
            cells = []
            for c in mine:
                x = cell.get((task["id"], c["id"]))
                if not x:
                    cells.append('<td class="num">–</td>')
                    continue
                secs = f' · {x["time"]:.0f} s' if x.get("time") is not None else ""
                cells.append(f'<td class="num">{x["tokens"] / 1000:,.0f}k<small>{x.get("passes", 0)}/{x["runs"]} passed{secs}</small></td>')
            body.append(f'<tr><th scope="row">{esc(task["title"])}</th>{"".join(cells)}</tr>')
        foot = ""
        if common:
            label = "All tasks" if len(common) == len(tasks) else f"The {len(common)} tasks all three finished"
            best = min(totals[c["id"]]["tokens"] for c in mine)
            tds = "".join(
                f'<td class="num"><b>{totals[c["id"]]["tokens"] / 1e6:.2f}M{"<span class=sr> (fewest)</span>" if totals[c["id"]]["tokens"] == best else ""}</b>'
                f'<small>{totals[c["id"]]["passes"]}/{totals[c["id"]]["runs"]} passed</small></td>' for c in mine)
            foot = f'<tfoot><tr><th scope="row">{label}</th>{tds}</tr></tfoot>'
        blocks.append(
            f'<h3>{esc(t["agent"])} · {esc(t["model"])}</h3><div class="table"><table><thead><tr><th scope="col">Task</th>{head}</tr></thead>'
            f'<tbody>{"".join(body)}</tbody>{foot}</table></div>')
    planned = data.get("planned")
    runs = sum(c.get("runs", 0) for c in data["cells"])
    when = f", {esc(day(data['to']))}" if data.get("to") else ""
    return f"""
  <section class="wrap section" id="agents" aria-labelledby="agents-title">
    <div class="section-head">
      <h2 id="agents-title">Agents: tokens to get the same job done</h2>
      <p>Claude Code and Codex, each driving a browser through its own tools, on the eight local web apps of Ardia’s public agent bench (Apache-2.0). A checker on each app’s server says whether the job got done. Fewer tokens is cheaper and faster for the same agent. Each cell is the median of that task’s runs, with how many passed and the median time; {runs} of {planned} planned runs finished{when}.</p>
    </div>
    {"".join(blocks)}
    <p class="small muted">How each browser was reached: Copper through its built-in MCP server (plain browser tools only; nothing in Copper calls a model), Ardia through its <code>ardia</code> CLI and skill, Chrome through Playwright MCP. The tasks, prompts, checkers and token counts are Ardia’s harness, unchanged. Raw runs and the adapter: <a href="{REPO}/tree/fork/perf/agentbench">perf/agentbench</a>.</p>
  </section>"""


def polar_section():
    speed, launch, memory = polar.figures()
    import statistics
    lc, lp = launch["copper"], launch["polar"]
    return f"""
  <section class="wrap section" id="polar" aria-labelledby="polar-title">
    <div class="section-head">
      <h2 id="polar-title">Copper and Polar, the agent browser</h2>
      <p>An earlier run on the same Mac mini, 18 November 2026: Copper 1.0.20261117.114 against Polar 0.2.12, each handed 28 web tasks twice over MCP and run by its own agent (in Copper, <code>jev_run</code>).</p>
    </div>
    <div class="table"><table>
      <thead><tr><th scope="col"></th><th scope="col" class="num">Copper</th><th scope="col" class="num">Polar</th></tr></thead>
      <tbody>
        <tr><th scope="row">Time per finished task, median</th><td class="num"><b>{speed["copper"] / 1000:.1f} s</b></td><td class="num">{speed["polar"] / 1000:.1f} s</td></tr>
        <tr><th scope="row">Cold launch → first window, median</th><td class="num"><b>{statistics.median(lc) / 1000:.2f} s</b><small>{lc[0] / 1000:.2f}–{lc[-1] / 1000:.2f}, n={len(lc)}</small></td><td class="num">{statistics.median(lp) / 1000:.2f} s<small>{lp[0] / 1000:.1f}–{lp[-1] / 1000:.1f}, n={len(lp)}</small></td></tr>
        <tr><th scope="row">Memory, idle with example.com open</th><td class="num"><b>{statistics.median(memory["copper"]):.0f} MB</b><small>n={len(memory["copper"])}</small></td><td class="num">{statistics.median(memory["polar"]):.0f} MB<small>n={len(memory["polar"])}</small></td></tr>
      </tbody>
    </table></div>
    <p class="small muted">Polar plans with a frontier model; Copper’s agent is a small, fast one, so this is a speed comparison, not a like-for-like of the models. Rows and the script that recomputes them: <a href="{REPO}/tree/fork/perf/xbench/polar-2026-11-18">perf/xbench/polar-2026-11-18</a>.</p>
  </section>"""


def method_section(bench, names):
    m = bench["machine"]
    b = bench["browsers"]
    ver = ", ".join(f"{esc(b[n]['name'])} {esc(b[n]['version'])}" for n in ORDER if n in b and n in names)
    rows = {r["id"]: r for r in bench["rows"]}
    cond = bench.get("conditions", {})
    load = f" Median load average as the measurements started: {cond['load1Median']}." if cond.get("load1Median") is not None else ""
    quiet, total = cond.get("quiet"), cond.get("samples")
    if quiet is not None and total and quiet < total:
        wait = (f"Other jobs share it. {quiet} of the {total} runs ran in rounds that held the Mac’s lock (no other job "
                f"running) and began with the load average under 2; the other {total - quiet} ran while it was busy.")
    else:
        wait = ("Other jobs share it, so each round took the Mac’s lock (no other job running) for its whole length "
                "and began once the load average was under 2.")
    seen = visible_words(rows)
    return f"""
  <section class="wrap section" id="method" aria-labelledby="method-title">
    <div class="prose">
      <h2 id="method-title">How we measure</h2>
      <h3>The Mac</h3>
      <p>{esc(m["model"])}, {esc(m["chip"])}, {esc(m["ram"])}, macOS {esc(m["macOS"])}, {esc(span_words(bench))}. Nobody sits at it, so its screen is locked. {esc(wait)}{esc(load)}</p>
      <h3>The browsers</h3>
      <p>{ver}. Each as shipped, with default settings, in a profile of its own that starts from the same template (one launch, our test page opened, a minute to settle, quit), so every launch restores the same one tab.</p>
      <ul>
        <li><strong>Copper</strong> runs in a test world of its own: the same app, with its own data folder, told to behave exactly as shipped (hidden pages slowed down, App Nap left to macOS).</li>
        <li><strong>Safari</strong> can’t run from a copy or in a profile of its own, and this Mac’s Safari profile belongs to its owner. So it only gets the launch to a window (its Start Page, no address), and its memory and idle runs happen in a WebDriver session, Safari’s own private window set.</li>
        <li><strong>Chrome</strong> runs from Google’s download with its own profile folder and its DevTools port open (that’s how tabs are opened and closed), restoring its last session like the others.</li>
        <li><strong>Ardia</strong> runs from its release download with its own data folder, onboarding marked done and its DevTools port open, not in the background test mode Ardia’s own benchmark gives it.</li>
        <li><strong>Arc</strong> isn’t here: it wants an Arc account at first launch, and nobody can sign in on a Mac nobody sits at.</li>
      </ul>
      <h3>The locked screen</h3>
      <p>With the screen locked, macOS calls every window hidden. WebKit then stops drawing pages, so Copper’s and Safari’s pages draw nothing during the idle minutes, while Chrome and Ardia keep drawing the tab in front. That tilts the idle rows toward Copper and Safari by one page’s drawing.{seen} Speedometer needs a page that draws, so Copper runs it headless (its pages ignore the lock there) and Safari has no score.</p>
      <h3>The runs</h3>
      <p>One harness drives every browser from outside the app, on the same local test page (60 boxes, 120 paragraphs, a one-second timer). Browsers take turns item by item, in an order that rotates each round, so nobody always goes first. A window counts once one at least 300×200 is on screen; a page counts at its first contentful paint, which the page reports itself. Memory is phys_footprint summed over every process the browser runs or macOS holds it responsible for; CPU, wakeups and energy are the kernel’s own per-process counters over the same processes. Each figure is the median of the runs, with the range and the count.</p>
      <h3>Not measured here</h3>
      <p>New tab, tab switch and new window need a driver inside each browser, and every browser has a different one; the clicks a person would make need an unlocked screen, and so does power while scrolling or playing video.</p>
      <p>The data: <a href="../assets/bench.json">bench.json</a>, every run in <a href="{REPO}/tree/fork/perf/xbench/results">perf/xbench/results</a>, the harness and its method in <a href="{REPO}/tree/fork/perf/xbench">perf/xbench</a>.</p>
    </div>
  </section>"""


def visible_words(rows):
    """Copper’s 1-tab idle with its page drawing (headless), next to the hidden one: the size of the tilt."""
    hid, vis = rows.get("idle-cpu-1", {}).get("browsers", {}).get("copper"), rows.get("idle-cpu-1-visible", {}).get("browsers", {}).get("copper")
    if not hid or not vis:
        return ""
    wv = rows.get("idle-wakeups-1-visible", {}).get("browsers", {}).get("copper")
    wh = rows.get("idle-wakeups-1", {}).get("browsers", {}).get("copper")
    wake = f", {num(wv['median'], '/s')} wakeups against {num(wh['median'], '/s')}" if wv and wh else ""
    return (f" Kept drawing (headless, which ignores the lock), Copper idles at {num(vis['median'], '%')} CPU with one tab "
            f"against {num(hid['median'], '%')} with it hidden{wake} (n={vis['n']}).")


def span_words(bench):
    a, b = bench["span"]
    return f"measured {day(a)}" if a == b else f"measured {day(a)} to {day(b)}"


def main_html(bench, agents):
    names = {n: SHORT[n] for n in ORDER if n in bench["browsers"]}
    rows = {r["id"]: r for r in bench["rows"]}
    groups = []
    for gid, title, sub, ids in GROUPS:
        figs = [metric(rows[i], names) for i in ids if i in rows]
        if figs:
            groups.append(f"""
  <section class="wrap section" id="{gid}" aria-labelledby="{gid}-title">
    <div class="section-head"><h2 id="{gid}-title">{title}</h2><p>{sub}</p></div>
    <div class="metrics">{"".join(figs)}</div>
  </section>""")
    lost = losses(bench["rows"], names) + agent_losses(agents)
    lost_html = ""
    if lost:
        lost_html = f"""
  <section class="wrap section" id="losses" aria-labelledby="losses-title">
    <div class="prose">
      <h2 id="losses-title">Where Copper loses</h2>
      <p>Where another browser beats Copper’s median. These stay on the page.</p>
      <ul>{"".join(lost)}</ul>
    </div>
  </section>"""
    agents_lead = ", and the tokens AI agents spend getting the same jobs done in each" if agents and agents.get("cells") else ""
    b = bench["browsers"]
    versions = " · ".join(f"{esc(b[n]['name'])} {esc(b[n]['version'])}" for n in ORDER if n in names)
    m = bench["machine"]
    return f"""<main id="main">
  <div class="wrap page-head">
    <span class="kicker">Benchmarks</span>
    <h1>Copper, timed against the browsers you’d use instead.</h1>
    <p class="lead">Copper, Safari, Chrome and Ardia on the same Mac mini, launched and loaded by one harness that reads every browser from the outside{agents_lead}. Every figure is a median with its range and run count, and the rows Copper loses stay on the page.</p>
    <p class="facts small muted">{esc(m["model"])} · {esc(m["chip"])} · {esc(m["ram"])} · macOS {esc(m["macOS"])}<br>{versions}<br>{esc(span_words(bench)[0].upper() + span_words(bench)[1:])}. <span aria-hidden="true">★</span> marks each row’s best median; overlapping ranges mean it’s close.</p>
  </div>{"".join(groups)}{lost_html}{agents_section(agents)}{polar_section()}{method_section(bench, names)}
</main>"""


STYLE = """<style>
  .facts { margin-top: 18px; line-height: 1.7; }
  .metrics { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 330px), 1fr)); gap: 16px; margin-top: 24px; }
  .metric { margin: 0; padding: 20px 20px 16px; border-radius: var(--r-l); background: var(--surface); border: 1px solid var(--line); }
  .metric figcaption { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 2px 12px; margin-bottom: 12px; }
  .metric .label { font: 600 16px/1.3 var(--display); }
  .metric .hint { font-size: 13px; color: var(--ink-2); }
  .bars { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
  .bar { display: grid; grid-template-columns: 4.6em minmax(0, 1fr) auto; grid-template-areas: "who track value" "who track range"; column-gap: 10px; align-items: center; font-size: 14.5px; color: var(--ink-2); }
  .bar .who { grid-area: who; }
  .bar .track { grid-area: track; height: 10px; }
  .bar i { display: block; height: 10px; width: calc(var(--v) * 100%); min-width: 6px; border-radius: 999px; background: var(--line-2); }
  .bar b { grid-area: value; text-align: right; font-weight: 600; font-variant-numeric: tabular-nums; color: var(--ink); }
  .bar small { grid-area: range; text-align: right; font-size: 12px; font-variant-numeric: tabular-nums; }
  .bar.us { color: var(--ink); font-weight: 600; }
  .bar.us i { background: var(--accent); }
  .bar.best b::after { content: " ★" / ""; color: var(--patina); font-size: .85em; }
  .gap { margin-top: 10px; font-size: 13px; color: var(--ink-2); }
  .gap a, .section small a { color: var(--ink); text-underline-offset: 3px; }
  #agents h3 { margin-top: 28px; font: 600 1.1rem/1.3 var(--display); }
  #agents .table, #polar .table { margin-top: 12px; }
  td small { display: block; font-size: 12px; color: var(--ink-2); }
  tfoot th, tfoot td { border-bottom: 0; }
  .section > .small { margin-top: 14px; max-width: 46rem; }
  @media (max-width: 480px) { .bar { grid-template-columns: 4.2em minmax(0, 1fr) auto; font-size: 14px; } }
</style>"""


def jsonld(bench, agents=None):
    d = {
        "@context": "https://schema.org", "@type": "Dataset",
        "name": "Mac browser benchmarks: Copper vs Safari, Chrome and Ardia",
        "description": "Cold launch, memory with 1 to 20 tabs, idle CPU, wakeups and power, and Speedometer 3.1, measured on one Mac mini; medians with range and run count.",
        "url": "https://copper.exowatt.com/benchmarks/", "dateModified": bench["date"], "isAccessibleForFree": True,
        "license": "https://opensource.org/licenses/MIT",
        "creator": {"@type": "Organization", "name": "Copper", "url": "https://copper.exowatt.com/"},
        "distribution": {"@type": "DataDownload", "encodingFormat": "application/json", "contentUrl": "https://copper.exowatt.com/assets/bench.json"},
        "variableMeasured": [r["label"] for r in bench["rows"]],
    }
    if agents and agents.get("cells"):
        d["description"] += " Also the tokens Claude Code and Codex spend driving Copper, Ardia and Playwright MCP through eight agent tasks."
        d["distribution"] = [d["distribution"], {"@type": "DataDownload", "encodingFormat": "application/json",
                                                 "contentUrl": "https://copper.exowatt.com/assets/agentbench.json"}]
        d["variableMeasured"].append("Agent tokens per task (median of runs)")
    return d


def render(bench, agents, template):
    title = "Mac browser benchmarks: Copper vs Safari, Chrome and Ardia"
    desc = ("Copper, Safari, Chrome and Ardia on one Mac mini: cold launch, memory with 1 to 20 tabs, idle CPU and power, "
            "Speedometer 3. Medians, losses left in.")
    page = template.split("-->", 1)[1].lstrip("\n") if template.startswith("<!doctype html>\n<!--") else template
    if not page.startswith("<!doctype html>"):
        page = "<!doctype html>\n" + page
    page = page.replace("{{TITLE}}", esc(title)).replace("{{DESCRIPTION}}", esc(desc)).replace("{{PATH}}", "benchmarks/")
    head_link = '<li><a href="../benchmarks/">Benchmarks</a></li>'
    header_end = page.index("</header>")
    at = page.index(head_link)
    assert at < header_end, "the Benchmarks link belongs to the header"
    page = page[:at] + '<li><a href="../benchmarks/" aria-current="page">Benchmarks</a></li>' + page[at + len(head_link):]
    ld = json.dumps(jsonld(bench, agents), ensure_ascii=False).replace("</", "<\\/")
    page = page.replace("</head>", f'{STYLE}\n<script type="application/ld+json">{ld}</script>\n</head>', 1)
    start, end = page.index('<main id="main">'), page.index("</main>") + len("</main>")
    return page[:start] + main_html(bench, agents) + page[end:]


def selftest():
    assert num(734.4, "MB") == "734 MB" and num(0.254, "%") == "0.25%" and num(12.34, "/s") == "12.3 /s"
    assert num(2.5, "ms") == "2.50 ms" and num(None) == "–"
    row = {"lowerIsBetter": True, "unit": "MB"}
    assert ratio_words(row, {"median": 300}, "Chrome", {"median": 100}) == "Chrome 100 MB against Copper’s 300 MB (3.0×)"
    assert ratio_words(row, {"median": 110}, "Chrome", {"median": 100}) == "Chrome 100 MB against Copper’s 110 MB (10%)"
    print("page selftest ok")


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    if "--check" in sys.argv:
        return selftest()
    bench = json.load(open(arg("--bench", os.path.join(SITE, "assets/bench.json"))))
    agents_file = arg("--agents", os.path.join(SITE, "assets/agentbench.json"))
    agents = json.load(open(agents_file)) if os.path.exists(agents_file) else None
    template = open(os.path.join(SITE, "_page-template.html")).read()
    out = arg("--out", os.path.join(SITE, "benchmarks/index.html"))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write(render(bench, agents, template))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
