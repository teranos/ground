"""#177 live: usage_update carries the session's cumulative cost, kept across a resume in another process.

acp_cost.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]


class Code:
    def __init__(self):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.rid = 0

    def ask(self, method, params):
        self.rid += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.rid, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        usage = []
        while True:
            msg = json.loads(self.p.stdout.readline())
            u = msg.get("params", {}).get("update", {})
            if u.get("sessionUpdate") == "usage_update":
                usage.append({k: v for k, v in u.items() if k != "sessionUpdate"})
            if msg.get("id") == self.rid and "method" not in msg:
                return msg, usage

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def turn(code, sid, text, label):
    msg, usage = code.ask("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
    print(label, msg.get("result", msg.get("error")), json.dumps(usage))


a = Code()
a.ask("initialize", {"protocolVersion": 1})
sid = a.ask("session/new", {"cwd": cwd, "mcpServers": []})[0]["result"]["sessionId"]
turn(a, sid, "Reply with only: ok", "process 1 turn 1:")
turn(a, sid, "Reply with only: again", "process 1 turn 2:")
a.close()
b = Code()
b.ask("initialize", {"protocolVersion": 1})
b.ask("session/resume", {"sessionId": sid, "cwd": cwd})
turn(b, sid, "Reply with only: third", "process 2 turn 3:")
b.close()
