import json, sys
# A server with one text resource, one binary one, and no others: what a
# prompt's resource_link reads through it is what is tested.
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q: continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{},'resources':{}})
    elif m=='tools/list': r['tools']=[]
    elif m=='resources/read':
        if p['uri']=='mem://notes/a':
            r['contents']=[{'uri':'mem://notes/a','mimeType':'text/plain','text':'the notes say hi'}]
        elif p['uri']=='mem://logo':
            r['contents']=[{'uri':'mem://logo','mimeType':'image/png','blob':'AAAA'}]
        else:
            print(json.dumps({'jsonrpc':'2.0','id':q['id'],'error':{'code':-32002,'message':'Resource not found','data':{'uri':p['uri']}}}),flush=True)
            continue
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
