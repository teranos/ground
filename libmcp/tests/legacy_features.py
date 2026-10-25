import json
import sys


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    if method == "server/discover":
        send(
            {
                "jsonrpc": "2.0",
                "id": req["id"],
                "error": {"code": -32601, "message": "legacy"},
            }
        )
    elif method == "initialize":
        assert req["params"]["capabilities"] == {
            "roots": {},
            "sampling": {},
            "elicitation": {},
        }
        send(
            {
                "jsonrpc": "2.0",
                "id": req["id"],
                "result": {
                    "protocolVersion": "2025-06-18",
                    "serverInfo": {"name": "legacy-features", "version": "1"},
                    "capabilities": {},
                },
            }
        )
    elif method == "notifications/initialized":
        continue
    elif method == "test/client_features":
        original = req["id"]
        for name, params, expected in [
            ("roots/list", {}, "roots"),
            ("sampling/createMessage", {"messages": [], "maxTokens": 1}, "model"),
            (
                "elicitation/create",
                {"message": "value?", "requestedSchema": {"type": "object"}},
                "action",
            ),
        ]:
            send({"jsonrpc": "2.0", "id": name, "method": name, "params": params})
            reply = json.loads(sys.stdin.readline())
            assert reply["id"] == name and expected in reply.get("result", {}), reply
        send({"jsonrpc": "2.0", "id": original, "result": {}})
