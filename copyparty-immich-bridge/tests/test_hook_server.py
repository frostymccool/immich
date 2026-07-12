import json
import threading
import urllib.error
import urllib.request

import pytest

from bridge.config import Config
from bridge.server import serve
from bridge.state import StateStore
from bridge.worker import ImportWorker


class FakeClient:
    pass


@pytest.fixture
def running_server(tmp_path):
    cfg = Config(
        immich_url="http://unused:1",
        api_key="k",
        watch_dirs=["/w/uploads"],
        path_map=[("/w/uploads", "/mnt/uploads")],
        state_db=str(tmp_path / "state.db"),
        bind_host="127.0.0.1",
        bind_port=0,
    )
    state = StateStore(cfg.state_db)
    worker = ImportWorker(cfg, state, FakeClient(), {"jpg"})  # not started: enqueue only
    httpd = serve(cfg, state, worker)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{httpd.server_port}"
    yield base, worker, state
    httpd.shutdown()
    httpd.server_close()


def post_json(url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as ex:
        return ex.code, json.loads(ex.read())


def get_json(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return resp.status, json.loads(resp.read())


def test_hook_single_event_maps_path(running_server):
    base, worker, _ = running_server
    xau_payload = {
        "ap": "/w/uploads/cam/IMG_1.jpg",
        "vp": "uploads/cam/IMG_1.jpg",
        "sz": 123,
        "mt": 1700000000,
        "wark": "w" * 44,
    }
    status, body = post_json(base + "/hook", xau_payload)
    assert status == 200
    assert body == {"queued": 1}
    assert worker._queue.get_nowait() == "/mnt/uploads/cam/IMG_1.jpg"


def test_hook_batch_and_dedupe(running_server):
    base, worker, _ = running_server
    events = [
        {"ap": "/w/uploads/a.jpg"},
        {"ap": "/w/uploads/a.jpg"},  # duplicate in same batch
        {"ap": "/w/uploads/b.jpg"},
        {"vp": "no-ap-field"},
    ]
    status, body = post_json(base + "/hook", events)
    assert status == 200
    assert body == {"queued": 2}


def test_hook_rejects_garbage(running_server):
    base, _, _ = running_server
    req = urllib.request.Request(
        base + "/hook", data=b"not json", headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        raised = False
    except urllib.error.HTTPError as ex:
        raised = ex.code == 400
    assert raised


def test_healthz_and_status(running_server):
    base, _, state = running_server
    status, body = get_json(base + "/healthz")
    assert status == 200 and body["ok"] is True

    state.record_success("/mnt/uploads/x.jpg", 1, 1.0, "h", "imported", "a-1")
    status, body = get_json(base + "/status")
    assert status == 200
    assert body["counts"] == {"imported": 1}
    assert body["recent"][0]["asset_id"] == "a-1"


def test_unknown_route_404(running_server):
    base, _, _ = running_server
    status, _ = post_json(base + "/nope", {})
    assert status == 404
