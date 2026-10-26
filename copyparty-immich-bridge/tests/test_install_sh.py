"""Runs install.sh end to end against fake docker/git/curl/ip commands (no Docker needed).

The fake `docker inspect` lists mounts the way real Docker does: alphabetically by destination, and
INCLUDING the hook script this installer mounts into copyparty on a re-run - the case that once made the
installer mistake /hooks/immich_bridge_hook.py for copyparty's data folder.
"""

import os
import shutil
import stat
import subprocess
import textwrap

import pytest

INSTALL = os.environ.get("INSTALL_SH") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "install.sh")

FAKE_DOCKER = """#!/usr/bin/env bash
case "$*" in
  "compose version") echo "Docker Compose v2"; exit 0;;
  "inspect copyparty") exit 0;;
  inspect\\ -f*Mounts*)
    printf 'bind|%s/copyparty/cfg|/cfg\\nbind|%s/hook/immich_bridge_hook.py|/hooks/immich_bridge_hook.py\\nbind|%s/data|/w\\n' "$FAKE_HOME" "$FAKE_HOME" "$FAKE_HOME"
    exit 0;;
  inspect\\ -f*State.Status*) echo running; exit 0;;
  compose*) echo "docker $*" >> "$FAKE_LOG"; exit 0;;
esac
exit 0
"""
FAKE_GIT = """#!/usr/bin/env bash
echo "git $*" >> "$FAKE_LOG"
if [ "$1" = clone ]; then dir="${@: -1}"; mkdir -p "$dir/.git" "$dir/copyparty-immich-bridge/hook"; touch "$dir/copyparty-immich-bridge/Dockerfile"; fi
exit 0
"""
FAKE_CURL = '#!/usr/bin/env bash\necho "curl $*" >> "$FAKE_LOG"; exit 0\n'
FAKE_IP = '#!/usr/bin/env bash\necho "1.1.1.1 via 1 dev eth0 src 192.168.1.50"\n'


@pytest.fixture
def box(tmp_path):
    home = tmp_path / "home"
    bin_dir = tmp_path / "bin"
    (home / "copyparty" / "cfg").mkdir(parents=True)
    (home / "copyparty" / "docker-compose.yml").write_text("services: {copyparty: {image: x}}\n")
    (home / "hook").mkdir()
    (home / "hook" / "immich_bridge_hook.py").write_text("# hook\n")
    for rel in ("Trips/Summer2026/Day3", "Trips/Old", "Work", ".hist"):
        (home / "data" / rel).mkdir(parents=True)
    bin_dir.mkdir()
    for name, body in (("docker", FAKE_DOCKER), ("git", FAKE_GIT), ("curl", FAKE_CURL), ("ip", FAKE_IP)):
        path = bin_dir / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def run(*args, env=None, stdin=subprocess.DEVNULL, **kw):
        full = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            HOME=str(home),
            FAKE_HOME=str(home),
            FAKE_LOG=str(tmp_path / "calls.log"),
            IMMICH_API_KEY="abcdef12345",
            HOOK="0",  # skips the installer's 10 s "did copyparty survive the hook" wait
        )
        full.update(env or {})
        return subprocess.run(["bash", INSTALL, *args], env=full, stdin=stdin, capture_output=True, text=True, timeout=60, **kw)

    box = type("Box", (), {})()
    box.home, box.run, box.tmp = home, run, tmp_path
    box.override = home / "copyparty" / "docker-compose.override.yml"
    return box


def test_rerun_with_the_hook_mounted_still_finds_the_data_folder(box):
    r = box.run(env={"APP_FOLDER": "Trips/Summer2026"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "-> /w " in r.stdout and "/hooks" not in r.stdout.split("Fetching")[0]
    text = box.override.read_text()
    assert "WATCH_DIRS: /w/Trips/Summer2026" in text and "BROWSE_ROOTS: /w\n" in text
    assert "/w:ro" in text


def test_rerun_keeps_the_folder_from_an_old_override_that_has_no_browse_roots(box):
    # what the first (pre-config-upgrade) installer wrote: no BROWSE_ROOTS line
    box.override.write_text(
        textwrap.dedent(
            """\
            # managed by the immich-bridge installer (delete this file to undo; re-run the installer to update)
            services:
              immich-bridge:
                environment:
                  WATCH_DIRS: /w/Trips/Summer2026
                  PRIORITY_DIRS: /w/Trips/Summer2026
            """
        )
    )
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Keeping the folder from your last install: Trips/Summer2026" in r.stdout
    assert "Which folder" not in r.stdout
    assert "PRIORITY_DIRS: /w/Trips/Summer2026" in box.override.read_text()


def test_fresh_install_without_a_terminal_asks_for_the_flag_instead_of_guessing(box):
    r = box.run()
    assert r.returncode != 0
    assert "APP_FOLDER" in r.stderr
    assert not box.override.exists()


def test_app_folder_dot_watches_everything_and_sets_no_priority(box):
    r = box.run(env={"APP_FOLDER": "."})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert "WATCH_DIRS: /w\n" in text
    assert "      PRIORITY_DIRS:" not in text and "# PRIORITY_DIRS" in text


def test_wide_watches_the_parent_but_keeps_the_priority_folder(box):
    r = box.run(env={"APP_FOLDER": "Trips/Summer2026", "WIDE": "1"})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert "WATCH_DIRS: /w/Trips\n" in text and "PRIORITY_DIRS: /w/Trips/Summer2026" in text


def test_token_is_kept_on_rerun_and_secret_files_are_private(box):
    box.run(env={"APP_FOLDER": "Work"})
    env_file = box.home / "copyparty" / "immich-bridge.env"
    first = env_file.read_text()
    token = [ln for ln in first.splitlines() if ln.startswith("BRIDGE_TOKEN=")][0]
    assert len(token) > len("BRIDGE_TOKEN=") + 15
    box.run()  # re-run, no flags
    assert token in env_file.read_text()
    for name in ("immich-bridge.env", "immich-bridge-hook.env"):
        mode = stat.S_IMODE(os.stat(box.home / "copyparty" / name).st_mode)
        assert mode == 0o600, name
    assert "IMMICH_API_KEY" not in (box.home / "copyparty" / "immich-bridge-hook.env").read_text()


def test_uninstall_removes_everything_it_created(box):
    box.run(env={"APP_FOLDER": "Work"})
    assert box.override.exists()
    r = box.run("--uninstall")
    assert r.returncode == 0, r.stdout + r.stderr
    assert not box.override.exists()
    assert not (box.home / "copyparty" / "immich-bridge.env").exists()
    assert (box.home / "copyparty" / "docker-compose.yml").exists()  # the user's own file is never touched


@pytest.mark.skipif(shutil.which("script") is None, reason="needs script(1) to provide a terminal")
def test_first_install_offers_a_numbered_list_newest_first_and_accepts_a_number(box):
    # make Trips/Summer2026 the most recently touched folder so it is listed first
    past = 1_600_000_000
    for rel in ("Trips/Old", "Work", "Trips"):
        os.utime(box.home / "data" / rel, (past, past))
    r = subprocess.run(
        ["script", "-qfc", f"bash {INSTALL}", "/dev/null"],
        input="1\n",
        env=dict(
            os.environ,
            PATH=f"{box.tmp / 'bin'}:{os.environ['PATH']}",
            HOME=str(box.home),
            FAKE_HOME=str(box.home),
            FAKE_LOG=str(box.tmp / "calls.log"),
            IMMICH_API_KEY="abcdef12345",
            HOOK="0",
        ),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert " 1) Trips/Summer2026" in r.stdout, r.stdout
    assert ".hist" not in r.stdout
    assert "Type the number" in r.stdout
    assert "WATCH_DIRS: /w/Trips/Summer2026" in box.override.read_text()
