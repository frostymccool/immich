import json
import os

import pytest

from bridge.config import Config
from bridge.settings import SettingsError, SettingsStore, validate


def make(tmp_path, **kw):
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(exist_ok=True)
    b.mkdir(exist_ok=True)
    cfg = Config(
        immich_url="http://x",
        api_key="k",
        watch_dirs=[str(a)],
        priority_dirs=[str(a)],
        state_db=str(tmp_path / "s.db"),
        **kw,
    )
    store = SettingsStore(cfg, str(tmp_path / "settings.json"), [str(tmp_path)])
    return cfg, store, a, b


def test_update_applies_live_and_persists(tmp_path):
    cfg, store, a, b = make(tmp_path)
    store.update({"watch_dirs": [str(a), str(b)], "sweep_interval": 60, "album_name": "Trip"})
    assert cfg.watch_dirs == [str(a), str(b)]
    assert cfg.sweep_interval == 60
    assert cfg.album_name == "Trip"
    saved = json.loads((tmp_path / "settings.json").read_text())
    assert saved["overrides"]["sweep_interval"] == 60
    assert sorted(store.overridden()) == ["album_name", "sweep_interval", "watch_dirs"]


def test_setting_back_to_default_drops_the_override(tmp_path):
    cfg, store, a, b = make(tmp_path)
    store.update({"sweep_interval": 60})
    store.update({"sweep_interval": 900})
    assert "sweep_interval" not in store.overridden()


def test_restart_reloads_saved_values(tmp_path):
    cfg, store, a, b = make(tmp_path)
    store.update({"watch_dirs": [str(a), str(b)], "priority_dirs": [str(b)], "post_import_action": "move"})
    cfg2, store2, _, _ = make(tmp_path)
    store2.load()
    assert cfg2.watch_dirs == [str(a), str(b)]
    assert cfg2.priority_dirs == [str(b)]
    assert cfg2.post_import_action == "move"


def test_reset_restores_environment_defaults(tmp_path):
    cfg, store, a, b = make(tmp_path)
    store.update({"watch_dirs": [str(b)], "priority_dirs": [], "sweep_interval": 5})
    store.reset()
    assert cfg.watch_dirs == [str(a)]
    assert cfg.priority_dirs == [str(a)]
    assert cfg.sweep_interval == 900
    assert store.overridden() == []
    assert json.loads((tmp_path / "settings.json").read_text())["overrides"] == {}


def test_invalid_change_applies_nothing(tmp_path):
    cfg, store, a, b = make(tmp_path)
    with pytest.raises(SettingsError) as ex:
        store.update({"sweep_interval": 30, "watch_dirs": [str(tmp_path / "gone")]})
    assert "does not exist" in str(ex.value)
    assert cfg.sweep_interval == 900  # the valid half was NOT applied either
    assert not os.path.exists(tmp_path / "settings.json")


@pytest.mark.parametrize(
    "changes,needle",
    [
        ({"watch_dirs": []}, "at least one"),
        ({"watch_dirs": ["relative/path"]}, "absolute"),
        ({"watch_dirs": ["/etc"]}, "outside"),
        ({"priority_dirs": ["/elsewhere"]}, "must be inside"),
        ({"sweep_interval": -1}, "between"),
        ({"sweep_interval": "abc"}, "whole number"),
        ({"max_attempts": 0}, "between"),
        ({"post_import_action": "shred"}, "one of"),
        ({"log_level": "LOUD"}, "one of"),
        ({"immich_url": "http://evil"}, "not editable"),
        ({"api_key": "x"}, "not editable"),
    ],
)
def test_validation_rejects(tmp_path, changes, needle):
    cfg, store, a, b = make(tmp_path)
    with pytest.raises(SettingsError) as ex:
        validate(cfg, changes, [str(tmp_path)])
    assert needle in str(ex.value)


def test_priority_must_stay_inside_new_watch_dirs(tmp_path):
    cfg, store, a, b = make(tmp_path)
    with pytest.raises(SettingsError) as ex:
        store.update({"watch_dirs": [str(b)]})  # priority (a) is no longer inside
    assert "must be inside" in str(ex.value)


def test_move_or_delete_needs_a_writable_mount(tmp_path):
    cfg, store, a, b = make(tmp_path)
    a.chmod(0o555)
    try:
        if os.access(a, os.W_OK):
            pytest.skip("running as root; cannot make a read-only dir")
        with pytest.raises(SettingsError) as ex:
            store.update({"post_import_action": "delete"})
        assert "read-only" in str(ex.value)
    finally:
        a.chmod(0o755)


def test_extensions_are_normalised(tmp_path):
    cfg, store, a, b = make(tmp_path)
    store.update({"include_extensions": ".JPG, png heic"})
    assert cfg.include_extensions == {"jpg", "png", "heic"}


def test_bad_saved_file_is_ignored_not_fatal(tmp_path):
    (tmp_path / "settings.json").write_text("{not json")
    cfg, store, a, b = make(tmp_path)
    store.load()
    assert cfg.watch_dirs == [str(a)]


def test_saved_folder_that_vanished_falls_back_to_env(tmp_path):
    (tmp_path / "settings.json").write_text(
        json.dumps({"overrides": {"watch_dirs": [str(tmp_path / "gone")], "sweep_interval": 42}})
    )
    cfg, store, a, b = make(tmp_path)
    store.load()
    assert cfg.watch_dirs == [str(a)]  # the unusable folder was skipped
    assert cfg.sweep_interval == 42  # the rest still loads


def test_change_callback_fires(tmp_path):
    cfg, store, a, b = make(tmp_path)
    hits = []
    store._on_change = lambda: hits.append(1)
    store.update({"sweep_interval": 10})
    store.reset()
    assert len(hits) == 2


def test_log_names_only_what_really_changed(tmp_path, caplog):
    cfg, store, a, b = make(tmp_path)
    with caplog.at_level("INFO", logger="bridge.settings"):
        store.update({"sweep_interval": 900, "max_attempts": 5, "album_name": "Trip"})
    assert "settings changed: album_name" in caplog.text
    assert "sweep_interval" not in caplog.text


def test_album_from_folder_is_editable_and_validated(tmp_path):
    cfg, store, a, b = make(tmp_path)
    assert cfg.album_from_folder is True
    store.update({"album_from_folder": False})
    assert cfg.album_from_folder is False
    assert "album_from_folder" in store.overridden()
    store.update({"album_from_folder": "true"})
    assert cfg.album_from_folder is True
    assert "album_from_folder" not in store.overridden()  # back to the default
    with pytest.raises(SettingsError):
        store.update({"album_from_folder": "maybe"})
    assert cfg.album_from_folder is True


def test_paused_is_persisted_and_survives_a_restart(tmp_path):
    cfg, store, a, b = make(tmp_path)
    assert cfg.paused is False
    store.update({"paused": True})
    assert cfg.paused is True and "paused" in store.overridden()
    cfg2, store2, _, _ = make(tmp_path)
    store2.load()
    assert cfg2.paused is True  # a restart does not silently resume
    store2.update({"paused": False})
    assert "paused" not in store2.overridden()
    with pytest.raises(SettingsError):
        store2.update({"paused": "maybe"})
