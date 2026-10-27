import json, sys
# Prompts a session's server offers: one with an argument, one with none, one
# with two, and one whose message is an image: what becomes a command, and
# what a command asks of the model, is what is tested.
prompts = [
    {'name': 'review', 'description': 'Review a file', 'arguments': [{'name': 'path', 'description': 'the file to review', 'required': True}]},
    {'name': 'hello', 'description': 'Say hello'},
    {'name': 'pair', 'description': 'Compare two files', 'arguments': [{'name': 'a'}, {'name': 'b'}]},
    {'name': 'picture', 'description': 'Look at a picture'},
]
for line in sys.stdin:
    q=json.loads(line); m=q['method']; p=q.get('params',{})
    if 'id' not in q: continue
    r={'resultType':'complete'}
    if m=='server/discover': r.update(supportedVersions=['2026-07-28'],capabilities={'tools':{},'prompts':{}})
    elif m=='tools/list': r['tools']=[]
    elif m=='prompts/list': r['prompts']=prompts
    elif m=='prompts/get':
        if p['name']=='review':
            r['messages']=[{'role':'user','content':{'type':'text','text':'Review '+p['arguments']['path']+' for bugs.'}},
                           {'role':'assistant','content':{'type':'text','text':'I will read it first.'}}]
        elif p['name']=='hello':
            r['messages']=[{'role':'user','content':{'type':'text','text':'Say hello.'}}]
        else:
            r['messages']=[{'role':'user','content':{'type':'image','data':'AAAA','mimeType':'image/png'}}]
    print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
