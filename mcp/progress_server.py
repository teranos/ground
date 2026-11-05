import json, sys
# One tool that reports its progress on the token its call carries: twice with
# a message and once without, then answers with the token it was given.
def send(x): print(json.dumps(x), flush=True)
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q: continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{}})
    elif m=='tools/list':
        r['tools']=[{'name':'count','inputSchema':{'type':'object'}}]
    elif m=='tools/call':
        token=p.get('_meta',{}).get('progressToken')
        if token is not None:
            for n, said in ((1,'counted 1 of 3'),(2,None),(3,'counted 3 of 3')):
                params={'progressToken':token,'progress':n,'total':3}
                if said: params['message']=said
                send({'jsonrpc':'2.0','method':'notifications/progress','params':params})
        r['content']=[{'type':'text','text':'token '+json.dumps(token)}]
    send({'jsonrpc':'2.0','id':q['id'],'result':r})
