import os
import time

from bridge.scanner import extension_of, is_candidate_name, iter_candidates

EXTS = {"jpg", "mp4"}


def touch(path, size=10, age=3600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"x" * size)
    mtime = time.time() - age
    os.utime(path, (mtime, mtime))


def scan(root, **kwargs):
    kwargs.setdefault("allowed_extensions", EXTS)
    kwargs.setdefault("min_file_age", 30)
    return sorted(iter_candidates([str(root)], **kwargs))


def test_name_filters():
    assert is_candidate_name("a.jpg")
    assert not is_candidate_name(".hidden.jpg")
    assert not is_candidate_name("a.jpg.PARTIAL")
    assert not is_candidate_name("a-123-tok.jpg.partial")


def test_extension_of():
    assert extension_of("a.JPG") == "jpg"
    assert extension_of("noext") == ""
    assert extension_of(".bashrc") == ""
    assert extension_of("trailingdot.") == ""


def test_basic_scan(tmp_path):
    touch(tmp_path / "good.jpg")
    touch(tmp_path / "sub" / "clip.mp4")
    touch(tmp_path / "notes.txt")
    touch(tmp_path / "empty.jpg", size=0)
    touch(tmp_path / "part.jpg.PARTIAL")
    touch(tmp_path / ".hist" / "up2k.snap")
    touch(tmp_path / ".hist" / "sneaky.jpg")
    touch(tmp_path / "young.jpg", age=1)

    found = scan(tmp_path)
    assert found == [str(tmp_path / "good.jpg"), str(tmp_path / "sub" / "clip.mp4")]


def test_excluded_dir_names(tmp_path):
    touch(tmp_path / "keep.jpg")
    touch(tmp_path / "imported" / "old.jpg")
    found = scan(tmp_path, excluded_dir_names={"imported"})
    assert found == [str(tmp_path / "keep.jpg")]


def test_missing_watch_dir_is_not_fatal(tmp_path):
    assert scan(tmp_path / "nonexistent") == []
