"""session/list: each session's entry, filtered by cwd, and the requests it refuses.

acp_list.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]


def run(*messages):
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    out = subprocess.run([binary], input=lines, capture_output=True, text=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def listing(i, **params):
    return {"jsonrpc": "2.0", "id": i, "method": "session/list", "params": params}


init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}}
a = run(init, {"jsonrpc": "2.0", "id": 1, "method": "session/new",
               "params": {"cwd": cwd, "mcpServers": [], "additionalDirectories": ["/lib"]}})
sid = a[1]["result"]["sessionId"]
print("process 1 opened", sid)

b = run(init, listing(2, cwd=cwd), listing(3, cwd="rel"), listing(4, cursor="x"), listing(5, cursor=7), listing(6, cwd=7))
print("listed in its cwd:", json.dumps([s for s in b[1]["result"]["sessions"] if s["sessionId"] == sid]))
for answer in b[2:]:
    print("id", answer["id"], json.dumps(answer.get("error")))
