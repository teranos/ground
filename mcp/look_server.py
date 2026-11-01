import json, sys
# One tool whose annotations say it only reads, one that says nothing, and
# one that fails as a tool: what a client is told of each is what is tested.
# look has a title of its own, touch only its annotations' title, break none.
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q: continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{}})
    elif m=='tools/list':
        r['tools']=[{'name':'look','title':'Look around','inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True}},
                    {'name':'touch','inputSchema':{'type':'object'},'annotations':{'title':'Touch a file'}},
                    {'name':'break','inputSchema':{'type':'object'}}]
    elif m=='tools/call':
        if p['name']=='break':
            r.update(isError=True, content=[{'type':'text','text':'disk full'}])
        else:
            r['content']=[{'type':'text','text':p['name']+' done'}]
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
