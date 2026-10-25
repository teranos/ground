"""v0.2 contract: multiplexing, explicit capabilities, MRTR and subscriptions."""

import ctypes as C
import json
from pathlib import Path
import sys
import time
import unittest
import test_mcp as base

lib = base.lib
HANDLER = C.CFUNCTYPE(
    C.c_int,
    C.c_void_p,
    C.c_char_p,
    C.c_char_p,
    C.POINTER(base.Response),
    C.POINTER(base.Error),
)


class Features(C.Structure):
    _fields_ = [
        ("capabilities_json", C.c_char_p),
        ("on_request", HANDLER),
        ("context", C.c_void_p),
        ("max_pending", C.c_size_t),
    ]


lib.mcp_features_init.argtypes = [C.POINTER(Features)]
lib.mcp_client_open_ex.argtypes = [
    C.POINTER(base.Options),
    C.POINTER(Features),
    C.POINTER(C.c_void_p),
    C.POINTER(base.Response),
    C.POINTER(base.Error),
]
lib.mcp_client_submit.argtypes = [
    C.c_void_p,
    C.c_char_p,
    C.c_char_p,
    C.c_int,
    C.POINTER(C.c_void_p),
    C.POINTER(base.Error),
]
lib.mcp_client_poll.argtypes = [C.c_void_p, C.c_int, C.POINTER(base.Error)]
lib.mcp_request_status.argtypes = [C.c_void_p]
lib.mcp_request_id.argtypes = [C.c_void_p]
lib.mcp_request_id.restype = C.c_int64
lib.mcp_request_take.argtypes = [
    C.c_void_p,
    C.POINTER(base.Response),
    C.POINTER(base.Error),
]
lib.mcp_request_cancel.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(base.Error)]
lib.mcp_request_resume.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(base.Error)]
lib.mcp_request_destroy.argtypes = [C.c_void_p, C.POINTER(base.Error)]
lib.mcp_client_call.argtypes = lib.mcp_client_request.argtypes
lib.mcp_response_set.argtypes = [
    C.POINTER(base.Response),
    C.c_char_p,
    C.POINTER(base.Error),
]
SERVER = str(Path(__file__).with_name("runtime_server.py").resolve())


class Runtime(unittest.TestCase):
    def setUp(self):
        self.client = C.c_void_p()
        self.error = base.Error()
        self.response = base.Response()
        self.opts = base.Options()
        lib.mcp_options_init(C.byref(self.opts))
        # Wide enough for an interpreter to start on a loaded machine: a
        # 300 ms probe missed once under a parallel build (#3). Tests that
        # want a timeout ask for one per request with ms=.
        self.opts.timeout_ms = 5000
        self.opts.probe_timeout_ms = 5000
        self.opts.shutdown_timeout_ms = 1000
        self.argv = (C.c_char_p * 3)(sys.executable.encode(), SERVER.encode(), None)
        self.opts.command = self.argv[0]
        self.opts.argv = self.argv
        self.events = []
        self.calls = []
        self.callback = base.CALLBACK(
            lambda _, p, n: self.events.append(json.loads(C.string_at(p, n)))
        )
        self.opts.on_message = self.callback
        self.features = Features()
        lib.mcp_features_init(C.byref(self.features))
        self.features.capabilities_json = b'{"elicitation":{"form":{}}}'

        def handler(_, method, params, response, error):
            self.calls.append((method.decode(), json.loads(params)))
            return lib.mcp_response_set(
                response, b'{"action":"accept","content":{"value":"yes"}}', error
            )

        self.handler = HANDLER(handler)
        self.features.on_request = self.handler
        self.assertEqual(
            lib.mcp_client_open_ex(
                C.byref(self.opts),
                C.byref(self.features),
                C.byref(self.client),
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
            self.error.message,
        )
        lib.mcp_response_free(C.byref(self.response))
        self.requests = []

    def tearDown(self):
        for request in self.requests:
            lib.mcp_request_destroy(request, C.byref(self.error))
        lib.mcp_response_free(C.byref(self.response))
        if self.client:
            self.assertEqual(
                lib.mcp_client_close(self.client, C.byref(self.error)),
                0,
                self.error.message,
            )

    def submit(self, method, params=None, ms=500):
        req = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_submit(
                self.client,
                method.encode(),
                json.dumps(params or {}).encode(),
                ms,
                C.byref(req),
                C.byref(self.error),
            ),
            0,
            self.error.message,
        )
        self.requests.append(req)
        return req

    def finish(self, req):
        until = time.monotonic() + 3
        while lib.mcp_request_status(req) == 13:
            self.assertLess(time.monotonic(), until)
            self.assertEqual(
                lib.mcp_client_poll(self.client, 20, C.byref(self.error)),
                0,
                self.error.message,
            )
        return lib.mcp_request_status(req)

    def take(self, req):
        lib.mcp_response_free(C.byref(self.response))
        rc = lib.mcp_request_take(req, C.byref(self.response), C.byref(self.error))
        return rc, self.response.value() if self.response.json else None

    def test_out_of_order_responses(self):
        a = self.submit("test/hold")
        b = self.submit("test/release")
        self.assertEqual(self.finish(b), 0)
        self.assertEqual(self.finish(a), 0)
        self.assertEqual(self.take(a)[1]["result"]["value"], "first")
        self.assertEqual(self.take(b)[1]["result"]["value"], "second")

    def test_explicit_cancel_and_late_response(self):
        a = self.submit("test/hold")
        lib.mcp_client_poll(self.client, 0, C.byref(self.error))
        self.assertEqual(
            lib.mcp_request_cancel(a, b"user interrupted", C.byref(self.error)), 0
        )
        self.assertEqual(lib.mcp_request_status(a), 14)
        b = self.submit("test/cancelled")
        self.assertEqual(self.finish(b), 0)
        self.assertTrue(self.take(b)[1]["result"]["cancelled"])
        self.assertEqual(self.finish(self.submit("test/echo")), 0)

    def test_timeout_cancels_one_request(self):
        a = self.submit("test/hold", ms=50)
        self.assertEqual(self.finish(a), 4)
        self.assertEqual(self.finish(self.submit("test/cancelled")), 0)
        self.assertTrue(self.take(self.requests[-1])[1]["result"]["cancelled"])

    def test_mrtr_resume_uses_fresh_id_and_opaque_state(self):
        req = self.submit("tools/call", {"name": "interactive", "arguments": {}})
        self.assertEqual(self.finish(req), 10)
        old = lib.mcp_request_id(req)
        self.assertEqual(
            lib.mcp_request_resume(
                req,
                b'{"question":{"action":"accept","content":{"value":"yes"}}}',
                C.byref(self.error),
            ),
            0,
            self.error.message,
        )
        self.assertNotEqual(lib.mcp_request_id(req), old)
        self.assertEqual(self.finish(req), 0)
        self.assertEqual(self.take(req)[1]["result"]["content"][0]["text"], "yes")

    def test_mrtr_callbacks_and_capabilities(self):
        self.assertEqual(
            lib.mcp_client_call(
                self.client,
                b"tools/call",
                b'{"name":"interactive","arguments":{}}',
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
            self.error.message,
        )
        self.assertEqual(self.calls[0][0], "elicitation/create")
        self.assertEqual(self.response.value()["result"]["content"][0]["text"], "yes")

    def test_subscription_and_parallel_request(self):
        sub = self.submit(
            "subscriptions/listen", {"notifications": {"toolsListChanged": True}}
        )
        for _ in range(10):
            lib.mcp_client_poll(self.client, 10, C.byref(self.error))
        self.assertEqual(lib.mcp_request_status(sub), 13)
        methods = [v["method"] for v in self.events]
        self.assertIn("notifications/subscriptions/acknowledged", methods)
        self.assertIn("notifications/tools/list_changed", methods)
        self.assertEqual(self.finish(self.submit("test/echo")), 0)
        self.assertEqual(lib.mcp_request_cancel(sub, b"done", C.byref(self.error)), 0)

    def test_expired_mrtr_cannot_be_sent(self):
        req = self.submit("tools/call", {"name": "interactive", "arguments": {}}, ms=30)
        self.assertEqual(self.finish(req), 10)
        time.sleep(0.05)
        self.assertEqual(
            lib.mcp_request_resume(req, b'{"question":{}}', C.byref(self.error)), 4
        )
        self.assertEqual(lib.mcp_request_status(req), 4)

    def test_mrtr_handler_cannot_reenter_client(self):
        attempts = []

        def handler(_, method, params, response, error):
            other = C.c_void_p()
            attempts.append(
                lib.mcp_client_submit(
                    self.client, b"test/echo", b"{}", 100, C.byref(other), error
                )
            )
            if other:
                self.requests.append(other)
            return lib.mcp_response_set(
                response, b'{"action":"accept","content":{"value":"yes"}}', error
            )

        self.handler = HANDLER(handler)
        self.features.on_request = self.handler
        # Features are copied on open; replace the existing callback's behavior through a new client.
        lib.mcp_client_close(self.client, C.byref(self.error))
        self.client = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_open_ex(
                C.byref(self.opts),
                C.byref(self.features),
                C.byref(self.client),
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
        )
        lib.mcp_response_free(C.byref(self.response))
        self.assertEqual(
            lib.mcp_client_call(
                self.client,
                b"tools/call",
                b'{"name":"interactive","arguments":{}}',
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
        )
        self.assertEqual(attempts, [8])

    def test_acknowledged_subscription_outlives_initial_timeout(self):
        sub = self.submit(
            "subscriptions/listen", {"notifications": {"toolsListChanged": True}}, ms=30
        )
        for _ in range(15):
            self.assertEqual(
                lib.mcp_client_poll(self.client, 10, C.byref(self.error)), 0
            )
        self.assertEqual(lib.mcp_request_status(sub), 13)

    def test_duplicate_progress_token_rejected_locally(self):
        a = self.submit("test/hold", {"_meta": {"progressToken": 1}})
        other = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_submit(
                self.client,
                b"test/echo",
                b'{"_meta":{"progressToken":1}}',
                100,
                C.byref(other),
                C.byref(self.error),
            ),
            1,
        )
        self.assertFalse(other)

    def test_handler_error_payload_is_preserved(self):
        def decline(_, method, params, response, error):
            lib.mcp_response_set(
                response,
                b'{"code":-32123,"message":"host declined","data":{"reason":"sacred"}}',
                error,
            )
            return 7

        self.handler = HANDLER(decline)
        self.features.on_request = self.handler
        lib.mcp_client_close(self.client, C.byref(self.error))
        self.client = C.c_void_p()
        self.assertEqual(
            lib.mcp_client_open_ex(
                C.byref(self.opts),
                C.byref(self.features),
                C.byref(self.client),
                C.byref(self.response),
                C.byref(self.error),
            ),
            0,
        )
        lib.mcp_response_free(C.byref(self.response))
        self.assertEqual(
            lib.mcp_client_call(
                self.client,
                b"tools/call",
                b'{"name":"interactive","arguments":{}}',
                C.byref(self.response),
                C.byref(self.error),
            ),
            7,
        )
        self.assertEqual(self.response.value()["data"], {"reason": "sacred"})

    def test_old_cancelled_response_after_many_requests(self):
        first = self.submit("test/hold")
        lib.mcp_client_poll(self.client, 0, C.byref(self.error))
        old_id = lib.mcp_request_id(first)
        self.assertEqual(lib.mcp_request_cancel(first, b"done", C.byref(self.error)), 0)
        for _ in range(260):
            req = self.submit("test/hold")
            lib.mcp_client_poll(self.client, 0, C.byref(self.error))
            self.assertEqual(
                lib.mcp_request_cancel(req, b"done", C.byref(self.error)), 0
            )
            self.requests.remove(req)
            lib.mcp_request_destroy(req, None)
        self.assertEqual(self.finish(self.submit("test/replay", {"oldId": old_id})), 0)

    def test_null_subscription_filter_fields_rejected(self):
        for notifications in (
            {"toolsListChanged": None},
            {"resourceSubscriptions": None},
        ):
            other = C.c_void_p()
            self.assertEqual(
                lib.mcp_client_submit(
                    self.client,
                    b"subscriptions/listen",
                    json.dumps({"notifications": notifications}).encode(),
                    100,
                    C.byref(other),
                    C.byref(self.error),
                ),
                1,
            )
            self.assertFalse(other)

    def test_progress_tracking(self):
        req = self.submit("test/progress", {"_meta": {"progressToken": "token"}})
        self.assertEqual(self.finish(req), 0)
        self.assertEqual(
            [
                e["params"]["progress"]
                for e in self.events
                if e["method"] == "notifications/progress"
            ],
            [0.5, 1.0],
        )


if __name__ == "__main__":
    unittest.main()
