import json
import logging
import threading
import urllib.error
import urllib.request

import pytest

from bridge.config import Config
from bridge.logbuffer import RingLogHandler
from bridge.server import serve
from bridge.settings import SettingsStore
from bridge.state import StateStore
from bridge.worker import ImportWorker

TOKEN = "s3cret-token"


class FakeClient:
    pass


def call(base, method, path, body=None, token=TOKEN, raw=False):
    headers = {}
    data = None
    if token is not None:
        headers["X-Bridge-Token"] = token
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = resp.read()
            return resp.status, (payload if raw else json.loads(payload)), resp.headers
    except urllib.error.HTTPError as ex:
        payload = ex.read()
        return ex.code, (payload if raw else json.loads(payload)), ex.headers


@pytest.fixture
def app(tmp_path):
    media = tmp_path / "media"
    (media / "trip" / "day1").mkdir(parents=True)
    (media / "other").mkdir()
    (media / ".hist").mkdir()
    (media / "trip" / "a.jpg").write_bytes(b"x")
    (media / "trip" / "notes.txt").write_bytes(b"x")

    def build(token=TOKEN):
        cfg = Config(
            immich_url="http://immich:2283",
            api_key="top-secret-key",
            watch_dirs=[str(media / "trip")],
            priority_dirs=[str(media / "trip")],
            state_db=str(tmp_path / "state.db"),
            settings_file=str(tmp_path / "settings.json"),
            browse_roots=[str(media)],
            token=token,
            bind_host="127.0.0.1",
            bind_port=0,
        )
        state = StateStore(cfg.state_db)
        worker = ImportWorker(cfg, state, FakeClient(), {"jpg"})
        logs = RingLogHandler(50)
        scans = []
        settings = SettingsStore(cfg, cfg.settings_file, cfg.browse_roots)
        httpd = serve(cfg, state, worker, settings, logs, scan_now=lambda: scans.append(1))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{httpd.server_port}", httpd, cfg, logs, scans

    started = []

    def make(**kw):
        result = build(**kw)
        started.append(result[1])
        return result

    yield make, media
    for httpd in started:
        httpd.shutdown()
        httpd.server_close()


def test_page_is_served_without_a_token(app):
    make, _ = app
    base, *_ = make()
    status, body, headers = call(base, "GET", "/", token=None, raw=True)
    assert status == 200
    assert b"<html" in body.lower()
    assert "text/html" in headers["Content-Type"]


def test_api_needs_the_token(app):
    make, _ = app
    base, *_ = make()
    assert call(base, "GET", "/api/config", token=None)[0] == 401
    assert call(base, "GET", "/api/config", token="wrong")[0] == 401
    assert call(base, "GET", "/api/config")[0] == 200


def test_bearer_header_also_works(app):
    make, _ = app
    base, *_ = make()
    req = urllib.request.Request(base + "/api/config", headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200


def test_api_is_off_entirely_without_a_server_token(app):
    make, _ = app
    base, *_ = make(token="")
    status, body, _ = call(base, "GET", "/api/config", token="anything")
    assert status == 403
    assert "BRIDGE_TOKEN" in body["error"]
    assert call(base, "PUT", "/api/config", {"sweep_interval": 5}, token="anything")[0] == 403


def test_hook_requires_the_token_when_one_is_set(app):
    make, _ = app
    base, *_ = make()
    assert call(base, "POST", "/hook", {"ap": "/x/a.jpg"}, token=None)[0] == 401
    assert call(base, "POST", "/hook", {"ap": "/x/a.jpg"})[0] == 200


def test_status_and_health_stay_open(app):
    make, _ = app
    base, *_ = make()
    assert call(base, "GET", "/healthz", token=None)[0] == 200
    status, body, _ = call(base, "GET", "/status", token=None)
    assert status == 200 and "counts" in body


def test_config_never_leaks_the_api_key(app):
    make, _ = app
    base, *_ = make()
    _, raw, _ = call(base, "GET", "/api/config", raw=True)
    assert b"top-secret-key" not in raw
    data = json.loads(raw)
    assert data["readonly"]["api_key_set"] is True
    assert data["readonly"]["immich_url"] == "http://immich:2283"
    assert TOKEN.encode() not in raw


def test_put_config_applies_live_and_persists(app):
    make, media = app
    base, _, cfg, _, scans = make()
    status, body, _ = call(
        base, "PUT", "/api/config",
        {"watch_dirs": [str(media / "trip"), str(media / "other")], "priority_dirs": [str(media / "other")], "sweep_interval": 120},
    )
    assert status == 200
    assert cfg.watch_dirs == [str(media / "trip"), str(media / "other")]
    assert cfg.priority_dirs == [str(media / "other")]
    assert body["values"]["sweep_interval"] == 120
    assert "watch_dirs" in body["overridden"]
    # /status reports the live values too, which is what the phone app shows
    assert call(base, "GET", "/status", token=None)[1]["priority_dirs"] == [str(media / "other")]


def test_put_config_rejects_bad_input_with_reasons(app):
    make, media = app
    base, _, cfg, _, _ = make()
    status, body, _ = call(base, "PUT", "/api/config", {"watch_dirs": ["/nope"], "max_attempts": 0})
    assert status == 400
    assert len(body["problems"]) == 2
    assert cfg.max_attempts == 5


def test_put_config_cannot_change_readonly_things(app):
    make, _ = app
    base, _, cfg, _, _ = make()
    for key in ("immich_url", "api_key", "token", "bind_port", "workers"):
        status, body, _ = call(base, "PUT", "/api/config", {key: "x"})
        assert status == 400, key
    assert cfg.immich_url == "http://immich:2283"
    assert cfg.token == TOKEN


def test_reset_endpoint(app):
    make, media = app
    base, _, cfg, _, _ = make()
    call(base, "PUT", "/api/config", {"sweep_interval": 5})
    status, body, _ = call(base, "POST", "/api/config/reset", {})
    assert status == 200
    assert cfg.sweep_interval == 900
    assert body["overridden"] == []


def test_scan_now(app):
    make, _ = app
    base, _, _, _, scans = make()
    assert call(base, "POST", "/api/scan", {})[0] == 200
    assert scans == [1]
    assert call(base, "POST", "/api/scan", {}, token="bad")[0] == 401
    assert scans == [1]


def test_folder_browser_lists_only_folders_inside_roots(app):
    make, media = app
    base, *_ = make()
    status, body, _ = call(base, "GET", "/api/fs")
    assert status == 200
    names = [d["name"] for d in body["dirs"]]
    assert names == ["other", "trip"]  # sorted, and the hidden .hist is not offered
    assert body["parent"] is None
    status, body, _ = call(base, "GET", f"/api/fs?path={media}/trip")
    assert [d["name"] for d in body["dirs"]] == ["day1"]
    assert body["files"] == 1  # a.jpg counts; notes.txt is not a media type
    assert body["parent"] == str(media)


@pytest.mark.parametrize("evil", ["/etc", "/", "{media}/../../etc", "{media}/trip/../../.."])
def test_folder_browser_refuses_to_leave_the_roots(app, evil):
    make, media = app
    base, *_ = make()
    status, body, _ = call(base, "GET", "/api/fs?path=" + evil.format(media=media))
    assert status in (400, 403)


def test_folder_browser_does_not_follow_symlinks_out(app, tmp_path):
    make, media = app
    (media / "escape").symlink_to("/etc")
    base, *_ = make()
    assert "escape" not in [d["name"] for d in call(base, "GET", "/api/fs")[1]["dirs"]]
    assert call(base, "GET", f"/api/fs?path={media}/escape")[0] == 403


def test_logs_endpoint_and_download(app):
    make, _ = app
    base, _, _, logs, _ = make()
    lg = logging.getLogger("bridge.test")
    lg.setLevel(logging.DEBUG)
    lg.addHandler(logs)
    lg.info("imported: IMG_1.JPG")
    lg.debug("noisy detail")
    lg.error("import failed for /w/x.jpg: HTTP 500")
    _, body, _ = call(base, "GET", "/api/logs?level=INFO")
    assert [e["level"] for e in body["entries"]] == ["INFO", "ERROR"]
    _, body, _ = call(base, "GET", "/api/logs?level=DEBUG")
    assert len(body["entries"]) == 3
    last = body["entries"][-1]["id"]
    assert call(base, "GET", f"/api/logs?level=DEBUG&after={last}")[1]["entries"] == []
    status, raw, headers = call(base, "GET", "/api/logs/download", raw=True)
    assert status == 200
    assert b"imported: IMG_1.JPG" in raw and b"HTTP 500" in raw
    assert "attachment" in headers["Content-Disposition"]
    assert call(base, "GET", "/api/logs/download", token=None)[0] == 401


def run_hook_script(base, ap, token):
    import os
    import subprocess
    import sys

    env = {k: v for k, v in os.environ.items() if not k.startswith("IMMICH_BRIDGE")}
    env["IMMICH_BRIDGE_URL"] = base
    if token is not None:
        env["IMMICH_BRIDGE_TOKEN"] = token
    script = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hook", "immich_bridge_hook.py")
    return subprocess.run(
        [sys.executable, script, json.dumps({"ap": ap})], env=env, capture_output=True, text=True, timeout=60
    )


def test_hook_script_sends_the_token(app):
    make, media = app
    base, _, cfg, _, _ = make()
    worker_queue_before = call(base, "GET", "/status", token=None)[1]["queue"]
    result = run_hook_script(base, str(media / "trip" / "a.jpg"), TOKEN)
    assert result.returncode == 0
    assert call(base, "GET", "/status", token=None)[1]["queue"] == worker_queue_before + 1


def test_hook_script_without_the_token_is_refused_but_never_fails_the_upload(app):
    make, media = app
    base, *_ = make()
    result = run_hook_script(base, str(media / "trip" / "a.jpg"), None)
    assert result.returncode == 0  # must never break copyparty
    assert call(base, "GET", "/status", token=None)[1]["queue"] == 0


def test_status_reports_album_health_and_backfill_endpoint_needs_the_token(app):
    make, _ = app
    base, *_ = make()
    status, body, _ = call(base, "GET", "/status", token=None)
    assert status == 200
    assert set(body["albums"]) >= {"enabled", "permission", "backfill"}
    assert call(base, "POST", "/api/albums/backfill", {}, token=None)[0] == 401
    status, body, _ = call(base, "POST", "/api/albums/backfill", {})
    assert status == 200 and "started" in body
    assert call(base, "POST", "/api/albums/recheck", {}, token="bad")[0] == 401


def test_pause_and_resume_endpoint(app):
    make, _ = app
    base, _, cfg, *_ = make()
    assert call(base, "GET", "/status", token=None)[1]["paused"] is False
    assert call(base, "POST", "/api/pause", {"paused": True}, token=None)[0] == 401
    assert cfg.paused is False
    status, body, _ = call(base, "POST", "/api/pause", {"paused": True})
    assert status == 200 and body["paused"] is True and cfg.paused is True
    assert call(base, "GET", "/status", token=None)[1]["paused"] is True  # the phone app / page can see it
    assert call(base, "POST", "/api/pause", {"paused": False})[1]["paused"] is False
    assert cfg.paused is False
    assert call(base, "POST", "/api/pause", {"paused": "yes"})[0] == 400
    assert call(base, "POST", "/api/pause", {})[0] == 400


def test_account_and_album_links_are_behind_the_token_not_in_the_open_status(app):
    make, _ = app
    base, httpd, cfg, *_ = make()
    # find the worker behind the server through its handler closure is awkward; use a fresh status call instead
    open_status = call(base, "GET", "/status", token=None, raw=True)[1]
    assert b"immich_user" not in open_status and b"@" not in open_status  # no e-mail on the open endpoint
    status, body, _ = call(base, "GET", "/api/config")
    assert status == 200
    assert "immich_user" in body["readonly"] and body["readonly"]["albums"] == []
    assert call(base, "GET", "/api/config", token=None)[0] == 401
