"""Runs move-root.sh end to end against fake docker/curl commands (no Docker needed).

The scenario mirrors the real move that was painful by hand: copyparty's web root was /w/<Parent> and the bridge
watched /w/<Parent>/<App>; the folders were then moved so both sit side by side under a new data folder.
"""

import os
import shutil
import sqlite3
import stat
import subprocess

import pytest

SCRIPT = os.environ.get("MOVE_ROOT_SH") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "move-root.sh")

FAKE_DOCKER = r"""#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  "compose version") echo "Docker Compose v2"; exit 0;;
  "inspect copyparty"|"inspect immich-bridge") exit 0;;
  inspect\ -f*Mounts*) printf 'bind|%s/copyparty/cfgdir|/cfg\nbind|%s/hook.py|/hooks/immich_bridge_hook.py\nbind|%s|/w\n' "$FAKE_HOME" "$FAKE_HOME" "$FAKE_OLD_DATA"; exit 0;;
  inspect\ -f*StartedAt*) echo 2026-01-01T00:00:00Z; exit 0;;
  inspect\ -f*Config.Image*) echo copyparty-immich-bridge; exit 0;;
  stop*) exit 0;;
  run*-c\ *)
    args=("$@"); i=0; for a in "${args[@]}"; do i=$((i+1)); [ "$a" = "-c" ] && break; done
    python3 -c "$(printf '%s' "${args[$i]}" | sed "s#/data/#$FAKE_STATE_DIR/#g")"; exit $?;;
  run*)
    args=("$@"); i=0; for a in "${args[@]}"; do i=$((i+1)); [ "$a" = "-" ] && break; done
    sed "s#/data/#$FAKE_STATE_DIR/#g" | python3 - "${args[@]:$i}"
    exit $?;;
  exec*) printf 'Asia2026\nAustralia\n'; exit 0;;
  logs*) printf '%s\n' "${FAKE_COPYPARTY_LOG:-01:20:47 up2k  uploads temporarily blocked due to indexing}"; exit 0;;
  compose*) exit 0;;
esac
exit 0
"""
FAKE_CURL = '#!/usr/bin/env bash\necho "curl $*" >> "$FAKE_LOG"\nexit 0\n'

COMPOSE = """services:
  copyparty:
    image: copyparty/ac:latest
    volumes:
      - OLD_DATA:/w:rw     # your actual media storage
      - HOME/copyparty/cfgdir:/cfg     # config
    restart: unless-stopped
"""
CONF = """[global]
  e2dsa
  e2v

[accounts]
  pics: secret-password

[/]            # create a volume at "/"
  /w/Australia           # share just the Australia sub folder
  accs:
    rw: *
"""


@pytest.fixture
def box(tmp_path):
    home = tmp_path / "home"
    bin_dir = tmp_path / "bin"
    old = tmp_path / "mnt" / "old"
    new = tmp_path / "mnt" / "CopyPUploads"
    state = tmp_path / "state"
    for d in (home / "copyparty" / "cfgdir", bin_dir, old / "Australia" / "Asia2026", new / "Asia2026", new / "Australia", state):
        d.mkdir(parents=True)
    (home / "copyparty" / "docker-compose.yml").write_text(COMPOSE.replace("OLD_DATA", str(old)).replace("HOME", str(home)))
    (home / "copyparty" / "cfgdir" / "copyparty.conf").write_text(CONF)
    (home / "copyparty" / "docker-compose.override.yml").write_text(
        "# managed by the immich-bridge installer\nservices:\n  immich-bridge:\n    environment:\n"
        "      WATCH_DIRS: /w/Australia/Asia2026\n      BROWSE_ROOTS: /w\n"
    )
    (home / "copyparty" / "immich-bridge.env").write_text("IMMICH_API_KEY=k\nBRIDGE_TOKEN=tok0123456789abcdef\n")
    # a fake installer in the source clone, so the script's hand-off to it can be seen
    inst = home / "immich-bridge-src" / "copyparty-immich-bridge"
    inst.mkdir(parents=True)
    (inst / "install.sh").write_text('echo "installer APP_FOLDER=$APP_FOLDER" >> "$FAKE_LOG"\n')
    db = sqlite3.connect(state / "state.db")
    db.execute("CREATE TABLE files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL, sha1 TEXT, status TEXT, asset_id TEXT, error TEXT, attempts INTEGER, updated_at REAL)")
    for rel in ("360 Oct 19/a.insv", "Go Kyoto/b.mp4"):
        db.execute("INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?)", (f"/w/Australia/Asia2026/{rel}", 1, 2.0, "s", "imported", "id", None, 0, 3.0))
    db.execute("INSERT INTO files VALUES ('/w/Other/c.mp4',1,2.0,'s','imported','id',NULL,0,3.0)")
    db.commit(); db.close()
    for name, body in (("docker", FAKE_DOCKER), ("curl", FAKE_CURL)):
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod((bin_dir / name).stat().st_mode | stat.S_IEXEC)

    def run(*args, env=None):
        full = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", HOME=str(home), FAKE_HOME=str(home),
                    FAKE_LOG=str(tmp_path / "calls.log"), FAKE_OLD_DATA=str(old), FAKE_STATE_DIR=str(state))
        full.update(env or {})
        return subprocess.run(["bash", SCRIPT, *args], env=full, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)

    b = type("Box", (), {})()
    b.run, b.home, b.old, b.new, b.state, b.tmp = run, home, old, new, state, tmp_path
    b.compose = home / "copyparty" / "docker-compose.yml"
    b.conf = home / "copyparty" / "cfgdir" / "copyparty.conf"
    b.calls = lambda: (tmp_path / "calls.log").read_text() if (tmp_path / "calls.log").exists() else ""
    return b


def args(box, *extra):
    return ["--data", str(box.new), "--app-folder", "Asia2026", *extra]


def test_dry_run_shows_the_plan_and_changes_nothing(box):
    before = (box.compose.read_text(), box.conf.read_text())
    r = box.run(*args(box))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "dry run" in r.stdout and "/Asia2026/" in r.stdout
    assert "/w/Australia  ->  /w" in r.stdout and "/w/Australia/Asia2026  ->  /w/Asia2026" in r.stdout
    assert (box.compose.read_text(), box.conf.read_text()) == before
    assert "compose" not in box.calls().replace("compose version", "")
    assert not (box.home / "copyparty" / "backups").exists()


def test_apply_repoints_everything_and_backs_up(box):
    r = box.run(*args(box), "--apply")
    assert r.returncode == 0, r.stdout + r.stderr
    assert f"- {box.new}:/w:rw     # your actual media storage" in box.compose.read_text()
    conf = box.conf.read_text()
    assert "\n  /w   # share this folder as the web root\n" in conf and "/w/Australia" not in conf
    assert "pics: secret-password" in conf and "rw: *" in conf  # the rest of the config is untouched
    backups = list((box.home / "copyparty" / "backups").glob("move-root-*"))
    assert len(backups) == 1
    assert str(box.old) in (backups[0] / "compose.bak").read_text() and "/w/Australia" in (backups[0] / "conf.bak").read_text()
    calls = box.calls()
    assert "force-recreate copyparty" in calls and "installer APP_FOLDER=Asia2026" in calls
    assert "PUT" in calls and '"watch_dirs":["/w/Asia2026"]' in calls
    assert "Phone app: set the copyparty upload path to  /Asia2026/" in r.stdout


def test_bridge_import_records_follow_the_move(box):
    r = box.run(*args(box), "--apply")
    assert r.returncode == 0, r.stdout + r.stderr
    rows = {p for (p,) in sqlite3.connect(box.state / "state.db").execute("SELECT path FROM files")}
    assert rows == {"/w/Asia2026/360 Oct 19/a.insv", "/w/Asia2026/Go Kyoto/b.mp4", "/w/Other/c.mp4"}
    assert (box.state / "state.db.pre-move").exists()  # the copy for rollback
    assert "2 file record(s) re-pointed" in r.stdout


def test_no_keep_history_leaves_the_records_alone(box):
    r = box.run(*args(box, "--no-keep-history"), "--apply")
    assert r.returncode == 0, r.stdout + r.stderr
    rows = {p for (p,) in sqlite3.connect(box.state / "state.db").execute("SELECT path FROM files")}
    assert "/w/Australia/Asia2026/Go Kyoto/b.mp4" in rows


def test_missing_app_folder_is_refused_before_anything_changes(box):
    r = box.run("--data", str(box.new), "--app-folder", "Nope", "--apply")
    assert r.returncode != 0 and "does not exist" in r.stderr
    assert "/w/Australia" in box.conf.read_text()
    assert not (box.home / "copyparty" / "backups").exists()


def test_ambiguous_compose_aborts_without_editing(box):
    box.compose.write_text(box.compose.read_text() + f"      - {box.old}:/w:ro\n")
    conf_before, compose_before = box.conf.read_text(), box.compose.read_text()
    r = box.run(*args(box), "--apply")
    assert r.returncode != 0 and "exactly one" in r.stderr
    assert box.conf.read_text() == conf_before and box.compose.read_text() == compose_before


def test_network_share_gets_the_database_moved_off_it(box, tmp_path):
    fake = tmp_path / "bin" / "findmnt"
    fake.write_text("#!/usr/bin/env bash\necho cifs\n"); fake.chmod(0o755)
    r = box.run(*args(box), "--apply")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "hist: /cfg/hists" in box.conf.read_text()
    assert (box.home / "copyparty" / "cfgdir" / "hists").is_dir()


def test_database_error_in_the_copyparty_log_is_reported(box):
    r = box.run(*args(box), "--apply", env={"FAKE_COPYPARTY_LOG": "ERROR: cannot use database at [/w/.hist/up2k.db]"})
    assert r.returncode != 0 and "PROBLEM: copyparty cannot use its index database" in r.stdout


def test_rollback_restores_the_files(box):
    original = (box.compose.read_text(), box.conf.read_text())
    assert box.run(*args(box), "--apply").returncode == 0
    assert box.compose.read_text() != original[0]
    backup = next((box.home / "copyparty" / "backups").glob("move-root-*"))
    r = box.run("--rollback", str(backup), "--apply")
    assert r.returncode == 0, r.stdout + r.stderr
    assert (box.compose.read_text(), box.conf.read_text()) == original
    rows = {p for (p,) in sqlite3.connect(box.state / "state.db").execute("SELECT path FROM files")}
    assert "/w/Australia/Asia2026/Go Kyoto/b.mp4" in rows


def test_web_root_subfolder_changes_the_phone_upload_path(box):
    (box.new / "Australia" / "Trips").mkdir()
    r = box.run("--data", str(box.new), "--app-folder", "Australia/Trips", "--root-sub", "Australia")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "/w/Australia  " in r.stdout and "/Trips/" in r.stdout


def test_app_folder_outside_the_web_root_is_refused(box):
    r = box.run("--data", str(box.new), "--app-folder", "Asia2026", "--root-sub", "Australia")
    assert r.returncode != 0 and "outside copyparty's web root" in r.stderr
