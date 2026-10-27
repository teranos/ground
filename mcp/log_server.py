import json, sys
# A tool that logs at three levels while its call runs, as MCP's
# notifications/message says: what reaches the user is what is tested.
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q: continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{},'logging':{}})
    elif m=='tools/list':
        r['tools']=[{'name':'noisy','inputSchema':{'type':'object'}}]
    elif m=='tools/call':
        for level, data in (('info', 'starting'), ('warning', 'disk is filling up'), ('error', {'errno': 28, 'path': '/var'})):
            print(json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{'level':level,'logger':'disk','data':data}}),flush=True)
        r['content']=[{'type':'text','text':'done'}]
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
