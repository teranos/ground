"""session/delete live: a session one process opened is deleted by another, and gone for both.

acp_delete.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]


def run(*messages):
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    out = subprocess.run([binary], input=lines, capture_output=True, text=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip()]


init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}}
opened = run(init, {"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": cwd, "mcpServers": []}})
sid = opened[1]["result"]["sessionId"]
print("process 1 opened", sid)

answers = run(init,
              {"jsonrpc": "2.0", "id": 2, "method": "session/delete", "params": {"sessionId": sid}},
              {"jsonrpc": "2.0", "id": 3, "method": "session/list", "params": {"cwd": cwd}},
              {"jsonrpc": "2.0", "id": 4, "method": "session/delete", "params": {"sessionId": sid}},
              {"jsonrpc": "2.0", "id": 5, "method": "session/delete", "params": {"_meta": {"sessionId": sid}}})
for a in answers[1:]:
    shown = a.get("result", a.get("error"))
    if a["id"] == 3:
        shown = [s["sessionId"] for s in a["result"]["sessions"] if s["sessionId"] == sid]
    print(f"process 2, id {a['id']}:", json.dumps(shown))
