"""Shared-album links: read the album, suggest names, download to the person's folder, import, tidy the NAS copy."""

import hashlib
import json
import os
import stat
import threading
import time
import urllib.error
import urllib.request

import pytest

from bridge import links
from bridge.config import Config
from bridge.immich import ImmichClient
from bridge.links import Album, Item, LinkError, LinkImports, Person
from bridge.server import serve
from bridge.state import StateStore
from bridge.worker import ImportWorker
from tests.stub_immich import StubImmich
from tests.test_worker import make_worker

JPEG = b"\xff\xd8\xff\xe0" + b"jpeg-bytes-" * 20
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"video-bytes-" * 20
DAY_MS = 1795600000000  # 2026-11-25 (UTC); the zone offset below makes it local 2026-11-25 too


def _entry(key, n, ts, video=False, camera=""):
    cam = f',[1,2,3,null,["Canon","{camera}"]]' if camera else ""
    vid = ',{"76647426":[1,2]}' if video else ""
    return (f'["{key}",["https://lh3.googleusercontent.com/pw/AP{n}x",4000,3000,null,null,null,null,null,[123]],'
            f'{ts},"dedup{n}",-18000000,null{cam}{vid}]')


def album_page(title="Beach day", n=3):
    entries = ",".join(_entry(f"AF1Qip{'abc'[i % 3]}{i}", i, DAY_MS + i * 60000, video=(n > 1 and i == n - 1), camera="Canon EOS Rebel T7" if i == 0 else "")
                       for i in range(n))
    return (f'<html><head><meta property="og:title" content="{title} · 25 Nov 2026"><title>x</title></head>'
            f"<body><script>AF_initDataCallback({{key: 'ds:1', data:[null,[{entries}]]}});</script></body></html>")


class Resp:
    def __init__(self, url, status=200, text="", body=b"", headers=None, history=()):
        self.url, self.status_code, self.text, self._body = url, status, text, body
        self.headers, self.history = headers or {}, list(history)

    def iter_content(self, n):
        for i in range(0, len(self._body), 7):
            yield self._body[i:i + 7]

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeGoogle:
    """Answers like Google: the short link redirects to the album page; '=d' / '=dv' give the original."""

    def __init__(self, page=None, files=None, redirect_to=None):
        self.page = page or album_page()
        self.files = files or {}
        self.redirect_to = redirect_to
        self.calls = []

    def get(self, url, headers=None, timeout=None, stream=False):
        self.calls.append(url)
        if url.startswith("https://photos.app.goo.gl/"):
            final = self.redirect_to or "https://photos.google.com/share/AF1QipXYZ?key=k"
            return Resp(final, text=self.page, history=[Resp(url, 302)])
        for suffix, (name, body, kind) in self.files.items():
            if url.endswith(suffix):
                return Resp(url, body=body, headers={"Content-Type": kind, "Content-Disposition": f'attachment; filename="{name}"'})
        return Resp(url, status=404)


def files_for_page():
    return {"AP0x=d": ("IMG_0001.JPG", JPEG, "image/jpeg"), "AP1x=d": ("IMG_0002.JPG", JPEG + b"2", "image/jpeg"),
            "AP2x=dv": ("GX010001.MP4", MP4, "video/mp4")}


class FakeClient:
    def __init__(self, cities=(), assets=None, found=()):
        self.cities, self.assets, self.found, self.searches = list(cities), assets or {}, list(found), []

    def search_metadata(self, body):
        self.searches.append(body)
        return {"assets": {"items": [{"exifInfo": {"city": c}} for c in self.cities] + self.found}}

    def get_asset(self, asset_id):
        return self.assets[asset_id]

    def find_by_checksum(self, sha1, ref_id):
        return None


def rig(tmp_path, session, client=None, state=None, done=lambda uid, a: True, clock=time.time, stage=lambda uid, a: None):
    folder = tmp_path / "watch" / "sam-0000"  # inside the test worker's watched folder
    folder.mkdir(parents=True)
    queued = []
    person = Person("main", str(folder), lambda p, s: queued.append(p) or True, client or FakeClient(), state)
    li = LinkImports(str(tmp_path / "links.db"), lambda uid: person if uid == "main" else None, done,
                     session_factory=lambda: session, clock=clock, correction_of=stage)
    return li, person, queued


def wait_job(li, jid):
    for _ in range(200):
        j = li.job(jid)
        if j["state"] != "running":
            return j
        time.sleep(0.02)
    raise AssertionError("job did not finish")


# ---------------------------------------------------------------------------------------------- reading + naming


def test_a_google_photos_album_page_gives_every_item_with_its_time_camera_and_kind():
    a = links._parse_google_photos(album_page(n=3))
    assert a.title == "Beach day" and len(a.items) == 3
    assert [i.video for i in a.items] == [False, False, True]
    assert a.items[0].camera == "Canon EOS Rebel T7" and a.items[0].ts == DAY_MS and a.items[0].tz == -18000000
    assert links.album_days(a) == ["2026-11-25"]


def test_names_are_suggested_best_first_and_the_first_one_needs_no_typing():
    a = links._parse_google_photos(album_page(title="Beach day"))
    assert links.suggest_names(a, "Springfield") == ["Springfield 2026-11-25", "Springfield 2026-11-25 Canon EOS Rebel T7",
                                              "Beach day 2026-11-25", "Beach day"]
    no_place = links.suggest_names(a, "")
    assert no_place[0] == "Beach day 2026-11-25" and len(no_place) == len({n.lower() for n in no_place}) <= 4
    blank = Album("Google Photos", "", [Item("k", "u")])
    assert links.suggest_names(blank, "", today="2026-01-02") == ["Shared album 2026-01-02"]


def test_a_name_cannot_climb_out_of_the_folder_or_hold_odd_characters():
    assert links.clean_name('../..//etc:"x"*') == "etc x"
    assert links.clean_name("  a   b  ") == "a b"


def test_the_place_comes_from_the_persons_own_photos_taken_then():
    a = links._parse_google_photos(album_page())
    c = FakeClient(cities=["Springfield", "Springfield", "Shelbyville"])
    assert links.place_from_library(c, a) == "Springfield"
    assert c.searches[0]["withExif"] is True
    assert links.place_from_library(None, a) == ""


@pytest.mark.parametrize("url", ["http://photos.app.goo.gl/x", "https://192.168.1.50/share", "https://example.com/a",
                                 "https://photos.google.com.evil.example/share/x", "file:///etc/passwd", ""])
def test_only_https_links_to_the_known_services_are_read(url):
    s = FakeGoogle()
    with pytest.raises(LinkError):
        links.read_album(url, s)
    assert s.calls == []


def test_a_redirect_to_somewhere_else_is_refused():
    with pytest.raises(LinkError, match="does not download"):
        links.read_album("https://photos.app.goo.gl/abc", FakeGoogle(redirect_to="http://192.168.1.50/x"))


def test_a_drive_link_must_be_a_folder_link():
    with pytest.raises(LinkError, match="folder link"):
        links.read_album("https://drive.google.com/file/d/abc/view", FakeGoogle())


# ---------------------------------------------------------------------------------------------- downloading


def test_import_downloads_every_original_into_a_new_folder_and_queues_each(tmp_path):
    g = FakeGoogle(files=files_for_page())
    li, person, queued = rig(tmp_path, g)
    info = li.inspect("https://photos.app.goo.gl/abc", "main")
    assert info["photos"] == 2 and info["videos"] == 1 and info["suggestions"][0] == "Beach day 2026-11-25"
    job = wait_job(li, li.start("https://photos.app.goo.gl/abc", info["suggestions"][0], "main")["id"])
    dest = os.path.join(person.folder, "Beach day 2026-11-25")
    assert job["state"] == "finished" and (job["done"], job["failed"], job["skipped"]) == (3, 0, 0)
    assert sorted(os.listdir(dest)) == ["GX010001.MP4", "IMG_0001.JPG", "IMG_0002.JPG"]  # no .part left behind
    assert open(os.path.join(dest, "GX010001.MP4"), "rb").read() == MP4
    assert sorted(map(os.path.basename, queued)) == ["GX010001.MP4", "IMG_0001.JPG", "IMG_0002.JPG"]
    assert "url" not in job and "folder" not in job


def test_pasting_the_same_link_again_skips_what_is_there_and_never_overwrites(tmp_path):
    g = FakeGoogle(files=files_for_page())
    li, person, queued = rig(tmp_path, g)
    url = "https://photos.app.goo.gl/abc"
    wait_job(li, li.start(url, "Trip", "main")["id"])
    dest = os.path.join(person.folder, "Trip")
    with open(os.path.join(dest, "IMG_0002.JPG"), "wb") as fh:  # someone else's different file with the same name
        fh.write(b"\xff\xd8\xffother")
    li = LinkImports(str(tmp_path / "older.db"), lambda uid: person, session_factory=lambda: g)  # no record of the first import
    job = wait_job(li, li.start(url, "Trip", "main")["id"])
    assert (job["done"], job["skipped"]) == (1, 2)
    assert open(os.path.join(dest, "IMG_0002.JPG"), "rb").read() == b"\xff\xd8\xffother"  # untouched
    assert len([n for n in os.listdir(dest) if n.startswith("IMG_0002_")]) == 1


def test_something_that_is_not_a_photo_or_video_is_not_saved(tmp_path):
    files = files_for_page()
    files["AP1x=d"] = ("page.html", b"<html>", "text/html")
    li, person, _ = rig(tmp_path, FakeGoogle(files=files))
    job = wait_job(li, li.start("https://photos.app.goo.gl/abc", "Trip", "main")["id"])
    assert (job["done"], job["failed"]) == (2, 1)
    assert "page.html" not in os.listdir(os.path.join(person.folder, "Trip"))


@pytest.mark.skipif(os.geteuid() == 0, reason="root can write anywhere")
def test_a_read_only_folder_says_how_to_allow_saving(tmp_path):
    li, person, _ = rig(tmp_path, FakeGoogle(files=files_for_page()))
    os.chmod(person.folder, stat.S_IRUSR | stat.S_IXUSR)
    try:
        with pytest.raises(LinkError, match="WRITABLE=1") as ex:
            li.start("https://photos.app.goo.gl/abc", "Trip", "main")
        assert ex.value.status == 409
    finally:
        os.chmod(person.folder, stat.S_IRWXU)


def test_a_download_cut_short_by_a_restart_is_reported_not_left_running(tmp_path):
    import sqlite3
    db = sqlite3.connect(str(tmp_path / "links.db"))  # written by 0.11 (no 'earlier' or 'key' columns yet)
    db.execute("""CREATE TABLE jobs (id TEXT PRIMARY KEY, uid TEXT, url TEXT, source TEXT, name TEXT, folder TEXT, created REAL,
        state TEXT, total INTEGER, done INTEGER, skipped INTEGER, failed INTEGER, bytes INTEGER, error TEXT)""")
    db.execute("CREATE TABLE files (path TEXT PRIMARY KEY, job TEXT, uid TEXT, size INTEGER, sha1 TEXT, added REAL, deleted_at REAL)")
    db.execute("INSERT INTO jobs VALUES ('j1','main','u','s','n','f',1,'running',3,1,0,0,0,NULL)")
    db.commit()
    db.close()
    li2 = LinkImports(str(tmp_path / "links.db"), lambda uid: None)
    j = li2.job("j1")
    assert j["state"] == "stopped" and "paste the link again" in j["error"] and j["earlier"] == 0


# ---------------------------------------------------------------------------------------------- tidying up


def test_the_nas_copy_is_deleted_only_once_immich_has_it_and_correction_is_done(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        worker._allowed = {"jpg", "mp4"}
        client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id)
        status = {"done": False}
        now = [time.time()]
        li, person, queued = rig(tmp_path, FakeGoogle(files=files_for_page()), client=client, state=state,
                                 done=lambda uid, a: status["done"], clock=lambda: now[0])
        dest = os.path.join(person.folder, "Trip")
        wait_job(li, li.start("https://photos.app.goo.gl/abc", "Trip", "main")["id"])
        mine = os.path.join(dest, "mine.jpg")  # the person's own file in the same folder: never ours to delete
        with open(mine, "wb") as fh:
            fh.write(JPEG + b"mine")
        assert li.cleanup() == 0  # nothing imported yet
        for p in queued:
            os.utime(p, (time.time() - 120, time.time() - 120))
            worker._process(p)
        for p in queued:
            rec = state.get(p)
            assert rec.status == "imported"
            stub.assets.append({"id": rec.asset_id})
        assert li.cleanup() == 0 and len(os.listdir(dest)) == 4  # in Immich, but correction not finished
        status["done"] = True
        assert li.cleanup() == 3
        assert os.listdir(dest) == ["mine.jpg"]  # the folder stays because the person's own file is in it
        assert li.jobs("main")[0]["kept_on_nas"] == 0


def test_after_the_keep_days_the_copy_goes_even_if_correction_never_finished(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id)
        now = [time.time()]
        files = {"AP0x=d": ("IMG_0001.JPG", JPEG, "image/jpeg")}
        li, person, queued = rig(tmp_path, FakeGoogle(page=album_page(n=1), files=files), client=client, state=state,
                                 done=lambda uid, a: False, clock=lambda: now[0])
        wait_job(li, li.start("https://photos.app.goo.gl/abc", "Trip", "main")["id"])
        os.utime(queued[0], (time.time() - 120, time.time() - 120))
        worker._process(queued[0])
        stub.assets.append({"id": state.get(queued[0]).asset_id})
        assert li.cleanup() == 0
        now[0] += links.KEEP_DAYS * 86400 + 1
        assert li.cleanup() == 1
        assert not os.path.exists(os.path.join(person.folder, "Trip"))  # empty folder removed


def test_a_changed_or_missing_asset_keeps_the_copy(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id)
        files = {"AP0x=d": ("IMG_0001.JPG", JPEG, "image/jpeg")}
        li, person, queued = rig(tmp_path, FakeGoogle(page=album_page(n=1), files=files), client=client, state=state)
        wait_job(li, li.start("https://photos.app.goo.gl/abc", "Trip", "main")["id"])
        os.utime(queued[0], (time.time() - 120, time.time() - 120))
        worker._process(queued[0])
        assert li.cleanup() == 0  # Immich does not answer for that asset (deleted there?) -> keep
        with open(queued[0], "ab") as fh:
            fh.write(b"edited")  # changed on the NAS after the import -> keep
        stub.assets.append({"id": state.get(queued[0]).asset_id})
        assert li.cleanup() == 0 and os.path.exists(queued[0])


def test_what_came_in_through_the_same_link_before_is_counted_and_not_downloaded_again(tmp_path):
    g = FakeGoogle(files=files_for_page())
    li, person, queued = rig(tmp_path, g)
    url = "https://photos.app.goo.gl/abc"
    wait_job(li, li.start(url, "Trip", "main")["id"])
    assert li.inspect(url, "main")["imported_before"] == 3
    calls = len(g.calls)
    job = wait_job(li, li.start(url, "Another name", "main")["id"])
    assert (job["earlier"], job["done"], job["skipped"]) == (3, 0, 0)
    assert not [c for c in g.calls[calls:] if "googleusercontent" in c]  # nothing downloaded again


def test_pasting_a_link_says_how_many_look_like_photos_already_in_the_library(tmp_path):
    same_second = {"type": "IMAGE", "fileCreatedAt": "2026-11-25T09:46:40.000Z"}  # = DAY_MS, the album's first photo
    video_then = {"type": "VIDEO", "fileCreatedAt": "2026-11-25T09:47:40Z"}  # the second item is a photo: no match
    other = {"type": "IMAGE", "fileCreatedAt": "2026-11-25T09:00:00Z", "originalFileName": "IMG_9.JPG"}
    li, _, _ = rig(tmp_path, FakeGoogle(), client=FakeClient(found=[same_second, video_then, other]))
    info = li.inspect("https://photos.app.goo.gl/abc", "main")
    assert (info["look_alikes"], info["imported_before"]) == (1, 0)
    drive = Album("Google Drive", "", [Item("k1", "u", name="img_9.jpg"), Item("k2", "u", name="IMG_10.JPG")])
    assert links.look_alikes_in_library(drive, [other]) == 1  # Drive gives names, not times


def test_each_file_of_an_import_is_followed_to_immich_and_through_correction(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        worker._allowed = {"jpg"}  # the clip is a type this Immich does not take
        client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id)
        stage = {}
        li, person, queued = rig(tmp_path, FakeGoogle(files=files_for_page()), client=client, state=state,
                                 done=lambda uid, a: stage.get(a) == "done", stage=lambda uid, a: stage.get(a, "waiting"))
        wait_job(li, li.start("https://photos.app.goo.gl/abc", "Trip", "main")["id"])
        s = li.jobs("main")[0]["stages"]
        assert (s["downloaded"], s["on_nas"], s["uploading"], s["in_immich"], s["corrects"]) == (3, 3, 3, 0, True)
        for p in queued:
            os.utime(p, (time.time() - 120, time.time() - 120))
            worker._process(p)
        s = li.jobs("main")[0]["stages"]
        assert (s["uploading"], s["in_immich"], s["not_taken"], s["waiting"]) == (0, 2, 1, 2)
        assert s["not_taken_reason"] == "Immich does not take .mp4 files; kept on the NAS"
        ids = [state.get(p).asset_id for p in queued if p.endswith(".JPG")]
        stub.assets.extend({"id": a} for a in ids)
        stage[ids[0]], stage[ids[1]] = "done", "checked"
        s = li.jobs("main")[0]["stages"]
        assert (s["corrected"], s["checked"], s["waiting"]) == (1, 1, 0)
        stage[ids[1]] = "done"
        assert li.cleanup() == 2
        s = li.jobs("main")[0]["stages"]
        assert (s["on_nas"], s["in_immich"], s["corrected"]) == (1, 2, 2)  # only the refused clip stays on the NAS


def test_without_automatic_correction_the_stages_stop_at_immich(tmp_path):
    li, _, _ = rig(tmp_path, FakeGoogle(files=files_for_page()))
    wait_job(li, li.start("https://photos.app.goo.gl/abc", "Trip", "main")["id"])
    assert li.jobs("main")[0]["stages"]["corrects"] is False


# ---------------------------------------------------------------------------------------------- the API


TOKEN = "s3cret-token"


def call(base, method, path, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, headers={"Content-Type": "application/json", **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as ex:
        return ex.code, json.loads(ex.read())


@pytest.fixture
def api(tmp_path):
    with StubImmich() as stub:
        stub.user_tokens["phone-token"] = {"id": stub.user_id, "name": "Sam", "email": "sam@example.com"}
        stub.user_tokens["other-token"] = {"id": "someone-else", "name": "Other", "email": "o@example.com"}
        cfg = Config(immich_url=stub.url, api_key="k", watch_dirs=[str(tmp_path)], state_db=str(tmp_path / "s.db"),
                     browse_roots=[str(tmp_path)], token=TOKEN, bind_host="127.0.0.1", bind_port=0)
        state = StateStore(cfg.state_db)
        client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id)
        worker = ImportWorker(cfg, state, client, {"jpg", "mp4"})
        worker.immich_user = {"id": stub.user_id}
        li, person, queued = rig(tmp_path, FakeGoogle(files=files_for_page()))
        httpd = serve(cfg, state, worker, links=li)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        yield f"http://127.0.0.1:{httpd.server_port}", li, person
        httpd.shutdown()


def test_the_page_inspects_then_imports_with_the_first_suggestion_when_no_name_is_given(api):
    base, li, person = api
    auth = {"X-Bridge-Token": TOKEN}
    code, info = call(base, "POST", "/api/links/inspect", {"url": "https://photos.app.goo.gl/abc"}, auth)
    assert code == 200 and info["suggestions"][0] == "Beach day 2026-11-25"
    code, job = call(base, "POST", "/api/links/import", {"url": "https://photos.app.goo.gl/abc"}, auth)
    assert code == 202 and job["name"] == "Beach day 2026-11-25"
    wait_job(li, job["id"])
    code, listing = call(base, "GET", "/api/links", None, auth)
    assert code == 200 and listing["jobs"][0]["done"] == 3


def test_the_link_api_needs_the_token_or_the_persons_own_immich_sign_in(api):
    base, li, person = api
    assert call(base, "POST", "/api/links/inspect", {"url": "https://photos.app.goo.gl/abc"})[0] == 401
    assert call(base, "POST", "/api/links/inspect", {"url": "https://photos.app.goo.gl/abc"}, {"X-Immich-Token": "bad"})[0] == 401
    assert call(base, "GET", "/api/links", None, {"X-Immich-Token": "other-token"})[0] == 404  # not a bridge user
    code, info = call(base, "POST", "/api/links/inspect", {"url": "https://photos.app.goo.gl/abc", "user": "someone"},
                      {"X-Immich-Token": "phone-token"})
    assert code == 200  # the phone always acts for its own person; a 'user' field is ignored
    code, err = call(base, "POST", "/api/links/inspect", {"url": "https://example.com/x"}, {"X-Bridge-Token": TOKEN})
    assert code == 400 and "Google Photos" in err["error"]
