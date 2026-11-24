"""Backing off while Immich is overloaded, and saying so over MQTT."""

import socket
import threading
import time

from bridge import pressure as P
from bridge.mqtt import MqttPublisher, connect_packet, publish_packet


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def monitor(load, ping=lambda: 0.1):
    c = Clock()
    return P.Pressure(ping=ping, load=load, clock=c), c


def test_a_high_load_starts_backing_off_and_waits_grow():
    level = [5.0]
    p, c = monitor(lambda: level[0])
    seen = []
    p.listeners.append(lambda info: seen.append(info["busy"]))
    p.check()
    assert p.busy and "overloaded" in p.reason and p.until - c.t == 60 and seen == [True]
    c.t += 30
    p.check()  # before the next check time: nothing is measured
    assert p.until - 1000 == 60
    c.t = p.until
    p.check()  # still overloaded: the wait doubles
    assert p.busy and p.until - c.t == 120
    level[0] = 2.0  # under the 'overloaded' level but over the 'healthy again' one: keep waiting
    c.t = p.until
    p.check()
    assert p.busy and p.until - c.t == 240
    level[0] = 0.5
    c.t = p.until
    p.check()
    assert not p.busy and p.reason == "" and seen == [True, True, True, False]


def test_the_longest_wait_is_half_an_hour():
    p, c = monitor(lambda: 9.0)
    for _ in range(12):
        c.t = max(c.t, p.until)
        p.check()
    assert p.until - c.t == 1800


def test_a_slow_or_silent_immich_counts_as_busy():
    p, _ = monitor(lambda: 0.1, ping=lambda: 9.0)
    p.check()
    assert p.busy and "slow" in p.reason
    q, _ = monitor(lambda: 0.1, ping=lambda: None)
    q.check()
    assert q.busy and "does not answer" in q.reason


def test_only_overload_errors_trigger_a_backoff():
    p, _ = monitor(lambda: 0.1)
    p.report_error(ValueError("Immich answered HTTP 400: bad file"))
    assert not p.busy
    p.report_error(RuntimeError("upload failed: HTTP 500: Failed to upload asset"))
    assert p.busy
    q, _ = monitor(lambda: 0.1)
    q.report_error(TimeoutError("read timed out"))
    assert q.busy


def test_waiting_returns_when_clear_or_stopping():
    p, _ = monitor(lambda: 9.0)
    p.check()
    stop = threading.Event()
    threading.Timer(0.3, lambda: setattr(p, "busy", False)).start()
    assert p.wait_until_clear(stop) is True
    p.busy = True
    threading.Timer(0.3, stop.set).start()
    assert p.wait_until_clear(stop) is False


def test_mqtt_packets_follow_the_3_1_1_layout():
    c = connect_packet("immich-bridge", "ImmichBridge/node", "OFF")
    assert c[0] == 0x10 and c[2:8] == b"\x00\x04MQTT" and c[8] == 4 and c[9] == 0x26  # clean, will, will retained
    p = publish_packet("ImmichBridge/state/backoff", "ON", True)
    assert p[0] == 0x31 and p[1] == len(p) - 2 and p.endswith(b"ImmichBridge/state/backoffON")
    big = publish_packet("t", "x" * 300, False)
    assert big[0] == 0x30 and big[1] & 0x80  # remaining length takes two bytes


class Broker:
    """Accepts one client, answers CONNACK, records PUBLISH topics/payloads."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.got: list[tuple[str, str, bool]] = []
        self.connect = b""
        threading.Thread(target=self._serve, daemon=True).start()

    def _read(self, conn):
        h = conn.recv(1)
        if not h:
            return None, b""
        mult, n = 1, 0
        while True:
            b = conn.recv(1)[0]
            n += (b & 0x7F) * mult
            mult *= 128
            if not b & 0x80:
                break
        body = b""
        while len(body) < n:
            body += conn.recv(n - len(body))
        return h[0], body

    def _serve(self):
        conn, _ = self.sock.accept()
        kind, self.connect = self._read(conn)
        conn.sendall(b"\x20\x02\x00\x00")
        while True:
            kind, body = self._read(conn)
            if kind is None:
                return
            if kind >> 4 == 3:
                tl = int.from_bytes(body[:2], "big")
                self.got.append((body[2:2 + tl].decode(), body[2 + tl:].decode(), bool(kind & 1)))


def test_state_and_events_reach_the_broker():
    broker = Broker()
    pub = MqttPublisher(lambda: f"mqtt://127.0.0.1:{broker.port}", lambda: {"state/backoff": "ON", "state/autofix": {"applied": 3}},
                        register=lambda: '{"name": "immich-bridge"}')
    pub.start()
    try:
        end = time.time() + 5
        while time.time() < end and not any(t == "ImmichBridge/state/backoff" for t, _, _ in broker.got):
            time.sleep(0.05)
        pub.event("warn", "backing off: test")
        while time.time() < end and not any(t == "ImmichBridge/event" for t, _, _ in broker.got):
            time.sleep(0.05)
        got = {t: (p, r) for t, p, r in broker.got}
        assert got["ImmichBridge/node"] == ("ON", True) and got["ImmichBridge/state/backoff"] == ("ON", True)
        assert got["ImmichBridge/state/autofix"] == ('{"applied": 3}', True)
        assert got["netdocs/immich-bridge/register"][1] is True
        assert got["ImmichBridge/event"][1] is False and "backing off" in got["ImmichBridge/event"][0]
        assert b"ImmichBridge/node" in broker.connect and b"OFF" in broker.connect  # the last will
    finally:
        pub.stop()
