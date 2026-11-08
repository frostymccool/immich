"""Several Immich accounts in one bridge: users store, router, manager, API and hook."""

import json
import os
import stat
import threading
import time
import urllib.error
import urllib.request

import pytest

from bridge.config import Config
from bridge.immich import ImmichClient
from bridge.logbuffer import RingLogHandler
from bridge.manager import CHECKING, UserManager
from bridge.router import Router
from bridge.server import serve
from bridge.settings import SettingsStore
from bridge.state import StateStore
from bridge.users import MAIN_ID, UsersError, UsersStore
from tests.stub_immich import StubImmich

TOKEN = "admin-token-123456"
EXTS = {"jpg", "mp4"}


def call(base, method, path, body=None, token=TOKEN):
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["X-Bridge-Token"] = token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as ex:
        return ex.code, json.loads(ex.read() or b"{}")


def put(root, rel, content=b"data", age=120):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(content)
    t = time.time() - age
    os.utime(path, (t, t))
    return path


# ---------------------------------------------------------------- users store ----------------------------------


@pytest.fixture
def tree(tmp_path):
    root = tmp_path / "media"
    for d in ("shared/alice", "shared/bob", "shared/alice/trips", "other"):
        (root / d).mkdir(parents=True)
    return str(root)


def store(tmp_path, tree):
    return UsersStore(str(tmp_path / "data" / "users.json"), [tree])


def new_user(tree, **kw):
    base = {"name": "Alice", "api_key": "key-alice-123456", "folders": [f"{tree}/shared/alice"]}
    base.update(kw)
    return base


def test_store_add_slug_defaults_and_file_mode(tmp_path, tree):
    s = store(tmp_path, tree)
    u = s.add(new_user(tree, name="Alice Smith!"))
    assert u.id == "alice-smith"
    assert u.paused is True  # new people start paused: review, then adopt/resume
    mode = stat.S_IMODE(os.stat(tmp_path / "data" / "users.json").st_mode)
    assert mode == 0o600
    again = store(tmp_path, tree)
    again.load()
    assert [x.id for x in again.users()] == ["alice-smith"]
    assert again.users()[0].api_key == "key-alice-123456"


def test_store_ids_never_collide_or_use_reserved_names(tmp_path, tree):
    s = store(tmp_path, tree)
    assert s.add(new_user(tree, name="Main")).id == "main-2"
    b = s.add(new_user(tree, name="Main", folders=[f"{tree}/shared/bob"]))
    assert b.id == "main-3"


@pytest.mark.parametrize(
    "change,fragment",
    [
        ({"name": ""}, "name"),
        ({"api_key": "short"}, "api_key"),
        ({"api_key": "has space in it"}, "api_key"),
        ({"folders": ["relative/path"]}, "absolute"),
        ({"folders": ["/etc"]}, "outside"),
        ({"folders": ["/"]}, "not allowed"),
        ({"folders": []}, "folder"),
        ({"cp_logins": ["bad login"]}, "not valid"),
        ({"cp_logins": ["*"]}, "not valid"),
        ({"bogus": 1}, "unknown"),
    ],
)
def test_store_rejects_bad_input(tmp_path, tree, change, fragment):
    s = store(tmp_path, tree)
    with pytest.raises(UsersError) as ex:
        s.add(new_user(tree, **change))
    assert fragment in str(ex.value)
    assert s.users() == []


def test_store_folder_must_exist_and_not_overlap_others(tmp_path, tree):
    s = store(tmp_path, tree)
    s.add(new_user(tree))
    with pytest.raises(UsersError, match="does not exist"):
        s.add(new_user(tree, name="X", folders=[f"{tree}/shared/nope"]))
    with pytest.raises(UsersError, match="overlaps"):
        s.add(new_user(tree, name="Bob", folders=[f"{tree}/shared/alice/trips"]))
    with pytest.raises(UsersError, match="overlaps"):
        s.add(new_user(tree, name="Bob", folders=[f"{tree}/shared"]))
    s.add(new_user(tree, name="Bob", folders=[f"{tree}/shared/bob"]))


def test_store_login_belongs_to_one_person_only(tmp_path, tree):
    s = store(tmp_path, tree)
    s.add(new_user(tree, cp_logins=["alice"]))
    with pytest.raises(UsersError, match="already belongs"):
        s.add(new_user(tree, name="Bob", folders=[f"{tree}/shared/bob"], cp_logins=["alice"]))
    s.update_main({"cp_logins": ["family"]})
    with pytest.raises(UsersError, match="main account"):
        s.update("alice", {"cp_logins": ["family"]})


def test_store_update_keeps_key_unless_new_one_sent(tmp_path, tree):
    s = store(tmp_path, tree)
    s.add(new_user(tree))
    s.update("alice", {"name": "Alice B", "api_key": ""})
    assert s.get("alice").api_key == "key-alice-123456"
    assert s.get("alice").name == "Alice B"
    s.update("alice", {"api_key": "another-key-98765"})
    assert s.get("alice").api_key == "another-key-98765"


def test_store_priority_must_be_inside_folders(tmp_path, tree):
    s = store(tmp_path, tree)
    with pytest.raises(UsersError, match="priority"):
        s.add(new_user(tree, priority_dirs=[f"{tree}/other"]))
    u = s.add(new_user(tree, priority_dirs=[f"{tree}/shared/alice/trips"]))
    assert u.priority_dirs == [f"{tree}/shared/alice/trips"]


def test_store_remove_ignores_folders_and_new_owner_releases_them(tmp_path, tree):
    s = store(tmp_path, tree)
    s.add(new_user(tree))
    s.remove("alice")
    assert s.ignored_dirs == [f"{tree}/shared/alice"]
    s.add(new_user(tree, name="Carol"))
    assert s.ignored_dirs == []


def test_corrupt_users_file_is_an_error_not_single_user_mode(tmp_path, tree):
    path = tmp_path / "data" / "users.json"
    path.parent.mkdir()
    path.write_text("{ not json")
    with pytest.raises(UsersError, match="cannot read"):
        UsersStore(str(path), [tree]).load()
    path.write_text(json.dumps({"version": 99}))
    with pytest.raises(UsersError, match="unknown format"):
        UsersStore(str(path), [tree]).load()
    path.write_text(json.dumps({"version": 1, "users": [{"id": "main", "name": "x", "api_key": "k", "folders": []}]}))
    with pytest.raises(UsersError, match="invalid or duplicate"):
        UsersStore(str(path), [tree]).load()


def test_missing_users_file_means_single_user(tmp_path, tree):
    s = store(tmp_path, tree)
    s.load()
    assert s.users() == [] and s.ignored_dirs == []


# ------------------------------------------------------------------- router ------------------------------------


def make_router(tmp_path, tree, main=None):
    s = store(tmp_path, tree)
    main_dirs = main or [f"{tree}/shared"]
    r = Router(lambda: main_dirs, s, claims_db=str(tmp_path / "data" / "router.db"))
    return s, r


def test_router_single_user_is_just_the_watched_folders(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    assert r.owner(f"{tree}/shared/x.jpg") == MAIN_ID
    assert r.owner(f"{tree}/other/x.jpg") is None
    assert r.owner(f"{tree}/shared/../other/x.jpg") is None


def test_router_longest_folder_wins_and_folders_are_pruned_from_main(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree))
    assert r.owner(f"{tree}/shared/alice/a.jpg") == "alice"
    assert r.owner(f"{tree}/shared/alice/trips/a.jpg") == "alice"
    assert r.owner(f"{tree}/shared/bob/b.jpg") == MAIN_ID
    assert r.owner(f"{tree}/shared/alicex/a.jpg") is None or r.owner(f"{tree}/shared/alicex/a.jpg") == MAIN_ID
    assert r.other_roots(MAIN_ID) == [f"{tree}/shared/alice"]


def test_router_claim_moves_main_files_to_the_login_owner(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree, cp_logins=["alice"]))
    f = put(tree, "shared/bob/b.jpg")
    assert r.owner(f) == MAIN_ID
    assert r.claim(f, "alice") is True
    assert r.owner(f) == "alice"
    assert r.claimed_for("alice") == [f]
    # a different file at the same path no longer inherits the claim
    with open(f, "ab") as fh:
        fh.write(b"changed")
    assert r.owner(f) == MAIN_ID


def test_router_folder_beats_login(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree, cp_logins=["alice"]))
    s.add(new_user(tree, name="Bob", folders=[f"{tree}/shared/bob"]))
    f = put(tree, "shared/bob/b.jpg")
    assert r.claim(f, "alice") is False
    assert r.owner(f) == "bob"


def test_router_disabled_person_keeps_their_folders_and_their_claimed_files_are_held(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree, cp_logins=["alice"]))
    f = put(tree, "shared/x.jpg")
    assert r.claim(f, "alice")
    s.update("alice", {"enabled": False})
    assert r.owner(f) is None  # claimed for a person who is switched off: HELD, never rerouted into main
    assert r.owner(f"{tree}/shared/alice/a.jpg") == "alice"  # her folder is still hers: not rerouted to main
    s.update("alice", {"enabled": True})
    assert r.owner(f) == "alice"


def test_router_removed_person_files_do_not_fall_into_main(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree))
    s.remove("alice")
    assert r.owner(f"{tree}/shared/alice/a.jpg") is None


def test_router_refuses_symlinks_that_point_into_somebody_elses_folder(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree, name="Bob", folders=[f"{tree}/shared/bob"]))
    s.add(new_user(tree))
    secret = put(tree, "shared/alice/private.jpg")
    os.symlink(secret, f"{tree}/shared/bob/leak.jpg")
    os.symlink(f"{tree}/shared/alice", f"{tree}/shared/bob/linkdir")
    assert r.owner(secret) == "alice"
    assert r.owner(f"{tree}/shared/bob/leak.jpg") is None
    assert r.owner(f"{tree}/shared/bob/linkdir/private.jpg") is None


def test_router_claims_survive_restart_and_gc_forgets_gone_files(tmp_path, tree):
    s, r = make_router(tmp_path, tree)
    s.add(new_user(tree, cp_logins=["alice"]))
    f = put(tree, "shared/x.jpg")
    r.claim(f, "alice")
    r.close()
    _, r2 = make_router(tmp_path, tree)
    s2 = store(tmp_path, tree)
    s2.load()
    r3 = Router(lambda: [f"{tree}/shared"], s2, claims_db=str(tmp_path / "data" / "router.db"))
    assert r3.owner(f) == "alice"
    os.remove(f)
    assert r3.gc() == 1


# ------------------------------------------------- manager + workers, two fake Immich accounts ----------------------


class World:
    def __init__(self, tmp_path, tree, stub_main, stub_alice, people_root=None, extra_keys=None):
        self.tree = tree
        self.stub_main, self.stub_alice = stub_main, stub_alice
        self.by_key = {"main-key": stub_main.url, "key-alice-123456": stub_alice.url, **(extra_keys or {})}
        self.cfg = Config(
            immich_url=stub_main.url,
            api_key="main-key",
            watch_dirs=[f"{tree}/shared"],
            state_db=str(tmp_path / "data" / "state.db"),
            settings_file=str(tmp_path / "data" / "settings.json"),
            browse_roots=[tree],
            min_file_age=0,
            token=TOKEN,
            bind_host="127.0.0.1",
            bind_port=0,
            people_root=people_root or "",
        )
        self.users = UsersStore(str(tmp_path / "data" / "users.json"), [tree])
        holder = []
        self.router = Router(lambda: holder[0].people.main_dirs() if holder else self.cfg.watch_dirs, self.users,
                             str(tmp_path / "data" / "router.db"), strict=lambda: bool(holder and holder[0].people.enabled))
        self.manager = UserManager(self.cfg, self.users, self.router, set(EXTS), client_factory=self._client)
        holder.append(self.manager)
        self.state = StateStore(self.cfg.state_db)
        self.manager.start_main(self.state, self._client("main-key"))
        self.manager.check_identities()
        self.settings = SettingsStore(self.cfg, self.cfg.settings_file, [tree])
        self.scans = []
        self.httpd = serve(
            self.cfg, self.state, self.manager.runtime(MAIN_ID).worker, self.settings, RingLogHandler(50),
            scan_now=lambda: self.scans.append(1), manager=self.manager,
        )
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_port}"

    def _client(self, key):
        return ImmichClient(self.by_key.get(key, "http://127.0.0.1:9"), key, "dev", timeout=3)

    def wait(self, cond, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            if cond():
                return True
            time.sleep(0.05)
        return False

    def drain(self, uid):
        w = self.manager.runtime(uid).worker
        return self.wait(lambda: w.queue_size == 0 and not w.active() and not w._pending)

    def close(self):
        self.manager.stop_all()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.router.close()


@pytest.fixture
def world(tmp_path, tree):
    with StubImmich() as main_stub, StubImmich() as alice_stub:
        alice_stub.user_id, alice_stub.user_name, alice_stub.user_email = "user-alice", "Alice", "alice@example.test"
        w = World(tmp_path, tree, main_stub, alice_stub)
        yield w
        w.close()


def add_alice(world, **extra):
    status, body = call(
        world.base, "POST", "/api/users",
        {"name": "Alice", "api_key": "key-alice-123456", "folders": [f"{world.tree}/shared/alice"], "cp_logins": ["alice"], **extra},
    )
    assert status == 201, body
    return body


def test_each_person_imports_into_their_own_immich_account(world):
    tree = world.tree
    add_alice(world)
    # new people start paused until reviewed
    assert world.manager.describe("alice")["paused"] is True
    mine = put(tree, "shared/main.jpg", b"main photo")
    hers = put(tree, "shared/alice/her.jpg", b"alice photo")
    status, preview = call(world.base, "GET", "/api/users/alice/adopt")
    assert status == 200 and preview["expected_count"] == 0
    assert call(world.base, "POST", "/api/users/alice/adopt", {"confirm": True, "expected_count": 0})[0] == 200
    world.manager.sweep_all()
    assert world.drain(MAIN_ID) and world.drain("alice")
    assert len(world.stub_main.uploads) == 1
    assert len(world.stub_alice.uploads) == 1
    assert world.manager.runtime(MAIN_ID).state.get(mine).status == "imported"
    assert world.manager.runtime(MAIN_ID).state.get(hers) is None  # main never touched her file
    assert world.manager.runtime("alice").state.get(hers).status == "imported"


def test_paused_new_person_imports_nothing_until_resumed(world):
    add_alice(world)
    put(world.tree, "shared/alice/her.jpg", b"alice photo")
    world.manager.sweep_all()
    time.sleep(0.6)
    assert world.stub_alice.uploads == []
    assert world.manager.runtime("alice").worker.queue_size == 1
    assert call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})[0] == 200
    assert world.drain("alice")
    assert len(world.stub_alice.uploads) == 1


def test_same_immich_account_is_refused(world):
    status, body = call(
        world.base, "POST", "/api/users",
        {"name": "Twin", "api_key": "main-key", "folders": [f"{world.tree}/shared/bob"]},
    )
    assert status == 400 and "same Immich account" in body["error"]
    assert world.users.users() == []


def test_bad_key_is_refused_and_nothing_saved(world):
    status, body = call(
        world.base, "POST", "/api/users",
        {"name": "Nobody", "api_key": "unknown-key-1234", "folders": [f"{world.tree}/shared/bob"]},
    )
    assert status == 400 and "Could not reach Immich" in body["error"]  # the harness maps unknown keys to a dead address
    assert world.users.users() == []


def test_hook_login_claims_files_outside_the_persons_folder(world):
    add_alice(world)
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    f = put(world.tree, "shared/bob/dropped.jpg", b"alice uploaded this to the shared area")
    status, body = call(world.base, "POST", "/hook", {"ap": f, "user": "alice"})
    assert body == {"queued": 1}
    assert world.drain("alice")
    assert len(world.stub_alice.uploads) == 1 and world.stub_main.uploads == []
    # later sweeps agree with the hook: main does not import it again, alice's sweep does not either
    world.manager.sweep_all()
    assert world.drain(MAIN_ID) and world.drain("alice")
    assert len(world.stub_alice.uploads) == 1 and world.stub_main.uploads == []


def test_hook_anonymous_or_unknown_login_falls_back_to_the_folder_owner(world):
    add_alice(world)
    f1 = put(world.tree, "shared/a.jpg", b"anon")
    f2 = put(world.tree, "shared/b.jpg", b"stranger")
    call(world.base, "POST", "/hook", {"ap": f1, "user": "*"})
    call(world.base, "POST", "/hook", {"ap": f2, "user": "mallory"})
    assert world.drain(MAIN_ID)
    assert len(world.stub_main.uploads) == 2


def test_hook_login_cannot_pull_files_out_of_someone_elses_folder(world):
    add_alice(world)
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    s2 = StubImmich()
    with s2:
        s2.user_id = "user-bob"
        world.by_key["key-bob-1234567"] = s2.url
        status, _ = call(world.base, "POST", "/api/users",
                         {"name": "Bob", "api_key": "key-bob-1234567", "folders": [f"{world.tree}/shared/bob"]})
        assert status == 201
        call(world.base, "POST", "/api/pause", {"paused": False, "user": "bob"})
        f = put(world.tree, "shared/bob/b.jpg", b"bobs photo")
        call(world.base, "POST", "/hook", {"ap": f, "user": "alice"})
        assert world.drain("bob") and world.drain("alice")
        assert len(s2.uploads) == 1 and world.stub_alice.uploads == []


def test_hook_outside_every_folder_is_reported_not_silent(world):
    add_alice(world)
    f = put(world.tree, "other/x.jpg", b"nowhere")
    status, body = call(world.base, "POST", "/hook", {"ap": f, "user": "alice"})
    assert body == {"queued": 0}
    listing = call(world.base, "GET", "/api/users")[1]
    assert listing["unassigned"]["count"] == 1
    assert listing["unassigned"]["recent"][0]["login"] == "alice"


def test_hook_needs_a_token_once_there_are_several_users(world):
    add_alice(world)
    world.cfg.token = ""
    f = put(world.tree, "shared/x.jpg", b"x")
    status, body = call(world.base, "POST", "/hook", {"ap": f, "user": "alice"}, token=None)
    assert status == 403


def test_hook_source_selects_its_own_path_map(world, tmp_path):
    cp2 = os.path.join(world.tree, "shared", "bob")
    world.cfg.source_maps = {"cp2": [("/w", cp2)]}
    f = put(cp2, "pic.jpg", b"from the second copyparty")
    status, body = call(world.base, "POST", "/hook", {"ap": "/w/pic.jpg", "bridge_source": "cp2"})
    assert body == {"queued": 1}
    assert world.drain(MAIN_ID)
    assert world.manager.runtime(MAIN_ID).state.get(f).status == "imported"
    # an unknown source is ignored, it does NOT fall through to the global map
    status, body = call(world.base, "POST", "/hook", {"ap": "/w/pic.jpg", "bridge_source": "nope"})
    assert body == {"queued": 0}


def test_api_never_returns_an_api_key(world):
    body = add_alice(world)
    assert "api_key" not in body and body["api_key_set"] is True
    everything = json.dumps(
        [call(world.base, "GET", p)[1] for p in ("/api/users", "/api/config", "/api/config?user=alice", "/status", "/status?user=alice")]
    )
    assert "key-alice-123456" not in everything and "main-key" not in everything


def test_users_api_needs_the_token(world):
    assert call(world.base, "GET", "/api/users", token=None)[0] == 401
    assert call(world.base, "POST", "/api/users", {"name": "x"}, token="wrong")[0] == 401
    assert call(world.base, "DELETE", "/api/users/alice", {"confirm": "alice"}, token=None)[0] == 401
    assert call(world.base, "GET", "/api/users/alice/adopt", token=None)[0] == 401


def test_status_is_aggregate_without_user_and_scoped_with_it(world):
    add_alice(world)
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    put(world.tree, "shared/m.jpg", b"m")
    put(world.tree, "shared/alice/a.jpg", b"a")
    world.manager.sweep_all()
    assert world.drain(MAIN_ID) and world.drain("alice")
    total = call(world.base, "GET", "/status", token=None)[1]
    assert total["counts"] == {"imported": 2}
    assert total["recent"] == [] and total["users"] == 2  # no paths on the open endpoint with several users
    # per-person detail (paths, errors) is NOT on the open endpoint
    assert call(world.base, "GET", "/status?user=alice", token=None)[0] == 401
    one = call(world.base, "GET", "/status?user=alice")[1]
    assert one["counts"] == {"imported": 1}
    assert call(world.base, "GET", "/status?user=ghost")[0] == 404
    assert call(world.base, "GET", "/api/config?user=ghost")[0] == 404
    assert call(world.base, "POST", "/api/albums/recheck", {"user": "ghost"})[0] == 404


def test_single_user_status_has_the_old_shape(world):
    status = call(world.base, "GET", "/status", token=None)[1]
    assert set(status) == {"counts", "queue", "paused", "active", "backlog", "watch_dirs", "priority_dirs", "albums", "recent"}


def test_adopt_moves_records_from_the_previous_owner(world):
    tree = world.tree
    old = put(tree, "shared/alice/old.jpg", b"imported into main before alice existed")
    world.manager.sweep_all()
    assert world.drain(MAIN_ID)
    assert world.manager.runtime(MAIN_ID).state.get(old).status == "imported"
    add_alice(world)
    status, preview = call(world.base, "GET", "/api/users/alice/adopt")
    assert preview["records_to_move"] == 1 and preview["files_in_folders"] == 1
    # the numbers must be echoed back: a stale preview is refused
    assert call(world.base, "POST", "/api/users/alice/adopt", {"confirm": True, "expected_count": 5})[0] == 409
    assert call(world.base, "POST", "/api/users/alice/adopt", {"confirm": True})[0] == 400
    status, body = call(world.base, "POST", "/api/users/alice/adopt", {"confirm": True, "expected_count": 1})
    assert status == 200 and body["moved"] == 1 and body["paused"] is False
    assert world.manager.runtime(MAIN_ID).state.get(old) is None
    world.manager.sweep_all()
    assert world.drain("alice")
    assert len(world.stub_alice.uploads) == 1
    assert len(world.stub_main.uploads) == 1  # main's Immich copy is left alone


def test_remove_person_needs_typed_id_and_keeps_their_files_out_of_main(world):
    add_alice(world)
    assert call(world.base, "DELETE", "/api/users/alice", {"confirm": "yes"})[0] == 400
    assert call(world.base, "DELETE", "/api/users/main", {"confirm": "main"})[0] == 400
    status, body = call(world.base, "DELETE", "/api/users/alice", {"confirm": "alice"})
    assert status == 200 and body["ignored_dirs"] == [f"{world.tree}/shared/alice"]
    assert world.manager.runtime("alice") is None
    assert not os.path.exists(os.path.join(os.path.dirname(world.cfg.state_db), "users", "alice"))
    f = put(world.tree, "shared/alice/after.jpg", b"after removal")
    world.manager.sweep_all()
    assert world.drain(MAIN_ID)
    assert world.stub_main.uploads == [] and world.stub_alice.uploads == []
    # giving the folder back to main is an explicit step
    folder = f"{world.tree}/shared/alice"
    status, pv = call(world.base, "POST", "/api/users/ignored/preview", {"folder": folder})
    assert status == 200 and pv["files"] == 1
    assert call(world.base, "POST", "/api/users/ignored/remove", {"folder": folder})[0] == 400  # needs confirm + count
    assert call(world.base, "POST", "/api/users/ignored/remove", {"folder": folder, "confirm": True, "expected_count": 9})[0] == 409
    assert call(world.base, "POST", "/api/users/ignored/remove", {"folder": folder, "confirm": True, "expected_count": 1})[0] == 200
    world.manager.sweep_all()
    assert world.drain(MAIN_ID)
    assert len(world.stub_main.uploads) == 1


def test_update_person_changes_folders_live(world):
    add_alice(world)
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    status, body = call(world.base, "PUT", "/api/users/alice", {"folders": [f"{world.tree}/shared/bob"]})
    assert status == 200 and body["folders"] == [f"{world.tree}/shared/bob"]
    assert body["paused"] is True  # a changed folder list is paused until reviewed
    f = put(world.tree, "shared/bob/b.jpg", b"now alice's folder")
    assert call(world.base, "POST", "/api/users/alice/adopt", {"confirm": True, "expected_count": 0})[0] == 200
    world.manager.sweep_all()
    assert world.drain("alice")
    assert len(world.stub_alice.uploads) == 1 and world.stub_main.uploads == []
    assert call(world.base, "PUT", "/api/users/ghost", {"name": "x"})[0] == 404


def test_main_account_can_have_its_own_pause_and_name(world):
    assert call(world.base, "PUT", "/api/users/main", {"name": "Dad", "paused": True})[0] == 200
    f = put(world.tree, "shared/m.jpg", b"m")
    world.manager.sweep_all()
    time.sleep(0.5)
    assert world.stub_main.uploads == []
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "main"})
    assert world.drain(MAIN_ID)
    assert len(world.stub_main.uploads) == 1
    assert call(world.base, "PUT", "/api/users/main", {"folders": ["/x"]})[0] == 400


def test_check_endpoint_reports_the_account_without_saving(world):
    status, body = call(world.base, "POST", "/api/users/check", {"api_key": "key-alice-123456"})
    assert status == 200 and body["immich_user"]["email"] == "alice@example.test"
    assert world.users.users() == []
    assert call(world.base, "POST", "/api/users/check", {"api_key": "main-key"})[0] == 400


def test_describe_flags_missing_folder_and_album_permission(world):
    add_alice(world)
    world.stub_alice.key_permissions = ["asset.upload"]
    world.manager.runtime("alice").worker.check_album_permission()
    d = call(world.base, "GET", "/api/users")[1]["users"]
    alice = next(u for u in d if u["id"] == "alice")
    assert alice["album_permission"]["ok"] is False
    assert alice["immich_user"]["email"] == "alice@example.test"
    os.rmdir(f"{world.tree}/shared/alice/trips")
    os.rmdir(f"{world.tree}/shared/alice")
    alice = next(u for u in call(world.base, "GET", "/api/users")[1]["users"] if u["id"] == "alice")
    assert alice["missing_folders"] == [f"{world.tree}/shared/alice"]


def test_symlinked_file_is_not_imported_into_the_wrong_account(world):
    add_alice(world)
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    secret = put(world.tree, "shared/private.jpg", b"main person's private photo")
    os.symlink(secret, f"{world.tree}/shared/alice/leak.jpg")
    world.manager.sweep_all()
    assert world.drain(MAIN_ID) and world.drain("alice")
    assert world.stub_alice.uploads == []
    assert len(world.stub_main.uploads) == 1


def test_person_is_held_until_their_account_is_known(tmp_path, tree):
    with StubImmich() as s_main:
        w = World.__new__(World)
        cfg = Config(immich_url=s_main.url, api_key="main-key", watch_dirs=[f"{tree}/shared"],
                     state_db=str(tmp_path / "data" / "state.db"), min_file_age=0)
        users = UsersStore(str(tmp_path / "data" / "users.json"), [tree])
        users.add(new_user(tree, paused=False))
        router = Router(lambda: cfg.watch_dirs, users, str(tmp_path / "data" / "router.db"))
        m = UserManager(cfg, users, router, set(EXTS),
                        client_factory=lambda k: ImmichClient("http://127.0.0.1:9", k, "d", timeout=1))
        m.start_all()
        rt = m.runtime("alice")
        assert rt.view.blocked == CHECKING and rt.view.paused is True
        m.stop_all()


def test_two_people_on_one_account_are_held_at_startup(tmp_path, tree):
    with StubImmich() as s_main:
        cfg = Config(immich_url=s_main.url, api_key="main-key", watch_dirs=[f"{tree}/shared"],
                     state_db=str(tmp_path / "data" / "state.db"), min_file_age=0)
        users = UsersStore(str(tmp_path / "data" / "users.json"), [tree])
        users.add(new_user(tree, paused=False))
        router = Router(lambda: cfg.watch_dirs, users, str(tmp_path / "data" / "router.db"))
        m = UserManager(cfg, users, router, set(EXTS),
                        client_factory=lambda k: ImmichClient(s_main.url, k, "d", timeout=2))  # SAME account for both
        m.start_main(StateStore(cfg.state_db), ImmichClient(s_main.url, "main-key", "d", timeout=2))
        m.start_all()
        m.check_identities()
        assert "same Immich account" in m.runtime("alice").view.blocked
        assert m.runtime(MAIN_ID).view.blocked is None
        assert m.describe("alice")["blocked"]
        m.stop_all()


# ------------------------------------------------ hook script + config for several copyparty containers --------------


def run_hook(payload, env_extra):
    """Runs the real hook script against a local server and returns what the server received."""
    import subprocess
    import sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    got = []

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            got.append((self.headers.get("X-Bridge-Token"), json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    hook = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hook", "immich_bridge_hook.py")
    env = {"PATH": os.environ["PATH"], "IMMICH_BRIDGE_URL": f"http://127.0.0.1:{httpd.server_port}", **env_extra}
    subprocess.run([sys.executable, "-I", hook, json.dumps(payload)], env=env, check=True, timeout=30)
    httpd.shutdown()
    httpd.server_close()
    return got


def test_hook_script_tags_the_source_and_passes_the_login_through():
    got = run_hook({"ap": "/w/a.jpg", "user": "alex", "src": "xau"}, {"IMMICH_BRIDGE_SOURCE": "cp2", "IMMICH_BRIDGE_TOKEN": "tok"})
    assert got == [("tok", {"ap": "/w/a.jpg", "user": "alex", "src": "xau", "bridge_source": "cp2"})]


def test_hook_script_without_source_sends_the_payload_unchanged():
    got = run_hook({"ap": "/w/a.jpg", "user": "alex"}, {})
    assert got == [(None, {"ap": "/w/a.jpg", "user": "alex"})]


def test_hook_script_tags_every_event_of_a_batch():
    got = run_hook([{"ap": "/w/a.jpg"}, {"ap": "/w/b.jpg"}], {"IMMICH_BRIDGE_SOURCE": "cp3"})
    assert [e["bridge_source"] for e in got[0][1]] == ["cp3", "cp3"]


def test_source_maps_env_is_parsed():
    cfg = Config.from_env({
        "IMMICH_URL": "http://i:2283", "IMMICH_API_KEY": "k", "WATCH_DIRS": "/cp/cp2",
        "SOURCE_MAPS": "cp2|/w=/cp/cp2, cp3|/data/up=/cp/cp3",
    })
    assert cfg.source_maps == {"cp2": [("/w", "/cp/cp2")], "cp3": [("/data/up", "/cp/cp3")]}
    assert cfg.map_source_path("cp2", "/w/trip/a.jpg") == "/cp/cp2/trip/a.jpg"
    assert cfg.map_source_path("cp2", "/other/a.jpg") == "/other/a.jpg"
    assert cfg.map_source_path("ghost", "/w/a.jpg") is None


@pytest.mark.parametrize("bad", ["cp2:/w=/x", "cp2|/w", "|/w=/x", "cp2|=/x"])
def test_source_maps_bad_entries_are_config_errors(bad):
    from bridge.config import ConfigError

    with pytest.raises(ConfigError):
        Config.from_env({"IMMICH_URL": "http://i:2283", "IMMICH_API_KEY": "k", "WATCH_DIRS": "/x", "SOURCE_MAPS": bad})


# --------------------------------------------- fixes from the second review round -------------------------------------


def test_claimed_file_stays_held_when_its_person_is_removed(world):
    add_alice(world)
    call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    f = put(world.tree, "shared/bob/dropped.jpg", b"alice's upload in the shared area")
    world.cfg.min_file_age = 10_000  # the sweep must not take it yet; only the hook claims it
    call(world.base, "POST", "/hook", {"ap": f, "user": "alice"})
    assert world.drain("alice")
    assert call(world.base, "DELETE", "/api/users/alice", {"confirm": "alice"})[0] == 200
    world.cfg.min_file_age = 0
    f2 = put(world.tree, "shared/bob/second.jpg", b"claimed then removed")
    assert world.router.owner(f) is None  # claimed by a person who is gone: held, NOT main's
    world.manager.sweep_all()
    assert world.drain(MAIN_ID)
    assert world.stub_main.uploads and all(True for _ in world.stub_main.uploads)  # f2 (unclaimed) goes to main
    assert world.manager.runtime(MAIN_ID).state.get(f) is None


def test_a_claim_is_never_overwritten_and_never_touches_a_file_main_already_imported(world):
    add_alice(world)
    s2 = StubImmich()
    with s2:
        s2.user_id = "user-bob"
        world.by_key["key-bob-1234567"] = s2.url
        assert call(world.base, "POST", "/api/users", {"name": "Bob", "api_key": "key-bob-1234567", "folders": [f"{world.tree}/shared/bob"], "cp_logins": ["bobby"]})[0] == 201
        f = put(world.tree, "shared/x.jpg", b"first uploader wins")
        assert world.router.claim(f, "alice") is True
        assert world.router.claim(f, "bob") is False
        assert world.router.owner(f) == "alice"
        # a file main already imported is not re-claimed by a later hook
        g = put(world.tree, "shared/g.jpg", b"already in main")
        world.manager.sweep_all()
        assert world.drain(MAIN_ID)
        call(world.base, "POST", "/hook", {"ap": g, "user": "alice"})
        assert world.router.owner(g) == MAIN_ID


def test_shrinking_a_persons_folders_ignores_the_dropped_one(world):
    add_alice(world, folders=[f"{world.tree}/shared/alice", f"{world.tree}/shared/bob"])
    status, body = call(world.base, "PUT", "/api/users/alice", {"folders": [f"{world.tree}/shared/alice"]})
    assert status == 200
    assert world.users.ignored_dirs == [f"{world.tree}/shared/bob"]
    assert world.router.owner(f"{world.tree}/shared/bob/x.jpg") is None  # not main's


def test_changing_folders_pauses_the_person_and_resume_cannot_skip_the_review(world):
    add_alice(world)
    call(world.base, "POST", "/api/users/alice/adopt", {"confirm": True, "expected_count": 0})
    assert world.manager.describe("alice")["paused"] is False
    old = put(world.tree, "shared/bob/old.jpg", b"main imported this already")
    world.manager.sweep_all()
    assert world.drain(MAIN_ID)
    status, body = call(world.base, "PUT", "/api/users/alice", {"folders": [f"{world.tree}/shared/alice", f"{world.tree}/shared/bob"]})
    assert status == 200 and body["paused"] is True  # a new folder list needs a fresh look
    status, body = call(world.base, "POST", "/api/pause", {"paused": False, "user": "alice"})
    assert status == 409 and "Review & start" in body["error"]
    assert world.stub_alice.uploads == []


def test_prefix_matching_is_case_sensitive(tmp_path):
    st = StateStore(str(tmp_path / "s.db"))
    st.record_success("/data/Alice/a.jpg", 1, 1.0, "h", "imported", "x")
    st.record_success("/data/alice/b.jpg", 1, 1.0, "h", "imported", "y")
    st.record_success("/data/alice_b/c.jpg", 1, 1.0, "h", "imported", "z")
    assert st.count_done_under(["/data/Alice"]) == 1
    assert st.forget_under(["/data/alice"]) == 1
    assert sorted(r.path for r in st.recent(10)) == ["/data/Alice/a.jpg", "/data/alice_b/c.jpg"]


def test_closed_store_reads_are_empty_not_errors(tmp_path):
    st = StateStore(str(tmp_path / "s.db"))
    st.close()
    assert st.counts() == {} and st.recent(5) == [] and st.last_failure() is None


def test_hook_paths_with_dotdot_are_refused_and_others_normalised(world):
    f = put(world.tree, "shared/ok.jpg", b"fine")
    assert call(world.base, "POST", "/hook", {"ap": f"{world.tree}/shared/bob/../ok.jpg"})[1] == {"queued": 0}
    assert call(world.base, "POST", "/hook", {"ap": f"{world.tree}/shared//ok.jpg"})[1] == {"queued": 1}


def test_bad_inputs_get_clean_errors_not_dropped_connections(world):
    req = urllib.request.Request(world.base + "/api/users", data=b"{}", method="POST",
                                 headers={"X-Bridge-Token": TOKEN, "Content-Length": "abc"})
    try:
        urllib.request.urlopen(req, timeout=5)
        code = 200
    except urllib.error.HTTPError as ex:
        code = ex.code
    except Exception:
        code = -1
    assert code in (400, -1)  # rejected; the server must also still answer afterwards
    assert call(world.base, "POST", "/api/pause", {"paused": True, "user": ["x"]})[0] == 400
    assert call(world.base, "POST", "/api/users/check", {"api_key": "main-key", "user": ["x"]})[0] == 400
    assert call(world.base, "GET", "/healthz", token=None)[0] == 200


def test_one_broken_person_does_not_stop_the_others_starting(tmp_path, tree):
    with StubImmich() as s_main:
        cfg = Config(immich_url=s_main.url, api_key="main-key", watch_dirs=[f"{tree}/shared"],
                     state_db=str(tmp_path / "data" / "state.db"), min_file_age=0)
        users = UsersStore(str(tmp_path / "data" / "users.json"), [tree])
        users.add(new_user(tree))
        users.add(new_user(tree, name="Bob", folders=[f"{tree}/shared/bob"], api_key="key-bob-1234567"))
        router = Router(lambda: cfg.watch_dirs, users, str(tmp_path / "data" / "router.db"))
        m = UserManager(cfg, users, router, set(EXTS), client_factory=lambda k: ImmichClient(s_main.url, k, "d", timeout=2))
        os.makedirs(tmp_path / "data", exist_ok=True)
        (tmp_path / "data" / "users").write_text("a FILE where the users directory should be")
        m.start_all()  # must not raise
        assert m.runtime("alice") is None and m.runtime("bob") is None
        assert m.describe("alice")["running"] is False
        m.stop_all()


def test_extras_stay_held_until_mains_own_account_is_known(tmp_path, tree):
    with StubImmich() as s_main:
        cfg = Config(immich_url=s_main.url, api_key="main-key", watch_dirs=[f"{tree}/shared"],
                     state_db=str(tmp_path / "data" / "state.db"), min_file_age=0)
        users = UsersStore(str(tmp_path / "data" / "users.json"), [tree])
        users.add(new_user(tree))
        router = Router(lambda: cfg.watch_dirs, users, str(tmp_path / "data" / "router.db"))
        m = UserManager(cfg, users, router, set(EXTS), client_factory=lambda k: ImmichClient(s_main.url, k, "d", timeout=2))
        m.start_main(StateStore(cfg.state_db), ImmichClient(s_main.url, "main-key", "d", timeout=2))
        m.start_all()
        m.runtime("alice").worker.immich_user = {"id": "user-1", "name": "x", "email": "x"}  # alice known, main NOT
        m._flag_duplicates()
        assert m.runtime("alice").view.blocked == CHECKING  # cannot be shown to differ from an unknown main
        m.stop_all()


def test_shutdown_waits_for_workers_then_closes_the_stores(world):
    add_alice(world)
    rt = world.manager.runtime("alice")
    world.manager.close_all()
    assert rt.state.counts() == {}
    assert not any(t.is_alive() for t in rt.worker._threads)


def check(world, **body):
    return call(world.base, "POST", "/api/users/check", {"api_key": "key-alice-123456", **body})


def test_invalid_key_is_called_invalid(world):
    world.stub_alice.api_key_status = 401
    code, body = check(world)
    assert code == 400 and "not valid" in body["error"]


def test_missing_permissions_are_listed_explicitly(world):
    world.stub_alice.key_permissions = ["asset.upload", "album.read"]
    code, body = check(world)
    assert code == 400
    assert "user.read" in body["error"] and "to tell which Immich account" in body["error"]
    assert "missing required permission:" in body["error"] and "asset.upload (needed" not in body["error"]
    assert "It currently has: album.read, asset.upload" in body["error"]


def test_every_missing_permission_is_named(world):
    world.stub_alice.key_permissions = ["album.read"]
    code, body = check(world)
    assert code == 400 and "permissions:" in body["error"]
    assert "user.read (needed" in body["error"] and "asset.upload (needed" in body["error"]
    world.stub_alice.key_permissions = []
    assert "no permissions at all" in check(world)[1]["error"]


def test_missing_permission_blocks_adding_the_person(world):
    world.stub_alice.key_permissions = ["user.read"]
    code, body = call(world.base, "POST", "/api/users",
                      {"name": "A", "api_key": "key-alice-123456", "folders": [f"{world.tree}/shared/alice"]})
    assert code == 400 and "asset.upload" in body["error"] and world.users.users() == []


def test_missing_album_permissions_are_listed_but_do_not_block(world):
    world.stub_alice.key_permissions = ["user.read", "asset.upload", "album.read"]
    code, body = check(world)
    assert code == 200
    assert body["album_permission"]["ok"] is False
    assert body["album_permission"]["missing"] == ["album.create", "albumAsset.create"]
    assert "create folder albums" in body["album_permission"]["why"]["album.create"]
    world.stub_alice.key_permissions = ["all"]
    assert check(world)[1]["album_permission"] == {"ok": True, "missing": [], "why": {}}


def test_other_immich_failures_are_reported_with_their_status(world):
    world.stub_alice.users_me_status = 500
    code, body = check(world)
    assert code == 400 and "HTTP 500" in body["error"]


def test_key_check_says_when_immich_is_unreachable(world):
    world.by_key["key-lost-1234567"] = "http://127.0.0.1:9"
    code, body = call(world.base, "POST", "/api/users/check", {"api_key": "key-lost-1234567"})
    assert code == 400 and "Could not reach Immich" in body["error"]



# ------------------------------------------- folder-per-person mode: <firstname>-<immich user id> ----------------------

from bridge.people import PeopleLayout, parse_folder  # noqa: E402

ID_MAIN = "11111111-aaaa-4bbb-8ccc-000000005567"
ID_LEZA = "22222222-aaaa-4bbb-8ccc-0000000091c2"
ID_SAM = "33333333-aaaa-4bbb-8ccc-00000000d00d"


@pytest.fixture
def pworld(tmp_path, tree):
    root = os.path.join(tree, "people")
    for d in (f"ian-{ID_MAIN}", f"leza-{ID_LEZA}", f"sam-{ID_SAM}", "notes", ".hidden"):
        os.makedirs(os.path.join(root, d))
    with StubImmich() as s_main, StubImmich() as s_leza, StubImmich() as s_sam:
        for stub, uid, name in ((s_main, ID_MAIN, "Ian"), (s_leza, ID_LEZA, "Leza"), (s_sam, ID_SAM, "Sam")):
            stub.user_id, stub.user_name, stub.user_email = uid, name, f"{name.lower()}@example.test"
        w = World(tmp_path, tree, s_main, s_leza, people_root=root,
                  extra_keys={"key-leza-1234567": s_leza.url, "key-sam-12345678": s_sam.url})
        w.by_key["key-alice-123456"] = s_leza.url
        w.s_sam, w.s_leza, w.root = s_sam, s_leza, root
        yield w
        w.close()


def folder_of(world, who):
    return next(e["folder"] for e in world.manager.people_folders()["folders"] if e["name"].lower() == who)


def test_parse_folder_names():
    assert parse_folder(f"leza-{ID_LEZA}") == ("Leza", ID_LEZA)
    assert parse_folder(f"mary-ann-{ID_LEZA.upper()}") == ("Mary-ann", ID_LEZA)  # hyphenated name; id lower-cased
    for bad in ("leza", "leza-5567", f"-{ID_LEZA}", f".leza-{ID_LEZA}", f"leza_{ID_LEZA}", f"leza-{ID_LEZA}x"):
        assert parse_folder(bad) is None, bad


def test_main_imports_only_its_own_folder_and_nobody_imports_unmatched_ones(pworld):
    mine = put(pworld.root, f"ian-{ID_MAIN}/a.jpg", b"ian photo")
    put(pworld.root, f"leza-{ID_LEZA}/l.jpg", b"leza photo before she is added")
    put(pworld.root, "loose.jpg", b"file directly in the people root")
    put(pworld.root, "notes/n.jpg", b"folder that is not name-id")
    pworld.manager.people.invalidate()
    pworld.manager.sweep_all()
    assert pworld.drain(MAIN_ID)
    assert len(pworld.stub_main.uploads) == 1 and pworld.s_leza.uploads == []
    assert pworld.manager.runtime(MAIN_ID).state.get(mine).status == "imported"
    # the open hook cannot route them either: not imported, reported
    f = os.path.join(pworld.root, f"leza-{ID_LEZA}", "l.jpg")
    assert call(pworld.base, "POST", "/hook", {"ap": f})[1] == {"queued": 0}


def test_dropdown_lists_names_without_ids_and_marks_who_has_what(pworld):
    body = call(pworld.base, "GET", "/api/people-folders")[1]
    assert body["enabled"] and body["root"] == pworld.root
    by = {e["name"]: e for e in body["folders"]}
    assert set(by) == {"Ian", "Leza", "Sam"}
    assert by["Ian"]["claimed_by"] == MAIN_ID and by["Leza"]["claimed_by"] is None
    assert by["Leza"]["last4"] == "91c2" and by["Leza"]["duplicate_name"] is False
    assert body["skipped"] == ["notes"]
    assert ID_LEZA not in json.dumps([{k: v for k, v in e.items() if k != "folder"} for e in body["folders"]])


def test_add_person_from_folder_checks_the_whole_id(pworld):
    leza = folder_of(pworld, "leza")
    status, body = call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})
    assert status == 201, body
    assert body["name"] == "Leza" and body["paused"] is True and body["id_last4"] == "91c2"
    assert body["folders"] == [os.path.join(pworld.root, leza)]
    assert pworld.users.get("leza").immich_id == ID_LEZA
    put(pworld.root, f"{leza}/l.jpg", b"leza photo")
    assert call(pworld.base, "POST", "/api/users/leza/adopt", {"confirm": True, "expected_count": 0})[0] == 200
    pworld.manager.sweep_all()
    assert pworld.drain("leza") and pworld.drain(MAIN_ID)
    assert len(pworld.s_leza.uploads) == 1 and pworld.stub_main.uploads == []


def test_the_wrong_account_key_is_refused_with_last_four_digits_not_the_id(pworld):
    leza = folder_of(pworld, "leza")
    status, body = call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-sam-12345678"})
    assert status == 400 and pworld.users.users() == []
    msg = body["error"]
    assert "Sam" in msg and "…d00d" in msg and "…91c2" in msg and "Leza" in msg
    assert ID_LEZA not in msg and ID_SAM not in msg
    status, body = call(pworld.base, "POST", "/api/users/check", {"people_folder": leza, "api_key": "key-sam-12345678"})
    assert status == 400 and "…91c2" in body["error"]
    ok = call(pworld.base, "POST", "/api/users/check", {"people_folder": leza, "api_key": "key-leza-1234567"})
    assert ok[0] == 200 and ok[1]["folder_ok"] is True and ok[1]["immich_user"]["name"] == "Leza"


def test_folder_must_exist_and_cannot_be_taken_twice(pworld):
    assert call(pworld.base, "POST", "/api/users", {"people_folder": "ghost-" + ID_SAM, "api_key": "key-sam-12345678"})[0] == 400
    assert call(pworld.base, "POST", "/api/users", {"people_folder": "../etc", "api_key": "key-sam-12345678"})[0] == 400
    leza = folder_of(pworld, "leza")
    assert call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})[0] == 201
    status, body = call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})
    assert status == 400  # the same account / folder again
    assert call(pworld.base, "POST", "/api/users", {"people_folder": folder_of(pworld, "ian"), "api_key": "main-key"})[0] == 400


def test_a_persons_key_can_only_be_replaced_by_a_key_of_the_same_account(pworld):
    leza = folder_of(pworld, "leza")
    call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})
    status, body = call(pworld.base, "PUT", "/api/users/leza", {"api_key": "key-sam-12345678"})
    assert status == 400 and "different Immich account" in body["error"] and "…91c2" in body["error"]
    assert pworld.users.get("leza").api_key == "key-leza-1234567"


def test_main_waits_until_its_account_id_is_known(tmp_path, tree):
    root = os.path.join(tree, "people")
    os.makedirs(os.path.join(root, f"ian-{ID_MAIN}"))
    ids = {"v": ""}
    lay = PeopleLayout(lambda: root, lambda: ids["v"], lambda: ["/unused"])
    assert lay.main_dirs() == []  # id unknown: imports NOTHING rather than guess
    ids["v"] = ID_MAIN.upper()
    assert lay.main_dirs() == [os.path.join(root, f"ian-{ID_MAIN}")]
    off = PeopleLayout(lambda: "", lambda: ID_MAIN, lambda: ["/data/x"])
    assert off.enabled is False and off.main_dirs() == ["/data/x"]


def test_people_root_is_validated_when_saved_and_can_be_switched_off(world):
    assert call(world.base, "PUT", "/api/config", {"people_root": "relative"})[0] == 400
    assert call(world.base, "PUT", "/api/config", {"people_root": "/"})[0] == 400
    assert call(world.base, "PUT", "/api/config", {"people_root": "/etc"})[0] == 400
    assert call(world.base, "PUT", "/api/config", {"people_root": world.tree + "/nope"})[0] == 400
    assert call(world.base, "PUT", "/api/config", {"people_root": world.tree + "/shared"})[0] == 200
    assert call(world.base, "GET", "/api/people-folders")[1]["enabled"] is True
    assert call(world.base, "PUT", "/api/config", {"people_root": ""})[0] == 200
    assert call(world.base, "GET", "/api/people-folders")[1]["enabled"] is False
    assert call(world.base, "POST", "/api/users", {"people_folder": "x", "api_key": "key-alice-123456"})[0] == 400


def test_two_people_with_the_same_first_name_get_a_hint(pworld):
    other = "44444444-aaaa-4bbb-8ccc-00000000beef"
    os.makedirs(os.path.join(pworld.root, f"sam-{other}"))
    body = call(pworld.base, "GET", "/api/people-folders")[1]
    sams = [e for e in body["folders"] if e["name"] == "Sam"]
    assert len(sams) == 2 and all(e["duplicate_name"] for e in sams)
    assert sorted(e["last4"] for e in sams) == ["beef", "d00d"]


def test_a_persons_id_folder_does_not_become_an_immich_album_name(pworld):
    leza = folder_of(pworld, "leza")
    call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})
    call(pworld.base, "POST", "/api/users/leza/adopt", {"confirm": True, "expected_count": 0})
    put(pworld.root, f"{leza}/top.jpg", b"directly in the person's folder")
    put(pworld.root, f"{leza}/Holiday/sub.jpg", b"in a subfolder")
    pworld.manager.sweep_all()
    assert pworld.drain("leza")
    names = [a["albumName"] for a in pworld.s_leza.albums]
    assert names == ["Holiday"], names  # no album carrying the account id
    assert not any(ID_LEZA in n for n in names)


# ------------------------------------------ review fixes for folder-per-person ----------------------------------------


def test_a_symlinked_folder_can_never_be_somebodys_folder(pworld):
    sam = f"sam-{ID_SAM}"
    os.symlink(os.path.join(pworld.root, sam), os.path.join(pworld.root, f"evil-{ID_LEZA}"))  # right id, wrong target
    os.symlink(os.path.join(pworld.root, f"leza-{ID_LEZA}"), os.path.join(pworld.root, f"mirror-{ID_MAIN}"))
    body = call(pworld.base, "GET", "/api/people-folders")[1]
    assert "evil-" + ID_LEZA not in [e["folder"] for e in body["folders"]]
    assert f"evil-{ID_LEZA}" in body["skipped"]
    assert all("mirror" not in d for d in pworld.manager.people.main_dirs())
    status, err = call(pworld.base, "POST", "/api/users", {"people_folder": f"evil-{ID_LEZA}", "api_key": "key-leza-1234567"})
    assert status == 400 and "not found" in err["error"]
    put(pworld.root, f"leza-{ID_LEZA}/l.jpg", b"leza's photo")
    pworld.manager.people.invalidate()
    pworld.manager.sweep_all()
    assert pworld.drain(MAIN_ID)
    assert pworld.stub_main.uploads == []  # the linked copy of Leza's folder was not imported into Ian's account


def test_a_file_symlink_inside_mains_own_folder_is_refused_in_this_mode(pworld):
    secret = put(pworld.root, f"leza-{ID_LEZA}/secret.jpg", b"leza's private photo")
    os.symlink(secret, os.path.join(pworld.root, f"ian-{ID_MAIN}", "leak.jpg"))
    put(pworld.root, f"ian-{ID_MAIN}/mine.jpg", b"ian's own")
    pworld.manager.people.invalidate()
    pworld.manager.sweep_all()
    assert pworld.drain(MAIN_ID)
    assert len(pworld.stub_main.uploads) == 1  # only his own file, with a SINGLE person (no extra people yet)


def test_a_remembered_main_id_never_routes_files(pworld):
    rt = pworld.manager.runtime(MAIN_ID)
    rt.state.set_meta("immich_user_id", ID_LEZA)  # an old run saw another account
    rt.worker.immich_user = None                   # and Immich has not answered yet this run
    pworld.manager.people.invalidate()
    assert pworld.manager.people.main_dirs() == []
    rt.worker.immich_user = {"id": ID_MAIN, "name": "Ian", "email": "x"}
    pworld.manager.people.invalidate()
    assert pworld.manager.people.main_dirs() == [os.path.join(pworld.root, f"ian-{ID_MAIN}")]


def test_a_person_is_held_when_their_key_stops_matching_their_folder(pworld):
    leza = folder_of(pworld, "leza")
    call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})
    rt = pworld.manager.runtime("leza")
    rt.worker.immich_user = {"id": ID_SAM, "name": "Sam", "email": "sam@example.test"}  # the key now resolves elsewhere
    pworld._flag = pworld.manager._flag_duplicates()
    assert "different Immich account" in rt.view.blocked and "…d00d" in rt.view.blocked and "…91c2" in rt.view.blocked
    assert rt.view.paused is True


def test_folders_inside_the_people_folder_must_be_named_for_that_persons_account(pworld):
    leza = folder_of(pworld, "leza")
    call(pworld.base, "POST", "/api/users", {"people_folder": leza, "api_key": "key-leza-1234567"})
    status, body = call(pworld.base, "PUT", "/api/users/leza", {"folders": [os.path.join(pworld.root, f"sam-{ID_SAM}")]})
    assert status == 400 and "must be named" in body["error"]
    status, body = call(pworld.base, "PUT", "/api/users/leza", {"folders": [os.path.join(pworld.root, f"ian-{ID_MAIN}")]})
    assert status == 400
    ok = os.path.join(pworld.root, f"leza-{ID_LEZA}", "Holiday")
    os.makedirs(ok)
    assert call(pworld.base, "PUT", "/api/users/leza", {"folders": [ok]})[0] == 200  # a subfolder of her own is fine
    assert pworld.manager.describe("leza")["paused"] is True
    # the old way, with a hand-typed folder named for somebody else's account, is refused the same way
    status, body = call(pworld.base, "POST", "/api/users", {"name": "Eve", "api_key": "key-sam-12345678",
                                                            "folders": [os.path.join(pworld.root, f"ian-{ID_MAIN}")]})
    assert status == 400 and "must be named" in body["error"] and pworld.users.get("eve") is None


def test_status_priority_dirs_follow_the_workers_view(pworld):
    pworld.cfg.priority_dirs = ["/elsewhere"]
    st = call(pworld.base, "GET", "/status", token=None)[1]
    assert st["priority_dirs"] == []  # in this mode the main account has no priority folder


def test_a_saved_people_root_survives_a_missing_mount_at_boot(tmp_path, tree):
    missing = os.path.join(tree, "not-mounted-yet")
    cfg = Config(immich_url="http://x", api_key="k", watch_dirs=[f"{tree}/shared"], state_db=str(tmp_path / "s.db"))
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"overrides": {"people_root": missing}}))
    store_ = SettingsStore(cfg, str(path), [tree])
    store_.load()
    assert cfg.people_root == missing  # kept: an empty scan imports nothing, dropping it would hand main the whole tree
    lay = PeopleLayout(lambda: cfg.people_root, lambda: ID_MAIN, lambda: cfg.watch_dirs)
    assert lay.enabled and lay.main_dirs() == []
    path.write_text(json.dumps({"overrides": {"people_root": "/etc"}}))
    cfg2 = Config(immich_url="http://x", api_key="k", watch_dirs=[f"{tree}/shared"], state_db=str(tmp_path / "s2.db"))
    SettingsStore(cfg2, str(path), [tree]).load()
    assert cfg2.people_root == ""  # outside the visible folders: still refused


def test_identity_check_wakes_the_sweep(tmp_path, tree):
    with StubImmich() as s_main:
        cfg = Config(immich_url=s_main.url, api_key="main-key", watch_dirs=[f"{tree}/shared"], state_db=str(tmp_path / "data" / "state.db"))
        users = UsersStore(str(tmp_path / "data" / "users.json"), [tree])
        router = Router(lambda: cfg.watch_dirs, users, str(tmp_path / "data" / "router.db"))
        m = UserManager(cfg, users, router, set(EXTS), client_factory=lambda k: ImmichClient(s_main.url, k, "d", timeout=2))
        m.start_main(StateStore(cfg.state_db), ImmichClient(s_main.url, "main-key", "d", timeout=2))
        woke = []
        m.wake = lambda: woke.append(1)
        m.check_identities()
        assert woke == [1]
        m.stop_all()


# ----------------------------------------------- automatic detection of the people folder ------------------------------


def test_people_folders_are_detected_automatically_in_the_mounted_data_folder(tmp_path, tree):
    for d in (f"ian-{ID_MAIN}", f"leza-{ID_LEZA}", "notes"):
        os.makedirs(os.path.join(tree, d))
    cfg = {"v": ""}
    lay = PeopleLayout(lambda: cfg["v"], lambda: ID_MAIN, lambda: ["/legacy"], lambda: [tree])
    assert lay.mode() == "auto" and lay.enabled and lay.root() == tree
    assert lay.main_dirs() == [os.path.join(tree, f"ian-{ID_MAIN}")]
    assert [e["name"] for e in lay.scan()[0]] == ["Ian", "Leza"]
    cfg["v"] = "off"
    lay.invalidate()
    assert lay.mode() == "off" and not lay.enabled and lay.main_dirs() == ["/legacy"]
    cfg["v"] = os.path.join(tree, "other")  # an explicit folder wins over detection
    lay.invalidate()
    assert lay.mode() == "set" and lay.root() == os.path.join(tree, "other")


def test_nothing_is_detected_without_matching_folders(tmp_path, tree):
    lay = PeopleLayout(lambda: "", lambda: ID_MAIN, lambda: ["/legacy"], lambda: [tree])
    assert lay.mode() == "auto" and lay.root() == "" and not lay.enabled
    assert lay.main_dirs() == ["/legacy"]  # a plain install keeps behaving exactly as before
    os.makedirs(os.path.join(tree, f"sam-{ID_SAM}"))
    lay.invalidate()
    assert lay.enabled  # switches on by itself as soon as such a folder appears


def test_auto_detected_dropdown_adds_a_person_end_to_end(tmp_path, tree):
    for d in (f"ian-{ID_MAIN}", f"leza-{ID_LEZA}"):
        os.makedirs(os.path.join(tree, d))
    with StubImmich() as s_main, StubImmich() as s_leza:
        for stub, uid, name in ((s_main, ID_MAIN, "Ian"), (s_leza, ID_LEZA, "Leza")):
            stub.user_id, stub.user_name, stub.user_email = uid, name, f"{name.lower()}@example.test"
        w = World(tmp_path, tree, s_main, s_leza, people_root="", extra_keys={"key-leza-1234567": s_leza.url})
        try:
            w.manager.people.invalidate()
            body = call(w.base, "GET", "/api/people-folders")[1]
            assert body["enabled"] and body["mode"] == "auto" and body["root"] == tree
            assert [e["name"] for e in body["folders"] if not e["claimed_by"]] == ["Leza"]
            users = call(w.base, "GET", "/api/users")[1]
            assert users["people_mode"] == "auto" and users["people_root"] == tree
            assert call(w.base, "POST", "/api/users", {"people_folder": f"leza-{ID_LEZA}", "api_key": "key-leza-1234567"})[0] == 201
        finally:
            w.close()


def test_people_root_setting_accepts_off_and_empty(world):
    assert call(world.base, "PUT", "/api/config", {"people_root": "off"})[0] == 200
    assert world.cfg.people_root == "off"
    assert call(world.base, "GET", "/api/people-folders")[1]["mode"] == "off"
    assert call(world.base, "PUT", "/api/config", {"people_root": ""})[0] == 200
    assert world.cfg.people_root == "" and call(world.base, "GET", "/api/people-folders")[1]["mode"] == "auto"
    assert call(world.base, "PUT", "/api/config", {"people_root": "Off "})[0] == 200 and world.cfg.people_root == "off"


def test_people_root_env_values():
    base = {"IMMICH_URL": "http://i", "IMMICH_API_KEY": "k", "WATCH_DIRS": "/x"}
    for raw, want in (("", ""), ("off", "off"), ("NONE", "off"), ("/w/people/", "/w/people")):
        assert Config.from_env({**base, "PEOPLE_ROOT": raw}).people_root == want
