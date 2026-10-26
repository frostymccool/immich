import os
import time

from bridge.config import Config
from bridge.immich import ImmichClient
from bridge.state import StateStore
from bridge.worker import ImportWorker
from tests.stub_immich import StubImmich

EXTS = {"jpg", "mp4"}


def make_cfg(tmp_path, stub, **overrides) -> Config:
    defaults = dict(
        immich_url=stub.url,
        api_key="k",
        watch_dirs=[str(tmp_path / "watch")],
        state_db=str(tmp_path / "state.db"),
        min_file_age=0,
    )
    defaults.update(overrides)
    return Config(**defaults)


def make_worker(tmp_path, stub, **overrides):
    cfg = make_cfg(tmp_path, stub, **overrides)
    state = StateStore(cfg.state_db)
    client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id)
    return ImportWorker(cfg, state, client, EXTS), state, cfg


def write_file(tmp_path, rel, content=b"data", age=60):
    path = tmp_path / "watch" / rel
    os.makedirs(path.parent, exist_ok=True)
    path.write_bytes(content)
    mtime = time.time() - age
    os.utime(path, (mtime, mtime))
    return str(path)


def test_import_pipeline(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        path = write_file(tmp_path, "photo.jpg", b"new content")
        worker._process(path)

        rec = state.get(path)
        assert rec.status == "imported"
        assert rec.asset_id == "asset-1"
        assert len(stub.uploads) == 1

        # second pass: state DB short-circuits, no new upload
        worker._process(path)
        assert len(stub.uploads) == 1


def test_checksum_duplicate_skips_upload(tmp_path):
    import hashlib

    content = b"already there"
    with StubImmich() as stub:
        stub.known_checksums[hashlib.sha1(content).hexdigest()] = "old-asset"
        worker, state, _ = make_worker(tmp_path, stub)
        path = write_file(tmp_path, "dup.jpg", content)
        worker._process(path)

        rec = state.get(path)
        assert rec.status == "duplicate"
        assert rec.asset_id == "old-asset"
        assert len(stub.uploads) == 0


def test_unsupported_extension_recorded_as_skipped(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        path = write_file(tmp_path, "sidecar.xmp")
        worker._process(path)
        assert state.get(path).status == "skipped"
        assert len(stub.uploads) == 0


def test_failure_recorded_and_retried_by_sweep(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, max_attempts=2)
        path = write_file(tmp_path, "photo.jpg")

        # break the client (wrong port) for the first attempt
        good_client = worker._client
        worker._client = ImmichClient("http://127.0.0.1:1", "k", "d")
        worker._process(path)
        assert state.get(path).status == "failed"
        assert state.get(path).attempts == 1

        # sweep re-queues it, a healthy client succeeds
        worker._client = good_client
        assert worker.sweep() == 1
        worker._process(worker._queue.get()[2])
        assert state.get(path).status == "imported"


def test_sweep_respects_attempt_budget(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub, max_attempts=1)
        path = write_file(tmp_path, "photo.jpg")
        worker._client = ImmichClient("http://127.0.0.1:1", "k", "d")
        worker._process(path)
        assert state.get(path).attempts == 1
        assert worker.sweep() == 0  # budget exhausted → not re-queued


def test_sweep_skips_done_files(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        path = write_file(tmp_path, "photo.jpg")
        worker._process(path)
        assert state.get(path).status == "imported"
        assert worker.sweep() == 0


def test_post_import_move(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, post_import_action="move")
        path = write_file(tmp_path, "photo.jpg")
        worker._process(path)
        assert not os.path.exists(path)
        moved = os.path.join(os.path.dirname(path), cfg.move_subdir, "photo.jpg")
        assert os.path.exists(moved)
        # the moved copy must not be re-imported by the next sweep
        assert worker.sweep() == 0


def test_post_import_delete(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub, post_import_action="delete")
        path = write_file(tmp_path, "photo.jpg")
        worker._process(path)
        assert not os.path.exists(path)
        assert state.get(path).status == "imported"


def test_album_assignment(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub, album_name="Copyparty imports")
        path = write_file(tmp_path, "photo.jpg")
        worker._process(path)
        assert stub.albums[0]["albumName"] == "Copyparty imports"
        assert stub.album_assets["album-1"] == ["asset-1"]


def test_enqueue_dedupes(tmp_path):
    with StubImmich() as stub:
        worker, _, _ = make_worker(tmp_path, stub)
        assert worker.enqueue("/x.jpg", "hook") is True
        assert worker.enqueue("/x.jpg", "hook") is False


def test_priority_dir_files_are_processed_first(tmp_path):
    with StubImmich() as stub:
        prio_dir = str(tmp_path / "watch" / "Summer2026")
        worker, _, _ = make_worker(tmp_path, stub, priority_dirs=[prio_dir])
        a = write_file(tmp_path, "other/a.jpg")
        b = write_file(tmp_path, "other/b.jpg")
        c = write_file(tmp_path, "Summer2026/c.jpg")
        d = write_file(tmp_path, "Summer2026/d.jpg")
        for p in (a, b, c, d):  # base-folder files are queued FIRST
            worker.enqueue(p, "test")

        order = []
        while not worker._queue.empty():
            order.append(worker._queue.get()[2])
        # priority folder first (FIFO within each tier), then the rest of the base
        assert order == [c, d, a, b]


def test_no_priority_dirs_keeps_fifo_order(tmp_path):
    with StubImmich() as stub:
        worker, _, _ = make_worker(tmp_path, stub)
        paths = [write_file(tmp_path, f"x{i}.jpg") for i in range(3)]
        for p in paths:
            worker.enqueue(p, "test")
        order = [worker._queue.get()[2] for _ in paths]
        assert order == paths


# -- folder-named albums ------------------------------------------------------------------------------------


def album_names(stub):
    return [a["albumName"] for a in stub.albums]


def test_folder_album_is_the_default_and_is_named_after_the_folder(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        assert cfg.album_from_folder is True
        path = write_file(tmp_path, "Day 3 hike/VID_20260101_120000_001.mp4", b"clip")
        worker._process(path)
        assert album_names(stub) == ["Day 3 hike"]
        assert stub.album_assets["album-1"] == ["asset-1"]


def test_files_from_the_same_folder_share_one_album_and_other_folders_get_their_own(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        for rel, data in [("Day 1/a.jpg", b"a"), ("Day 1/b.jpg", b"b"), ("Day 2/c.jpg", b"c")]:
            worker._process(write_file(tmp_path, rel, data))
        assert album_names(stub) == ["Day 1", "Day 2"]
        assert stub.album_assets["album-1"] == ["asset-1", "asset-2"]
        assert stub.album_assets["album-2"] == ["asset-3"]


def test_only_the_immediate_parent_folder_names_the_album(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._process(write_file(tmp_path, "Trips/Summer/Day 3/x.jpg", b"x"))
        assert album_names(stub) == ["Day 3"]


def test_folder_albums_can_be_switched_off(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub, album_from_folder=False)
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"a"))
        assert stub.albums == []
        assert state.get(str(tmp_path / "watch" / "Day 1" / "a.jpg")).status == "imported"


def test_fixed_album_and_folder_album_both_apply(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub, album_name="Everything")
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"a"))
        assert album_names(stub) == ["Everything", "Day 1"]
        assert stub.album_assets["album-1"] == ["asset-1"]
        assert stub.album_assets["album-2"] == ["asset-1"]


def test_fixed_album_with_the_same_name_as_the_folder_is_not_added_twice(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub, album_name="Day 1")
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"a"))
        assert album_names(stub) == ["Day 1"]
        assert stub.album_assets["album-1"] == ["asset-1"]


def test_hidden_folders_do_not_become_albums(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._process(write_file(tmp_path, ".imported/a.jpg", b"a"))
        assert stub.albums == []


def test_a_file_already_in_immich_is_still_put_in_the_folder_album(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"same bytes"))
        worker._process(write_file(tmp_path, "Day 2/copy.jpg", b"same bytes"))  # identical content
        assert album_names(stub) == ["Day 1", "Day 2"]
        assert stub.album_assets["album-2"] == ["asset-1"]  # the existing asset, not a new upload
        assert len(stub.uploads) == 1


def test_album_failure_never_fails_the_import(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        stub.removed_albums.update({"album-1", "album-2", "album-3"})  # every PUT answers 404
        path = write_file(tmp_path, "Day 1/a.jpg", b"a")
        worker._process(path)
        assert state.get(path).status == "imported"


def test_album_name_tidying_and_limits():
    from bridge.scanner import folder_album_name

    assert folder_album_name("/w/Trips/  Day   3  /x.jpg") == "Day 3"
    assert folder_album_name("/w/.imported/x.jpg") is None
    assert folder_album_name("/x.jpg") is None
    assert len(folder_album_name("/w/" + "a" * 300 + "/x.jpg")) == 200


# -- album diagnostics + back-fill ---------------------------------------------------------------------------


def test_missing_album_permission_is_detected_logged_and_does_not_stop_imports(tmp_path, caplog):
    with StubImmich() as stub:
        stub.key_permissions = ["asset.upload", "asset.read"]
        stub.forbid_albums = True
        worker, state, _ = make_worker(tmp_path, stub)
        with caplog.at_level("INFO", logger="bridge.worker"):
            worker.check_album_permission()
        assert "cannot use albums" in caplog.text and "album.create" in caplog.text
        path = write_file(tmp_path, "Day 1/a.jpg", b"a")
        worker._process(path)
        assert state.get(path).status == "imported"  # the import itself is unaffected
        info = worker.album_info()
        assert info["enabled"] is True
        assert info["permission"]["ok"] is False and "album.create" in info["permission"]["missing"]
        assert info["failed"] == 1 and "403" in info["last_error"]


def test_album_info_when_everything_works(tmp_path):
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker.check_album_permission()
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"a"))
        info = worker.album_info()
        assert info["permission"]["ok"] is True and info["added"] == 1 and info["failed"] == 0


def _wait_backfill(worker, timeout=10):
    deadline = time.time() + timeout
    while worker.backfill["running"] and time.time() < deadline:
        time.sleep(0.02)
    assert not worker.backfill["running"]


def test_backfill_adds_files_imported_before_folder_albums_existed(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, album_from_folder=False)
        for rel, data in [("Day 1/a.jpg", b"a"), ("Day 1/b.jpg", b"b"), ("Day 2/c.jpg", b"c")]:
            worker._process(write_file(tmp_path, rel, data))
        assert stub.albums == []  # imported while the feature was off
        cfg.album_from_folder = True
        assert worker.start_backfill() is True
        _wait_backfill(worker)
        assert [a["albumName"] for a in stub.albums] == ["Day 1", "Day 2"]
        assert stub.album_assets["album-1"] == ["asset-1", "asset-2"]
        assert stub.album_assets["album-2"] == ["asset-3"]
        assert worker.backfill["total"] == 3 and worker.backfill["done"] == 3 and worker.backfill["failed"] == 0


def test_backfill_twice_is_harmless_and_failures_are_counted(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, album_from_folder=False)
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"a"))
        cfg.album_from_folder = True
        worker.start_backfill(); _wait_backfill(worker)
        worker.start_backfill(); _wait_backfill(worker)  # already in the album -> still "done", no duplicates
        assert stub.album_assets["album-1"] == ["asset-1"]
        assert worker.backfill["failed"] == 0
        stub.forbid_albums = True
        worker.start_backfill(); _wait_backfill(worker)
        assert worker.backfill["failed"] == 1


def test_backfill_ignores_failed_and_skipped_files(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        state.record_failure("/w/x/bad.jpg", 1, 1.0, None, "boom")
        state.record_skip("/w/x/doc.txt", 1, 1.0, "unsupported extension")
        assert state.done_assets() == []


# -- pause / resume ------------------------------------------------------------------------------------------


def _wait_for(predicate, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def test_paused_imports_nothing_new_but_keeps_the_arrivals_queued(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, paused=True)
        a = write_file(tmp_path, "Day 1/a.jpg", b"a")
        b = write_file(tmp_path, "Day 1/b.jpg", b"b")
        worker.start()
        try:
            assert worker.enqueue(a, "hook") and worker.enqueue(b, "hook")
            time.sleep(1.2)  # long enough for a worker to take one and hold it
            assert state.get(a) is None and state.get(b) is None
            assert stub.uploads == []
            assert worker.queue_size == 2  # one held by the worker + one still queued: both counted
            assert worker.enqueue(a, "sweep") is False  # a held file is not queued a second time
        finally:
            cfg.paused = False
            worker.stop()


def test_resume_imports_everything_that_waited(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, paused=True)
        paths = [write_file(tmp_path, f"Day 1/{n}.jpg", n.encode()) for n in "abc"]
        worker.start()
        try:
            for p in paths:
                worker.enqueue(p, "hook")
            time.sleep(0.8)
            assert all(state.get(p) is None for p in paths)
            cfg.paused = False  # resume
            assert _wait_for(lambda: all(state.get(p) is not None and state.get(p).status == "imported" for p in paths))
            assert worker.queue_size == 0
            assert len(stub.uploads) == 3
        finally:
            worker.stop()


def test_pausing_while_running_stops_new_work_after_the_current_file(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub)
        first = write_file(tmp_path, "Day 1/a.jpg", b"a")
        worker.start()
        try:
            worker.enqueue(first, "hook")
            assert _wait_for(lambda: state.get(first) is not None)  # imported normally
            cfg.paused = True
            later = write_file(tmp_path, "Day 1/b.jpg", b"b")
            worker.enqueue(later, "hook")
            time.sleep(1.0)
            assert state.get(later) is None
            cfg.paused = False
            assert _wait_for(lambda: state.get(later) is not None)
        finally:
            worker.stop()


def test_stopping_while_paused_does_not_hang(tmp_path):
    with StubImmich() as stub:
        worker, state, cfg = make_worker(tmp_path, stub, paused=True)
        worker.start()
        worker.enqueue(write_file(tmp_path, "Day 1/a.jpg", b"a"), "hook")
        time.sleep(0.8)
        worker.stop()
        assert _wait_for(lambda: not any(t.is_alive() for t in worker._threads), timeout=5)


def test_identity_and_album_links_after_an_import(tmp_path, caplog):
    with StubImmich() as stub:
        stub.user_name, stub.user_email = "Ann Example", "ann@example.test"
        worker, state, _ = make_worker(tmp_path, stub)
        with caplog.at_level("INFO", logger="bridge.worker"):
            assert worker.refresh_identity() == {"name": "Ann Example", "email": "ann@example.test"}
        assert "Ann Example" in caplog.text and "log in as this user" in caplog.text
        worker._process(write_file(tmp_path, "Day 1/a.jpg", b"a"))
        links = worker.album_links(stub.url + "/")
        assert links == [{"name": "Day 1", "id": "album-1", "url": f"{stub.url}/albums/album-1"}]
