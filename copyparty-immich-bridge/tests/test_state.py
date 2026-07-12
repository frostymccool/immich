from bridge.state import StateStore


def make_store(tmp_path):
    return StateStore(str(tmp_path / "state.db"))


def test_unknown_file_not_done(tmp_path):
    store = make_store(tmp_path)
    assert not store.is_done("/a.jpg", 100, 1000.0)


def test_record_success_and_is_done(tmp_path):
    store = make_store(tmp_path)
    store.record_success("/a.jpg", 100, 1000.0, "abc", "imported", "asset-1")
    assert store.is_done("/a.jpg", 100, 1000.0)
    rec = store.get("/a.jpg")
    assert rec.status == "imported"
    assert rec.asset_id == "asset-1"
    assert rec.attempts == 0


def test_changed_file_not_done(tmp_path):
    store = make_store(tmp_path)
    store.record_success("/a.jpg", 100, 1000.0, "abc", "imported", "asset-1")
    assert not store.is_done("/a.jpg", 101, 1000.0)  # size changed
    assert not store.is_done("/a.jpg", 100, 2000.0)  # mtime changed


def test_duplicate_counts_as_done(tmp_path):
    store = make_store(tmp_path)
    store.record_success("/a.jpg", 100, 1000.0, "abc", "duplicate", None)
    assert store.is_done("/a.jpg", 100, 1000.0)


def test_failure_attempts_accumulate_per_version(tmp_path):
    store = make_store(tmp_path)
    store.record_failure("/a.jpg", 100, 1000.0, None, "boom")
    store.record_failure("/a.jpg", 100, 1000.0, None, "boom again")
    rec = store.get("/a.jpg")
    assert rec.attempts == 2
    assert not store.is_done("/a.jpg", 100, 1000.0)
    assert not store.attempts_exhausted("/a.jpg", 100, 1000.0, max_attempts=3)
    store.record_failure("/a.jpg", 100, 1000.0, None, "boom 3")
    assert store.attempts_exhausted("/a.jpg", 100, 1000.0, max_attempts=3)
    # a NEW version of the file resets the budget
    assert not store.attempts_exhausted("/a.jpg", 200, 1000.0, max_attempts=3)
    store.record_failure("/a.jpg", 200, 2000.0, None, "new version boom")
    assert store.get("/a.jpg").attempts == 1


def test_success_after_failure_resets(tmp_path):
    store = make_store(tmp_path)
    store.record_failure("/a.jpg", 100, 1000.0, None, "boom")
    store.record_success("/a.jpg", 100, 1000.0, "abc", "imported", "asset-1")
    rec = store.get("/a.jpg")
    assert rec.status == "imported"
    assert rec.attempts == 0
    assert store.is_done("/a.jpg", 100, 1000.0)


def test_counts_and_recent(tmp_path):
    store = make_store(tmp_path)
    store.record_success("/a.jpg", 1, 1.0, "h1", "imported", "x")
    store.record_success("/b.jpg", 2, 2.0, "h2", "duplicate", None)
    store.record_skip("/c.xmp", 3, 3.0, "unsupported extension")
    assert store.counts() == {"imported": 1, "duplicate": 1, "skipped": 1}
    assert len(store.recent(10)) == 3
