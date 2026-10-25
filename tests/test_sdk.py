"""Run explicitly with SDK_PYTHON and SDK_ROOT pinned as in spec/README.md."""

import ctypes as C
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest
import hashlib
from jsonschema import Draft202012Validator
import test_http as http

lib = http.lib
base = http.base
SDK = Path(os.environ["SDK_ROOT"]).resolve()
PYTHON = Path(os.environ["SDK_PYTHON"]).absolute()
FIXTURE = Path(__file__).with_name("sdk_server.py").resolve()
SPEC = Path(__file__).resolve().parents[1] / "spec"
PIN = json.loads((SPEC / "PINNED.json").read_text())
assert (
    subprocess.check_output(
        ["git", "-C", str(SDK), "rev-parse", "HEAD"], text=True
    ).strip()
    == PIN["sdk_commit"]
)
assert (
    hashlib.sha256((SPEC / "2026-07-28.json").read_bytes()).hexdigest()
    == PIN["schema_sha256"]
)
SCHEMA = json.loads((SPEC / "2026-07-28.json").read_text())


def validate(kind, value):
    Draft202012Validator(
        {
            "$schema": SCHEMA["$schema"],
            "$defs": SCHEMA["$defs"],
            "$ref": "#/$defs/" + kind,
        }
    ).validate(value)


class SDKInterop(unittest.TestCase):
    def exercise(self, transport, protocol=0):
        opts = base.Options()
        lib.mcp_options_init(C.byref(opts))
        opts.timeout_ms = 3000
        opts.probe_timeout_ms = 3000
        opts.protocol = protocol
        client = C.c_void_p()
        response = base.Response()
        error = base.Error()
        process = None
        env = dict(os.environ, PYTHONPATH=str(SDK / "src"))
        if transport == "stdio":
            argv = (C.c_char_p * 3)(str(PYTHON).encode(), str(FIXTURE).encode(), None)
            opts.command = argv[0]
            opts.argv = argv
            entries = [f"{k}={v}".encode() for k, v in env.items()]
            envp = (C.c_char_p * (len(entries) + 1))(*entries, None)
            opts.envp = envp
            status = lib.mcp_client_open(
                C.byref(opts), C.byref(client), C.byref(response), C.byref(error)
            )
        else:
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            process = subprocess.Popen(
                [str(PYTHON), str(FIXTURE), transport, str(port)],
                env=env,
                stderr=subprocess.PIPE,
            )
            until = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    if process.poll() is not None:
                        self.fail(process.stderr.read().decode())
                    self.assertLess(time.monotonic(), until)
                    time.sleep(0.02)
            status = lib.mcp_client_open_http(
                C.byref(opts),
                None,
                f"http://127.0.0.1:{port}/mcp".encode(),
                None,
                C.byref(client),
                C.byref(response),
                C.byref(error),
            )
        try:
            self.assertEqual(status, 0, (error.message, response.raw()))
            lib.mcp_response_free(C.byref(response))
            self.assertEqual(
                lib.mcp_tools_list(client, None, C.byref(response), C.byref(error)),
                0,
                (error.message, response.raw()),
            )
            if protocol != 2:
                validate("ListToolsResult", response.value()["result"])
            self.assertEqual(response.value()["result"]["tools"][0]["name"], "sdk-echo")
            lib.mcp_response_free(C.byref(response))
            self.assertEqual(
                lib.mcp_tools_call(
                    client,
                    b"sdk-echo",
                    '{"value":"SDK ☃"}'.encode(),
                    C.byref(response),
                    C.byref(error),
                ),
                0,
                (error.message, response.raw()),
            )
            if protocol != 2:
                validate("CallToolResult", response.value()["result"])
            self.assertEqual(response.value()["result"]["content"][0]["text"], "SDK ☃")
        finally:
            lib.mcp_response_free(C.byref(response))
            if client:
                self.assertEqual(
                    lib.mcp_client_close(client, C.byref(error)), 0, error.message
                )
            if process:
                process.terminate()
                process.wait(timeout=5)
                stderr = process.stderr.read().decode()
                process.stderr.close()
                self.assertNotIn("Traceback", stderr, stderr)

    def test_modern_stdio(self):
        self.exercise("stdio")

    def test_legacy_stdio(self):
        self.exercise("stdio", 2)

    def test_modern_http_json(self):
        self.exercise("json")

    def test_modern_http_sse(self):
        self.exercise("sse")


if __name__ == "__main__":
    unittest.main()
