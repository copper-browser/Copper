#!/usr/bin/env python3
"""The local page a launch restores: 64 KB of HTML, a 134 KB stylesheet and a
275 KB script, so a launch measures the browser and not a site's servers."""
import os, random
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")
os.makedirs(here, exist_ok=True)
random.seed(7)
css = "\n".join(f".c{i}{{color:#{random.randrange(0xffffff):06x};padding:{i%9}px;margin:{i%5}px}}" for i in range(3000))
js = "window.__items=[];\n" + "\n".join(f"function f{i}(x){{return x*{i}+{i%7}}}; window.__items.push(f{i}({i}));" for i in range(4000))
rows = "\n".join(f'<div class="c{i%3000}"><h3>Row {i}</h3><p>Lorem ipsum dolor sit amet {i}, consectetur adipiscing elit.</p></div>' for i in range(600))
open(os.path.join(here, "style.css"), "w").write(css)
open(os.path.join(here, "app.js"), "w").write(js)
open(os.path.join(here, "index.html"), "w").write(f'''<!doctype html><html><head><meta charset="utf-8"><title>Perf page</title>
<link rel="stylesheet" href="style.css"><script src="app.js"></script></head>
<body><h1>Copper perf page</h1>{rows}</body></html>''')
