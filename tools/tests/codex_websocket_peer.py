"""Independent fake daemon: requires HTTP Upgrade and masked client frames."""
import base64
import hashlib
import json
import os
import struct
import sys

mode = os.environ.get("GROUND_TEST_WS_MODE", "normal")
source, sink = sys.stdin.buffer, sys.stdout.buffer
assert source.readline() == b"GET / HTTP/1.1\r\n"
headers = {}
while True:
    line = source.readline()
    if line == b"\r\n":
        break
    assert line, "EOF before handshake"
    name, value = line.decode().split(":", 1)
    headers[name.lower()] = value.strip()
assert headers["upgrade"] == "websocket"
assert headers["sec-websocket-version"] == "13"
accept = base64.b64encode(hashlib.sha1(
    (headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
).digest()).decode()
if mode == "bad-handshake":
    accept = "invalid"
sink.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
sink.flush()


def frame(opcode, payload, final=True):
    header = bytes([(0x80 if final else 0) | opcode])
    if len(payload) < 126:
        header += bytes([len(payload)])
    elif len(payload) <= 65535:
        header += b"\x7e" + struct.pack("!H", len(payload))
    else:
        header += b"\x7f" + struct.pack("!Q", len(payload))
    sink.write(header + payload)
    sink.flush()


while True:
    header = source.read(2)
    if not header:
        break
    assert len(header) == 2 and header[0] & 0x80 and header[1] & 0x80
    opcode, length = header[0] & 0xf, header[1] & 0x7f
    if length == 126:
        length = struct.unpack("!H", source.read(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", source.read(8))[0]
    mask = source.read(4)
    payload = bytes(c ^ mask[i % 4] for i, c in enumerate(source.read(length)))
    if opcode == 10:
        assert payload == b"ground-ping"
        continue
    assert opcode == 1, "client must send JSON in a WebSocket text frame"
    request = json.loads(payload)
    if "id" not in request:
        assert request == {"method": "initialized", "params": {}}
        continue
    if request["method"] == "thread/loaded/list" and "params" not in request:
        frame(1, json.dumps({"id": request["id"], "error": {
            "code": -32600, "message": "missing field `params`"
        }}).encode())
        continue
    if mode == "close":
        frame(8, struct.pack("!H", 1000))
        break
    frame(1, json.dumps({"method": "account/rateLimits/updated", "params": {}}).encode())
    response = json.dumps({"id": request["id"], "result": {
        "method": request["method"], "padding": "x" * (66000 if mode == "large" else 200)
    }}).encode()
    if mode == "large":
        frame(1, response)
    else:
        frame(1, response[:10], final=False)
        frame(9, b"ground-ping")
        frame(0, response[10:])
