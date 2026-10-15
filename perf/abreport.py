# abreport.py FILE — medians per build from `perf.py ablaunch` output (first round dropped).
import json, statistics as st, sys
rows=[json.loads(l[3:]) for l in open(sys.argv[1]) if l.startswith('AB ')]
rows=[r for r in rows if r['round']>0]
labels=[]
[labels.append(r['label']) for r in rows if r['label'] not in labels]
for key in ['window','t.verify','t.load','page.ask','page.commit','page.paint','page.finish','settled']:
    out=[]
    for label in labels:
        xs=[r['pace'].get('marks',{}).get(key) for r in rows if r['label']==label]
        xs=[x for x in xs if x is not None]
        out.append(f"{label}={round(st.median(xs)) if xs else '-':>5}")
    print(f'{key:12s}', '  '.join(out))
for label in labels:
    xs=[r['pace'].get('launchBusy') for r in rows if r['label']==label]; fp=[(r['pace'].get('launchSlow') or [[0,0]])[0][1] for r in rows if r['label']==label]
    al=[r.get('active_loaded_ms') for r in rows if r['label']==label]
    print(f'{label}: busy20s={round(st.median(xs))} firstPass={round(st.median(fp))} activeLoaded(ext)={round(st.median([a for a in al if a]))}')
