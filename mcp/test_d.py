import json
import os
from pathlib import Path
import subprocess
import sys

client = str(Path(sys.argv[1]).resolve())
server = os.environ["LIBMCP_SERVER"]  # the library's test server, from its source
for mode in ("modern", "legacy", "fragment"):
    for method, params, expected in [
        ("tools/list", {}, 0),
        ("tools/call", {"name": "echo", "arguments": {"text": '☃\n"\\'}}, 0),
        ("test/remote", {}, 1),
        ("resources/read", {"uri": "test:input"}, 1),
        ("tools/call", {"name": "fail", "arguments": {}}, 1),
    ]:
        proc = subprocess.run([client, method, json.dumps(params), "--", sys.executable, server, mode], capture_output=True, timeout=5)
        assert proc.returncode == expected, (mode, method, proc.returncode, proc.stderr)
        response = json.loads(proc.stdout)
        assert "error" in response if method == "test/remote" else "result" in response
        if expected:
            assert b"ground mcp:" in proc.stderr
        if method == "test/remote":
            assert response["error"]["data"] == {"nested": [0, None, False]}
print("15 D -betterC subprocess round trips passed")
