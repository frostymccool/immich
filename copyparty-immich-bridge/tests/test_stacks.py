"""RAW + JPG stacking: same rules as the phone app, the whole library on the first sweep, once per pair."""

import requests

from bridge.immich import ImmichError
from bridge.stacks import RawStacker, stack_order

DIR = "/usr/src/app/upload/library/u1/2026/05/01"


def asset(i, name, folder=DIR, stack=None, created="2026-05-01T10:00:00Z"):
    return {"id": f"a{i}", "originalFileName": name, "originalPath": f"{folder}/x-{name}", "stack": stack, "createdAt": created}


class Lib:
    """Answers /search/metadata like Immich (paged; createdAfter; originalFileName as a part-of-name match)."""

    def __init__(self, assets, refuse=(), fail=None):
        self.assets, self.refuse, self.fail, self.stacks, self.bodies = list(assets), set(refuse), fail, [], []

    def search_metadata(self, body):
        self.bodies.append(body)
        items = [a for a in self.assets if a["createdAt"] > body.get("createdAfter", "")
                 and body.get("originalFileName", "").lower() in a["originalFileName"].lower()]
        size, page = body["size"], body["page"]
        chunk = items[(page - 1) * size: page * size]
        return {"assets": {"items": chunk, "nextPage": str(page + 1) if page * size < len(items) else None}}

    def create_stack(self, ids):
        if self.fail:
            raise self.fail
        if ids[-1] in self.refuse:
            raise ImmichError("Immich answered HTTP 400: Not found or no asset.update access")
        self.stacks.append(ids)
        for a in self.assets:
            if a["id"] in ids:
                a["stack"] = {"id": f"s{len(self.stacks)}"}
        return {"id": f"s{len(self.stacks)}"}


def stacker(tmp_path, lib, busy=lambda: False, now=[1795600000.0]):
    return RawStacker(str(tmp_path / "stacks.db"), lib, busy=busy, clock=lambda: now[0])


def test_the_jpg_comes_first_and_only_one_raw_with_its_own_jpg_makes_a_stack():
    raw, jpg, heic = asset(1, "IMG_1.DNG"), asset(2, "img_1.jpg"), asset(3, "IMG_1.HEIC")
    assert stack_order([raw, heic, jpg]) == ["a2", "a3", "a1"]  # JPG, then HEIC, then the RAW
    assert stack_order([raw]) is None and stack_order([jpg]) is None
    assert stack_order([raw, asset(4, "IMG_1.NEF"), jpg]) is None  # two RAWs: not a camera pair
    assert stack_order([raw, asset(5, "IMG_1.jpg", stack={"id": "s"})]) is None  # already stacked (a burst): left alone


def test_the_first_sweep_stacks_every_pair_in_the_library_and_leaves_the_rest(tmp_path):
    lib = Lib([asset(1, "IMG_1.dng"), asset(2, "IMG_1.jpg"),
               asset(3, "IMG_2.dng"),  # no JPG
               asset(4, "IMG_3.dng", folder="/other"), asset(5, "IMG_3.jpg"),  # different folders
               asset(6, "P1.CR3"), asset(7, "p1.JPG"), asset(8, "clip.mp4")]
              + [asset(100 + i, f"F{i}.jpg") for i in range(1500)])  # more than one page
    s = stacker(tmp_path, lib)
    got = s.run_once()
    assert lib.stacks == [["a2", "a1"], ["a7", "a6"]] and got["stacked"] == 2
    assert "createdAfter" not in lib.bodies[0] and lib.bodies[0]["withStacked"] is True and len(lib.bodies) == 2
    assert s.describe()["stacked"] == 2 and s.run_once()["stacked"] == 0  # once per pair


def test_a_later_sweep_finds_the_partner_of_a_new_upload_even_when_it_came_long_before(tmp_path):
    lib = Lib([asset(1, "IMG_9.dng", created="2026-01-01T00:00:00Z")])
    now = [1795600000.0]
    s = stacker(tmp_path, lib, now=now)
    assert s.run_once()["stacked"] == 0
    lib.assets.append(asset(2, "IMG_9.jpg", created="2026-11-26T12:00:00Z"))
    now[0] += 3600
    assert s.run_once()["stacked"] == 1 and lib.stacks == [["a2", "a1"]]
    assert any(b.get("originalFileName") == "img_9" for b in lib.bodies)  # looked the old RAW up by name


def test_a_refusal_is_logged_once_and_a_busy_or_unreachable_immich_is_tried_again(tmp_path):
    lib = Lib([asset(1, "A.dng"), asset(2, "A.jpg"), asset(3, "B.dng"), asset(4, "B.jpg")], refuse={"a1"})
    busy = [True]
    s = stacker(tmp_path, lib, busy=lambda: busy[0])
    assert s.run_once()["held"] and lib.stacks == [] and s.describe()["last_sweep"] is None
    busy[0] = False
    lib.fail = requests.ConnectionError("down")
    assert s.run_once()["stacked"] == 0 and s.describe()["last_sweep"] is None
    lib.fail = ImmichError("the API key lacks the permission needed to stack photos")
    assert s.run_once()["refused"] == 0  # the key, not the pair: nothing recorded
    lib.fail = None
    got = s.run_once()
    assert (got["stacked"], got["refused"]) == (1, 1) and lib.stacks == [["a4", "a3"]]
    assert s.run_once()["refused"] == 0  # the refused pair is not asked again


def test_a_dry_run_lists_the_pairs_without_stacking(tmp_path):
    lib = Lib([asset(1, "A.dng"), asset(2, "A.jpg")])
    s = stacker(tmp_path, lib)
    got = s.run_once(dry=True)
    assert got["planned"] == [{"name": "A.dng", "ids": ["a2", "a1"]}] and lib.stacks == []
    assert s.run_once(limit=1)["stacked"] == 1
