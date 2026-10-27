"""Drive ground code over ACP: one session with one stdio MCP server, a list of prompts, every update shown.

acp_drive.py GROUND_CODE CWD SERVER_PY CLIENT_CAPS_JSON PROMPTS_JSON [EXTRA_JSON]
PROMPTS_JSON is a list; each item is a prompt's content blocks (a list) or a string (one text block).
EXTRA_JSON is a list of raw messages sent between session/new and the first prompt (params.sessionId filled in).
"""
import json
import subprocess
import sys

binary, cwd, server, caps, prompts = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4]), json.loads(sys.argv[5])
extra = json.loads(sys.argv[6]) if len(sys.argv) > 6 else []
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
rid = 0


def write(v):
    p.stdin.write(json.dumps(v) + "\n")
    p.stdin.flush()


def show(u):
    kind = u.get("sessionUpdate")
    if kind in ("agent_message_chunk", "agent_thought_chunk", "user_message_chunk"):
        if kind == "agent_message_chunk":
            print("  message:", json.dumps(u["content"].get("text", u["content"]))[:300])
        return
    keep = {k: v for k, v in u.items() if k not in ("rawInput", "rawOutput", "locations")}
    print("  " + kind + ":", json.dumps(keep)[:600])


def ask(method, params, quiet=False):
    global rid
    rid += 1
    write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        msg = json.loads(p.stdout.readline())
        m = msg.get("method")
        if m == "session/request_permission":
            tc = msg["params"]["toolCall"]
            print("  permission:", json.dumps({k: tc.get(k) for k in ("toolCallId", "title", "kind")}))
            allow = [o for o in msg["params"]["options"] if o["kind"].startswith("allow")][0]
            write({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": {"outcome": "selected", "optionId": allow["optionId"]}}})
        elif m == "session/update":
            show(msg["params"]["update"])
        elif m is not None and "id" in msg:
            print("  client asked:", m)
            write({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "not here"}})
        if msg.get("id") == rid and m is None:
            if not quiet:
                print(" ", method, "->", json.dumps(msg.get("result", msg.get("error")))[:600])
            return msg


init = ask("initialize", {"protocolVersion": 1, "clientCapabilities": caps}, quiet=True)
print("initialize agentCapabilities:", json.dumps(init["result"].get("agentCapabilities")))
servers = [{"name": "test", "command": "python3", "args": [server], "env": []}]
sid = ask("session/new", {"cwd": cwd, "mcpServers": servers})["result"]["sessionId"]
for e in extra:
    e.setdefault("params", {})["sessionId"] = sid
    write(e)
for prompt in prompts:
    blocks = [{"type": "text", "text": prompt}] if isinstance(prompt, str) else prompt
    print("prompt:", json.dumps(blocks)[:200])
    ask("session/prompt", {"sessionId": sid, "prompt": blocks})
p.stdin.close()
p.wait()
print("stderr tail:", p.stderr.read()[-600:])
