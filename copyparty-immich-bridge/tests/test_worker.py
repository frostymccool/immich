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
        worker._process(worker._queue.get())
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
