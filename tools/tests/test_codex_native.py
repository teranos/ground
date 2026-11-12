"""Exercise the compiled Ground hook against an independent Unix WebSocket peer."""
import base64
from contextlib import closing
import hashlib
import json
import os
import platform
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import tempfile
import time
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "ground_hook"
MIGRATION = ROOT / "migrations/20261109_001_codex_effort_checks.sql"
SAND = ROOT / "build" / ("codex-policy-sand.dylib" if platform.system() == "Darwin" else "codex-policy-sand.so")


class NativeHook(unittest.TestCase):
    def run_hook(self, remaining=33, current="high", *, loaded=True, mismatch=False,
                 event="PostModelRequest", turn="turn", migrated=True, mode="normal",
                 expired=False, other_bucket=False, fail_update=False, repeat=False, policy=None, reset_in=None, duration=300, secondary=None):
        with tempfile.TemporaryDirectory(prefix="gce-", dir="/tmp") as directory:
            home = Path(directory)
            database = home / ".local/share/ground/ground.db"
            database.parent.mkdir(parents=True)
            with closing(sqlite3.connect(database)) as db:
                if migrated:
                    db.executescript(MIGRATION.read_text())
            path = str(home / "daemon.sock")
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(2)
            calls, errors = [], []
            effort = [current]

            def peer():
                try:
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        return
                    with connection, connection.makefile("rb") as stream:
                        connection.settimeout(3)
                        self.assertEqual(stream.readline(), b"GET / HTTP/1.1\r\n")
                        headers = {}
                        while True:
                            line = stream.readline()
                            if line == b"\r\n":
                                break
                            key, value = line.decode().split(":", 1)
                            headers[key.lower()] = value.strip()
                        accept = base64.b64encode(hashlib.sha1(
                            (headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                        ).digest()).decode()
                        if mode == "bad-handshake":
                            accept = "wrong"
                        connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n"
                                            f"Upgrade: websocket\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())

                        def send(opcode, payload, final=True):
                            prefix = bytes([opcode | (128 if final else 0)])
                            if len(payload) < 126:
                                prefix += bytes([len(payload)])
                            elif len(payload) < 65536:
                                prefix += b"\x7e" + struct.pack("!H", len(payload))
                            else:
                                prefix += b"\x7f" + struct.pack("!Q", len(payload))
                            connection.sendall(prefix + payload)

                        while True:
                            header = stream.read(2)
                            if not header:
                                return
                            self.assertEqual(len(header), 2)
                            self.assertTrue(header[1] & 128, "client frames must be masked")
                            length = header[1] & 127
                            if length == 126:
                                length = struct.unpack("!H", stream.read(2))[0]
                            elif length == 127:
                                length = struct.unpack("!Q", stream.read(8))[0]
                            mask = stream.read(4)
                            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(stream.read(length)))
                            if header[0] & 15 == 10:
                                self.assertEqual(payload, b"ping")
                                continue
                            request = json.loads(payload)
                            method = request["method"]
                            if "id" not in request:
                                self.assertEqual(method, "initialized")
                                continue
                            calls.append(method)
                            if method == "initialize":
                                result = {}
                            elif method == "thread/loaded/list":
                                self.assertIn("params", request)
                                result = {"data": ["session"] if loaded else [], "nextCursor": None}
                            elif method == "thread/read":
                                self.assertFalse(request["params"]["includeTurns"])
                                result = {"thread": {"reasoningEffort": effort[0]}}
                            elif method == "account/rateLimits/read":
                                result = {"rateLimitsByLimitId": {"other" if other_bucket else "codex": {
                                    "primary": {"usedPercent": 100 - remaining, "windowDurationMins": duration,
                                                "resetsAt": 1 if expired else (int(time.time()) + reset_in if reset_in is not None else 9999999999)},
                                    "secondary": secondary,
                                }}}
                            elif method == "thread/settings/update":
                                self.assertEqual(request["params"]["threadId"], "session")
                                if not mismatch and not fail_update:
                                    effort[0] = request["params"]["effort"]
                                result = {}
                            else:
                                self.fail(f"Unexpected RPC: {method}")
                            response = {"id": request["id"], "result": result}
                            if fail_update and method == "thread/settings/update":
                                response = {"id": request["id"], "error": {"code": -32600, "message": "rejected"}}
                            if mode == "large":
                                response["padding"] = "x" * 66000
                            encoded = json.dumps(response).encode()
                            if mode == "close":
                                send(8, b"\x03\xe8")
                                return
                            if mode == "fragmented":
                                send(1, encoded[:9], False)
                                send(9, b"ping")
                                send(0, encoded[9:])
                            else:
                                send(1, encoded)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=peer)
            worker.start()
            env = dict(os.environ, HOME=str(home), GROUND_CODEX_SOCKET=path)
            env.pop("GROUND_SAND", None)
            cwd = home
            if policy:
                self.assertTrue(SAND.exists(), "run make test-codex to build the PBT fixture")
                env["GROUND_SAND"] = str(SAND)
                cwd = home / policy
                cwd.mkdir()
            payload = json.dumps({"hook_event_name": event, "session_id": "session",
                                  "turn_id": turn, "cwd": str(cwd)})
            try:
                for _ in range(2 if repeat else 1):
                    process = subprocess.run([str(HOOK)], input=payload, text=True, env=env,
                                             cwd=home, capture_output=True, timeout=15)
                    self.assertEqual(process.returncode, 0, process.stderr)
                worker.join(4)
                self.assertFalse(worker.is_alive())
                if errors:
                    raise errors[0]
                with closing(sqlite3.connect(database)) as db:
                    db.row_factory = sqlite3.Row
                    rows = [dict(row) for row in db.execute("SELECT * FROM codex_effort_checks")] if migrated else []
                return rows, calls, effort[0]
            finally:
                listener.close()
                worker.join(4)

    def test_thresholds_and_never_raise(self):
        for remaining, before, expected in [(50, "high", "high"), (49.9, "high", "medium"),
                                             (20, "high", "medium"), (19.9, "high", "low"),
                                             (0, "medium", "low"), (33, "low", "low"),
                                             (3, "minimal", "minimal")]:
            with self.subTest(remaining=remaining, before=before):
                rows, calls, actual = self.run_hook(remaining, before)
                self.assertEqual(actual, expected)
                self.assertEqual(rows[0]["status"], "unchanged" if before == expected else "lowered")
                if expected != before:
                    self.assertEqual(rows[0]["verified_effort"], expected)

    def test_transport(self):
        for mode in ("fragmented", "large"):
            with self.subTest(mode=mode):
                rows, _, actual = self.run_hook(mode=mode)
                self.assertEqual(rows[0]["status"], "lowered")
                self.assertEqual(actual, "medium")

    def test_failures_leave_evidence(self):
        for options in ({"mismatch": True}, {"fail_update": True}, {"mode": "close"},
                        {"mode": "bad-handshake"}, {"expired": True},
                        {"other_bucket": True}, {"current": "unknown"}):
            with self.subTest(options=options):
                rows, _, _ = self.run_hook(**options)
                self.assertEqual(rows[0]["status"], "error")
                self.assertTrue(rows[0]["detail"])

    def test_unloaded_never_resumes(self):
        rows, calls, actual = self.run_hook(loaded=False)
        self.assertEqual(rows[0]["status"], "unloaded")
        self.assertEqual(actual, "high")
        self.assertEqual(calls, ["initialize", "thread/loaded/list"])

    def test_throttle(self):
        rows, calls, _ = self.run_hook(repeat=True)
        self.assertEqual(len(rows), 1)
        self.assertEqual(calls.count("initialize"), 1)

    def test_other_events_and_claude_do_not_connect(self):
        for options in ({"event": "PostToolUse"}, {"turn": ""}):
            with self.subTest(options=options):
                rows, calls, actual = self.run_hook(**options)
                self.assertEqual(rows, [])
                self.assertEqual(calls, [])
                self.assertEqual(actual, "high")

    def test_migration_required_before_network(self):
        rows, calls, actual = self.run_hook(migrated=False)
        self.assertEqual(calls, [])
        self.assertEqual(actual, "high")

    def test_loaded_pbt_changes_thresholds(self):
        for remaining, expected in ((60, "medium"), (25, "low")):
            with self.subTest(remaining=remaining):
                rows, _, actual = self.run_hook(remaining=remaining, policy="custom")
                self.assertEqual(rows[0]["status"], "lowered")
                self.assertEqual(actual, expected)

    def test_loaded_pbt_disables_controller(self):
        rows, calls, actual = self.run_hook(remaining=1, policy="disabled")
        self.assertEqual(rows, [])
        self.assertEqual(calls, [])
        self.assertEqual(actual, "high")

    def test_reset_grace_leaves_high_effort_even_with_low_weekly_quota(self):
        rows, calls, actual = self.run_hook(remaining=3, reset_in=1800,
            secondary={"usedPercent": 99, "windowDurationMins": 10080, "resetsAt": 9999999999})
        self.assertEqual(actual, "high")
        self.assertEqual(rows[0]["status"], "reset_grace")
        self.assertNotIn("thread/settings/update", calls)

    def test_reset_grace_requires_five_hour_window(self):
        for options in ({"reset_in": 7200}, {"reset_in": 1800, "duration": 10080},
                        {"reset_in": 1800, "duration": None}):
            with self.subTest(options=options):
                rows, calls, actual = self.run_hook(remaining=3, **options)
                self.assertEqual(actual, "low")
                self.assertEqual(rows[0]["status"], "lowered")

    def test_loaded_pbt_changes_reset_grace(self):
        # The custom policy grants 30 minutes, not the shipped 60.
        rows, _, actual = self.run_hook(remaining=3, reset_in=2700, policy="custom")
        self.assertEqual(actual, "low")
        rows, calls, actual = self.run_hook(remaining=3, reset_in=900, policy="custom")
        self.assertEqual(actual, "high")
        self.assertEqual(rows[0]["status"], "reset_grace")
        self.assertNotIn("thread/settings/update", calls)

    def test_loaded_pbt_can_disable_reset_grace(self):
        rows, _, actual = self.run_hook(remaining=3, reset_in=900, policy="grace-off")
        self.assertEqual(actual, "low")
        self.assertEqual(rows[0]["status"], "lowered")


if __name__ == "__main__":
    unittest.main()
