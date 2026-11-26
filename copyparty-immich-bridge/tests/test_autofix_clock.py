"""Wrong camera clocks: proven by the file (GoPro zone tag) or found from pictures of the same moment."""

import os
from datetime import datetime, timedelta

import pytest

from bridge import autofix as af
from bridge.autofix import NO_ZONE, AutoFix, clock_offset_from_pairs, describe_offset
from bridge.state import StateStore
from tests.test_geofix import KYOTO, LISBON, asset, rig  # noqa: F401

DIM = 12
CANON = {"Make": "Canon", "Model": "Canon EOS Rebel T7"}
# The camera clock: 8 h 11 min 45 s behind UTC (left on US Pacific time, and drifted)
CLOCK_S = -(8 * 3600 + 11 * 60 + 45)
PHONE_UTC = [datetime(2026, 5, 1, 4, 30) + timedelta(minutes=20 * i) for i in range(5)]  # the rig's Kyoto phone photos


def unit(i):
    return [1.0 if k == i else 0.0 for k in range(DIM)]


def phone_id(i):
    return f"00000000-0000-4000-8000-{i:012d}"


@pytest.fixture
def auto(rig, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setattr(af, "PAUSE_S", 0)
    state = StateStore(str(tmp_path / "state.db"))
    fix = AutoFix(str(tmp_path / "autofix.db"), rig.gf, state, rig.client, embed=lambda jpeg: unit(DIM - 1))
    n = [0]

    def imported(path, shown_utc, exif=None):
        """Imported by the bridge; Immich shows `shown_utc` as the capture instant (what it read from the file)."""
        n[0] += 1
        aid = f"11111111-0000-4000-8000-{n[0]:012d}"
        st = os.stat(path)
        state.record_success(path, st.st_size, st.st_mtime, f"{n[0]:040d}", "imported", aid)
        shown = shown_utc.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        rig.stub.assets.append({"id": aid, "fileCreatedAt": shown, "localDateTime": shown,
                                "exifInfo": {"latitude": None, "longitude": None, "dateTimeOriginal": shown, "timeZone": "UTC", **(exif or {})}})
        return aid

    def seed(aid, vec):
        with fix._lock:
            fix._db.execute("INSERT OR REPLACE INTO embeds VALUES (?,?)", (aid, __import__("json").dumps(vec)))
            fix._db.commit()

    yield fix, imported, seed, state
    fix.close()
    state.close()


def updates(rig):
    return dict(rig.stub.__dict__.get("asset_updates", []))


def canon_set(rig, imported, seed, n=5, folder="Temple"):
    ids = []
    for i in range(n):
        naive = PHONE_UTC[i] + timedelta(seconds=CLOCK_S)
        p = rig.add(f"{folder}/IMG_{5600 + i}.JPG", {"DateTimeOriginal": naive.strftime("%Y:%m:%d %H:%M:%S"), **CANON})
        aid = imported(p, naive)
        seed(aid, unit(i))
        ids.append(aid)
    return ids


# ---------------------------------------------------------------------------------------------- the rules


def test_agreeing_pairs_give_the_clock_and_scattered_ones_do_not():
    off, n, why = clock_offset_from_pairs([-29505, -29490, -29520, -29530, -40000])
    assert off == -29512.5 and n == 4 and why == ""
    assert clock_offset_from_pairs([-29505, -29500])[0] is None  # too few
    assert "do not agree" in clock_offset_from_pairs([0, 3600, 7200, -3600, 9000])[2]
    assert "more than a day" in clock_offset_from_pairs([-100000] * 3)[2]
    assert describe_offset(CLOCK_S) == "8 h 11 min behind UTC"


# ---------------------------------------------------------------------------------------------- proven by the file


def test_a_gopro_clip_with_a_zone_tag_gets_its_true_time_even_without_a_place(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    # HERO12: CreateDate is UTC, the zone tag says the camera was on UTC-5; Immich read 18:00 as 13:00 UTC
    p = rig.add("Lake/GX011688.MP4", {"CreateDate": "2026:06:10 18:00:15", "TimeZone": -300, "Make": "GoPro", "Model": "HERO12 Black"})
    aid = imported(p, datetime(2026, 6, 10, 13, 0, 15))
    assert fix.run_once().get("time_fixed") == 1
    assert updates(rig)[aid] == {"dateTimeOriginal": "2026-06-10T13:00:15-05:00"}
    row = fix.describe()["review"][0]
    assert row["reason"].startswith("time corrected (clock read from the file); no place yet")
    assert fix.run_once() == {}  # rechecked only later, and then the time is already right


def test_a_geotagged_clip_with_a_wrong_time_keeps_its_place_and_gets_its_time(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    p = rig.add("Lake/GX011694.MP4", {"CreateDate": "2026:06:10 17:21:37", "TimeZone": -300, "Model": "HERO13 Black",
                                      "GPSLatitude": 8.98, "GPSLongitude": -79.52})
    aid = imported(p, datetime(2026, 6, 10, 12, 21, 37), {"latitude": 8.98, "longitude": -79.52})
    assert fix.run_once().get("applied") == 1
    assert updates(rig)[aid] == {"dateTimeOriginal": "2026-06-10T12:21:37-05:00"}  # Panama is UTC-5 all year


def test_a_right_time_and_a_place_are_left_alone(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    p = rig.add("Lake/GX011700.MP4", {"CreateDate": "2026:06:10 17:21:37", "TimeZone": -300, "Model": "HERO13 Black"})
    imported(p, datetime(2026, 6, 10, 17, 21, 37), {"latitude": 8.98, "longitude": -79.52})
    rig.stub.assets[-1]["localDateTime"] = "2026-06-10T12:21:37.000Z"  # Immich shows it in the place's zone
    assert fix.run_once() == {"has_place": 1}
    assert updates(rig) == {}


# ---------------------------------------------------------------------------------------------- found from pictures


def test_a_camera_with_a_wrong_clock_is_aligned_by_pictures_of_the_same_moment(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    for i in range(5):
        seed(phone_id(i), unit(i))  # the phone photographed the same moments
    ids = canon_set(rig, imported, seed)
    first = fix.run_once()
    assert first == {"review": 5, "clock decided": 1} and updates(rig) == {}
    clock = fix.describe()["clocks"][0]
    assert clock["status"] == "decided" and clock["offset_s"] == CLOCK_S and clock["pairs"] == 5 and clock["zone"] == "Asia/Tokyo"
    assert fix.run_once() == {"applied": 5}
    got = updates(rig)
    assert got[ids[0]]["dateTimeOriginal"] == "2026-05-01T13:30:00+09:00"  # the true instant, in Kyoto time
    assert (got[ids[0]]["latitude"], got[ids[0]]["longitude"]) == KYOTO
    with fix._lock:
        whys = [r[0] for r in fix._db.execute("SELECT why FROM changes WHERE field='dateTimeOriginal'")]
    assert len(whys) == 5 and "8 h 11 min behind UTC" in whys[0]


def test_pictures_that_only_look_alike_at_other_times_change_nothing(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    for j, i in enumerate([3, 0, 4, 1, 2]):  # each Canon shot matches a phone shot, but at scattered moments
        seed(phone_id(i), unit(j))
    canon_set(rig, imported, seed)
    for _ in range(3):
        fix.run_once()
    assert updates(rig) == {}
    assert fix.describe()["clocks"][0]["status"] == "review"


def test_another_camera_with_an_unknown_clock_is_never_the_reference(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    for i in range(5):  # a second zone-less camera that "matches" perfectly, but its clock proves nothing
        naive = PHONE_UTC[i] + timedelta(hours=3)
        p = rig.add(f"Other/DSC_{i}.JPG", {"DateTimeOriginal": naive.strftime("%Y:%m:%d %H:%M:%S"), "Model": "NIKON Z 6"})
        seed(imported(p, naive), unit(i))
    canon_set(rig, imported, seed)
    fix.run_once()
    fix.run_once()
    assert updates(rig) == {}


def test_a_gopro_fixed_from_its_own_file_then_sets_a_camera_clock(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    rig.stub.assets = []  # no phone photos at all: only the GoPro's own clock can be trusted
    for i in range(4):
        true = PHONE_UTC[i]
        p = rig.add(f"Temple/GX01{1660 + i}.MP4", {"CreateDate": true.strftime("%Y:%m:%d %H:%M:%S"), "TimeZone": 540, "Model": "HERO12 Black"})
        seed(imported(p, true - timedelta(hours=9)), unit(i))  # Immich read the UTC clock as Kyoto local
    canon_set(rig, imported, seed, n=4)
    fix.run_once()  # GoPro times corrected; the Canon waits; its clock is decided from the corrected GoPro
    clock = fix.describe()["clocks"][0]
    assert clock["status"] == "decided" and clock["offset_s"] == CLOCK_S
    fix.run_once()
    canon = [u for a, u in updates(rig).items() if a.startswith("11111111") and "latitude" not in u]
    assert any(u["dateTimeOriginal"] == "2026-05-01T13:30:00+09:00" for u in canon)


def test_the_place_of_an_outing_comes_from_look_alike_photos_hours_away(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    # the phone photographed the temple 1 h before the GoPro clip (no geotagged photo within 30 min)
    p = rig.add("Temple/GX011690.MP4", {"CreateDate": "2026:05:01 07:00:00", "TimeZone": 540, "Model": "HERO12 Black"})
    aid = imported(p, datetime(2026, 4, 30, 22, 0))
    seed(aid, unit(0))
    for i in range(5):
        seed(phone_id(i), [0.8 if k == 0 else (0.6 if k == 1 else 0.0) for k in range(DIM)])  # same scene, cos 0.8
    assert fix.run_once().get("applied") == 1
    u = updates(rig)[aid]
    assert (u["latitude"], u["longitude"]) == KYOTO and u["dateTimeOriginal"] == "2026-05-01T16:00:00+09:00"


def test_look_alike_photos_in_two_places_give_no_place(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    rig.stub.assets.append(asset(900, datetime(2026, 5, 1, 6, 30), 0, LISBON, "Lisbon", "Portugal", "Europe/Lisbon"))
    p = rig.add("Temple/GX011691.MP4", {"CreateDate": "2026:05:01 07:00:00", "TimeZone": 540, "Model": "HERO12 Black"})
    aid = imported(p, datetime(2026, 4, 30, 22, 0))
    seed(aid, unit(0))
    for i in [*range(5), 900]:
        seed(phone_id(i), unit(0))
    assert fix.run_once().get("time_fixed") == 1
    assert "latitude" not in updates(rig)[aid] and "different places" in fix.describe()["review"][0]["reason"]


def test_a_trimmed_copy_without_the_zone_tag_follows_the_clips_numbered_next_to_it(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    p1 = rig.add("Lake/GX011694.MP4", {"CreateDate": "2026:06:10 17:21:37", "TimeZone": -300, "Model": "HERO13 Black"})
    imported(p1, datetime(2026, 6, 10, 12, 21, 37))
    p2 = rig.add("Lake/GX011695.MP4", {"CreateDate": "2026:06:10 17:27:37"})  # exported: no model, no zone tag
    a2 = imported(p2, datetime(2026, 6, 10, 17, 27, 37))
    far = rig.add("Lake/GX011720.MP4", {"CreateDate": "2026:06:10 17:40:00"})  # too far in the series: left alone
    a3 = imported(far, datetime(2026, 6, 10, 17, 40))
    fix.run_once()
    got = updates(rig)
    assert got[a2] == {"dateTimeOriginal": "2026-06-10T12:27:37-05:00"} and a3 not in got


def test_a_file_marked_as_placed_by_older_rules_is_looked_at_again(rig, auto, tmp_path):  # noqa: F811
    fix, imported, seed, state = auto
    p = rig.add("Lake/GX011694.MP4", {"CreateDate": "2026:06:10 17:21:37", "TimeZone": -300, "Model": "HERO13 Black"})
    aid = imported(p, datetime(2026, 6, 10, 12, 21, 37), {"latitude": 8.98, "longitude": -79.52})
    with fix._lock:
        fix._db.execute("INSERT INTO autofix (asset_id, path, status, reason, checked_at) VALUES (?,?,'has_place','',?)", (aid, p, 1e10))
        fix._db.execute("PRAGMA user_version=1")
        fix._db.commit()
    again = AutoFix(str(tmp_path / "autofix.db"), rig.gf, state, rig.client)
    assert again.run_once().get("applied") == 1
    assert updates(rig)[aid] == {"dateTimeOriginal": "2026-06-10T12:21:37-05:00"}
    again.close()


def test_the_local_time_follows_the_owners_phone_not_a_stale_camera_zone(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    # camera left on UTC+10 while the owner was on UTC+8: name 12:28 (+10) = 02:28 UTC; the phone around then says +8
    for i in range(3):
        t = datetime(2026, 6, 26, 1, 30) + timedelta(minutes=40 * i)
        rig.stub.assets.append({"id": f"p{i}", "fileCreatedAt": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                                "localDateTime": (t + timedelta(hours=8)).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                                "exifInfo": {"timeZone": "Asia/Singapore", "dateTimeOriginal": t.strftime("%Y-%m-%dT%H:%M:%S.000Z")}})
    p = rig.add("Coast/VID_20260626_122855_007.mp4", {"CreateDate": "2026:06:26 02:28:55"})
    aid = imported(p, datetime(2026, 6, 26, 2, 28, 55))  # Immich: right instant, shown in UTC
    fix.run_once()
    assert updates(rig)[aid] == {"dateTimeOriginal": "2026-06-26T10:28:55+08:00"}


def test_a_camera_zone_alone_never_changes_a_right_instant(rig, auto):  # noqa: F811
    fix, imported, seed, _ = auto
    rig.stub.assets = []
    p = rig.add("Coast/VID_20260626_122855_007.mp4", {"CreateDate": "2026:06:26 02:28:55"})
    imported(p, datetime(2026, 6, 26, 2, 28, 55))
    fix.run_once()
    assert updates(rig) == {}
