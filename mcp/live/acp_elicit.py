"""#167 live: what a session's MCP server elicits is asked of the client, and the answer reaches the server.

acp_elicit.py GROUND_CODE CWD SERVER_PY LOG legacy|modern
"""
import json
import subprocess
import sys

binary, cwd, server, log, protocol = sys.argv[1:6]
wait = float(sys.argv[6]) if len(sys.argv) > 6 else 0
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
rid = 0


def write(v):
    p.stdin.write(json.dumps(v) + "\n")
    p.stdin.flush()


def ask(method, params):
    global rid
    rid += 1
    write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        msg = json.loads(p.stdout.readline())
        m = msg.get("method")
        if m == "elicitation/create":
            print("client got", m, json.dumps(msg["params"]))
            if wait:
                import time
                started = time.time()
                time.sleep(wait)
                print(f"client answered after {time.time() - started:.1f}s")
            answer = {"action": "accept", "content": {"branch": "main"}} if msg["params"].get("mode") == "form" else {"action": "accept"}
            write({"jsonrpc": "2.0", "id": msg["id"], "result": answer})
        elif m == "elicitation/complete":
            print("client got", m, json.dumps(msg["params"]))
        elif m == "session/request_permission":
            allow = [o for o in msg["params"]["options"] if o["kind"].startswith("allow")][0]
            write({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": {"outcome": "selected", "optionId": allow["optionId"]}}})
        elif m == "session/update":
            u = msg["params"]["update"]
            if u.get("sessionUpdate") in ("tool_call", "tool_call_update") and u.get("status") in ("completed", "failed"):
                print("tool", u.get("toolCallId"), u.get("status"), json.dumps(u.get("rawOutput", u.get("content")))[:200])
        if msg.get("id") == rid and "method" not in msg:
            return msg


ask("initialize", {"protocolVersion": 1, "clientCapabilities": {"elicitation": {"form": {}, "url": {}}}})
servers = [{"name": "elicit", "command": "python3", "args": [server],
            "env": [{"name": "ELICIT_PROTOCOL", "value": protocol}, {"name": "ELICIT_LOG", "value": log}]}]
sid = ask("session/new", {"cwd": cwd, "mcpServers": servers})["result"]["sessionId"]
tools = "the elicit tool `ask`, then the elicit tool `link`" if protocol == "legacy" else "the elicit tool `ask`"
done = ask("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"Call {tools}, each with no arguments. Then reply with only: done"}]})
print("prompt", done.get("result", done.get("error")))
p.stdin.close()
p.wait()
print("server log:")
print(open(log).read())
