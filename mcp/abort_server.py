import json, os, sys
# A tool that never answers on its own, one that answers at once, and every
# notification written down: what a cancel puts on the wire is what is tested.
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q:
        with open(os.environ['ABORT_LOG'],'a') as f: f.write(json.dumps(q)+'\n')
        continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{}})
    elif m=='tools/list':
        r['tools']=[{'name':name,'inputSchema':{'type':'object'}} for name in ('wait','quick')]
    elif m=='tools/call':
        with open(os.environ['ABORT_LOG'],'a') as f: f.write(json.dumps(q)+'\n')
        if p['name']=='wait': continue
        r['content']=[{'type':'text','text':'quick'}]
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
