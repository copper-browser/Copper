#!/usr/bin/env python3
"""The question set Copper sends Jev for a page, for a goal of our own: what a
crawled page (perf/crawl.py, jev_dump) is asked to label for mini-Jev.

    perf/questions.py DUMP.json [--goal "..."] [--out body.json]

One goal per page from TEMPLATES (a bank the eval goals never use), picked
from what the page offers and seeded by the page. Out comes the body Copper
would POST ({model, state, questions}):
  - Copper's own `operation` and `<op>_target` heads (jev_dump built them with
    Copper's code; only the goal is swapped in), and `value_N` per quoted value;
  - six nouls in the style of Copper's `unmet`: unwanted_modal, consent_wall,
    login_wall, bot_check, done, unmet.
When the dump was made with this goal as its goal_hint, Copper's part is
checked against what Copper built, key for key (`parity: ok`).
"""
import argparse
import copy
import hashlib
import json
import os
import re
import sys

# Not agentbench's goals (Wikipedia game, Flights, fbpub questions, uibench forms).
TEMPLATES = [
    ("search", "TYPE_TEXT", 'Look up "{term}" with this site\'s own search box and show the matching results.'),
    ("search_open", "TYPE_TEXT", 'Use the search field to find "{term}", then open whichever result fits it best.'),
    ("field", "TYPE_TEXT", 'Put "{value}" into the {field} box and send the form.'),
    ("open", "CLICK", 'Go to the page behind "{link}".'),
    ("open_read", "CLICK", 'Open "{link}" and stay there once its content is showing.'),
    ("select", "SELECT", 'Change the {field} dropdown to "{option}".'),
    ("contact", "CLICK", "Get to this site's contact or support page."),
    ("about", "CLICK", "Find out who runs this site: open its about page."),
    ("cookies", None, "Dismiss whatever is covering the page so its main content can be read."),
]
SAMPLE_TERMS = ["gift card", "return policy", "opening hours", "pricing", "careers", "shipping", "accessibility", "privacy"]
SAMPLE_VALUES = {"email": "sam.rivera@example.org", "name": "Sam Rivera", "zip": "33101", "phone": "305 555 0142"}

NOULS = {
    "unwanted_modal": "A dialog, popup, banner or overlay the goal did not ask for is open over the page and has to be closed "
                      "before the goal can go on: for example a newsletter signup, an app promo, a chat window or a survey.",
    "consent_wall": "The page asks the user to accept, reject or manage cookies or tracking, in a banner or a dialog, "
                    "and that choice is still open.",
    "login_wall": "The page asks the user to sign in, log in or create an account before it shows or does what the goal needs.",
    "bot_check": "The page is a human or bot check instead of the site's content: for example a CAPTCHA, a \"verify you are "
                 "human\" step, a security challenge or an access-denied page.",
    "done": "Every requirement of the goal is visibly satisfied on the current page: what the goal asks for is shown or was "
            "applied, not only reachable from here.",
}


def literals(goal):
    """The quoted values (the templates put every value in double quotes)."""
    return list(dict.fromkeys(m for m in re.findall(r'"([^"]+)"', goal) if m.strip()))


def heads(questions):
    return {k: v for k, v in questions.items() if k == "operation" or k.endswith("_target")}


def pick_goal(dump, seed):
    """One plausible goal for this page from TEMPLATES, chosen by the page's seed."""
    state, q = dump["state"], dump["questions"]
    ops = set((q.get("operation") or {}).get("criteria", {}))
    els = state["elements"]
    def labelled(op):
        return [e for e in els if op in e.get("operations", []) and 2 < len(e.get("label", "")) <= 60]
    fields = labelled("TYPE_TEXT")
    search = [e for e in fields if re.search(r"search|find|query|look", e["label"], re.I) or e.get("role") == "searchbox"]
    links = [e for e in labelled("CLICK") if e.get("role") in ("link", "button", "tab", "menuitem") and "TYPE_TEXT" not in e["operations"]
             and not re.search(r"cookie|accept|reject|sign|log ?in|menu|close|skip", e["label"], re.I)]
    selects = [e for e in els if "SELECT" in e.get("operations", []) and e.get("options")]
    words = " ".join(e.get("label", "") for e in els).lower()
    fits = []
    for name, op, text in TEMPLATES:
        if op and op not in ops:
            continue
        if name.startswith("search") and not search:
            continue
        if name == "field" and not [f for f in fields if f not in search]:
            continue
        if name.startswith("open") and not links:
            continue
        if name == "select" and not selects:
            continue
        if name == "contact" and not re.search(r"contact|support|help", words):
            continue
        if name == "about" and not re.search(r"\babout\b", words):
            continue
        if name == "cookies" and not re.search(r"cookie|consent|accept", (state["page"]["text"] + words).lower()):
            continue
        fits.append((name, text))
    if not fits:
        fits = [("contact", TEMPLATES[6][2])]
    r = int(seed, 16)
    name, text = fits[r % len(fits)]
    if name.startswith("search"):
        return name, text.format(term=SAMPLE_TERMS[r // 7 % len(SAMPLE_TERMS)])
    if name == "field":
        f = [f for f in fields if f not in search][r // 7 % len([f for f in fields if f not in search])]
        kind = next((k for k in SAMPLE_VALUES if k in f["label"].lower()), "name")
        return name, text.format(value=SAMPLE_VALUES[kind], field=f["label"].strip().lower())
    if name.startswith("open"):
        return name, text.format(link=links[r // 7 % len(links)]["label"].strip().replace('"', "'"))
    if name == "select":
        s = selects[r // 7 % len(selects)]
        option = s["options"][r // 11 % len(s["options"])]["label"].split(" → ")[-1].replace('"', "'")
        return name, text.format(field=s["label"].strip().lower(), option=option)
    return name, text


def build(dump, goal):
    q = copy.deepcopy(heads(dump["questions"]))
    for question in q.values():
        question["instructions"]["goal"] = goal
    criteria = dump["copper"].get("value_criteria")
    if criteria:
        for i, value in enumerate(literals(goal), 1):
            q[f"value_{i}"] = {"type": "choice", "criteria": copy.deepcopy(criteria),
                               "instructions": {"goal": goal, "value": value, "rules": dump["copper"]["value_rule"]}}
    copper_part = copy.deepcopy(q)
    statements = dict(NOULS, unmet=dump["copper"]["unmet_statement"])
    for name, statement in statements.items():
        q[name] = {"type": "noul", "instructions": {"goal": goal, "statement": statement}}
    return q, copper_part


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump")
    ap.add_argument("--goal")
    ap.add_argument("--out")
    a = ap.parse_args()
    with open(os.path.expanduser(a.dump)) as f:
        dump = json.load(f)
    seed = hashlib.sha1(dump["state"]["page"]["url"].encode()).hexdigest()
    template, goal = ("given", a.goal) if a.goal else pick_goal(dump, seed)
    questions, copper_part = build(dump, goal)
    body = {"model": dump.get("model") or "jev-1.14.0", "state": dump["state"], "questions": questions}
    out = {"goal": goal, "template": template, "url": dump["state"]["page"]["url"], "body": body}
    if dump.get("goal_hint") == goal:
        theirs = {k: v for k, v in dump["questions"].items() if k != "unmet"}
        out["parity"] = "ok" if theirs == copper_part else "MISMATCH"
        if theirs != copper_part:
            print("parity MISMATCH: " + ", ".join(sorted(set(theirs) ^ set(copper_part)) or
                  [k for k in theirs if theirs[k] != copper_part.get(k)]), file=sys.stderr)
    text = json.dumps(out, indent=1, ensure_ascii=False)
    if a.out:
        with open(os.path.expanduser(a.out), "w") as f:
            f.write(text)
    print(json.dumps({"goal": goal, "template": template, "questions": sorted(questions), "parity": out.get("parity")}))
    sys.exit(1 if out.get("parity") == "MISMATCH" else 0)


if __name__ == "__main__":
    main()
