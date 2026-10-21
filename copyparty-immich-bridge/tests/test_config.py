import pytest

from bridge.config import Config, ConfigError

BASE_ENV = {
    "IMMICH_URL": "http://immich:2283/",
    "IMMICH_API_KEY": "key123",
    "WATCH_DIRS": "/w/uploads",
}


def test_minimal_config():
    cfg = Config.from_env(dict(BASE_ENV))
    assert cfg.immich_url == "http://immich:2283"
    assert cfg.watch_dirs == ["/w/uploads"]
    assert cfg.post_import_action == "keep"
    assert cfg.sweep_interval == 900
    assert cfg.verify_tls is True


@pytest.mark.parametrize("missing", ["IMMICH_URL", "IMMICH_API_KEY", "WATCH_DIRS"])
def test_required_vars(missing):
    env = dict(BASE_ENV)
    del env[missing]
    with pytest.raises(ConfigError):
        Config.from_env(env)


def test_api_key_file(tmp_path):
    key_file = tmp_path / "key"
    key_file.write_text("secret-from-file\n")
    env = dict(BASE_ENV)
    del env["IMMICH_API_KEY"]
    env["IMMICH_API_KEY_FILE"] = str(key_file)
    assert Config.from_env(env).api_key == "secret-from-file"


def test_watch_dirs_split_and_trailing_slash():
    env = dict(BASE_ENV, WATCH_DIRS="/a/, /b/c,/d")
    assert Config.from_env(env).watch_dirs == ["/a", "/b/c", "/d"]


def test_path_map():
    env = dict(BASE_ENV, PATH_MAP="/w/uploads=/mnt/cp, /other/=/x")
    cfg = Config.from_env(env)
    assert cfg.map_hook_path("/w/uploads/sub/f.jpg") == "/mnt/cp/sub/f.jpg"
    assert cfg.map_hook_path("/w/uploads") == "/mnt/cp"
    assert cfg.map_hook_path("/other/f.jpg") == "/x/f.jpg"
    # a prefix must match on a path-segment boundary
    assert cfg.map_hook_path("/w/uploads2/f.jpg") == "/w/uploads2/f.jpg"
    assert cfg.map_hook_path("/unmapped/f.jpg") == "/unmapped/f.jpg"


def test_bad_path_map():
    with pytest.raises(ConfigError):
        Config.from_env(dict(BASE_ENV, PATH_MAP="no-equals-sign"))


def test_invalid_post_import_action():
    with pytest.raises(ConfigError):
        Config.from_env(dict(BASE_ENV, POST_IMPORT_ACTION="shred"))


def test_extensions_normalized():
    env = dict(BASE_ENV, INCLUDE_EXTENSIONS=".JPG, mp4,  HEIC")
    assert Config.from_env(env).include_extensions == {"jpg", "mp4", "heic"}


def test_bad_int():
    with pytest.raises(ConfigError):
        Config.from_env(dict(BASE_ENV, SWEEP_INTERVAL_SECONDS="soon"))
