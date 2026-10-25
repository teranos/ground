"""Loopback transport contract. Assertions observe actual HTTP bytes."""

import base64
import ctypes as C
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
import unittest
import test_runtime as rt

base = rt.base
lib = rt.lib
lib.mcp_client_open_http.argtypes = [
    C.POINTER(base.Options),
    C.POINTER(rt.Features),
    C.c_char_p,
    C.c_char_p,
    C.POINTER(C.c_void_p),
    C.POINTER(base.Response),
    C.POINTER(base.Error),
]
lib.mcp_client_create_http.argtypes = [
    C.POINTER(base.Options),
    C.POINTER(rt.Features),
    C.c_char_p,
    C.c_char_p,
    C.POINTER(C.c_void_p),
    C.POINTER(base.Error),
]
lib.mcp_client_set_bearer.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(base.Error)]
lib.mcp_client_auth_challenge.argtypes = [C.c_void_p]
lib.mcp_client_auth_challenge.restype = C.c_char_p
lib.mcp_client_http_status.argtypes = [C.c_void_p]
lib.mcp_client_http_status.restype = C.c_long
for name, restype in (
    ("auth_challenge", C.c_char_p),
    ("http_status", C.c_long),
    ("transport_code", C.c_int),
):
    accessor = getattr(lib, "mcp_request_" + name)
    accessor.argtypes = [C.c_void_p]
    accessor.restype = restype
lib.mcp_client_tools_catalog.argtypes = [
    C.c_void_p,
    C.POINTER(base.Response),
    C.POINTER(base.Error),
]


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancellation and header-limit rejection close the connection.

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.observed.append((req, dict(self.headers)))
        method = req["method"]
        ident = req["id"]
        params = req.get("params", {})
        self.server.errors.append(None) if False else None
        result = {"resultType": "complete"}
        status = 200
        headers = {}
        sse = False
        if (
            method == "server/discover"
            and self.headers.get("Authorization") == "Bearer expired"
        ):
            status = 401
            headers["WWW-Authenticate"] = (
                'Bearer resource_metadata="https://example.invalid/meta"'
            )
        elif method == "server/discover":
            result.update(
                supportedVersions=["2026-07-28"],
                capabilities={"tools": {}, "resources": {}, "prompts": {}},
            )
        elif method == "tools/list":
            result["tools"] = [
                {
                    "name": "mirror",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "nested": {
                                "type": "object",
                                "properties": {
                                    "value": {
                                        "type": "string",
                                        "x-mcp-header": "X-Value",
                                    }
                                },
                            }
                        },
                    },
                },
                {
                    "name": "unsafe",
                    "inputSchema": {
                        "properties": {"x": {"x-mcp-header": "Bad\nHeader"}}
                    },
                },
                {
                    "name": "array",
                    "inputSchema": {
                        "properties": {
                            "x": {"items": {"type": "string", "x-mcp-header": "Hidden"}}
                        }
                    },
                },
                {
                    "name": "wrong-type",
                    "inputSchema": {
                        "properties": {"x": {"type": "number", "x-mcp-header": "Float"}}
                    },
                },
                {
                    "name": "duplicate",
                    "inputSchema": {
                        "properties": {
                            "a": {"type": "string", "x-mcp-header": "Same"},
                            "b": {"type": "boolean", "x-mcp-header": "same"},
                        }
                    },
                },
                {
                    "name": "root",
                    "inputSchema": {"type": "string", "x-mcp-header": "Root"},
                },
            ]
        elif method == "tools/call":
            result["content"] = [{"type": "text", "text": "ok"}]
            if params.get("name") == "checked-output":
                result["structuredContent"] = params["arguments"].get("value")
                if params["arguments"].get("error"):
                    result["isError"] = True
        elif method == "resources/read" and "requestState" not in params:
            result = {"resultType": "input_required", "requestState": "next"}
            headers["WWW-Authenticate"] = 'Bearer realm="first-round"'
        elif method == "subscriptions/listen":
            meta = {"io.modelcontextprotocol/subscriptionId": ident}
            messages = [
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/subscriptions/acknowledged",
                    "params": {"_meta": meta, "notifications": params["notifications"]},
                },
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/tools/list_changed",
                    "params": {"_meta": meta},
                },
            ]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for message in messages:
                    data = b"data: " + json.dumps(message).encode() + b"\n\n"
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                    self.wfile.flush()
                for _ in range(30):
                    time.sleep(0.01)
                    self.wfile.write(b"3\r\n:\n\n\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        elif method == "test/sse":
            sse = True
            result["echo"] = "☃"
        elif method == "test/auth":
            status = 401
            headers["WWW-Authenticate"] = (
                'Bearer resource_metadata="https://example.invalid/.well-known/oauth-protected-resource"'
            )
            result = {"message": "expired"}
        elif method == "test/forbidden":
            status = 403
            headers["WWW-Authenticate"] = 'Bearer error="insufficient_scope"'
        elif method in ("test/challenges", "test/challenge-limit"):
            status = 401
        elif method == "test/interim":
            self.send_response_only(103)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("WWW-Authenticate", 'Bearer realm="interim"')
            self.end_headers()
        elif method == "test/disconnect":
            self.close_connection = True
            return
        elif method == "test/redirect":
            status = 302
            headers["Location"] = "/stolen"
            result = {"message": "redirected"}
        elif method == "test/http-error":
            status = 400
        elif method == "test/status-error":
            status = 503
        elif method == "test/truncated":
            sse = True
        elif method == "test/hold":
            time.sleep(0.3)
        wire = json.dumps(
            {"jsonrpc": "2.0", "id": ident, "result": result}, ensure_ascii=False
        ).encode()
        if method == "test/http-error":
            wire = json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": ident,
                    "error": {"code": -32602, "message": "invalid"},
                }
            ).encode()
        if method == "test/truncated":
            wire = b": comment\n\n"
        elif sse:
            wire = (
                b"\xef\xbb\xbf: keepalive\r\n\r\nevent: message\r\ndata: "
                + wire
                + b"\r\n\r\n"
            )
        self.send_response(status)
        if method != "resources/read" or "requestState" not in params:
            self.send_header(
                "Content-Type",
                "text/plain"
                if method == "test/content-type"
                else "text/event-stream"
                if sse
                else "application/json",
            )
        for k, v in headers.items():
            self.send_header(k, v)
        if method == "test/challenges":
            self.send_header("WWW-Authenticate", 'Basic realm="one,two"')
            self.send_header("WWW-Authenticate", 'Bearer realm="three"')
        if method == "test/challenge-limit":
            for _ in range(2):
                self.send_header("WWW-Authenticate", 'Bearer realm="' + "x" * 600 + '"')
        self.send_header("Content-Length", str(len(wire)))
        self.end_headers()
        try:
            if sse:
                for i in range(0, len(wire), 3):
                    self.wfile.write(wire[i : i + 3])
                    self.wfile.flush()
            else:
                self.wfile.write(wire)
        except (BrokenPipeError, ConnectionResetError):
            pass


class HTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Peer)
        cls.server.observed = []
        cls.server.errors = []
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.client = C.c_void_p()
        self.response = base.Response()
        self.error = base.Error()
        self.opts = base.Options()
        lib.mcp_options_init(C.byref(self.opts))
        self.opts.timeout_ms = 500
        self.opts.probe_timeout_ms = 500
        self.url = f"http://127.0.0.1:{self.server.server_port}/mcp".encode()
        self.assertEqual(
            lib.mcp_client_open_http(
                C.byref(self.opts),
                None,
                self.url,
                b"token",
                C.byref(self.client),
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
            self.error.message,
        )
        lib.mcp_response_free(C.byref(self.response))

    def tearDown(self):
        self.doCleanups()
        lib.mcp_response_free(C.byref(self.response))
        lib.mcp_client_close(self.client, C.byref(self.error))

    def request(self, m, p=None):
        lib.mcp_response_free(C.byref(self.response))
        return lib.mcp_client_request(
            self.client,
            m.encode(),
            json.dumps(p or {}).encode(),
            C.byref(self.response),
            C.byref(self.error),
        )

    def submit(self, method):
        req = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_submit(
                self.client,
                method.encode(),
                b"{}",
                1000,
                C.byref(req),
                C.byref(self.error),
            ),
            0,
            self.error.message,
        )
        self.addCleanup(lib.mcp_request_destroy, req, None)
        return req

    def finish(self, req):
        deadline = time.monotonic() + 2
        while lib.mcp_request_status(req) == 13:
            self.assertLess(time.monotonic(), deadline)
            self.assertEqual(
                lib.mcp_client_poll(self.client, 20, C.byref(self.error)),
                0,
                self.error.message,
            )
        return lib.mcp_request_status(req)

    def test_request_diagnostics_survive_other_transfers_and_take(self):
        first = self.submit("test/auth")
        second = self.submit("test/forbidden")
        self.assertEqual(lib.mcp_request_http_status(first), 0)
        self.assertIsNone(lib.mcp_request_auth_challenge(first))
        self.assertEqual(self.finish(first), 16)
        self.assertEqual(self.finish(second), 15)
        self.assertEqual(self.request("ping"), 0)
        for req, status, challenge in (
            (first, 401, b'resource_metadata="https://example.invalid/'),
            (second, 403, b'error="insufficient_scope"'),
        ):
            lib.mcp_response_free(C.byref(self.response))
            self.assertIn(
                lib.mcp_request_take(req, C.byref(self.response), C.byref(self.error)),
                (15, 16),
            )
            self.assertTrue(self.response.json)
            self.assertEqual(lib.mcp_request_http_status(req), status)
            self.assertEqual(lib.mcp_request_transport_code(req), 0)
            self.assertIn(challenge, lib.mcp_request_auth_challenge(req))

    def test_repeated_challenges_preserve_order_and_quoted_commas(self):
        req = self.submit("test/challenges")
        self.assertEqual(self.finish(req), 16)
        self.assertEqual(
            lib.mcp_request_auth_challenge(req),
            b'Basic realm="one,two", Bearer realm="three"',
        )

    def test_interim_headers_do_not_leak_into_final_response(self):
        req = self.submit("test/interim")
        self.assertEqual(self.finish(req), 0)
        self.assertEqual(lib.mcp_request_http_status(req), 200)
        self.assertIsNone(lib.mcp_request_auth_challenge(req))

    def test_transport_failure_is_request_owned(self):
        req = self.submit("test/disconnect")
        self.assertEqual(self.finish(req), 3)
        code = lib.mcp_request_transport_code(req)
        self.assertNotEqual(code, 0)
        self.assertEqual(self.request("ping"), 0)
        self.assertEqual(lib.mcp_request_transport_code(req), code)
        self.assertEqual(lib.mcp_request_http_status(req), 0)

    def test_sse_and_cancel_diagnostics(self):
        req = self.submit("test/sse")
        self.assertEqual(self.finish(req), 0)
        self.assertEqual(lib.mcp_request_http_status(req), 200)
        held = self.submit("test/hold")
        self.assertEqual(lib.mcp_request_cancel(held, b"done", None), 0)
        self.assertEqual(lib.mcp_request_status(held), 14)
        self.assertEqual(lib.mcp_request_http_status(held), 0)
        self.assertEqual(lib.mcp_request_transport_code(held), 0)

    def test_challenges_have_an_aggregate_bound(self):
        lib.mcp_client_close(self.client, None)
        self.opts.max_message_bytes = 1024
        self.assertEqual(
            lib.mcp_client_create_http(
                C.byref(self.opts),
                None,
                self.url,
                None,
                C.byref(self.client),
                C.byref(self.error),
            ),
            0,
        )
        req = self.submit("test/challenge-limit")
        self.assertEqual(self.finish(req), 9)
        self.assertEqual(lib.mcp_request_http_status(req), 401)
        self.assertLessEqual(len(lib.mcp_request_auth_challenge(req)), 1024)

    def test_resume_resets_diagnostics_and_content_type(self):
        req = self.submit("resources/read")
        self.assertEqual(self.finish(req), 10)
        self.assertEqual(lib.mcp_request_http_status(req), 200)
        self.assertEqual(
            lib.mcp_request_auth_challenge(req), b'Bearer realm="first-round"'
        )
        self.assertEqual(lib.mcp_request_resume(req, b"[]", None), 1)
        self.assertEqual(lib.mcp_request_http_status(req), 200)
        self.assertEqual(lib.mcp_request_resume(req, b"{}", None), 0)
        self.assertEqual(lib.mcp_request_http_status(req), 0)
        self.assertEqual(lib.mcp_request_transport_code(req), 0)
        self.assertIsNone(lib.mcp_request_auth_challenge(req))
        # The second response omits Content-Type: the first round cannot supply it.
        self.assertEqual(self.finish(req), 6)
        self.assertEqual(lib.mcp_request_http_status(req), 200)
        self.assertIsNone(lib.mcp_request_auth_challenge(req))

    def test_initial_auth_challenge_and_explicit_discovery(self):
        lib.mcp_client_close(self.client, C.byref(self.error))
        self.client = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_create_http(
                C.byref(self.opts),
                None,
                self.url,
                b"expired",
                C.byref(self.client),
                C.byref(self.error),
            ),
            0,
        )
        self.assertEqual(self.request("server/discover"), 16)
        self.assertIn(b"resource_metadata", lib.mcp_client_auth_challenge(self.client))
        self.assertEqual(
            lib.mcp_client_set_bearer(self.client, b"fresh", C.byref(self.error)), 0
        )
        self.assertEqual(self.request("server/discover"), 0)
        self.assertEqual(self.request("tools/list"), 0)

    def test_headers_and_sse(self):
        self.assertEqual(self.request("test/sse"), 0, self.error.message)
        self.assertEqual(self.response.value()["result"]["echo"], "☃")
        req, h = self.server.observed[-1]
        self.assertEqual(h["Accept"], "application/json, text/event-stream")
        self.assertEqual(
            h["MCP-Protocol-Version"],
            req["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
        )
        self.assertEqual(h["Mcp-Method"], "test/sse")
        self.assertEqual(h["Authorization"], "Bearer token")

    def test_mirrored_headers_and_filtered_catalog(self):
        self.assertEqual(self.request("tools/list"), 0, self.error.message)
        self.assertEqual(
            len(self.response.value()["result"]["tools"]), 6
        )  # raw wire is preserved
        lib.mcp_response_free(C.byref(self.response))
        self.assertEqual(
            lib.mcp_client_tools_catalog(
                self.client, C.byref(self.response), C.byref(self.error)
            ),
            0,
        )
        self.assertEqual([x["name"] for x in self.response.value()], ["mirror"])
        value = " ☃\x00\n"
        self.assertEqual(
            self.request(
                "tools/call",
                {"name": "mirror", "arguments": {"nested": {"value": value}}},
            ),
            0,
            self.error.message,
        )
        h = self.server.observed[-1][1]
        self.assertEqual(h["Mcp-Name"], "mirror")
        self.assertEqual(
            h["Mcp-Param-X-Value"],
            "=?base64?" + base64.b64encode(value.encode()).decode() + "?=",
        )

    def test_empty_mirrored_header_is_present(self):
        self.assertEqual(self.request("tools/list"), 0)
        self.assertEqual(
            self.request(
                "tools/call", {"name": "mirror", "arguments": {"nested": {"value": ""}}}
            ),
            0,
        )
        self.assertIn("Mcp-Param-X-Value", self.server.observed[-1][1])
        self.assertEqual(self.server.observed[-1][1]["Mcp-Param-X-Value"], "")

    def test_subscription_multiplexes_with_calls_and_cancels_by_close(self):
        events = []
        callback = base.CALLBACK(
            lambda _, p, n: events.append(json.loads(C.string_at(p, n)))
        )
        lib.mcp_client_close(self.client, C.byref(self.error))
        self.client = C.c_void_p()
        self.opts.on_message = callback
        self.assertEqual(
            lib.mcp_client_open_http(
                C.byref(self.opts),
                None,
                self.url,
                None,
                C.byref(self.client),
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
        )
        lib.mcp_response_free(C.byref(self.response))
        req = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_submit(
                self.client,
                b"subscriptions/listen",
                b'{"notifications":{"toolsListChanged":true}}',
                50,
                C.byref(req),
                C.byref(self.error),
            ),
            0,
        )
        try:
            until = time.monotonic() + 1
            while len(events) < 2:
                self.assertLess(time.monotonic(), until)
                self.assertEqual(
                    lib.mcp_client_poll(self.client, 10, C.byref(self.error)),
                    0,
                    self.error.message,
                )
            self.assertEqual(self.request("ping"), 0)
            self.assertEqual(lib.mcp_request_status(req), 13)
            self.assertEqual(
                lib.mcp_request_cancel(req, b"done", C.byref(self.error)), 0
            )
            self.assertEqual(lib.mcp_request_status(req), 14)
            self.assertNotEqual(
                self.server.observed[-1][0]["method"], "notifications/cancelled"
            )
        finally:
            lib.mcp_request_destroy(req, None)

    def test_auth_is_host_owned_and_preserved(self):
        self.assertEqual(self.request("test/auth"), 16, self.error.message)
        self.assertEqual(lib.mcp_client_http_status(self.client), 401)
        self.assertIn(b"resource_metadata", lib.mcp_client_auth_challenge(self.client))
        self.assertEqual(self.response.value()["result"]["message"], "expired")
        self.assertEqual(
            lib.mcp_client_set_bearer(self.client, b"new-token", C.byref(self.error)), 0
        )
        self.assertEqual(self.request("ping"), 0)
        self.assertEqual(
            self.server.observed[-1][1]["Authorization"], "Bearer new-token"
        )

    def test_redirect_is_not_followed(self):
        count = len(self.server.observed)
        self.assertEqual(self.request("test/redirect"), 15)
        self.assertEqual(len(self.server.observed), count + 1)

    def test_error_envelope_on_http_400(self):
        self.assertEqual(self.request("test/http-error"), 7)
        self.assertEqual(self.response.error_code, -32602)

    def test_wrong_content_type(self):
        self.assertEqual(self.request("test/content-type"), 6)

    def test_error_status_with_result_is_not_success(self):
        self.assertEqual(self.request("test/status-error"), 15)

    def test_truncated_sse(self):
        self.assertEqual(self.request("test/truncated"), 6)

    def test_http_timeout_leaves_other_requests_usable(self):
        req = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_submit(
                self.client, b"test/hold", b"{}", 30, C.byref(req), C.byref(self.error)
            ),
            0,
        )
        while lib.mcp_request_status(req) == 13:
            self.assertEqual(
                lib.mcp_client_poll(self.client, 20, C.byref(self.error)), 0
            )
        self.assertEqual(lib.mcp_request_status(req), 4)
        lib.mcp_request_destroy(req, None)
        self.assertEqual(self.request("ping"), 0)


if __name__ == "__main__":
    unittest.main()
