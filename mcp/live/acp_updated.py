"""#176 live: each turn's session_info_update carries updatedAt, the first with the title; session/list reports the same time.

acp_updated.py GROUND_CODE CWD
"""
import json
import subprocess
import sys
import time

binary, cwd = sys.argv[1], sys.argv[2]
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
rid = 0


def ask(method, params):
    global rid
    rid += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
    p.stdin.flush()
    info = []
    while True:
        msg = json.loads(p.stdout.readline())
        u = msg.get("params", {}).get("update", {})
        if u.get("sessionUpdate") == "session_info_update":
            info.append({k: v for k, v in u.items() if k != "sessionUpdate"})
        if msg.get("id") == rid and "method" not in msg:
            return msg, info


ask("initialize", {"protocolVersion": 1})
sid = ask("session/new", {"cwd": cwd, "mcpServers": []})[0]["result"]["sessionId"]
for text in ["Plan the release notes. Reply with only: ok", "Reply with only: again"]:
    msg, info = ask("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
    print("prompt", msg.get("result", msg.get("error")), "info:", json.dumps(info))
    time.sleep(2)
listed, _ = ask("session/list", {"cwd": cwd})
print("list:", json.dumps([s for s in listed["result"]["sessions"] if s["sessionId"] == sid]))
p.stdin.close()
p.wait()
