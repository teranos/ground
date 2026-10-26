import json, os, sys
# A tool that asks the user through elicitation/create while its call runs,
# as a legacy server asks (a request of its own, answered on the wire) or as a
# 2026-07-28 server does (input_required, answered by the call's continuation).
# The capabilities the client declared, and every elicitation answer, are
# written down: what ground code declares and passes on is what is tested.
modern = os.environ['ELICIT_PROTOCOL'] == 'modern'
log = os.environ['ELICIT_LOG']
def note(v):
    with open(log, 'a') as f: f.write(json.dumps(v) + '\n')
def send(v): print(json.dumps(v), flush=True)
form = {'message': 'Which branch?', 'requestedSchema': {'type': 'object', 'properties': {'branch': {'type': 'string'}}, 'required': ['branch']}}
link = {'mode': 'url', 'message': 'Sign in', 'elicitationId': 'x1', 'url': 'https://example.com/sign-in'}
def ask(params, id_):
    send({'jsonrpc': '2.0', 'id': id_, 'method': 'elicitation/create', 'params': params})
    reply = json.loads(sys.stdin.readline())
    note({'answer': reply})
    return reply
for line in sys.stdin:
    q = json.loads(line); m = q['method']; p = q.get('params', {})
    if 'id' not in q: continue
    if m == 'server/discover' and not modern:
        send({'jsonrpc': '2.0', 'id': q['id'], 'error': {'code': -32601, 'message': 'legacy'}}); continue
    r = {'resultType': 'complete'} if modern else {}
    if m == 'server/discover':
        note({'capabilities': p['_meta']['io.modelcontextprotocol/clientCapabilities']})
        r.update(supportedVersions=['2026-07-28'], capabilities={'tools': {}})
    elif m == 'initialize':
        note({'capabilities': p['capabilities']})
        r.update(protocolVersion='2025-06-18', serverInfo={'name': 'elicit', 'version': '1'}, capabilities={'tools': {}})
    elif m == 'tools/list':
        r['tools'] = [{'name': n, 'inputSchema': {'type': 'object'}} for n in ('ask', 'link')]
    elif m == 'tools/call' and modern:
        if 'inputResponses' not in p:
            r.update(resultType='input_required', requestState='s1',
                     inputRequests={'q': {'method': 'elicitation/create', 'params': dict(form, mode='form')}})
        else:
            note({'answer': p['inputResponses']['q'], 'state': p['requestState']})
            r['content'] = [{'type': 'text', 'text': json.dumps(p['inputResponses']['q'])}]
    elif m == 'tools/call':
        if p['name'] == 'ask':
            reply = ask(form, 'e1')
        else:
            reply = ask(link, 'e2')
            send({'jsonrpc': '2.0', 'method': 'notifications/elicitation/complete', 'params': {'elicitationId': 'x1'}})
        r['content'] = [{'type': 'text', 'text': json.dumps(reply.get('result', reply.get('error')))}]
    send({'jsonrpc': '2.0', 'id': q['id'], 'result': r})
