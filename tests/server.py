"""Deterministic wire peer; assertions here also turn child exit into failure."""
import json
import os
import signal
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "modern"
initialized = False
modern = mode not in {"legacy", "silent-probe", "legacy-error", "old-version", "bad-version"}
log = os.environ.get("LIBMCP_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"event": "start", "pid": os.getpid(), "cwd": os.getcwd(), "value": os.environ.get("LIBMCP_TEST")}) + "\n")


def send(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"event": "request", "method": method, "params": req.get("params")}) + "\n")
    if not method:  # client's reply to a legacy server request
        assert req["id"] in ("ping", "unsupported")
        assert ("result" in req) if req["id"] == "ping" else req["error"]["code"] == -32601
        continue
    params = req.get("params", {})
    ident = req.get("id")
    if method == "server/discover":
        if mode == "silent-probe":
            continue
        if not modern:
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32602, "message": "initialize first"}})
            continue
        if mode == "modern-version-error":
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32022, "message": "unsupported", "data": {"supported": ["2099-01-01"]}}})
            continue
        if mode == "large-error":
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32022, "message": "☃" * 9000, "data": {"sacred": True}}})
            continue
        assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
        initialized = True
        result = {"resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": {"tools": {}, "resources": {}, "prompts": {}}}
    elif method == "initialize":
        assert not modern and not initialized
        initialized = True
        result = {"protocolVersion": "2099-01-01" if mode == "bad-version" else "2024-11-05" if mode == "old-version" else "2025-11-25", "capabilities": {"tools": {}, "resources": {}, "prompts": {}}, "serverInfo": {"name": "test", "version": "1"}}
    elif method == "notifications/cancelled":
        continue
    elif method == "notifications/initialized":
        assert initialized and not modern
        continue
    else:
        assert initialized
        if modern:
            meta = params["_meta"]
            assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
            assert meta["io.modelcontextprotocol/clientCapabilities"] == {}
            assert meta["io.modelcontextprotocol/clientInfo"]["name"]
        if method == "test/timeout":
            time.sleep(1)
            continue
        if method == "test/eof":
            sys.exit(0)
        if method == "test/partial":
            sys.stdout.write('{"jsonrpc":'); sys.stdout.flush(); sys.exit(0)
        if method == "test/invalid":
            sys.stdout.write('{bad json}\n'); sys.stdout.flush(); continue
        if method == "test/utf8":
            sys.stdout.buffer.write(b'{"jsonrpc":"2.0","method":"\xff"}\n'); sys.stdout.flush(); continue
        if method == "test/trailing":
            sys.stdout.write('{} garbage\n'); sys.stdout.flush(); continue
        if method == "test/wrong-id":
            send({"jsonrpc": "2.0", "id": 999, "result": {}}); continue
        if method == "test/both":
            send({"jsonrpc": "2.0", "id": ident, "result": {}, "error": {"code": 1, "message": "bad"}}); continue
        if method == "test/null-result":
            send({"jsonrpc": "2.0", "id": ident, "result": None}); continue
        if method == "test/bad-error":
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": "1", "message": 42}}); continue
        if method == "test/bad-result-type":
            send({"jsonrpc": "2.0", "id": ident, "result": {"resultType": "banana"}}); continue
        if method == "test/oversize":
            sys.stdout.write("x" * 10000 + "\n"); sys.stdout.flush(); continue
        if method == "test/flood":
            while True:
                send({"jsonrpc": "2.0", "method": "notifications/message", "params": {}})
        if method == "test/remote":
            # Retain whitespace, Unicode, data and exact error code at the ABI.
            sys.stdout.write(' {"jsonrpc":"2.0", "id":%d, "error":{"code":-32001,"message":"sacred ☃","data":{"nested":[0,null,false]}}}\n' % ident)
            sys.stdout.flush(); continue
        if method == "resources/read" and params.get("uri") == "test:input":
            result = {"resultType": "input_required", "requestState": "opaque", "inputRequests": {}}
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"data": "hello"}})
            if not modern:
                send({"jsonrpc": "2.0", "id": "ping", "method": "ping"})
                send({"jsonrpc": "2.0", "id": "unsupported", "method": "sampling/createMessage", "params": {}})
            result = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}], "nextCursor": "next"} if "cursor" not in params else {"tools": []}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": json.dumps(params["arguments"], ensure_ascii=False)}], "isError": params["name"] == "fail"}
        elif method in ("resources/list", "prompts/list"):
            result = {method.split("/")[0]: []}
        elif method == "resources/read":
            result = {"contents": [{"uri": params["uri"], "text": "resource"}]}
        elif method == "prompts/get":
            result = {"messages": [], "description": params["name"]}
        elif method == "test/environment":
            result = {"value": os.environ.get("LIBMCP_TEST"), "cwd": os.getcwd()}
        elif method == "test/nonzero":
            sys.exit(17)
        elif method == "test/hang-close":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            result = {}
            send({"jsonrpc": "2.0", "id": ident, "result": result})
            while True:
                time.sleep(1)
        else:
            result = {"echo": params}
        if modern:
            result.setdefault("resultType", "complete")
    wire = json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}, ensure_ascii=False, separators=(",", ":")) + "\n"
    # Fragment actual protocol messages across arbitrary byte boundaries.
    if mode == "fragment":
        for b in wire.encode():
            sys.stdout.buffer.write(bytes([b])); sys.stdout.flush()
    else:
        sys.stdout.write(wire); sys.stdout.flush()
    if mode == "exit-after-discover":
        sys.exit(0)
