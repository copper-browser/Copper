#!/usr/bin/env python3
"""canvas-easel bench: an easel board (SVG-card collage) on a PROBE Copper.

    bench.py apply NAME [BOARD]      create canvas NAME from board.json.gz (or BOARD); prints its id
    bench.py measure ID VIEW [N]     open ID in front, focus VIEW (section | overview), N runs of
                                     ../canvas-big/measure.js; prints JSON (runs + medians)

Uses the probe's CLI like canvas-big (`$COPPER_BIN call|eval`), so set SEARCH_PROBE,
SEARCH_MCP_PORT (never 4123) and COPPER_BIN first.
"""
import gzip, json, os, statistics, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'canvas-big'))
import drive  # noqa: E402  (call / run / parse, argv chunking)

VIEWS = {'section': ['lm-sec-build'], 'overview': ['lm-frame']}


def guard():
    port = os.environ.get('SEARCH_MCP_PORT', '')
    if not os.environ.get('SEARCH_PROBE') or port in ('', '4123'):
        sys.exit('bench: set SEARCH_PROBE and a SEARCH_MCP_PORT other than 4123 (probe worlds only)')


def ok(rc_out):
    rc, out, err, _ = rc_out
    if rc != 0:
        sys.exit(f'bench: {err.strip() or out.strip()}')
    return drive.parse(out)


def apply(name, board=None):
    path = board or os.path.join(HERE, 'board.json.gz')
    ops = json.load(gzip.open(path) if path.endswith('.gz') else open(path))
    c = ok(drive.call('canvas_create', {'name': name}))
    cid = c['id'] if isinstance(c, dict) else json.loads(c)['id']
    t = time.time()
    batch, size = [], 0
    def flush():
        nonlocal batch, size
        if batch:
            r = ok(drive.call('canvas_apply', {'id': cid}, ops=batch))
            errs = (r or {}).get('errors') if isinstance(r, dict) else None
            if errs:
                sys.exit(f'bench: apply errors {errs[:3]}')
        batch, size = [], 0
    for op in ops:
        n = len(json.dumps(op))
        if batch and (size + n > 550_000 or len(batch) >= 40):
            flush()
        batch.append(op); size += n
    flush()
    print(json.dumps({'id': cid, 'ops': len(ops), 'applySeconds': round(time.time() - t, 2)}))


def measure(cid, view, n):
    ok(drive.call('canvas_open', {'id': cid, 'foreground': True}))
    time.sleep(1.5)
    ok(drive.call('canvas_focus', {'id': cid, 'shapeIds': VIEWS[view]}))
    time.sleep(15)
    js = open(os.path.join(HERE, '..', 'canvas-big', 'measure.js')).read()
    runs = []
    for _ in range(n):
        drive.run([drive.copper(), 'eval', js])
        time.sleep(6.8)
        for _ in range(10):
            rc, out, err, _ = drive.run([drive.copper(), 'eval', js])
            r = drive.parse(out)
            if isinstance(r, dict) and r.get('state') == 'done':
                runs.append(r); break
            time.sleep(0.5)
        time.sleep(2)
    keys = ['fps', 'p50', 'p95', 'p99', 'max', 'over33', 'over100']
    med = {k: statistics.median([r['run'][k] for r in runs]) for k in keys} if runs else {}
    b = runs[0]['before'] if runs else {}
    phases = {}
    for ph in ('pan', 'zoom'):
        rs = [r['run'].get('phases', {}).get(ph) for r in runs]
        rs = [x for x in rs if x]
        if rs:
            phases[ph] = {k: statistics.median([x[k] for x in rs]) for k in ('p50', 'p95', 'max', 'over33')}
    print(json.dumps({'view': view, 'z': (b.get('view') or {}).get('z'), 'mounted': b.get('mountedShapes'),
                      'images': b.get('images'), 'imagePixelsMP': b.get('imagePixelsMP'), 'median': med,
                      'phases': phases, 'runs': [r['run'] for r in runs]}))


if __name__ == '__main__':
    guard()
    if sys.argv[1] == 'apply':
        apply(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif sys.argv[1] == 'measure':
        measure(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 3)
    else:
        sys.exit(__doc__)
