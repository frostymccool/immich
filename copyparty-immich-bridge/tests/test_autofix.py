"""Automatic correction: only strong evidence changes anything, and only in Immich."""

import os
import time
from datetime import datetime, timedelta

import pytest

from bridge.autofix import AutoFix, evaluate
from bridge.state import StateStore
from tests.test_geofix import KYOTO, LISBON, asset, rig  # noqa: F401

CLIP = "00000000-0000-4000-8000-000000009999"


def ref(minutes, where=KYOTO):
    return {"id": f"r{minutes}", "utc": datetime(2026, 5, 1, 5, 0) + timedelta(minutes=minutes), "lat": where[0], "lon": where[1], "zone": "Asia/Tokyo"}


NOW = datetime(2026, 5, 1, 5, 0)


def test_two_agreeing_photos_are_enough():
    best, why = evaluate(NOW, [ref(-20), ref(25)])
    assert best["id"] == "r-20" and why == ""


def test_one_photo_counts_only_when_close():
    assert evaluate(NOW, [ref(8)])[0] is not None
    best, why = evaluate(NOW, [ref(25)])
    assert best is None and "only one" in why


def test_nothing_within_the_window_changes_nothing():
    best, why = evaluate(NOW, [ref(47), ref(-90)])
    assert best is None and "no geotagged" in why


def test_photos_in_different_places_mean_travelling():
    best, why = evaluate(NOW, [ref(-10), ref(10, LISBON)])
    assert best is None and "disagree" in why


@pytest.fixture
def auto(rig, tmp_path):  # noqa: F811
    state = StateStore(str(tmp_path / "state.db"))
    fix = AutoFix(str(tmp_path / "autofix.db"), rig.gf, state, rig.client)

    def imported(path, tags_exif=None):
        st = os.stat(path)
        state.record_success(path, st.st_size, st.st_mtime, "a" * 40, "imported", CLIP)
        rig.stub.assets.append({"id": CLIP, "fileCreatedAt": "2020-01-01T00:00:00.000Z", "localDateTime": "2020-01-01T00:00:00.000Z",
                                "exifInfo": tags_exif or {"latitude": None, "longitude": None, "dateTimeOriginal": "2026-05-01T05:20:00.000Z"}})
    yield fix, imported, state
    fix.close()
    state.close()


def test_a_clip_with_a_known_instant_gets_the_place_and_keeps_its_instant(rig, auto):  # noqa: F811
    fix, imported, _ = auto
    # camera still on UTC-4; the true instant 05:20 UTC is between the Kyoto phone photos
    imported(rig.add("Trip/VID_20260501_012000_002.mp4", {"CreateDate": "2026:05:01 05:20:00"}))
    assert fix.run_once() == {"applied": 1}
    aid, fields = rig.stub.asset_updates[0]
    assert aid == CLIP and (fields["latitude"], fields["longitude"]) == KYOTO
    assert fields["dateTimeOriginal"] == "2026-05-01T14:20:00+09:00"  # same instant, Kyoto's local time
    row = fix.describe()["applied"][0]
    assert row["old_time"] == "2026-05-01T05:20:00.000Z" and row["zone"] == "Asia/Tokyo"
    assert fix.run_once() == {}  # done once


def test_a_clock_with_no_zone_is_left_for_review(rig, auto):  # noqa: F811
    fix, imported, _ = auto
    imported(rig.add("Trip/GX010001.MP4", {"CreateDate": "2026:05:01 14:03:22", "Model": "HERO11 Black"}))
    assert fix.run_once() == {"review": 1}
    assert not rig.stub.__dict__.get("asset_updates")
    assert "no time zone" in fix.describe()["review"][0]["reason"]


def test_an_asset_that_already_has_a_place_is_never_touched(rig, auto):  # noqa: F811
    fix, imported, _ = auto
    imported(rig.add("Trip/VID_20260501_012000_002.mp4", {"CreateDate": "2026:05:01 05:20:00"}), {"latitude": 1.0, "longitude": 2.0})
    assert fix.run_once() == {"has_place": 1}
    assert not rig.stub.__dict__.get("asset_updates")


def test_files_immich_already_had_are_never_corrected(rig, auto):  # noqa: F811
    fix, _, state = auto
    path = rig.add("Trip/VID_20260501_012000_002.mp4", {"CreateDate": "2026:05:01 05:20:00"})
    st = os.stat(path)
    state.record_success(path, st.st_size, st.st_mtime, "a" * 40, "duplicate", CLIP)
    assert fix.run_once() == {}


def test_the_page_can_read_the_result_and_start_a_pass(rig, auto, tmp_path):  # noqa: F811
    import threading

    from bridge.config import Config
    from bridge.logbuffer import RingLogHandler
    from bridge.server import serve
    from bridge.settings import SettingsStore
    from bridge.worker import ImportWorker
    from tests.test_webapi import TOKEN, call

    fix, imported, state = auto
    imported(rig.add("Trip/VID_20260501_012000_002.mp4", {"CreateDate": "2026:05:01 05:20:00"}))
    rig.gf.autofix = fix
    cfg = Config(immich_url=rig.stub.url, api_key="key", watch_dirs=[str(rig.root)], state_db=str(tmp_path / "state.db"),
                 settings_file=str(tmp_path / "settings.json"), browse_roots=[str(rig.root)], token=TOKEN, bind_host="127.0.0.1", bind_port=0)
    worker = ImportWorker(cfg, state, rig.client, {"mp4"})
    httpd = serve(cfg, state, worker, SettingsStore(cfg, cfg.settings_file, cfg.browse_roots), RingLogHandler(50), geofix=rig.gf)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{httpd.server_port}"
    try:
        assert call(base, "POST", "/api/geofix/auto/run", {})[0] == 200
        end = time.time() + 5
        while time.time() < end and call(base, "GET", "/api/geofix/auto")[1]["counts"].get("applied") != 1:
            time.sleep(0.05)
        assert call(base, "GET", "/api/geofix/auto")[1]["counts"] == {"applied": 1}
        assert call(base, "GET", "/api/geofix/auto", token=None)[0] in (401, 403)
    finally:
        httpd.shutdown()
        httpd.server_close()
