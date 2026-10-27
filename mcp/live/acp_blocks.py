"""A prompt's blocks: text goes to the model; a block ground code cannot read is refused by its type; no prompt is refused.

acp_blocks.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]

text = {"type": "text", "text": "Answer with exactly one word: what colour is the sky on a clear day?"}
prompts = [
    ("text only", {"prompt": [text]}),
    ("text and a file:// resource_link", {"prompt": [text, {"type": "resource_link", "name": "a", "uri": "file:///etc/hosts"}]}),
    ("text and an image", {"prompt": [text, {"type": "image", "data": "AAAA", "mimeType": "image/png"}]}),
    ("a resource holding a blob", {"prompt": [{"type": "resource", "resource": {"uri": "file:///a.png", "blob": "AAAA"}}]}),
    ("a block naming no type", {"prompt": [{"text": "hi"}]}),
    ("no prompt", {}),
    ("a prompt only in _meta", {"_meta": {"prompt": [text]}}),
]

p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def ask(msg):
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()
    while True:
        answer = json.loads(p.stdout.readline())
        if answer.get("id") == msg["id"]:
            return answer


ask({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}})
sid = ask({"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": cwd, "mcpServers": []}})["result"]["sessionId"]
for i, (label, params) in enumerate(prompts, 2):
    answer = ask({"jsonrpc": "2.0", "id": i, "method": "session/prompt", "params": {"sessionId": sid, **params}})
    print(f"{label}:", json.dumps(answer.get("result", answer.get("error"))))
p.stdin.close()
p.wait()
