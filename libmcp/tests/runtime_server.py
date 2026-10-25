import json
import sys

held = None
cancelled = False


def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def response(req, result):
    send(
        {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {"resultType": "complete", **result},
        }
    )


for line in sys.stdin:
    req = json.loads(line)
    method = req["method"]
    p = req.get("params", {})
    if method == "notifications/cancelled":
        cancelled = True
        if held and held["id"] == p["requestId"]:
            response(held, {"value": "late"})
            held = None
        continue
    if "_meta" not in p:
        # A legacy request, which the client sends when server/discover
        # missed its probe window. Refused on the wire, not by dying: a dead
        # server reads as a closed stream and hides the timeout (#3).
        send({"jsonrpc": "2.0", "id": req.get("id"), "error": {"code": -32601,
              "message": "runtime server speaks 2026-07-28 only; no _meta on " + method}})
        continue
    meta = p["_meta"]
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert meta["io.modelcontextprotocol/clientCapabilities"] == {
        "elicitation": {"form": {}}
    }
    if method == "server/discover":
        response(
            req,
            {
                "supportedVersions": ["2026-07-28"],
                "capabilities": {
                    "tools": {},
                    "resources": {},
                    "prompts": {},
                    "completions": {},
                },
            },
        )
    elif method == "test/hold":
        held = req
    elif method == "test/release":
        response(req, {"value": "second"})
        response(held, {"value": "first"})
        held = None
    elif method == "test/replay":
        send({"jsonrpc": "2.0", "id": p["oldId"], "result": {}})
        response(req, {})
    elif method == "test/cancelled":
        response(req, {"cancelled": cancelled})
    elif method == "tools/call":
        if "inputResponses" not in p:
            response(
                req,
                {
                    "resultType": "input_required",
                    "requestState": "opaque\u0000state☃",
                    "inputRequests": {
                        "question": {
                            "method": "elicitation/create",
                            "params": {
                                "mode": "form",
                                "message": "value?",
                                "requestedSchema": {
                                    "type": "object",
                                    "properties": {"value": {"type": "string"}},
                                },
                            },
                        }
                    },
                },
            )
        else:
            assert p["requestState"] == "opaque\u0000state☃"
            response(
                req,
                {
                    "content": [
                        {
                            "type": "text",
                            "text": p["inputResponses"]["question"]["content"]["value"],
                        }
                    ]
                },
            )
    elif method == "subscriptions/listen":
        meta = {"io.modelcontextprotocol/subscriptionId": req["id"]}
        send(
            {
                "jsonrpc": "2.0",
                "method": "notifications/subscriptions/acknowledged",
                "params": {"_meta": meta, "notifications": p["notifications"]},
            }
        )
        send(
            {
                "jsonrpc": "2.0",
                "method": "notifications/tools/list_changed",
                "params": {"_meta": meta},
            }
        )
    elif method == "test/progress":
        for value in [0.5, 1.0]:
            send(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": p["_meta"]["progressToken"],
                        "progress": value,
                        "total": 1.0,
                    },
                }
            )
        response(req, {})
    else:
        response(req, {"value": "ok"})
