"""A session's effort: set by set_config_option, refused when unknown or a boolean, kept across a resume.

acp_effort.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]


def run(*messages):
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    out = subprocess.run([binary], input=lines, capture_output=True, text=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def effort(answer):
    if "error" in answer:
        return json.dumps(answer["error"])
    return [o["currentValue"] for o in answer["result"]["configOptions"] if o["id"] == "effort"]


def set_option(i, sid, **value):
    return {"jsonrpc": "2.0", "id": i, "method": "session/set_config_option",
            "params": {"sessionId": sid, "configId": "effort", **value}}


init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}}
a = run(init, {"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": cwd, "mcpServers": []}})
sid = a[1]["result"]["sessionId"]
print("process 1 opened", sid, "at", effort(a[1]))

b = run(init,
        {"jsonrpc": "2.0", "id": 2, "method": "session/resume", "params": {"sessionId": sid, "cwd": cwd}},
        set_option(3, sid, value="xhigh"),
        set_option(4, sid, value="ultra"),
        set_option(5, sid, type="boolean", value=True),
        set_option(6, sid, value=True),
        set_option(7, sid))
print("set xhigh:", effort(b[2]))
print("set ultra:", effort(b[3]))
print("set type boolean, true:", effort(b[4]))
print("set true:", effort(b[5]))
print("set nothing:", effort(b[6]))

c = run(init, {"jsonrpc": "2.0", "id": 8, "method": "session/resume", "params": {"sessionId": sid, "cwd": cwd}})
print("process 3 resumed at", effort(c[1]))
