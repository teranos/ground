"""A session's additionalDirectories: kept in order and decoded, refused when relative, replaced by a resume.

acp_dirs.py GROUND_CODE CWD
"""
import json
import subprocess
import sys

binary, cwd = sys.argv[1], sys.argv[2]


def run(*messages):
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    out = subprocess.run([binary], input=lines, capture_output=True, text=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def listed(answer, sid):
    return [s.get("additionalDirectories") for s in answer["result"]["sessions"] if s["sessionId"] == sid]


init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}}
a = run(init,
        {"jsonrpc": "2.0", "id": 1, "method": "session/new",
         "params": {"cwd": cwd, "mcpServers": [], "additionalDirectories": ["/lib/café", "/lib/b"]}},
        {"jsonrpc": "2.0", "id": 2, "method": "session/new",
         "params": {"cwd": cwd, "mcpServers": [], "additionalDirectories": ["/lib", "rel"]}},
        {"jsonrpc": "2.0", "id": 3, "method": "session/new",
         "params": {"cwd": cwd, "mcpServers": [], "_meta": {"additionalDirectories": ["rel"]}}})
sid = a[1]["result"]["sessionId"]
print("process 1 opened", sid)
print("relative path:", json.dumps(a[2].get("error")))
print("list only in _meta:", "opened" if "result" in a[3] else json.dumps(a[3].get("error")))

b = run(init,
        {"jsonrpc": "2.0", "id": 4, "method": "session/list", "params": {"cwd": cwd}},
        {"jsonrpc": "2.0", "id": 5, "method": "session/resume",
         "params": {"sessionId": sid, "cwd": cwd, "additionalDirectories": ["/srv/other"]}},
        {"jsonrpc": "2.0", "id": 6, "method": "session/list", "params": {"cwd": cwd}},
        {"jsonrpc": "2.0", "id": 7, "method": "session/resume", "params": {"sessionId": sid, "cwd": cwd}},
        {"jsonrpc": "2.0", "id": 8, "method": "session/list", "params": {"cwd": cwd}})
print("process 2 lists:", json.dumps(listed(b[1], sid), ensure_ascii=False))
print("after a resume with /srv/other:", json.dumps(listed(b[3], sid)))
print("after a resume with none:", json.dumps(listed(b[5], sid)))
