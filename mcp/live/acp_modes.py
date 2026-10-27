"""A session's modes: offered on session/new, set by set_mode and by config option, kept across a resume.

acp_modes.py GROUND_CODE CWD
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
        while True:
            msg = json.loads(self.p.stdout.readline())
            if msg.get("id") == self.rid:
                return msg

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def mode_option(result):
    options = {o["id"]: o for o in result["configOptions"]}
    return options["mode"]["currentValue"]


a = Code()
a.ask("initialize", {"protocolVersion": 1})
new = a.ask("session/new", {"cwd": cwd, "mcpServers": []})["result"]
sid = new["sessionId"]
print("new: currentModeId", new["modes"]["currentModeId"],
      "offers", [(m["id"], m["name"]) for m in new["modes"]["availableModes"]])
print("set_mode plan:", json.dumps(a.ask("session/set_mode", {"sessionId": sid, "modeId": "plan"}).get("result")))
print("set_mode yolo:", json.dumps(a.ask("session/set_mode", {"sessionId": sid, "modeId": "yolo"}).get("error")))
print("set_mode, sessionId only in _meta:",
      json.dumps(a.ask("session/set_mode", {"modeId": "plan", "_meta": {"sessionId": sid}}).get("error")))
print("set_config_option mode=dontAsk:",
      mode_option(a.ask("session/set_config_option", {"sessionId": sid, "configId": "mode", "value": "dontAsk"})["result"]))
a.close()

b = Code()
b.ask("initialize", {"protocolVersion": 1})
resumed = b.ask("session/resume", {"sessionId": sid, "cwd": cwd})["result"]
print("resumed in another process: currentModeId", resumed["modes"]["currentModeId"],
      "mode option", mode_option(resumed))
b.close()
