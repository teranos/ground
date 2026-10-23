import json
from pathlib import Path
import subprocess
import sys

server = str(Path(__file__).with_name("server.py").resolve())
config = {"params": {"mcpServers": [{"name": "test", "command": sys.executable, "args": [server, "modern"], "env": []}]}}
p = subprocess.run([sys.argv[1], json.dumps(config)], capture_output=True, timeout=5)
assert p.returncode == 0, p.stderr
assert json.loads(json.loads(p.stdout)["result"]["content"][0]["text"])["text"] == "harness"
print("D harness: connect, retain tool catalog, dispatch by server/tool, close passed")
