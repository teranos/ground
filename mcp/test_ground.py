"""ACP drives the real Ground harness, which owns each MCP subprocess."""
import json
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import select
import subprocess
import sys
import tempfile
import threading

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


class Peer(BaseHTTPRequestHandler):
    """A Streamable HTTP MCP server on loopback, as libmcp's own test_http.py speaks it."""
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.seen.append((req["method"], self.headers.get("Authorization")))
        result = {"resultType": "complete"}
        if req["method"] == "server/discover":
            result.update(supportedVersions=["2026-07-28"], capabilities={"tools": {}})
        elif req["method"] == "tools/list":
            result["tools"] = [{"name": "remote", "inputSchema": {"type": "object"}}]
        wire = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(wire)))
        self.end_headers()
        self.wfile.write(wire)


def http(name, url, headers):
    return {"type": "http", "name": name, "url": url, "headers": headers}


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp).resolve()  # the server reports getcwd, and macOS's temp dir is a link
    proc = subprocess.Popen([GROUND, "code"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        init = request(proc, 1, "initialize", {"protocolVersion": 1})
        # "Agent supports McpServer::Http": libmcp's Streamable HTTP client.
        assert init["result"]["agentCapabilities"]["mcpCapabilities"] == {"http": True}, init
        peer = ThreadingHTTPServer(("127.0.0.1", 0), Peer)
        peer.seen = []
        threading.Thread(target=peer.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{peer.server_port}/mcp"
        # A session's http server is reached at its url, its bearer token the
        # Authorization header the client named, and its tools discovered.
        result = request(proc, 20, "session/new", {"cwd": str(tmp), "mcpServers": [http("far", url, [{"name": "Authorization", "value": "Bearer t0k"}])]})
        assert "result" in result, result
        assert ("server/discover", "Bearer t0k") in peer.seen and ("tools/list", "Bearer t0k") in peer.seen, peer.seen
        assert "result" in request(proc, 21, "session/close", {"sessionId": result["result"]["sessionId"]})
        # No headers, no token.
        result = request(proc, 22, "session/new", {"cwd": str(tmp), "mcpServers": [http("bare", url, [])]})
        assert "result" in result, result
        assert peer.seen[-1] == ("tools/list", None), peer.seen
        assert "result" in request(proc, 23, "session/close", {"sessionId": result["result"]["sessionId"]})
        # libmcp sets no header but the bearer token: any other is refused by
        # name, before anything is asked of the server.
        asked = len(peer.seen)
        result = request(proc, 24, "session/new", {"cwd": str(tmp), "mcpServers": [http("far", url, [{"name": "X-Key", "value": "v"}])]})
        assert result["error"]["data"]["failure"]["message"] == "the http MCP server far names the header X-Key; libmcp sets no header but Authorization: Bearer", result
        result = request(proc, 25, "session/new", {"cwd": str(tmp), "mcpServers": [http("far", url, [{"name": "Authorization", "value": "Basic eA=="}])]})
        assert result["error"]["data"]["failure"]["message"] == "the http MCP server far names an Authorization that is not Bearer; libmcp sets no other", result
        assert len(peer.seen) == asked
        # SSE is not advertised, and not taken.
        result = request(proc, 26, "session/new", {"cwd": str(tmp), "mcpServers": [{"type": "sse", "name": "old", "url": url, "headers": []}]})
        assert "SSE" in result["error"]["data"]["failure"]["message"], result
        result = request(proc, 27, "session/new", {"cwd": str(tmp), "mcpServers": [http("nourl", None, [])]})
        assert "error" in result, result
        # libmcp's own refusal crosses intact: plain HTTP off loopback.
        result = request(proc, 28, "session/new", {"cwd": str(tmp), "mcpServers": [http("open", "http://example.invalid/mcp", [])]})
        assert result["error"]["data"]["failure"]["server"] == "open", result
        peer.shutdown()
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
    # A named pipe's end is EOF too, though Darwin's poll never reports it on one.
    fifo = tmp / "in"
    os.mkfifo(fifo)
    rfd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    wfd = os.open(fifo, os.O_WRONLY)
    os.set_blocking(rfd, True)
    named = subprocess.Popen([GROUND, "code"], stdin=rfd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    os.close(rfd)
    try:
        os.write(wfd, (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}}) + "\n").encode())
        os.close(wfd)
        assert named.wait(timeout=8) == 0, named.stderr.read()
        assert json.loads(named.stdout.readline())["id"] == 1
    finally:
        if named.poll() is None:
            named.kill(); named.wait()
print("Ground ACP: session ownership, http servers, resume, paginated discovery, env/cwd, rollback, validation and EOF cleanup, from a pipe and a named pipe, passed")
