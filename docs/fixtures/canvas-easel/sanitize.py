#!/usr/bin/env python3
"""Turn an easel board's canvas ops into a shareable bench fixture.

Every `<text>` run inside the board's SVG cards, and every frame/text title,
becomes placeholder words of the same length, so the fixture renders like the
real board (same cards, same sizes, same filters, patterns and embedded
pictures) without carrying anyone's notes. Pictures (public-domain paintings
from the Art Institute of Chicago) are kept as they are.

    python3 sanitize.py ops.json > board.json   # then gzip
"""
import base64, json, re, sys, urllib.parse

WORDS = ('lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et '
         'dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea '
         'commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur').split()

def filler(text, seed=[0]):
    out = []
    n = 0
    while n < len(text):
        w = WORDS[seed[0] % len(WORDS)]
        seed[0] += 1
        out.append(w)
        n += len(w) + 1
    s = ' '.join(out)[: len(text)]
    return s.upper() if text.isupper() else (s[:1].upper() + s[1:] if text[:1].isupper() else s)

def scrub_svg(svg):
    # text nodes between tags inside <text>/<tspan>; leave attributes, styles, data URLs alone
    def repl(m):
        inner = m.group(2)
        if not inner.strip() or inner.lstrip().startswith('<'):
            return m.group(0)
        return m.group(1) + filler(inner) + m.group(3)
    return re.sub(r'(<(?:text|tspan)\b[^>]*>)([^<]+)(</(?:text|tspan)>)', repl, svg)

def main(path):
    ops = json.load(open(path))
    for op in ops:
        s = op.get('shape', {})
        for k in ('title', 'text', 'label'):
            if isinstance(s.get(k), str) and s[k].strip():
                s[k] = filler(s[k])
        src = s.get('src') or ''
        if src.startswith('data:image/svg+xml'):
            head, body = src.split(',', 1)
            if head.endswith(';base64'):
                svg = scrub_svg(base64.b64decode(body).decode('utf8'))
                s['src'] = head + ',' + base64.b64encode(svg.encode('utf8')).decode('ascii')
            else:
                s['src'] = head + ',' + urllib.parse.quote(scrub_svg(urllib.parse.unquote(body)), safe='')
    json.dump(ops, sys.stdout, separators=(',', ':'))

if __name__ == '__main__':
    main(sys.argv[1])
