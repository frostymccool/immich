"""Fix locations: scan -> suggest from the person's own Immich photos -> accept -> sidecar sent at import.

exiftool is replaced by tests/fake_exiftool.py (see its note): these tests prove the bridge's own logic, not what
the real tool prints for a real GoPro file.
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

import pytest

from bridge.config import Config
from bridge.geofix import GeoFix, GeoFixError, build_sidecar, neighbour_from_asset, parse_exif_time, parse_offset, rank_suggestions
from bridge.immich import ImmichClient
from bridge.logbuffer import RingLogHandler
from bridge.server import serve
from bridge.settings import SettingsStore
from bridge.state import StateStore
from bridge.worker import ImportWorker
from tests.stub_immich import StubImmich
from tests.test_webapi import TOKEN, call

FAKE = os.path.join(os.path.dirname(__file__), "fake_exiftool.py")
KYOTO, LISBON, HOME = (35.0116, 135.7681), (38.7223, -9.1393), (51.0447, -114.0719)


def asset(n, utc, offset_min, where, city, country, zone):
    local = utc + timedelta(minutes=offset_min)
    return {"id": f"00000000-0000-4000-8000-{n:012d}", "fileCreatedAt": utc.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "localDateTime": local.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "exifInfo": {"latitude": where[0], "longitude": where[1], "city": city, "state": "", "country": country, "timeZone": zone}}


def kyoto_trip():
    """The owner was in Kyoto (UTC+9) on 1 May: phone photos 13:30-15:00 local; and at home (UTC-6) the days before."""
    out = [asset(i, datetime(2026, 5, 1, 4, 30) + timedelta(minutes=20 * i), 540, KYOTO, "Kyoto", "Japan", "Asia/Tokyo") for i in range(5)]
    # home photos whose INSTANT is close to the camera's wall-clock digits, to prove the match is by local time
    out += [asset(100 + i, datetime(2026, 4, 28, 14, 0) + timedelta(minutes=30 * i), -360, HOME, "Calgary", "Canada", "America/Edmonton") for i in range(4)]
    return out


def test_exif_times_and_offsets_are_parsed():
    assert parse_exif_time("2026:05:01 14:03:22") == (datetime(2026, 5, 1, 14, 3, 22), None)
    assert parse_exif_time("2026:05:01 14:03:22.50+09:00") == (datetime(2026, 5, 1, 14, 3, 22), 540)
    assert parse_exif_time("2026:05:01 14:03:22Z") == (datetime(2026, 5, 1, 14, 3, 22), 0)
    assert parse_exif_time("0000:00:00 00:00:00") == (None, None) and parse_exif_time(None) == (None, None)
    assert parse_exif_time("1904:01:01 00:00:00") == (None, None)  # an unset QuickTime clock is not a date
    assert parse_offset("-03:30") == -210 and parse_offset("+0545") == 345 and parse_offset("nonsense") is None
    assert parse_offset("+19:00") is None


def test_sidecar_holds_the_place_and_the_local_time_with_its_zone():
    xml = build_sidecar(datetime(2026, 5, 1, 14, 3, 22), 540, KYOTO[0], -9.1393).decode()
    root = ET.fromstring(xml[xml.index("<x:xmpmeta"): xml.index("<?xpacket end")])
    ns = {"exif": "http://ns.adobe.com/exif/1.0/"}
    assert root.find(".//exif:DateTimeOriginal", ns).text == "2026-05-01T14:03:22+09:00"
    assert root.find(".//exif:GPSLatitude", ns).text == "35,0.696000N"
    assert root.find(".//exif:GPSLongitude", ns).text == "9,8.358000W"
    # a file that already knows its zone only gets the place
    only_place = build_sidecar(None, None, KYOTO[0], KYOTO[1]).decode()
    assert "DateTimeOriginal" not in only_place and "GPSLatitude" in only_place


def test_a_clock_without_a_zone_is_matched_by_local_time_not_by_instant():
    ns = [neighbour_from_asset(a) for a in kyoto_trip()]
    # camera says 14:03-14:40 on 1 May, no zone. By instant that is near nothing; by wall clock it is Kyoto.
    got = rank_suggestions(datetime(2026, 5, 1, 14, 3), datetime(2026, 5, 1, 14, 40), None, ns)
    assert got[0]["label"] == "Kyoto, Japan" and got[0]["offset_min"] == 540 and got[0]["zone"] == "Asia/Tokyo"
    assert got[0]["confidence"] == "high" and got[0]["count"] == 5 and got[0]["gap_seconds"] == 0
    assert [g["label"] for g in got[1:]] == ["Calgary, Canada"] and got[1]["confidence"] == "low"


def test_a_file_with_a_known_zone_is_matched_by_the_true_instant():
    ns = [neighbour_from_asset(a) for a in kyoto_trip()]
    # 08:10 in Calgary (UTC-6) on 28 April = 14:10 UTC: the home photos, although Kyoto's wall clock never matches
    got = rank_suggestions(datetime(2026, 4, 28, 8, 10), datetime(2026, 4, 28, 8, 10), -360, ns)
    assert got[0]["label"] == "Calgary, Canada" and got[0]["gap_seconds"] == 600  # 10 min from the 14:00 UTC photo


def test_assets_without_gps_or_times_are_no_evidence():
    a = asset(1, datetime(2026, 5, 1), 0, (0, 0), "", "", "")
    assert neighbour_from_asset(a) is None
    assert neighbour_from_asset({"id": "x", "exifInfo": {"latitude": 1.0, "longitude": 2.0}}) is None


class Rig:
    """A folder of camera files + the fake exiftool + a stub Immich with the owner's phone photos."""

    def __init__(self, tmp_path, monkeypatch, stub):
        self.root = tmp_path / "media"
        self.stub = stub
        self.manifest = tmp_path / "manifest.json"
        self.calls = tmp_path / "exiftool-calls.log"
        self.tags: dict = {}
        monkeypatch.setenv("FAKE_EXIFTOOL_MANIFEST", str(self.manifest))
        monkeypatch.setenv("FAKE_EXIFTOOL_LOG", str(self.calls))
        monkeypatch.setattr("bridge.geofix.REVERSE_GEOCODE", False)  # tests never ask OpenStreetMap
        self.client = ImmichClient(stub.url, "key", "dev", timeout=3)
        self.gf = GeoFix(str(tmp_path / "geofix.db"), lambda: [str(self.root)], lambda: {"jpg", "mp4", "insv"}, exiftool=FAKE)

    def add(self, rel, tags, content=None):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if content is not None else rel.encode() * 3)
        self.tags[os.path.basename(rel)] = tags
        self.manifest.write_text(json.dumps(self.tags))
        return str(path)

    def scan(self, folder=None, search=True):
        self.gf.start_scan(folder or str(self.root), "main", self.client.search_metadata if search else None)
        end = time.time() + 10
        while self.gf.status["running"] and time.time() < end:
            time.sleep(0.02)
        assert not self.gf.status["running"]
        return self.gf.describe()


@pytest.fixture
def rig(tmp_path, monkeypatch):
    with StubImmich() as stub:
        stub.assets = kyoto_trip()
        r = Rig(tmp_path, monkeypatch, stub)
        yield r
        r.gf.close()
        r.client.close()


def gopro_day(rig):
    a = rig.add("Kyoto walk/GX010001.MP4", {"CreateDate": "2026:05:01 14:03:22", "Make": "GoPro", "Model": "HERO11 Black"})
    b = rig.add("Kyoto walk/GX010002.MP4", {"CreateDate": "2026:05:01 14:40:00", "Make": "GoPro", "Model": "HERO11 Black"})
    return a, b


def test_scan_groups_files_and_suggests_the_place(rig):
    gopro_day(rig)
    rig.add("Kyoto walk/GX010009.MP4", {"CreateDate": "2026:05:01 21:30:00"})  # > 3 h later: its own group
    rig.add("Kyoto walk/IMG_phone.jpg", {"DateTimeOriginal": "2026:05:01 14:10:00", "OffsetTimeOriginal": "+09:00",
                                         "GPSLatitude": 35.01, "GPSLongitude": 135.76})  # complete: left alone
    rig.add("Kyoto walk/notes.txt", {})
    out = rig.scan()
    assert out["status"]["phase"] == "done" and out["status"]["error"] == ""
    assert out["summary"] == {"files": 4, "fine": 1, "need": 3, "accepted": 0, "skipped": 0, "open": 3, "confident": 1}
    first, second = out["sessions"]
    assert (first["need_count"], first["start"], first["end"]) == (2, "2026-05-01T14:03:22", "2026-05-01T14:40:00")
    assert first["needs"] == {"place and time zone": 2} and first["cameras"] == ["GoPro HERO11 Black"] and first["videos"] == 2
    top = first["suggestions"][0]
    assert (top["label"], top["offset_min"], top["confidence"]) == ("Kyoto, Japan", 540, "high") and len(top["samples"]) == 3
    assert second["need_count"] == 1 and second["suggestions"][0]["label"] == "Kyoto, Japan" and second["suggestions"][0]["confidence"] == "medium"
    # the question to Immich covers every possible zone of the camera (UTC-12..+14) around the group
    q = rig.stub.searches[0]
    assert q["takenAfter"][:19] == "2026-04-30T12:03:22" and q["takenBefore"][:19] == "2026-05-02T14:40:00" and q["withExif"] is True


def test_real_camera_tag_shapes_insta360_uses_the_clock_in_its_name(rig):
    """Tags exactly as real exiftool -json -n printed them for a HERO9 and an Insta360 video (no Make on either, no
    zone, no GPS). Insta360's CreateDate is the camera clock already turned into UTC (here 9 h behind the name), so
    the wall clock comes from the name; GoPro's CreateDate IS the wall clock."""
    rig.add("Kyoto walk/GX013948.MP4", {"CreateDate": "2026:05:01 14:03:22", "MediaCreateDate": "2026:05:01 14:03:22",
                                        "Model": "HERO9 Black"})
    rig.add("Kyoto walk/VID_20260501_142000_00_001.insv", {"CreateDate": "2026:05:01 05:20:00",
                                                           "MediaCreateDate": "2026:05:01 05:20:00"})
    out = rig.scan()
    (only,) = out["sessions"]  # both on the same afternoon: ONE group, not split by the 9 h UTC gap
    assert (only["start"], only["end"]) == ("2026-05-01T14:03:22", "2026-05-01T14:20:00")
    assert only["needs"] == {"place and time zone": 2} and only["suggestions"][0]["label"] == "Kyoto, Japan"


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="needs real ffmpeg")
def test_a_photo_immich_has_no_preview_for_is_previewed_from_its_original(rig, tmp_path):
    """Real Immich answers 404 'Asset media not found' for some videos' previews while the original is there."""
    clip = tmp_path / "orig.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=1920x1080:d=2", str(clip)], check=True)
    aid = "00000000-0000-4000-8000-000000000042"
    rig.stub.no_preview.add(aid)
    rig.stub.originals[aid] = (clip.read_bytes(), "video/mp4")
    small, ctype = rig.gf.immich_preview(rig.client, aid, big=False)
    big, _ = rig.gf.immich_preview(rig.client, aid, big=True)
    assert ctype == "image/jpeg" and small[:2] == big[:2] == b"\xff\xd8" and len(big) > len(small)
    assert sum("/original" in p for p in rig.stub.paths) == 1  # downloaded once for both sizes, then cached
    assert not [n for n in os.listdir(rig.gf._thumbs) if n.endswith(".original")]  # the download is not kept
    gone = "00000000-0000-4000-8000-000000000043"
    rig.stub.no_preview.add(gone)  # no preview AND no original: a clear error, not a crash
    with pytest.raises(GeoFixError):
        rig.gf.immich_preview(rig.client, gone, big=False)


def test_metadata_cached_by_an_older_reader_is_read_again(rig):
    clip = rig.add("Kyoto walk/GX010001.MP4", {"CreateDate": "2026:05:01 14:03:22"})
    rig.gf.close()
    db = sqlite3.connect(str(rig.root.parent / "geofix.db"))
    st = os.stat(clip)  # what 0.3.0 left behind: its table shape, the right size/mtime but no time, no reader version
    db.executescript("""DROP TABLE files; CREATE TABLE files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL, taken TEXT,
        offset_min INTEGER, lat REAL, lon REAL, make TEXT, model TEXT);
        DROP TABLE decisions; CREATE TABLE decisions (name TEXT, size INTEGER, path TEXT, status TEXT, lat REAL, lon REAL,
        offset_min INTEGER, taken TEXT, label TEXT, source TEXT, decided_at REAL, applied_at REAL, applied_note TEXT,
        PRIMARY KEY (name, size));""")
    db.execute("INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?)", (clip, st.st_size, st.st_mtime, None, None, None, None, "", ""))
    db.execute("INSERT INTO decisions (name, size, status) VALUES ('kept.MP4', 1, 'skipped')")
    db.execute("PRAGMA user_version = 0")
    db.commit()
    db.close()
    rig.gf = GeoFix(str(rig.root.parent / "geofix.db"), lambda: [str(rig.root)], lambda: {"jpg", "mp4", "insv"}, exiftool=FAKE)
    assert rig.gf._read_metadata([clip])[0]["taken"] == datetime(2026, 5, 1, 14, 3, 22)
    assert rig.gf._db.execute("SELECT status FROM decisions WHERE name='kept.MP4'").fetchone() == ("skipped",)


def test_the_search_widens_only_when_nothing_is_near(rig):
    rig.add("old/GOPR0001.JPG", {"DateTimeOriginal": "2026:05:09 10:00:00"})  # 8 days after the Kyoto photos
    out = rig.scan()
    s = out["sessions"][0]
    assert s["searched_hours"] == 336 and s["suggestions"][0]["label"] == "Kyoto, Japan" and s["suggestions"][0]["confidence"] == "low"
    assert len(rig.stub.searches) == 3  # 12 h, 3 days, 14 days
    rig.add("older/GOPR0002.JPG", {"DateTimeOriginal": "2025:01:01 10:00:00"})
    s = [x for x in rig.scan()["sessions"] if x["folder"].endswith("older")][0]
    assert s["suggestions"] == [] and s["searched_hours"] == 336


def test_accepting_makes_a_sidecar_and_nothing_is_written_next_to_the_files(rig):
    a, b = gopro_day(rig)
    own = rig.add("Kyoto walk/IMG_0003.jpg", {"DateTimeOriginal": "2026:05:01 14:20:00", "OffsetTimeOriginal": "+09:00"})
    before = sorted(os.listdir(os.path.dirname(a)))
    sid = rig.scan()["sessions"][0]["id"]
    assert rig.gf.sidecar_for(a) is None
    rig.gf.decide(sid, "accept", 0)
    xml = rig.gf.sidecar_for(a).decode()
    assert "<exif:DateTimeOriginal>2026-05-01T14:03:22+09:00</exif:DateTimeOriginal>" in xml and "<exif:GPSLatitude>35,0.696000N" in xml
    # the photo that knows its own zone only gets the place: its own clock is not overridden
    own_xml = rig.gf.sidecar_for(own).decode()
    assert "GPSLatitude" in own_xml and "DateTimeOriginal" not in own_xml
    assert sorted(os.listdir(os.path.dirname(a))) == before
    s = rig.gf.describe()["sessions"][0]
    # confident: the exact spot of the photos is the default (no saved place, OpenStreetMap off in tests)
    assert s["decision"]["status"] == "accepted" and s["decision"]["label"] == "Exact spot of your photos, Kyoto, Japan"
    assert s["states"] == {"accepted": 3} and s["decision"]["zone"] == "Asia/Tokyo"
    ex = s["example"]
    assert (ex["name"], ex["local"], ex["offset"], ex["utc"]) == ("GX010001.MP4", "2026-05-01 14:03", "+09:00", "2026-05-01 05:03")
    # before: Immich reads the zone-less camera clock as UTC; after: the same wall clock in Tokyo = 9 h earlier
    assert ex["before"] == {"local": "2026-05-01 14:03", "zone": "UTC"} and ex["shift_minutes"] == -540
    assert ex["after"] == {"local": "2026-05-01 14:03", "offset": "+09:00", "abbr": "JST", "zone": "Asia/Tokyo"}
    rig.gf.decide(sid, "clear")
    assert rig.gf.sidecar_for(a) is None and rig.gf.describe()["sessions"][0]["decision"] is None


def test_a_suggestion_offers_the_exact_spot_and_the_town_each_with_its_zone_name(rig, monkeypatch):
    gopro_day(rig)
    town = [{"name": "Kyoto", "latitude": 35.02, "longitude": 135.75, "admin1name": "Kyoto"},
            {"name": "Kyoto", "latitude": 10.0, "longitude": 10.0}]  # a namesake far away is never used
    rig.gf.start_scan(str(rig.root), "main", rig.client.search_metadata, lambda name: town)
    end = time.time() + 10
    while rig.gf.status["running"] and time.time() < end:
        time.sleep(0.02)
    s = rig.gf.describe()["sessions"][0]
    top = s["suggestions"][0]
    spot, area = top["levels"]
    assert top["default_level"] == 0 and spot["kind"] == "spot" and area["kind"] == "town"
    assert (spot["lat"], spot["lon"]) == KYOTO and spot["photos"] == 5 and spot["radius_m"] == 25
    assert spot["label"] == "Exact spot of your photos" and not spot["saved"]
    assert (area["lat"], area["lon"], area["label"]) == (35.02, 135.75, "Kyoto, Japan")
    assert spot["zone"] == area["zone"] == "Asia/Tokyo" and spot["abbr"] == "JST" and spot["offset_min"] == 540
    assert spot["example"]["after"]["zone"] == "Asia/Tokyo" and s["before"] == {"local": "2026-05-01 14:03", "zone": "UTC"}
    assert [e["place"] for e in top["evidence"]] == ["Kyoto"] * 3  # the Immich photos shown as evidence, with their time
    # a saved place names the spot (and a far one does not)
    rig.gf.save_place("Hotel", KYOTO[0] + 0.0005, KYOTO[1], 150)
    rig.gf.save_place("Elsewhere", 0.0, 0.0)
    assert rig.gf.describe()["sessions"][0]["suggestions"][0]["levels"][0]["label"] == "Hotel"
    rig.gf.decide(s["id"], "accept", 0, level=1)  # the less exact choice
    d = rig.gf.describe()["sessions"][0]["decision"]
    assert d["label"] == "Kyoto, Japan" and (d["lat"], d["lon"]) == (35.02, 135.75)
    with pytest.raises(GeoFixError):
        rig.gf.decide(s["id"], "accept", 0, level=5)
    with pytest.raises(GeoFixError):
        rig.gf.save_place("  ", 1, 1)
    rig.gf.delete_place(rig.gf.saved_places()[0]["id"])
    assert [p["name"] for p in rig.gf.saved_places()] == ["Hotel"]


def test_the_exact_spot_is_the_densest_knot_and_a_loose_one_is_not_the_default():
    from bridge.geofix import rank_suggestions
    start = datetime(2026, 5, 1, 14, 0)

    def n(i, lat, lon, minutes):
        return {"id": f"a{i}", "utc": start - timedelta(hours=9) + timedelta(minutes=minutes), "local": start + timedelta(minutes=minutes),
                "offset": 540, "lat": lat, "lon": lon, "zone": "", "city": "Kyoto", "state": "", "country": "Japan"}

    # nearest in time: one photo 120 m north; then four at home; the spot is home, not the middle of all five
    home = [n(i, KYOTO[0], KYOTO[1] + 0.00001 * i, 30 + i) for i in range(4)]
    top = rank_suggestions(start, start, None, [n(9, KYOTO[0] + 0.00108, KYOTO[1], 5)] + home)[0]
    assert top["spot"]["photos"] == 4 and abs(top["spot"]["lat"] - KYOTO[0]) < 0.0001 and top["spot"]["radius_m"] == 25
    # six photos strewn ~60 m apart with no knot: the spot is offered, but the town is the default even when confident
    gf = GeoFix(":memory:", lambda: [], lambda: set())
    strewn = [n(i, KYOTO[0] + 0.0006 * (i % 3), KYOTO[1] + 0.0007 * (i // 3), i) for i in range(6)]
    g = rank_suggestions(start, start, None, strewn)[0]
    g["confidence"] = "high"
    gf._add_levels(g, {"need": [{"taken": start}]}, None)
    assert g["spot"]["photos"] < 3 and g["spot"]["nearby"] == 6 and g["default_level"] == 1
    top["confidence"] = "high"  # the home knot (4 of 5 photos, 25 m) IS the default
    gf._add_levels(top, {"need": [{"taken": start}]}, None)
    assert top["default_level"] == 0
    gf.close()


def test_each_file_gets_its_own_daylight_saving_offset():
    """A group that spans the start of daylight saving: each file gets the zone's offset at its own time."""
    from bridge.geofix import zone_at, zone_offset
    zone = zone_at(37.66, -121.87)
    assert zone == "America/Los_Angeles"
    assert zone_offset(zone, datetime(2025, 3, 9, 1, 30)) == (-480, "PST")
    assert zone_offset(zone, datetime(2025, 3, 9, 4, 0)) == (-420, "PDT")
    assert zone_at(0.0, -160.0) in ("Etc/GMT+11", "")  # open sea: an Etc zone or nothing, never a crash


def test_street_name_comes_from_openstreetmap_once_and_is_cached(rig, monkeypatch):
    import bridge.geofix as gfm
    monkeypatch.setattr(gfm, "REVERSE_GEOCODE", True)
    asked = []

    class Resp:
        status_code = 200

        def json(self):
            return {"address": {"house_number": "12", "road": "Example Road", "city": "Sometown"}, "display_name": "12, Example Road, Sometown"}

    def fake_get(url, params, timeout, headers):
        asked.append((url, params["lat"], params["lon"], headers["User-Agent"]))
        return Resp()

    monkeypatch.setattr(gfm.requests, "get", fake_get)
    monkeypatch.setattr(gfm.time, "sleep", lambda s: None)
    assert rig.gf._street_name(35.0116, 135.7681) == "12 Example Road"
    assert rig.gf._street_name(35.01161, 135.76811) == "12 Example Road"  # same ~10 m cell: from the cache
    assert len(asked) == 1 and asked[0][0] == gfm.NOMINATIM_URL and asked[0][3].startswith("copyparty-immich-bridge/")
    monkeypatch.setattr(gfm, "REVERSE_GEOCODE", False)
    assert rig.gf._street_name(1.0, 1.0) == "" and len(asked) == 1  # switched off: never asked


def test_the_choice_follows_a_file_that_is_moved_to_another_folder(rig):
    a, _ = gopro_day(rig)
    rig.gf.decide(rig.scan()["sessions"][0]["id"], "accept", 0)
    moved = rig.root / "ian-folder" / "Kyoto walk" / "GX010001.MP4"
    moved.parent.mkdir(parents=True)
    os.rename(a, moved)
    assert b"GPSLatitude" in rig.gf.sidecar_for(str(moved))
    assert rig.gf.sidecar_for(str(rig.root / "nowhere.mp4")) is None


def test_skip_by_hand_and_accept_confident(rig):
    gopro_day(rig)
    rig.add("evening/GX010009.MP4", {"CreateDate": "2026:05:01 21:30:00"})
    rig.add("undated/GX019999.MP4", {})
    out = rig.scan()
    by = {os.path.basename(s["folder"]): s for s in out["sessions"]}
    assert by["undated"]["start"] is None and by["undated"]["suggestions"] == []
    assert rig.gf.accept_confident() == 1  # only the confident one; 'likely' ones wait for a person
    rig.gf.decide(by["evening"]["id"], "skip")
    rig.gf.decide(by["undated"]["id"], "accept", custom={"lat": LISBON[0], "lon": LISBON[1], "offset_min": None, "label": "Lisbon"})
    out = rig.gf.describe()
    assert out["summary"]["accepted"] == 3 and out["summary"]["skipped"] == 1 and out["summary"]["open"] == 0 and out["summary"]["confident"] == 0
    undated_xml = rig.gf.sidecar_for(str(rig.root / "undated" / "GX019999.MP4")).decode()
    assert "38,43.338000N" in undated_xml and "9,8.358000W" in undated_xml and "DateTimeOriginal" not in undated_xml
    assert rig.gf.sidecar_for(str(rig.root / "evening" / "GX010009.MP4")) is None
    for bad in ({"lat": 91, "lon": 0}, {"lat": 1, "lon": 2, "offset_min": 7}, {"lat": "1", "lon": 2}):
        with pytest.raises(GeoFixError):
            rig.gf.decide(by["undated"]["id"], "accept", custom=bad)
    with pytest.raises(GeoFixError):
        rig.gf.decide(by["evening"]["id"], "accept", 5)
    with pytest.raises(GeoFixError):
        rig.gf.decide("nope", "skip")


def test_a_second_scan_reads_only_new_files(rig):
    gopro_day(rig)
    rig.scan()
    rig.calls.write_text("")
    rig.add("Kyoto walk/GX010003.MP4", {"CreateDate": "2026:05:01 15:00:00"})
    out = rig.scan()
    asked = [p for line in rig.calls.read_text().splitlines() for p in json.loads(line)]
    assert [os.path.basename(p) for p in asked] == ["GX010003.MP4"] and out["sessions"][0]["need_count"] == 3


def test_immich_trouble_keeps_the_scan_and_says_why(rig):
    gopro_day(rig)
    rig.stub.forbid_search = True
    out = rig.scan()
    assert out["status"]["phase"] == "done" and "asset.read" in out["status"]["error"]
    assert out["sessions"][0]["need_count"] == 2 and out["sessions"][0]["suggestions"] == []


def test_folders_outside_the_mounted_ones_and_a_missing_exiftool_are_refused(rig, tmp_path):
    with pytest.raises(GeoFixError) as e:
        rig.gf.start_scan(str(tmp_path), "main", None)
    assert e.value.code == 403
    link = rig.root / "escape"
    rig.root.mkdir(exist_ok=True)
    os.symlink(str(tmp_path), link)
    with pytest.raises(GeoFixError):
        rig.gf.start_scan(str(link), "main", None)
    none = GeoFix(str(tmp_path / "g2.db"), lambda: [str(rig.root)], lambda: {"jpg"}, exiftool="/nonexistent/exiftool")
    with pytest.raises(GeoFixError) as e:
        none.start_scan(str(rig.root), "main", None)
    assert e.value.code == 503 and "exiftool" in str(e.value)
    none.close()


def test_previews_are_only_for_files_of_the_scan(rig, tmp_path):
    a, _ = gopro_day(rig)
    rig.scan()
    secret = tmp_path / "secret.jpg"
    secret.write_bytes(b"x")
    with pytest.raises(GeoFixError) as e:
        rig.gf.thumbnail(str(secret))
    assert e.value.code == 404
    with pytest.raises(GeoFixError):  # in the scan, but not a real video: a clean "no preview", never a crash
        rig.gf.thumbnail(a)


# -- through the web API and the import worker -----------------------------------------------------------------


@pytest.fixture
def live(rig, tmp_path):
    cfg = Config(immich_url=rig.stub.url, api_key="key", watch_dirs=[str(rig.root / "inbox")], state_db=str(tmp_path / "state.db"),
                 settings_file=str(tmp_path / "settings.json"), browse_roots=[str(rig.root)], min_file_age=0, token=TOKEN,
                 bind_host="127.0.0.1", bind_port=0)
    (rig.root / "inbox").mkdir(parents=True)
    state = StateStore(cfg.state_db)
    worker = ImportWorker(cfg, state, rig.client, {"jpg", "mp4"})
    ImportWorker.geofix = rig.gf
    worker.start()
    httpd = serve(cfg, state, worker, SettingsStore(cfg, cfg.settings_file, cfg.browse_roots), RingLogHandler(50), geofix=rig.gf)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_port}", worker
    ImportWorker.geofix = None
    worker.stop()
    httpd.shutdown()
    httpd.server_close()
    state.close()


def wait_for(cond, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return False


def test_the_whole_way_scan_accept_then_the_import_carries_the_sidecar(rig, live):
    base, worker = live
    a = rig.add("inbox/Kyoto walk/GX010001.MP4", {"CreateDate": "2026:05:01 14:03:22"})
    plain = rig.add("inbox/Kyoto walk/IMG_2.jpg", {"DateTimeOriginal": "2026:05:01 14:10:00", "GPSLatitude": 35.0, "GPSLongitude": 135.7})
    assert call(base, "GET", "/api/geofix", token=None)[0] == 401
    assert call(base, "POST", "/api/geofix/scan", {"folder": "/etc"})[0] == 403
    assert call(base, "POST", "/api/geofix/scan", {"folder": str(rig.root / "inbox")})[0] == 200
    assert wait_for(lambda: call(base, "GET", "/api/geofix")[1]["status"]["phase"] == "done")
    st = call(base, "GET", "/api/geofix")[1]
    assert st["tools"]["exiftool"] == "13.00-fake" and st["summary"]["need"] == 1
    sid = st["sessions"][0]["id"]
    assert call(base, "POST", "/api/geofix/decide", {"session": sid, "action": "accept", "suggestion": 0})[0] == 200
    code, xml, _ = call(base, "GET", "/api/geofix/sidecar?path=" + urllib.request.quote(a), raw=True)
    assert code == 200 and b"2026-05-01T14:03:22+09:00" in xml
    code, png, headers = call(base, "GET", "/api/geofix/immich-thumb?id=" + st["sessions"][0]["suggestions"][0]["samples"][0], raw=True)
    assert code == 200 and png.startswith(b"\x89PNG") and headers["Content-Type"] == "image/png"
    assert call(base, "GET", "/api/geofix/immich-thumb?id=../../etc/passwd")[0] == 400
    sample = st["sessions"][0]["suggestions"][0]["samples"][0]
    assert call(base, "GET", f"/api/geofix/immich-thumb?id={sample}&big=1", raw=True)[0] == 200  # enlarged view
    assert any("size=preview" in p for p in rig.stub.paths if "/thumbnail" in p)
    rig.stub.places = [{"name": "Lisbon", "latitude": 38.72, "longitude": -9.14, "admin1name": "Lisbon"}]
    assert call(base, "GET", "/api/geofix/places?q=lis")[1]["places"] == [{"name": "Lisbon", "region": "Lisbon", "lat": 38.72, "lon": -9.14}]

    worker.enqueue(a, "test")
    worker.enqueue(plain, "test")
    assert wait_for(lambda: len(rig.stub.uploads) == 2)
    sent = {u["raw_len"]: u["sidecar"] for u in rig.stub.uploads}
    with_side = [s for s in sent.values() if s]
    assert len(with_side) == 1 and "<exif:GPSLatitude>35,0.696000N</exif:GPSLatitude>" in with_side[0] and with_side[0].rstrip().endswith("<?xpacket end='w'?>")
    assert wait_for(lambda: call(base, "GET", "/api/geofix")[1]["sessions"][0]["decision"]["notes"] == {"imported with this place": 1})


def test_a_file_already_in_immich_is_reported_as_not_changed(rig, live):
    base, worker = live
    a = rig.add("inbox/GX010001.MP4", {"CreateDate": "2026:05:01 14:03:22"})
    worker.enqueue(a, "test")
    assert wait_for(lambda: len(rig.stub.uploads) == 1) and rig.stub.uploads[0]["sidecar"] is None
    assert call(base, "POST", "/api/geofix/scan", {"folder": str(rig.root / "inbox")})[0] == 200
    assert wait_for(lambda: call(base, "GET", "/api/geofix")[1]["status"]["phase"] == "done")
    sid = call(base, "GET", "/api/geofix")[1]["sessions"][0]["id"]
    call(base, "POST", "/api/geofix/accept-confident", {})
    os.utime(a, (time.time(), time.time() - 5))  # looks new to the bridge again; Immich knows the checksum
    worker.enqueue(a, "test")
    assert wait_for(lambda: (call(base, "GET", "/api/geofix")[1]["sessions"][0]["decision"] or {}).get("notes") == {"already in Immich: not changed": 1})
    assert len(rig.stub.uploads) == 1 and sid


@pytest.mark.skipif(not (shutil.which("exiftool") and shutil.which("ffmpeg")), reason="needs real exiftool and ffmpeg")
def test_real_exiftool_reads_the_clock_of_a_video_whose_header_is_at_the_end(tmp_path):
    """GoPro/Insta360 videos keep their movie header (moov) at the END of the file, like ffmpeg's default mp4.

    With -fast2 exiftool stops before it and prints no dates at all (seen on real HERO9 / Insta360 files), so every
    video was scanned as having no time. This runs the REAL tool on such a file with the exact scan command.
    """
    clip = tmp_path / "GX010001.MP4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1", "-metadata",
                    "creation_time=2026-05-01T14:03:22Z", "-metadata", "model=HERO9 Black", str(clip)], check=True)
    gf = GeoFix(str(tmp_path / "geofix.db"), lambda: [str(tmp_path)], lambda: {"mp4"})
    try:
        tags = gf._exiftool_json([str(clip)])[str(clip)]
        assert tags.get("CreateDate") == "2026:05:01 14:03:22" and tags.get("MediaCreateDate") == "2026:05:01 14:03:22"
        assert not any(k in tags for k in ("GPSLatitude", "OffsetTimeOriginal"))  # video: no zone, no place -> both needed
        files = gf._read_metadata([str(clip)])
        assert files[0]["taken"] == datetime(2026, 5, 1, 14, 3, 22) and files[0]["need"] == "place and time zone"
    finally:
        gf.close()
