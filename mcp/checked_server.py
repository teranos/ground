import json, os, sys
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q: continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{}})
    elif m=='tools/list':
        r['tools']=[{'name':name,'inputSchema':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']},'outputSchema':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}} for name in ('echo','bad-output')]
    elif m=='tools/call':
        with open(os.environ['CHECKED_LOG'],'a') as f: f.write(json.dumps(q)+'\n')
        r['content']=[]
        r['structuredContent']={'text':p['arguments']['text'] if p['name']=='echo' else 42}
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
