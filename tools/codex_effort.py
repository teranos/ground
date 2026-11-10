#!/usr/bin/env python3
"""Probe Codex effort control. Preview by default; never starts/resumes a thread."""

import argparse
import base64
from contextlib import closing
import hashlib
import json
import math
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import struct
import sys
import tempfile
import time


class ControlError(RuntimeError):
    pass


class AppServer:
    """One connection to the existing server, using WebSocket frames through Codex's raw proxy."""

    def __init__(self, executable="codex", socket=None, timeout=10):
        command = [executable, "app-server", "proxy"]
        if socket:
            command += ["--sock", socket]
        self.stderr = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr
            )
        except OSError:
            self.stderr.close()
            raise
        self.timeout = timeout
        self.buffer = b""
        self.sequence = 0

    def __enter__(self):
        try:
            self.upgrade()
            self.call("initialize", {
                "clientInfo": {"name": "ground-effort", "title": "Ground effort controller", "version": "0.1"},
                "capabilities": {"experimentalApi": True, "requestAttestation": False},
            })
            self.send({"method": "initialized", "params": {}})
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *args):
        self.close()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()
        self.stderr.close()

    LIMIT = 2 * 1024 * 1024

    def write(self, data):
        try:
            self.process.stdin.write(data)
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise ControlError("Codex proxy connection closed") from error

    def read_more(self, deadline, context):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
            raise ControlError(f"Codex timed out during {context}")
        chunk = os.read(self.process.stdout.fileno(), 65536)
        if not chunk:
            raise ControlError("Cannot reach the existing Codex app-server through its proxy")
        self.buffer += chunk
        if len(self.buffer) > self.LIMIT + 65536:
            raise ControlError("Codex proxy response exceeded the controller's limit")

    def read_exact(self, count, deadline, context):
        while len(self.buffer) < count:
            self.read_more(deadline, context)
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def upgrade(self):
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        self.write(("GET / HTTP/1.1\r\nHost: localhost\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Key: {key}\r\n"
                    "Sec-WebSocket-Version: 13\r\n\r\n").encode("ascii"))
        deadline = time.monotonic() + self.timeout
        while b"\r\n\r\n" not in self.buffer:
            if len(self.buffer) > 16384:
                raise ControlError("Codex WebSocket handshake headers exceeded the limit")
            self.read_more(deadline, "WebSocket handshake")
        header, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = header.decode("iso-8859-1").split("\r\n")
        fields = {}
        for line in lines[1:]:
            name, separator, value = line.partition(":")
            if separator:
                fields[name.lower()] = value.strip()
        expected = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
        ).digest()).decode("ascii")
        if (len(lines[0].split()) < 2 or lines[0].split()[1] != "101"
                or fields.get("upgrade", "").lower() != "websocket"
                or "upgrade" not in [token.strip() for token in fields.get("connection", "").lower().split(",")]
                or fields.get("sec-websocket-accept") != expected):
            raise ControlError("Codex rejected the WebSocket upgrade or returned an invalid handshake")

    def frame(self, opcode, payload):
        # RFC 6455 requires clients to mask every frame, even over a local socket.
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length <= 65535:
            header += b"\xfe" + struct.pack("!H", length)
        else:
            header += b"\xff" + struct.pack("!Q", length)
        mask = os.urandom(4)
        self.write(header + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))

    def send(self, message):
        self.frame(1, json.dumps(message).encode("utf-8"))

    def receive(self, deadline, context):
        payload = bytearray()
        started = False
        while True:
            first, second = self.read_exact(2, deadline, context)
            final, opcode = bool(first & 0x80), first & 0x0f
            if first & 0x70 or second & 0x80:
                raise ControlError("Invalid Codex WebSocket frame flags")
            length = second & 0x7f
            if length == 126:
                length = struct.unpack("!H", self.read_exact(2, deadline, context))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.read_exact(8, deadline, context))[0]
            if opcode >= 8 and (not final or length > 125):
                raise ControlError("Invalid Codex WebSocket control frame")
            if length > self.LIMIT or len(payload) + length > self.LIMIT:
                raise ControlError("Codex WebSocket message exceeded the controller's limit")
            chunk = self.read_exact(length, deadline, context)
            if opcode == 8:
                raise ControlError("Codex closed the WebSocket connection")
            if opcode == 9:
                self.frame(10, chunk)
                continue
            if opcode == 10:
                continue
            if (opcode == 1 and not started) or (opcode == 0 and started):
                started = True
                payload.extend(chunk)
            else:
                raise ControlError("Unexpected Codex WebSocket message type")
            if final:
                try:
                    return json.loads(payload.decode("utf-8"))
                except (ValueError, UnicodeError) as error:
                    raise ControlError("Codex WebSocket returned invalid JSON") from error

    def call(self, method, params=None):
        self.sequence += 1
        request_id = self.sequence
        request = {"id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        self.send(request)
        deadline = time.monotonic() + self.timeout
        while True:
            message = self.receive(deadline, method)
            if not isinstance(message, dict):
                raise ControlError("Codex returned an invalid RPC message")
            if "method" in message:
                if "id" in message:
                    self.send({"id": message["id"], "error": {
                        "code": -32601, "message": "Ground effort controller cannot handle this request"
                    }})
                continue
            if message.get("id") != request_id:
                continue
            if "error" in message:
                error = message["error"]
                code = error.get("code") if isinstance(error, dict) else "unknown"
                detail = str(error.get("message", ""))[:300] if isinstance(error, dict) else ""
                raise ControlError(f"Codex rejected {method} (RPC error {code}): {detail}")
            if "result" not in message:
                raise ControlError(f"Codex omitted the result for {method}")
            return message["result"]


def remaining_quota(result, now, limit_id="codex"):
    """Use the nearer of this Codex bucket's unexpired quota windows."""
    buckets = result.get("rateLimitsByLimitId")
    if isinstance(buckets, dict):
        bucket = buckets.get(limit_id)
    else:
        bucket = result.get("rateLimits")
        if not isinstance(bucket, dict) or bucket.get("limitId") != limit_id:
            bucket = None
    if not isinstance(bucket, dict):
        raise ControlError("No usage reading for the selected Codex bucket")
    readings = []
    for name in ("primary", "secondary"):
        window = bucket.get(name)
        if not isinstance(window, dict):
            continue
        used, reset = window.get("usedPercent"), window.get("resetsAt")
        if (type(used) in (int, float) and math.isfinite(used) and 0 <= used <= 100
                and type(reset) in (int, float) and math.isfinite(reset) and reset > now):
            readings.append(100 - used)
    if not readings:
        raise ControlError("No valid unexpired Codex quota window")
    return min(readings)


def wanted_effort(remaining):
    if remaining < 20:
        return "low"
    if remaining < 50:
        return "medium"
    return None


def loaded_threads(server):
    # Unlike account/rateLimits/read, the loaded-list RPC requires a params
    # object even when all its fields are optional.
    params, loaded, cursors = {}, [], set()
    while True:
        page = server.call("thread/loaded/list", params)
        ids = page.get("data")
        if not isinstance(ids, list) or not all(isinstance(item, str) for item in ids):
            raise ControlError("Codex returned an invalid loaded-thread list")
        loaded.extend(ids)
        cursor = page.get("nextCursor")
        if cursor is None:
            return loaded
        if not isinstance(cursor, str) or cursor in cursors:
            raise ControlError("Codex returned an invalid loaded-thread cursor")
        cursors.add(cursor)
        params = {"cursor": cursor}


def control(server, thread_id, *, turn_id=None, apply=False, now=None, limit_id="codex"):
    loaded = loaded_threads(server)
    if thread_id not in loaded:
        raise ControlError("Target thread is not loaded on this server; refusing to resume it")
    thread = server.call("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"]
    current = thread.get("reasoningEffort")
    remaining = remaining_quota(server.call("account/rateLimits/read"),
                                time.time() if now is None else now, limit_id)
    wanted = wanted_effort(remaining)
    levels = ("minimal", "low", "medium", "high", "xhigh", "max", "ultra")
    if current not in levels:
        raise ControlError("Current thread effort is unavailable or unsupported; leaving it unchanged")
    lower = wanted is not None and levels.index(wanted) < levels.index(current)
    result = {"threadId": thread_id, "remainingPercent": remaining,
              "currentEffort": current, "policyEffort": wanted,
              "action": "lower" if lower else "unchanged", "applied": False}
    if apply and lower:
        # Change the running turn first. If experimental control fails, do not
        # claim a successful change or silently change only future turns.
        if turn_id:
            server.call("turn/settings/update", {
                "threadId": thread_id, "turnId": turn_id, "effort": wanted,
            })
        try:
            server.call("thread/settings/update", {"threadId": thread_id, "effort": wanted})
        except ControlError as error:
            if turn_id:
                raise ControlError("Running turn was lowered, but future thread settings failed") from error
            raise
        result["applied"] = True
        result["scope"] = "running-and-future-turns" if turn_id else "future-turns"
        verified = server.call("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"].get("reasoningEffort")
        if verified != wanted:
            raise ControlError("Settings update returned successfully but thread effort did not match")
        result["verifiedEffort"] = verified
    return result


def hook_pass(payload, database, *, executable="codex", socket=None, now=None, factory=AppServer):
    """A bounded, fail-open pass for Codex model-event hooks, with Ground evidence."""
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    turn = payload.get("turn_id")
    if (event not in ("PreModelRequest", "PostModelRequest")
            or not isinstance(session, str) or not session
            or not isinstance(turn, str) or not turn):
        return None
    stamp = time.time() if now is None else now
    # Schema is installed only by migrations/20261109_001_codex_effort_checks.sql.
    # Require an existing database; a typo must not create an empty store.
    database_uri = Path(database).resolve().as_uri() + "?mode=rw"
    with closing(sqlite3.connect(database_uri, uri=True, timeout=1)) as db, db:
        db.execute("BEGIN IMMEDIATE")
        previous = db.execute("SELECT MAX(checked_at) FROM codex_effort_checks WHERE session = ?", (session,)).fetchone()[0]
        if previous is not None and stamp - previous < 60:
            return None
        row = db.execute("""INSERT INTO codex_effort_checks
            (session, turn_id, event, checked_at, status) VALUES (?, ?, ?, ?, 'checking')""",
            (session, turn, event, stamp)).lastrowid
    # No database write lock is held while talking to the app-server.
    result, status, detail = None, "error", None
    try:
        with factory(executable, socket, timeout=5) as server:
            # The stable thread control changes subsequent turns. Mid-turn
            # experimental control remains an explicit CLI option only.
            result = control(server, session, apply=True, now=stamp)
        status = "lowered" if result["applied"] else "unchanged"
    except (ControlError, OSError, KeyError, TypeError) as error:
        detail = str(error)[:500]
        if isinstance(error, ControlError) and detail.startswith("Target thread is not loaded"):
            status = "unloaded"
    with closing(sqlite3.connect(database_uri, uri=True, timeout=1)) as db, db:
        db.execute("""UPDATE codex_effort_checks SET completed_at = ?, status = ?,
            remaining_percentage = ?, before_effort = ?, policy_effort = ?,
            verified_effort = ?, detail = ? WHERE id = ?""",
            (time.time(), status, (result or {}).get("remainingPercent"),
             (result or {}).get("currentEffort"), (result or {}).get("policyEffort"),
             (result or {}).get("verifiedEffort"), detail, row))
    return {"status": status, "result": result, "detail": detail}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--thread-id")
    target.add_argument("--list-loaded", action="store_true", help="Read loaded thread IDs from this server")
    target.add_argument("--hook", action="store_true", help="Apply policy from a Codex hook payload on stdin")
    parser.add_argument("--turn-id", help="Also lower this running turn (experimental Codex API)")
    parser.add_argument("--apply", action="store_true", help="Apply a decrease; default only previews")
    parser.add_argument("--socket", help="Use this existing app-server control socket")
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--limit-id", default="codex")
    parser.add_argument("--database", default=os.path.expanduser("~/.local/share/ground/ground.db"))
    args = parser.parse_args()
    if args.list_loaded and (args.apply or args.turn_id):
        parser.error("--list-loaded cannot be combined with --apply or --turn-id")
    if args.hook:
        try:
            payload = json.loads(sys.stdin.buffer.read(1048576))
            if not isinstance(payload, dict):
                raise ControlError("Hook payload must be an object")
            outcome = hook_pass(payload, args.database, executable=args.codex, socket=args.socket)
            if outcome and outcome["status"] == "lowered":
                print("ground: Codex effort set to " + outcome["result"]["verifiedEffort"], file=sys.stderr)
            elif outcome and outcome["status"] == "error":
                print("ground codex effort: " + outcome["detail"], file=sys.stderr)
        except (ControlError, OSError, ValueError, sqlite3.Error) as error:
            print(f"ground codex effort: {error}", file=sys.stderr)
        # Policy failures must never stop the user's request or model call.
        return 0
    try:
        with AppServer(args.codex, args.socket) as server:
            if args.list_loaded:
                print(json.dumps({"loadedThreadIds": loaded_threads(server)}))
            else:
                print(json.dumps(control(server, args.thread_id, turn_id=args.turn_id,
                                         apply=args.apply, limit_id=args.limit_id)))
    except (ControlError, OSError, KeyError, TypeError) as error:
        print(f"ground codex effort: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
