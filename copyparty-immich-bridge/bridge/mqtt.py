"""Publish-only MQTT 3.1.1 client (no dependency): retained state under one prefix, a last will, events.

Off unless `mqtt_url` (env MQTT_URL) is set, e.g. mqtt://broker:1883 or mqtt://user:pass@broker:1883.
"""

from __future__ import annotations

import json
import logging
import queue
import socket
import struct
import threading
import time
from collections.abc import Callable
from urllib.parse import urlparse

log = logging.getLogger(__name__)
PREFIX = "ImmichBridge/"
KEEPALIVE = 60


def _str(s: str) -> bytes:
    b = s.encode()
    return struct.pack("!H", len(b)) + b


def _remaining(n: int) -> bytes:
    out = bytearray()
    while True:
        byte, n = n % 128, n // 128
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def connect_packet(client_id: str, will_topic: str, will_payload: str, user: str = "", password: str = "") -> bytes:
    flags = 0x02 | 0x04 | 0x20  # clean session, will, will retained (QoS 0)
    payload = _str(client_id) + _str(will_topic) + _str(will_payload)
    if user:
        flags |= 0x80
        payload += _str(user)
        if password:
            flags |= 0x40
            payload += _str(password)
    var = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", KEEPALIVE)
    return bytes([0x10]) + _remaining(len(var) + len(payload)) + var + payload


def publish_packet(topic: str, payload: str, retain: bool) -> bytes:
    body = _str(topic) + payload.encode()
    return bytes([0x30 | (0x01 if retain else 0)]) + _remaining(len(body)) + body


class MqttPublisher:
    def __init__(self, url: Callable[[], str], snapshot: Callable[[], dict], every_s: int = 60,
                 register: Callable[[], str | None] | None = None):
        self._url, self._snapshot, self._every, self._register = url, snapshot, every_s, register
        self._q: queue.Queue = queue.Queue(maxsize=1000)
        self._stop = threading.Event()
        self.connected = False
        self.last_error = ""

    def event(self, level: str, msg: str) -> None:
        self._put(("event", json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "level": level, "src": "bridge", "msg": msg}), False))

    def refresh(self) -> None:
        self._put(("refresh", "", False))

    def _put(self, item) -> None:
        try:
            self._q.put_nowait(item)
        except queue.Full:
            pass

    def _state_messages(self) -> list[tuple[str, str, bool]]:
        s = self._snapshot()
        out = [("node", "ON", True), ("state/updated", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), True)]
        for k, v in s.items():
            out.append((k, v if isinstance(v, str) else json.dumps(v), True))
        return out

    def _session(self, url: str) -> None:
        u = urlparse(url)
        sock = socket.create_connection((u.hostname, u.port or 1883), timeout=10)
        try:
            sock.sendall(connect_packet(f"immich-bridge-{socket.gethostname()}"[:23], PREFIX + "node", "OFF",
                                        u.username or "", u.password or ""))
            ack = sock.recv(4)
            if len(ack) < 4 or ack[0] != 0x20 or ack[3] != 0:
                raise OSError(f"broker refused the connection (CONNACK {ack.hex()})")
            self.connected, self.last_error = True, ""
            log.info("MQTT connected to %s:%s, publishing under %s", u.hostname, u.port or 1883, PREFIX)
            reg = self._register() if self._register else None
            if reg:  # the network's device index (mqtt-netdocs) lists the bridge from this retained message
                sock.sendall(publish_packet("netdocs/immich-bridge/register", reg, True))
            last_state = last_ping = 0.0
            while not self._stop.is_set() and self._url() == url:
                now = time.time()
                if now - last_state >= self._every:
                    for t, p, r in self._state_messages():
                        sock.sendall(publish_packet(PREFIX + t, p, r))
                    last_state = now
                if now - last_ping >= KEEPALIVE / 2:
                    sock.sendall(b"\xc0\x00")  # PINGREQ
                    last_ping = now
                try:
                    kind, payload, retain = self._q.get(timeout=1)
                except queue.Empty:
                    continue
                if kind == "refresh":
                    last_state = 0.0
                else:
                    sock.sendall(publish_packet(PREFIX + kind, payload, retain))
            if self._url() != url or self._stop.is_set():
                sock.sendall(publish_packet(PREFIX + "node", "OFF", True))
                sock.sendall(b"\xe0\x00")  # DISCONNECT
        finally:
            self.connected = False
            sock.close()

    def run(self) -> None:
        wait = 5
        while not self._stop.is_set():
            url = self._url()
            if not url:
                self._stop.wait(10)
                continue
            try:
                self._session(url)
                wait = 5
            except (OSError, ValueError) as ex:
                self.last_error = str(ex)[:200]
                log.warning("MQTT: %s (retry in %d s)", self.last_error, wait)
                self._stop.wait(wait)
                wait = min(wait * 2, 300)

    def start(self) -> None:
        threading.Thread(target=self.run, name="mqtt", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
