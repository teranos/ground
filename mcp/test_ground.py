"""ACP drives the real Ground harness, which owns each MCP subprocess."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile

GROUND = str(Path(sys.argv[1]).resolve())
SERVER = os.environ["LIBMCP_SERVER"]  # the library's test server, from its source


def request(proc, ident, method, params):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    ready, _, _ = select.select([proc.stdout], [], [], 8)
    assert ready, (method, "Ground did not respond")
    line = proc.stdout.readline()
    assert line, (method, "Ground exited")
    response = json.loads(line)
    assert response["id"] == ident, response
    return response


def server(name, log, mode="modern"):
    return {"name": name, "command": sys.executable, "args": [SERVER, mode], "env": [{"name": "LIBMCP_LOG", "value": str(log)}, {"name": "LIBMCP_TEST", "value": "from-acp"}]}


def records(log):
    return [json.loads(line) for line in log.read_text().splitlines()]


def dead(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp).resolve()  # the server reports getcwd, and macOS's temp dir is a link
    proc = subprocess.Popen([GROUND, "code"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert "result" in request(proc, 1, "initialize", {"protocolVersion": 1})
        log1, log2 = tmp / "a.jsonl", tmp / "b.jsonl"
        result = request(proc, 2, "session/new", {"cwd": str(tmp), "mcpServers": [server("same-name", log1)]})
        assert "result" in result, result
        sid1 = result["result"]["sessionId"]
        result = request(proc, 3, "session/new", {"cwd": str(tmp), "mcpServers": [server("same-name", log2, "legacy")]})
        assert "result" in result, result
        sid2 = result["result"]["sessionId"]
        a, b = records(log1), records(log2)
        for rows in (a, b):
            assert rows[0]["cwd"] == str(tmp)
            assert rows[0]["value"] == "from-acp"
            assert sum(r.get("method") == "tools/list" for r in rows) == 2, rows
        assert "result" in request(proc, 4, "session/close", {"sessionId": sid1})
        assert dead(a[0]["pid"]) and not dead(b[0]["pid"])
        # The store lists every unclosed session this machine has, so this test asks for its own cwd.
        sessions = request(proc, 5, "session/list", {"cwd": str(tmp)})["result"]["sessions"]
        assert [s["sessionId"] for s in sessions] == [sid2]
        # Partial setup must roll back both ownership and process state.
        rollback = tmp / "rollback.jsonl"
        bad = server("missing", tmp / "missing.jsonl")
        bad["command"] = "/does/not/exist"
        result = request(proc, 6, "session/new", {"cwd": str(tmp), "mcpServers": [server("first", rollback), bad]})
        assert result["error"]["data"]["failure"]["server"] == "missing", result
        assert result["error"]["data"]["failure"]["systemErrno"] == 2
        assert dead(records(rollback)[0]["pid"])
        assert len(request(proc, 7, "session/list", {"cwd": str(tmp)})["result"]["sessions"]) == 1
        # Validate all configurations before spawning even the first one.
        never = tmp / "never.jsonl"
        for malformed in (
            [server("dup", never), server("dup", never)],
            [server("valid", never), {"type": "http", "name": "remote", "url": "https://example.com"}],
            [dict(server("bad-env", never), env=[{"name": "X=Y", "value": "z"}])],
            [dict(server("nul", never), args=["bad\x00arg"])],
        ):
            assert "error" in request(proc, 8, "session/new", {"cwd": str(tmp), "mcpServers": malformed})
        assert not never.exists()
        # Errors larger than the original ACP reply buffer cross intact.
        result = request(proc, 9, "session/new", {"cwd": str(tmp), "mcpServers": [server("large-error", tmp / "large.jsonl", "large-error")]})
        remote = json.loads(result["error"]["data"]["failure"]["response"])
        assert remote["error"]["message"] == "☃" * 9000
        assert remote["error"]["data"]["sacred"] is True
        # "List of MCP servers to connect to for this session." Resumed, a session's
        # servers are the ones the request names: the old ones end, the new ones
        # come up in the session's cwd.
        log3 = tmp / "c.jsonl"
        result = request(proc, 10, "session/resume", {"sessionId": sid2, "cwd": str(tmp), "mcpServers": [server("again", log3)]})
        assert "result" in result, result
        c = records(log3)
        assert c[0]["cwd"] == str(tmp) and dead(b[0]["pid"]) and not dead(c[0]["pid"])
        # Servers that fail to come up leave the session as it was.
        result = request(proc, 11, "session/resume", {"sessionId": sid2, "cwd": str(tmp), "mcpServers": [bad]})
        assert result["error"]["data"]["failure"]["server"] == "missing", result
        assert not dead(c[0]["pid"])
        # A session found in the store, by another process, is given its servers there.
        other = subprocess.Popen([GROUND, "code"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            log4 = tmp / "d.jsonl"
            result = request(other, 1, "session/resume", {"sessionId": sid2, "cwd": str(tmp), "mcpServers": [server("elsewhere", log4)]})
            assert "result" in result, result
            d = records(log4)
            assert d[0]["cwd"] == str(tmp)
            other.stdin.close()
            assert other.wait(timeout=8) == 0, other.stderr.read()
            assert dead(d[0]["pid"])
        finally:
            if other.poll() is None:
                other.kill(); other.wait()
        # EOF shuts the remaining session down and reaps its child.
        proc.stdin.close()
        assert proc.wait(timeout=8) == 0, proc.stderr.read()
        assert dead(c[0]["pid"])
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
print("Ground ACP: session ownership, resume, paginated discovery, env/cwd, rollback, validation and EOF cleanup passed")
