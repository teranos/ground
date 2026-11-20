import importlib.util
from contextlib import closing
import json
import os
import sqlite3
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("codex_effort", Path(__file__).parents[1] / "codex_effort.py")
effort = importlib.util.module_from_spec(spec)
spec.loader.exec_module(effort)


def snapshot(used=60, secondary=None, reset=200):
    return {"rateLimitsByLimitId": {"codex": {
        "primary": {"usedPercent": used, "resetsAt": reset},
        "secondary": secondary,
    }}}


class Server:
    def __init__(self, current="high", usage=None, loaded=True, fail=None):
        self.current = current
        self.usage = snapshot() if usage is None else usage
        self.loaded = loaded
        self.fail = fail
        self.calls = []

    def call(self, method, params=None):
        self.calls.append((method, params))
        if method == self.fail:
            raise effort.ControlError("test rejection")
        if method == "thread/settings/update":
            self.current = params["effort"]
        return {
            "thread/loaded/list": {"data": ["thread-1"] if self.loaded else []},
            "thread/read": {"thread": {"reasoningEffort": self.current}},
            "account/rateLimits/read": self.usage,
        }.get(method, {})


class PolicyTests(unittest.TestCase):
    def test_loaded_thread_discovery_includes_later_pages(self):
        class Paginated:
            def call(self, method, params):
                self.last_method = method
                if not params:
                    return {"data": ["first"], "nextCursor": "page-2"}
                return {"data": ["second"], "nextCursor": None}
        self.assertEqual(effort.loaded_threads(Paginated()), ["first", "second"])

    def test_repeated_loaded_thread_cursor_is_rejected(self):
        class Repeated:
            def call(self, method, params):
                return {"data": [], "nextCursor": "same-page"}
        with self.assertRaisesRegex(effort.ControlError, "cursor"):
            effort.loaded_threads(Repeated())

    def test_remaining_boundaries(self):
        for remaining, wanted in [(100, None), (50, None), (49.9, "medium"),
                                  (20, "medium"), (19.9, "low"), (0, "low")]:
            with self.subTest(remaining=remaining):
                self.assertEqual(effort.wanted_effort(remaining), wanted)

    def test_nearer_window_governs(self):
        self.assertEqual(effort.remaining_quota(snapshot(30, {
            "usedPercent": 85, "resetsAt": 200}), 100), 15)

    def test_expired_window_does_not_pin(self):
        self.assertEqual(effort.remaining_quota(snapshot(99, {
            "usedPercent": 10, "resetsAt": 200}, reset=99), 100), 90)

    def test_missing_expired_and_invalid_readings_are_errors(self):
        for reading in ({}, snapshot(reset=100), snapshot(used=None),
                        snapshot(used=True), snapshot(used=float("nan")), snapshot(used=101)):
            with self.subTest(reading=reading), self.assertRaises(effort.ControlError):
                effort.remaining_quota(reading, 100)

    def test_other_buckets_do_not_change_codex_policy(self):
        reading = snapshot(10)
        reading["rateLimitsByLimitId"]["claude"] = snapshot(99)["rateLimitsByLimitId"]["codex"]
        self.assertEqual(effort.remaining_quota(reading, 100), 90)

    def test_preview_makes_no_settings_calls(self):
        server = Server()
        result = effort.control(server, "thread-1", now=100)
        self.assertEqual(result["policyEffort"], "medium")
        self.assertFalse(result["applied"])
        self.assertFalse(any(method.endswith("settings/update") for method, _ in server.calls))

    def test_apply_targets_only_requested_thread_and_effort(self):
        server = Server(usage=snapshot(90))
        result = effort.control(server, "thread-1", apply=True, now=100)
        self.assertTrue(result["applied"])
        self.assertEqual(server.calls[-2], ("thread/settings/update", {
            "threadId": "thread-1", "effort": "low"}))
        self.assertEqual(result["verifiedEffort"], "low")

    def test_never_raises_existing_lower_effort(self):
        server = Server(current="low")
        result = effort.control(server, "thread-1", apply=True, now=100)
        self.assertEqual(result["action"], "unchanged")
        self.assertFalse(result["applied"])

    def test_unloaded_thread_is_never_resumed(self):
        server = Server(loaded=False)
        with self.assertRaises(effort.ControlError):
            effort.control(server, "thread-1", apply=True, now=100)
        self.assertEqual(server.calls, [("thread/loaded/list", {})])

    def test_unknown_effort_makes_no_changes(self):
        server = Server(current=None)
        with self.assertRaises(effort.ControlError):
            effort.control(server, "thread-1", apply=True, now=100)
        self.assertEqual(len(server.calls), 3)

    def test_success_response_without_setting_change_is_not_claimed_as_applied(self):
        class IgnoredUpdate(Server):
            def call(self, method, params=None):
                if method == "thread/settings/update":
                    return {}
                return super().call(method, params)
        with self.assertRaisesRegex(effort.ControlError, "did not match"):
            effort.control(IgnoredUpdate(), "thread-1", apply=True, now=100)

    def test_active_turn_failure_does_not_change_future_settings(self):
        server = Server(fail="turn/settings/update")
        with self.assertRaises(effort.ControlError):
            effort.control(server, "thread-1", turn_id="turn-1", apply=True, now=100)
        self.assertEqual(server.calls[-1][0], "turn/settings/update")

    def test_partial_apply_is_reported(self):
        server = Server(fail="thread/settings/update")
        with self.assertRaisesRegex(effort.ControlError, "Running turn was lowered"):
            effort.control(server, "thread-1", turn_id="turn-1", apply=True, now=100)


class HookTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.database = Path(self.directory.name) / "ground.db"
        migration = Path(__file__).parents[2] / "migrations/20261109_001_codex_effort_checks.sql"
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript(migration.read_text())
        self.payload = {"hook_event_name": "PreModelRequest", "session_id": "thread-1", "turn_id": "turn-1"}

    def factory(self, server):
        class Connection:
            def __enter__(self):
                return server
            def __exit__(self, *args):
                pass
        return lambda *args, **kwargs: Connection()

    def test_hook_lowers_verifies_and_records_one_check_per_minute(self):
        server = Server()
        result = effort.hook_pass(self.payload, self.database, now=100, factory=self.factory(server))
        self.assertEqual(result["status"], "lowered")
        calls = len(server.calls)
        self.assertIsNone(effort.hook_pass(self.payload, self.database, now=120, factory=self.factory(server)))
        self.assertEqual(len(server.calls), calls)
        with closing(sqlite3.connect(self.database)) as db, db:
            self.assertEqual(db.execute("SELECT status, before_effort, verified_effort FROM codex_effort_checks").fetchall(),
                             [("lowered", "high", "medium")])

    def test_failure_records_error_without_settings_update(self):
        server = Server(fail="account/rateLimits/read")
        result = effort.hook_pass(self.payload, self.database, now=100, factory=self.factory(server))
        self.assertEqual(result["status"], "error")
        self.assertFalse(any(method.endswith("settings/update") for method, _ in server.calls))

    def test_embedded_session_records_unloaded_and_never_resumes(self):
        server = Server(loaded=False)
        result = effort.hook_pass(self.payload, self.database, now=100, factory=self.factory(server))
        self.assertEqual(result["status"], "unloaded")
        self.assertEqual(server.calls, [("thread/loaded/list", {})])

    def test_claude_event_never_touches_database_or_server(self):
        payload = {"hook_event_name": "PreToolUse", "session_id": "claude-1"}
        self.assertIsNone(effort.hook_pass(payload, "/nonexistent/ground.db", factory=lambda *a, **k: self.fail("connected")))

    def test_unmigrated_database_stays_unmodified(self):
        database = Path(self.directory.name) / "unmigrated.db"
        with closing(sqlite3.connect(database)):
            pass
        with self.assertRaises(sqlite3.OperationalError):
            effort.hook_pass(self.payload, database, now=100, factory=lambda *a, **k: self.fail("connected"))
        with closing(sqlite3.connect(database)) as db, db:
            self.assertEqual(db.execute("SELECT name FROM sqlite_master").fetchall(), [])

    def test_migration_can_be_applied_again_without_losing_evidence(self):
        effort.hook_pass(self.payload, self.database, now=100, factory=self.factory(Server()))
        migration = Path(__file__).parents[2] / "migrations/20261109_001_codex_effort_checks.sql"
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript(migration.read_text())
            self.assertEqual(db.execute("SELECT COUNT(*) FROM codex_effort_checks").fetchone()[0], 1)


class TransportTests(unittest.TestCase):
    def test_proxy_launch_failure_closes_diagnostic_file(self):
        with tempfile.TemporaryFile() as diagnostic:
            with patch.object(effort.tempfile, "TemporaryFile", return_value=diagnostic):
                with patch.object(effort.subprocess, "Popen", side_effect=FileNotFoundError("missing codex")):
                    with self.assertRaises(FileNotFoundError):
                        effort.AppServer("missing-codex")
            self.assertTrue(diagnostic.closed, "A failed proxy launch must close its diagnostic file")

    def connect(self, mode="normal"):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        proxy = Path(directory.name) / "fake-codex"
        fixture = Path(__file__).with_name("codex_websocket_peer.py").resolve()
        proxy.write_text(f"#!{sys.executable}\nimport runpy\nrunpy.run_path({str(fixture)!r}, run_name='__main__')\n")
        proxy.chmod(0o700)
        environment = patch.dict(os.environ, {"GROUND_TEST_WS_MODE": mode})
        environment.start()
        self.addCleanup(environment.stop)
        return effort.AppServer(str(proxy), timeout=1)

    def test_websocket_upgrade_masking_fragmentation_and_ping(self):
        with self.connect() as server:
            result = server.call("thread/loaded/list", {})
            self.assertEqual(result["method"], "thread/loaded/list")
            self.assertEqual(len(result["padding"]), 200)
        self.assertIsNotNone(server.process.poll())

    def test_large_websocket_frame(self):
        with self.connect("large") as server:
            self.assertEqual(len(server.call("thread/loaded/list", {})["padding"]), 66000)

    def test_rpc_error_preserves_daemon_diagnostic(self):
        with self.connect() as server:
            with self.assertRaisesRegex(effort.ControlError, "missing field.*params"):
                server.call("thread/loaded/list")

    def test_invalid_upgrade_is_rejected_before_rpc(self):
        with self.assertRaisesRegex(effort.ControlError, "invalid handshake"):
            with self.connect("bad-handshake"):
                self.fail("Invalid handshake accepted")

    def test_server_close_is_reported(self):
        with self.assertRaisesRegex(effort.ControlError, "closed the WebSocket"):
            with self.connect("close"):
                self.fail("Closed socket accepted")


if __name__ == "__main__":
    unittest.main()
