"""A turn cancelled while it runs: a sessionId only in _meta cancels nothing, $/cancel_request by the prompt's id does.
A cancel with no turn running is answered with nothing and said on stderr.

acp_cancel.py GROUND_CODE CWD
"""
import json
import subprocess
import sys
import threading
import time

binary, cwd = sys.argv[1], sys.argv[2]
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
answers = {}
arrived = threading.Condition()


def read():
    for line in p.stdout:
        msg = json.loads(line)
        if "id" in msg and "method" not in msg:
            with arrived:
                answers[msg["id"]] = (time.monotonic(), msg)
                arrived.notify_all()


def send(msg):
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()


def wait(i, limit=180):
    with arrived:
        arrived.wait_for(lambda: i in answers, timeout=limit)
    return answers.get(i)


threading.Thread(target=read, daemon=True).start()
send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}})
send({"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": cwd, "mcpServers": []}})
sid = wait(1)[1]["result"]["sessionId"]
send({"jsonrpc": "2.0", "id": 2, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [
    {"type": "text", "text": "Count from 1 to 400, one number per line, no other text."}]}})
time.sleep(1)
send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"_meta": {"sessionId": sid}}})
time.sleep(1)
print("answered after the _meta-only cancel:", 2 in answers)
cancelled_at = time.monotonic()
send({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": 2}})
at, answer = wait(2)
print("prompt:", json.dumps(answer.get("result", answer.get("error"))), f"{at - cancelled_at:.1f}s after $/cancel_request")
send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}})
send({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": "p/1"}})
send({"jsonrpc": "2.0", "id": 3, "method": "session/close", "params": {"sessionId": sid}})
wait(3)
p.stdin.close()
p.wait()
for line in p.stderr.read().splitlines():
    if "cancel" in line:
        print("stderr:", line)
