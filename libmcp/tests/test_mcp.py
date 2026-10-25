"""Exercise the installed C ABI against real subprocesses, without an SDK."""
import ctypes as C
import json
import os
from pathlib import Path
import signal
import sys
import time
import unittest

lib = C.CDLL(str(Path(sys.argv.pop(1)).resolve()))
SERVER = str(Path(__file__).with_name("server.py").resolve())
CALLBACK = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_size_t)


class Error(C.Structure):
    _fields_ = [("code", C.c_int), ("system_errno", C.c_int), ("child_status", C.c_int),
                ("cleanup_code", C.c_int), ("cleanup_errno", C.c_int), ("cleanup_child_status", C.c_int),
                ("message", C.c_char_p), ("cleanup_message", C.c_char_p)]


class Response(C.Structure):
    _fields_ = [("json", C.c_void_p), ("length", C.c_size_t), ("error_code", C.c_int64)]

    def raw(self):
        return C.string_at(self.json, self.length) if self.json else b""

    def value(self):
        return json.loads(self.raw())


class Options(C.Structure):
    _fields_ = [("command", C.c_char_p), ("argv", C.POINTER(C.c_char_p)),
                ("envp", C.POINTER(C.c_char_p)), ("cwd", C.c_char_p),
                ("client_name", C.c_char_p), ("client_version", C.c_char_p),
                ("protocol", C.c_int), ("timeout_ms", C.c_int),
                ("probe_timeout_ms", C.c_int), ("shutdown_timeout_ms", C.c_int),
                ("max_message_bytes", C.c_size_t), ("on_message", CALLBACK), ("context", C.c_void_p)]


lib.mcp_options_init.argtypes = [C.POINTER(Options)]
lib.mcp_client_open.argtypes = [C.POINTER(Options), C.POINTER(C.c_void_p), C.POINTER(Response), C.POINTER(Error)]
lib.mcp_client_close.argtypes = [C.c_void_p, C.POINTER(Error)]
lib.mcp_client_request.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.POINTER(Response), C.POINTER(Error)]
lib.mcp_response_free.argtypes = [C.POINTER(Response)]
lib.mcp_client_protocol_version.argtypes = [C.c_void_p]
lib.mcp_client_protocol_version.restype = C.c_char_p
for f in ("mcp_tools_list", "mcp_resources_list", "mcp_resources_read", "mcp_prompts_list"):
    getattr(lib, f).argtypes = [C.c_void_p, C.c_char_p, C.POINTER(Response), C.POINTER(Error)]
for f in ("mcp_tools_call", "mcp_prompts_get"):
    getattr(lib, f).argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.POINTER(Response), C.POINTER(Error)]


class MCP(unittest.TestCase):
    def setUp(self):
        self.client = C.c_void_p()
        self.response = Response()
        self.error = Error()
        self.events = []
        self.callback = CALLBACK(lambda _, p, n: self.events.append(json.loads(C.string_at(p, n))))

    def tearDown(self):
        lib.mcp_response_free(C.byref(self.response))
        if self.client:
            # Explicit tests assert the shutdown result where it is relevant.
            lib.mcp_client_close(self.client, C.byref(self.error))

    def open(self, mode="modern", **changes):
        self.options = Options()
        lib.mcp_options_init(C.byref(self.options))
        self.argv = (C.c_char_p * 4)(sys.executable.encode(), SERVER.encode(), mode.encode(), None)
        self.options.command = self.argv[0]
        self.options.argv = self.argv
        self.options.on_message = self.callback
        # timeout_ms stays 400: test_deadline_keeps_connection_usable measures
        # it. The probe and shutdown windows are wide enough for an interpreter
        # to start on a loaded machine (#3); silent-probe still falls back.
        self.options.timeout_ms = 400
        self.options.probe_timeout_ms = 2000
        self.options.shutdown_timeout_ms = 1000
        for k, v in changes.items():
            setattr(self.options, k, v)
        return lib.mcp_client_open(C.byref(self.options), C.byref(self.client), C.byref(self.response), C.byref(self.error))

    def request(self, method, params=b"{}"):
        lib.mcp_response_free(C.byref(self.response))
        return lib.mcp_client_request(self.client, method.encode(), params, C.byref(self.response), C.byref(self.error))

    def close(self):
        rc = lib.mcp_client_close(self.client, C.byref(self.error))
        self.client = C.c_void_p()
        return rc

    def test_modern_roundtrip_and_helpers(self):
        self.assertEqual(self.open(), 0, self.error.message)
        self.assertEqual(lib.mcp_client_protocol_version(self.client), b"2026-07-28")
        lib.mcp_response_free(C.byref(self.response))
        self.assertEqual(lib.mcp_tools_list(self.client, None, C.byref(self.response), C.byref(self.error)), 0)
        self.assertEqual(self.response.value()["result"]["nextCursor"], "next")
        self.assertEqual(len(self.events), 1)
        lib.mcp_response_free(C.byref(self.response))
        self.assertEqual(lib.mcp_tools_list(self.client, b"next", C.byref(self.response), C.byref(self.error)), 0)
        self.assertEqual(self.response.value()["result"]["tools"], [])
        for function, args in [("mcp_resources_list", [None]), ("mcp_resources_read", [b"file:///a"]), ("mcp_prompts_list", [None]), ("mcp_prompts_get", [b"hi", b'{}'])]:
            lib.mcp_response_free(C.byref(self.response))
            self.assertEqual(getattr(lib, function)(self.client, *args, C.byref(self.response), C.byref(self.error)), 0)
        self.assertEqual(self.close(), 0, self.error.message)

    def test_legacy_negotiation_and_server_requests(self):
        self.assertEqual(self.open("legacy"), 0, self.error.message)
        self.assertEqual(lib.mcp_client_protocol_version(self.client), b"2025-11-25")
        self.assertEqual(self.request("tools/list"), 0)
        self.assertEqual(len(self.events), 4)  # probe error, log, ping, unsupported request
        self.assertEqual(self.request("ping"), 0)  # ensures the peer consumed replies
        self.assertEqual(self.close(), 0, self.error.message)

    def test_probe_timeout_falls_back(self):
        self.assertEqual(self.open("silent-probe"), 0, self.error.message)
        self.assertEqual(self.request("ping"), 0)
        self.assertEqual(self.close(), 0)

    def test_explicit_legacy_and_old_version(self):
        self.assertEqual(self.open("old-version", protocol=2), 0, self.error.message)
        self.assertEqual(lib.mcp_client_protocol_version(self.client), b"2024-11-05")

    def test_no_downgrade_from_modern_error(self):
        self.assertEqual(self.open("modern-version-error"), 7)
        self.assertEqual(self.response.error_code, -32022)
        self.assertFalse(self.client)

    def test_unknown_version_fails(self):
        self.assertEqual(self.open("bad-version", protocol=2), 12)
        self.assertIn("2099-01-01", self.response.raw().decode())
        self.assertFalse(self.client)

    def test_fragmented_unicode_and_escaped_params(self):
        self.assertEqual(self.open("fragment"), 0)
        params = json.dumps({"nested": {"text": '☃\\\n"; $(touch /tmp/libmcp-should-not-exist)'}}).encode()
        self.assertEqual(self.request("test/echo", params), 0)
        self.assertEqual(self.response.value()["result"]["echo"]["nested"], json.loads(params)["nested"])

    def test_errors_preserve_wire_and_connection(self):
        self.assertEqual(self.open(), 0)
        self.assertEqual(self.request("test/remote"), 7)
        self.assertEqual(self.error.code, 7)
        self.assertEqual(self.response.error_code, -32001)
        self.assertTrue(self.response.raw().startswith(b' {"jsonrpc"'))
        self.assertEqual(self.response.value()["error"]["data"], {"nested": [0, None, False]})
        self.assertEqual(self.request("resources/read", b'{"uri":"test:input"}'), 10)
        self.assertEqual(self.response.value()["result"]["requestState"], "opaque")
        lib.mcp_response_free(C.byref(self.response))
        self.assertEqual(lib.mcp_tools_call(self.client, b"fail", b'{}', C.byref(self.response), C.byref(self.error)), 11)
        self.assertEqual(self.request("ping"), 0)

    def test_malformed_frame_is_preserved(self):
        self.assertEqual(self.open(), 0)
        self.assertEqual(self.request("test/invalid"), 6)
        self.assertEqual(self.response.raw(), b'{bad json}')

    def test_truncated_frame_is_preserved(self):
        self.assertEqual(self.open(), 0)
        self.assertEqual(self.request("test/partial"), 6)
        self.assertEqual(self.response.raw(), b'{"jsonrpc":')

    def test_bad_params_do_not_break_connection(self):
        self.assertEqual(self.open(), 0)
        for params in (b"[]", b"null", b"{} trailing", b"{", b'123', b'{"_meta":false}', b'{"_meta":null}', b'{"_meta":{"progressToken":null}}'):
            self.assertEqual(self.request("test/echo", params), 1, params)
        self.assertEqual(self.request("ping"), 0)

    def test_environment_and_cwd(self):
        env = (C.c_char_p * 2)(b"LIBMCP_TEST=sacred", None)
        self.assertEqual(self.open(envp=env, cwd=b"/tmp"), 0, self.error.message)
        self.assertEqual(self.request("test/environment"), 0)
        self.assertEqual(self.response.value()["result"]["value"], "sacred")
        self.assertEqual(self.response.value()["result"]["cwd"], os.path.realpath("/tmp"))

    def test_invalid_options_and_exec_failure(self):
        self.assertEqual(self.open(timeout_ms=0), 1)
        self.assertEqual(self.open(command=b"/does/not/exist"), 3)
        self.assertEqual(self.error.system_errno, 2)
        self.assertFalse(self.client)

    def test_deadline_keeps_connection_usable(self):
        self.assertEqual(self.open(), 0)
        start = time.monotonic()
        self.assertEqual(self.request("test/timeout"), 4)
        self.assertLess(time.monotonic() - start, 0.9)
        time.sleep(0.6)  # Let the deliberately blocking legacy test peer resume.
        self.assertEqual(self.request("ping"), 0)

    def test_notification_flood_has_absolute_deadline(self):
        self.assertEqual(self.open(), 0)
        start = time.monotonic()
        self.assertEqual(self.request("test/flood"), 4)
        self.assertLess(time.monotonic() - start, 0.9)

    def test_size_limit(self):
        self.assertEqual(self.open(max_message_bytes=1024), 0)
        self.assertEqual(self.request("test/oversize"), 9)
        self.assertEqual(self.request("ping"), 8)

    def test_shutdown_reports_forced_termination(self):
        self.assertEqual(self.open(shutdown_timeout_ms=50), 0)  # the window this test measures
        self.assertEqual(self.request("test/hang-close"), 0)
        start = time.monotonic()
        self.assertEqual(self.close(), 4)
        self.assertLess(time.monotonic() - start, 0.8)

    def test_shutdown_reports_exit_code(self):
        self.assertEqual(self.open(), 0)
        self.assertEqual(self.request("test/nonzero"), 5)
        self.assertEqual(self.close(), 3)
        self.assertEqual(self.error.child_status, 17 << 8)


def wire_failure(name, status):
    def test(self):
        self.assertEqual(self.open(), 0)
        self.assertEqual(self.request("test/" + name), status, self.error.message)
        self.assertEqual(self.request("ping"), 8)
    return test


for name, status in [("eof", 5), ("partial", 6), ("invalid", 6), ("trailing", 6), ("wrong-id", 6), ("both", 6), ("null-result", 6), ("bad-error", 6), ("bad-result-type", 6), ("utf8", 6)]:
    setattr(MCP, "test_wire_" + name.replace("-", "_"), wire_failure(name, status))

if __name__ == "__main__":
    # A library must not change the embedding process's SIGPIPE disposition.
    previous = signal.getsignal(signal.SIGPIPE)
    program = unittest.main(exit=False)
    assert signal.getsignal(signal.SIGPIPE) == previous
    sys.exit(not program.result.wasSuccessful())
