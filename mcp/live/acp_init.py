"""libacp live: initialize in both shapes and a version none fits, then a v2-shaped client's elicitation honoured.

acp_init.py GROUND_CODE CWD ELICIT_SERVER_PY LOG
"""
import json
import subprocess
import sys

binary, cwd, server, log = sys.argv[1:5]


def start():
    return subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def send(p, msg):
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()


for label, params in [
    ("v1 shape", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": True}}}),
    ("v2 shape", {"protocolVersion": 2, "info": {"name": "probe", "version": "1"}, "capabilities": {"elicitation": {"form": {}}}}),
    ("version 0", {"protocolVersion": 0}),
    ("no version", {}),
]:
    p = start()
    send(p, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": params})
    answer = json.loads(p.stdout.readline())
    p.stdin.close()
    p.wait()
    shown = answer.get("error") or {k: answer["result"][k] for k in ("protocolVersion",) if k in answer["result"]}
    print(f"{label}: {json.dumps(shown)}")

# A v2-shaped client offering form elicitation, whose session's server elicits.
p = start()
send(p, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 2, "info": {"name": "probe", "version": "1"}, "capabilities": {"elicitation": {"form": {}}}}})
print("v2-shaped client initialize:", json.loads(p.stdout.readline())["result"]["protocolVersion"])
rid = 0


def ask(method, params):
    global rid
    rid += 1
    send(p, {"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        msg = json.loads(p.stdout.readline())
        m = msg.get("method")
        if m == "elicitation/create":
            print("client got elicitation/create:", json.dumps({k: msg["params"].get(k) for k in ("mode", "message")}))
            send(p, {"jsonrpc": "2.0", "id": msg["id"], "result": {"action": "accept", "content": {"branch": "main"}}})
        elif m == "session/request_permission":
            allow = [o for o in msg["params"]["options"] if o["kind"].startswith("allow")][0]
            send(p, {"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": {"outcome": "selected", "optionId": allow["optionId"]}}})
        if msg.get("id") == rid and m is None:
            return msg


servers = [{"name": "elicit", "command": "python3", "args": [server],
            "env": [{"name": "ELICIT_PROTOCOL", "value": "legacy"}, {"name": "ELICIT_LOG", "value": log}]}]
sid = ask("session/new", {"cwd": cwd, "mcpServers": servers})["result"]["sessionId"]
done = ask("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "Call the elicit tool `ask` with no arguments, then reply with only: done"}]})
print("prompt:", json.dumps(done.get("result", done.get("error"))))
p.stdin.close()
p.wait()
print("server log:", open(log).read().strip())
