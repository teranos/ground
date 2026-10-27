"""#166 live: a session is titled by its first prompt, told once, kept across processes, and listed.

acp_title.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]


class Code:
    def __init__(self):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        self.rid = 0

    def ask(self, method, params):
        self.rid += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.rid, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        told = []
        while True:
            msg = json.loads(self.p.stdout.readline())
            update = msg.get("params", {}).get("update", {})
            if update.get("sessionUpdate") == "session_info_update":
                told.append(update)
            if msg.get("id") == self.rid:
                return msg, told

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def prompt(code, sid, text):
    msg, told = code.ask("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
    return msg.get("result", {}).get("stopReason"), told


a = Code()
a.ask("initialize", {"protocolVersion": 1})
sid = a.ask("session/new", {"cwd": cwd, "mcpServers": []})[0]["result"]["sessionId"]
print("first prompt:", prompt(a, sid, "  Check the   title live\nReply with only: ok"))
print("second prompt:", prompt(a, sid, "Reply with only: again"))
a.close()

b = Code()
b.ask("initialize", {"protocolVersion": 1})
b.ask("session/resume", {"sessionId": sid, "cwd": cwd})
print("after resume, third prompt:", prompt(b, sid, "Reply with only: third"))
listed, _ = b.ask("session/list", {"cwd": cwd})
mine = [s for s in listed["result"]["sessions"] if s["sessionId"] == sid]
print("session/list:", json.dumps(mine))
b.close()
