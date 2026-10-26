"""Live local server; assert that schema-invalid calls cause no side effects."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    log = Path(tmp) / "calls.jsonl"
    config = json.dumps({"params": {"mcpServers": [{"name": "test", "command": sys.executable,
                         "args": [str(Path(__file__).with_name("checked_server.py").resolve())],
                         "env": [{"name": "CHECKED_LOG", "value": str(log)}]}]}})
    subprocess.run([str(Path(sys.argv[1]).resolve()), config], check=True, timeout=20)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert [c["params"]["name"] for c in calls] == ["echo", "bad-output", "echo", "bad-output"], calls
    assert calls[0]["params"]["arguments"] == {"text": "corrected"}, calls
    assert calls[2]["params"]["arguments"] == {"text": "polled"}, calls
    print("Wire audit: zero invalid-input executions; exactly the valid-input calls, waited and polled")
