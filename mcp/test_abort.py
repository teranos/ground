"""Live local server; assert a stopped tool call is cancelled on the wire."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    log = Path(tmp) / "wire.jsonl"
    config = json.dumps({"params": {"mcpServers": [{"name": "test", "command": sys.executable,
                         "args": [str(Path(__file__).with_name("abort_server.py").resolve())],
                         "env": [{"name": "ABORT_LOG", "value": str(log)}]}]}})
    subprocess.run([str(Path(sys.argv[1]).resolve()), config], check=True, timeout=20)
    wire = [json.loads(line) for line in log.read_text().splitlines()]
    calls = [w for w in wire if w.get("method") == "tools/call"]
    cancels = [w for w in wire if w.get("method") == "notifications/cancelled"]
    assert [c["params"]["name"] for c in calls] == ["wait", "quick"], wire
    assert len(cancels) == 1 and cancels[0]["params"]["requestId"] == calls[0]["id"], wire
    assert cancels[0]["params"]["reason"] == "the client cancelled the turn", wire
    print("Wire audit: the stopped call was cancelled by its id, with ground's reason")
