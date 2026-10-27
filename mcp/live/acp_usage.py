"""#169 live: each gateway answer in a turn is followed by usage_update {used, size}.

acp_usage.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
rid = 0


def ask(method, params):
    global rid
    rid += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
    p.stdin.flush()
    seen = []
    while True:
        msg = json.loads(p.stdout.readline())
        update = msg.get("params", {}).get("update", {})
        kind = update.get("sessionUpdate")
        if kind == "usage_update":
            seen.append(update)
        elif kind:
            seen.append(kind)
        if msg.get("id") == rid:
            return msg, seen


ask("initialize", {"protocolVersion": 1})
sid = ask("session/new", {"cwd": cwd, "mcpServers": []})[0]["result"]["sessionId"]
for text in ["Reply with only: ok", "Reply with only: again"]:
    msg, seen = ask("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
    print(msg.get("result", msg.get("error")), seen)
p.stdin.close()
p.wait()
