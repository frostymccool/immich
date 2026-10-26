import hashlib

from bridge.immich import ImmichClient, sha1_hex
from tests.stub_immich import StubImmich


def make_client(stub: StubImmich) -> ImmichClient:
    return ImmichClient(stub.url, "test-key", "test-device")


def test_sha1_hex(tmp_path):
    f = tmp_path / "f.bin"
    f.write_bytes(b"hello world")
    assert sha1_hex(str(f)) == hashlib.sha1(b"hello world").hexdigest()


def test_supported_extensions():
    with StubImmich() as stub:
        exts = make_client(stub).supported_extensions()
    assert exts == {"jpg", "png", "heic", "mp4"}  # sidecar xmp excluded


def test_supported_extensions_legacy_route():
    with StubImmich(media_types_route="/api/server-info/media-types") as stub:
        exts = make_client(stub).supported_extensions()
    assert "jpg" in exts


def test_find_by_checksum():
    with StubImmich() as stub:
        stub.known_checksums["aa" * 20] = "existing-1"
        client = make_client(stub)
        assert client.find_by_checksum("aa" * 20, "ref") == "existing-1"
        assert client.find_by_checksum("bb" * 20, "ref") is None


def test_upload_created_then_duplicate(tmp_path):
    f = tmp_path / "photo.jpg"
    f.write_bytes(b"jpegbytes")
    checksum = sha1_hex(str(f))
    with StubImmich() as stub:
        client = make_client(stub)
        first = client.upload(str(f), checksum)
        assert first.status == "imported"
        assert first.asset_id == "asset-1"
        again = client.upload(str(f), checksum)
        assert again.status == "duplicate"
        assert again.asset_id == "asset-1"
        assert len(stub.uploads) == 1


def test_album_created_once_and_assets_added(tmp_path):
    with StubImmich() as stub:
        client = make_client(stub)
        client.add_to_album("Copyparty", "asset-x")
        client.add_to_album("Copyparty", "asset-y")
        assert len(stub.albums) == 1
        assert stub.album_assets["album-1"] == ["asset-x", "asset-y"]


def test_each_album_name_is_looked_up_once_and_kept_separate(tmp_path):
    with StubImmich() as stub:
        client = ImmichClient(stub.url, "k", "dev")
        assert client.add_to_album("Day 1", "a1") is True
        assert client.add_to_album("Day 2", "a2") is True
        assert client.add_to_album("Day 1", "a3") is True
        assert [a["albumName"] for a in stub.albums] == ["Day 1", "Day 2"]
        assert stub.album_assets["album-1"] == ["a1", "a3"]
        assert stub.album_assets["album-2"] == ["a2"]


def test_existing_album_is_reused_not_duplicated(tmp_path):
    with StubImmich() as stub:
        stub.albums.append({"id": "album-9", "albumName": "Day 1"})
        client = ImmichClient(stub.url, "k", "dev")
        assert client.add_to_album("Day 1", "a1") is True
        assert len(stub.albums) == 1
        assert stub.album_assets["album-9"] == ["a1"]


def test_album_deleted_in_immich_is_recreated_on_the_next_file(tmp_path):
    with StubImmich() as stub:
        client = ImmichClient(stub.url, "k", "dev")
        assert client.add_to_album("Day 1", "a1") is True
        stub.remove_album("Day 1")  # user deletes it in Immich
        assert client.add_to_album("Day 1", "a2") is True  # cached id is stale -> retried once with a fresh album
        assert [a["albumName"] for a in stub.albums] == ["Day 1"]
        assert stub.albums[0]["id"] != "album-1"
        assert stub.album_assets[stub.albums[0]["id"]] == ["a2"]


def test_permission_status_all_missing_and_unknown(tmp_path):
    with StubImmich() as stub:
        client = ImmichClient(stub.url, "k", "dev")
        assert client.album_permission_status() == {"ok": True, "missing": []}  # "all"
        stub.key_permissions = ["asset.upload", "asset.read", "album.read"]
        status = client.album_permission_status()
        assert status["ok"] is False and status["missing"] == ["album.create", "albumAsset.create"]
        stub.key_permissions = ["album.read", "album.create", "albumAsset.create"]
        assert client.album_permission_status()["ok"] is True
    # Immich unreachable -> "can't tell", never an exception
    assert ImmichClient("http://127.0.0.1:1", "k", "dev").album_permission_status() == {"ok": None, "missing": []}


def test_a_key_without_album_permission_is_counted_and_reported_not_raised(tmp_path):
    with StubImmich() as stub:
        stub.forbid_albums = True
        client = ImmichClient(stub.url, "k", "dev")
        assert client.add_to_album("Day 1", "a1") is False
        assert client.album_stats["failed"] == 1 and client.album_stats["added"] == 0
        assert "403" in client.album_stats["last_error"] and "album" in client.album_stats["last_error"]


def test_immich_saying_200_with_a_per_asset_error_is_a_failure(tmp_path):
    with StubImmich() as stub:
        stub.album_item_error = "no_permission"
        client = ImmichClient(stub.url, "k", "dev")
        assert client.add_to_album("Day 1", "a1") is False
        assert "no_permission" in client.album_stats["last_error"]


def test_already_in_the_album_counts_as_success(tmp_path):
    with StubImmich() as stub:
        client = ImmichClient(stub.url, "k", "dev")
        assert client.add_to_album("Day 1", "a1") is True
        assert client.add_to_album("Day 1", "a1") is True  # Immich reports "duplicate": fine
        assert client.album_stats == {"added": 2, "failed": 0, "last_error": None, "last_error_at": None}
