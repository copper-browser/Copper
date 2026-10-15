# compare.py LABEL… — medians from perf/results/LABEL side by side.
import json, sys, statistics as st, os
R=os.path.join(os.path.dirname(os.path.abspath(__file__)),'results')
def med(xs):
    xs=[x for x in xs if x is not None]
    return round(st.median(xs)) if xs else None
def summary(label):
    d=os.path.join(R,label); out={}
    L=[json.loads(l) for l in open(os.path.join(d,'launch.jsonl'))][1:]  # drop first (cold disk)
    m=lambda k:[r['pace'].get('marks',{}).get(k) for r in L]
    out['launch.window']=med(m('window')); out['launch.page.ask']=med(m('page.ask')); out['launch.page.paint']=med(m('page.paint'))
    out['launch.busy20s']=med([r['pace'].get('launchBusy') for r in L]); out['launch.firstPass']=med([ (r['pace'].get('launchSlow') or [[0,0]])[0][1] for r in L])
    S=[json.loads(l) for l in open(os.path.join(d,'spaces.jsonl'))]
    out['space.busy']=med([r['pace'].get('busy') for r in S]); out['space.longest']=med([r['pace'].get('longest') for r in S]); out['space.maxLongest']=max(r['pace'].get('longest',0) for r in S)
    out['space.moved']=med([r['slide'].get('moved') for r in S])
    out['space.r1.landedLoading']=sum(1 for r in S if r['round']==0 and r.get('landed_loading'))
    out['space.r1.landedCold']=sum(1 for r in S if r['round']==0 and not r.get('landed_built', True))
    cs=[r['pace'].get('counts') or {} for r in S]
    if any(cs):
        for k in ('browser','tab','history','spaces'): out['space.n.'+k]=med([c.get(k,0) for c in cs])
    for f in ['load-lightspeed','load-github']:
        X=[json.loads(l) for l in open(os.path.join(d,f+'.jsonl'))]
        out[f+'.overhead']=med([r.get('app_overhead_ms') for r in X]); out[f+'.fcp']=med([r.get('req_to_fcp_ms') for r in X])
        out[f+'.busy']=med([r.get('busy') for r in X]); out[f+'.longest']=med([r.get('longest') for r in X])
    for f in ['reload-lightspeed','reload-github']:
        p=os.path.join(d,f+'.jsonl')
        if not os.path.exists(p): continue
        X=[json.loads(l) for l in open(p)]
        out[f+'.fcp']=med([r.get('req_to_fcp_ms') for r in X]); out[f+'.load']=med([r.get('req_to_load_ms') for r in X]); out[f+'.kB']=med([ (r.get('bytes') or 0)//1000 for r in X]); out[f+'.type']=X[0].get('type')
    return out
labels=sys.argv[1:]
rows=[summary(l) for l in labels]
keys=[]
[keys.append(k) for r in rows for k in r if k not in keys]
for k in keys:
    print(f'{k:28s}', '  '.join(f'{str(r.get(k)):>8s}' for r in rows))
