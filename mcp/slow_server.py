import json, sys, time
# A server that speaks 2026-07-28 alone and takes a second to start, as one
# launched through npx or uvx can: whether it opens is what is tested.
time.sleep(1)
for line in sys.stdin:
    q=json.loads(line); m=q['method']
    if 'id' not in q: continue
    if '_meta' not in q.get('params',{}):
        print(json.dumps({'jsonrpc':'2.0','id':q['id'],'error':{'code':-32601,'message':'2026-07-28 only: '+m}}),flush=True)
        continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{}})
    elif m=='tools/list': r['tools']=[{'name':'slow','inputSchema':{'type':'object'}}]
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
