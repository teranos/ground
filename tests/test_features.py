import ctypes as C
import json
from pathlib import Path
import sys
import unittest
import test_runtime as rt

lib = rt.lib
base = rt.base


class LegacyFeatures(unittest.TestCase):
    def test_explicit_legacy_features(self):
        options = base.Options()
        lib.mcp_options_init(C.byref(options))
        server = Path(__file__).with_name("legacy_features.py").resolve()
        argv = (C.c_char_p * 3)(sys.executable.encode(), str(server).encode(), None)
        options.command = argv[0]
        options.argv = argv
        features = rt.Features()
        lib.mcp_features_init(C.byref(features))
        features.capabilities_json = b'{"roots":{},"sampling":{},"elicitation":{}}'
        calls = []

        def handle(_, method, params, response, error):
            calls.append(method)
            result = {
                b"roots/list": {"roots": [{"uri": "file:///tmp"}]},
                b"sampling/createMessage": {
                    "model": "host",
                    "role": "assistant",
                    "content": {"type": "text", "text": "sample"},
                },
                b"elicitation/create": {
                    "action": "accept",
                    "content": {"value": "yes"},
                },
            }[method]
            return lib.mcp_response_set(response, json.dumps(result).encode(), error)

        handler = rt.HANDLER(handle)
        features.on_request = handler
        client = C.c_void_p()
        response = base.Response()
        error = base.Error()
        try:
            self.assertEqual(
                lib.mcp_client_open_ex(
                    C.byref(options),
                    C.byref(features),
                    C.byref(client),
                    C.byref(response),
                    C.byref(error),
                ),
                0,
                error.message,
            )
            lib.mcp_response_free(C.byref(response))
            self.assertEqual(
                lib.mcp_client_request(
                    client,
                    b"test/client_features",
                    b"{}",
                    C.byref(response),
                    C.byref(error),
                ),
                0,
                error.message,
            )
            self.assertEqual(
                calls, [b"roots/list", b"sampling/createMessage", b"elicitation/create"]
            )
        finally:
            lib.mcp_response_free(C.byref(response))
            if client:
                self.assertEqual(
                    lib.mcp_client_close(client, C.byref(error)), 0, error.message
                )


if __name__ == "__main__":
    unittest.main()
