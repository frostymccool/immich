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
  "inspect ghost") exit 1;;
  "inspect copyparty2"|"inspect copyparty3"|"inspect copyparty4") exit 0;;
  inspect\\ -f*Mounts*copyparty2) printf 'bind|%s/cp2cfg|/cfg\\nbind|%s/data2|/w\\n' "$FAKE_HOME" "$FAKE_HOME"; exit 0;;
  inspect\\ -f*Mounts*copyparty3) printf 'bind|%s/data|/w\\n' "$FAKE_HOME"; exit 0;;
  inspect\\ -f*Mounts*copyparty4) printf 'bind|%s/data/Work|/w\\n' "$FAKE_HOME"; exit 0;;
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
if [ "$1" = clone ]; then dir="${@: -1}"; mkdir -p "$dir/.git" "$dir/copyparty-immich-bridge/hook"; touch "$dir/copyparty-immich-bridge/Dockerfile"; printf "#!/usr/bin/env bash\\n# update-bridge.sh\\n" > "$dir/copyparty-immich-bridge/update-bridge.sh"; fi
case " $* " in *" log "*) [ -z "${FAKE_NO_GIT_LOG:-}" ] && echo "e4d5866 2026-11-01";; esac
exit 0
"""
FAKE_CURL = '#!/usr/bin/env bash\necho "curl $*" >> "$FAKE_LOG"\ncase "$*" in *api-keys/me*) printf \'%s\' "${FAKE_KEY_JSON:-}";; esac\nexit 0\n'
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
    (home / "data2" / "Alex").mkdir(parents=True)
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


def test_a_key_without_album_permissions_gets_a_note_but_the_install_still_works(box):
    r = box.run(env={"APP_FOLDER": "Work", "FAKE_KEY_JSON": '{"permissions":["asset.upload","asset.read","album.read"]}'})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "lacks album permissions" in r.stdout and "album.create" in r.stdout and "albumAsset.create" in r.stdout
    assert "album.read" not in r.stdout.split("missing:")[1].split(")")[0]
    assert box.override.exists()


def test_a_key_with_all_or_the_album_permissions_gets_no_note(box):
    for perms in ('{"permissions":["all"]}', '{"permissions":["album.read","album.create","albumAsset.create","asset.upload"]}', ""):
        r = box.run(env={"APP_FOLDER": "Work", "FAKE_KEY_JSON": perms})
        assert r.returncode == 0, r.stdout + r.stderr
        assert "lacks album permissions" not in r.stdout, perms


def test_override_records_which_commit_was_installed(box):
    r = box.run(env={"APP_FOLDER": "Trips/Summer2026"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert 'BRIDGE_BUILD: "e4d5866 2026-11-01"' in box.override.read_text()


def test_unknown_commit_is_recorded_as_unknown_not_empty(box):
    r = box.run(env={"APP_FOLDER": "Trips/Summer2026", "FAKE_NO_GIT_LOG": "1"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert 'BRIDGE_BUILD: "unknown"' in box.override.read_text()


def test_installer_saves_the_updater_in_the_copyparty_folder_and_uninstall_removes_it(box):
    r = box.run(env={"APP_FOLDER": "Trips/Summer2026"})
    assert r.returncode == 0, r.stdout + r.stderr
    updater = box.home / "copyparty" / "update-bridge.sh"
    assert updater.exists() and os.access(updater, os.X_OK)
    assert "update-bridge.sh" in r.stdout.split("Settings page:")[-1]
    r = box.run("--uninstall")
    assert r.returncode == 0, r.stdout + r.stderr
    assert not updater.exists()


# ---- several copyparty containers --------------------------------------------------------------


def test_extra_copyparty_is_mounted_mapped_and_remembered(box):
    r = box.run(env={"APP_FOLDER": "Trips/Summer2026", "EXTRA_COPYPARTY": "copyparty2"})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert f"{box.home}/data2:/cp/copyparty2:ro" in text
    assert "BROWSE_ROOTS: /w,/cp/copyparty2\n" in text
    assert 'SOURCE_MAPS: "copyparty2|/w=/cp/copyparty2"' in text
    assert "# EXTRA_COPYPARTY: copyparty2" in text
    assert "WATCH_DIRS: /w/Trips/Summer2026" in text  # main's own setup is untouched
    # the hook for the other copyparty is printed, never written into another compose project
    token = [ln for ln in (box.home / "copyparty" / "immich-bridge.env").read_text().splitlines() if ln.startswith("BRIDGE_TOKEN=")][0].split("=", 1)[1]
    assert "IMMICH_BRIDGE_SOURCE: copyparty2" in r.stdout and f"IMMICH_BRIDGE_TOKEN: {token}" in r.stdout
    assert "http://192.168.1.50:8099" in r.stdout
    first = text
    r2 = box.run()  # a re-run with no variables keeps everything, byte for byte
    assert r2.returncode == 0, r2.stdout + r2.stderr
    assert box.override.read_text() == first


def test_extra_copyparty_none_forgets_them(box):
    box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": "copyparty2"})
    r = box.run(env={"EXTRA_COPYPARTY": "none"})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert "/cp/" not in text and "SOURCE_MAPS: not set" in text and "BROWSE_ROOTS: /w\n" in text


def test_without_extras_the_override_has_no_new_lines_that_matter(box):
    r = box.run(env={"APP_FOLDER": "Work"})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert "BROWSE_ROOTS: /w\n" in text and "/cp/" not in text and "# EXTRA_COPYPARTY" not in text


@pytest.mark.parametrize("name,why", [("ghost", "was not found"), ("copyparty", "main copyparty"), ("bad name!", "usable container name")])
def test_extra_copyparty_refuses_unknown_or_silly_names(box, name, why):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": name})
    assert r.returncode != 0 and why in r.stderr
    assert not box.override.exists()


@pytest.mark.parametrize("name", ["copyparty3", "copyparty4"])
def test_extra_copyparty_refuses_a_data_folder_shared_with_another(box, name):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": name})
    assert r.returncode != 0 and "two owners" in r.stderr
    assert not box.override.exists()


def test_extra_copyparty_can_be_mounted_writable(box):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": "copyparty2", "WRITABLE": "1"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert f"{box.home}/data2:/cp/copyparty2:rw" in box.override.read_text()


def test_a_vanished_remembered_extra_does_not_block_updates(box):
    box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": "copyparty2"})
    box.override.write_text(box.override.read_text().replace("copyparty2", "ghost"))  # the container was removed
    r = box.run()  # what update-bridge.sh does: no variables
    assert r.returncode == 0, r.stdout + r.stderr
    assert "no longer exists" in r.stdout
    assert "/cp/" not in box.override.read_text() and "# EXTRA_COPYPARTY" not in box.override.read_text()


def test_extra_named_on_the_command_line_that_does_not_exist_is_still_an_error(box):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": "ghost"})
    assert r.returncode != 0 and "EXTRA_COPYPARTY=none" in r.stderr


def test_extra_listed_twice_is_mounted_once(box):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": "copyparty2,copyparty2"})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert text.count("/cp/copyparty2:ro") == 1 and "# EXTRA_COPYPARTY: copyparty2\n" in text


def test_extra_value_with_a_newline_cannot_inject_yaml(box):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": "copyparty2\n    privileged: true"})
    assert r.returncode != 0 and "control characters" in r.stderr
    assert not box.override.exists()


def test_extra_with_a_host_folder_picks_that_mount(box):
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": f"copyparty2={box.home}/data2"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert f"{box.home}/data2:/cp/copyparty2:ro" in box.override.read_text()
    r = box.run(env={"APP_FOLDER": "Work", "EXTRA_COPYPARTY": f"copyparty2={box.home}/nope"})
    assert r.returncode != 0 and "could not find a data mount" in r.stderr


def test_uninstall_says_where_the_keys_live(box):
    box.run(env={"APP_FOLDER": "Work"})
    r = box.run("--uninstall")
    assert r.returncode == 0 and "API key" in r.stdout and "docker volume rm" in r.stdout


# ---- folder-per-person -------------------------------------------------------------------------------


def test_people_root_is_written_asks_no_folder_question_and_is_remembered(box):
    r = box.run(env={"PEOPLE_ROOT": "."})
    assert r.returncode == 0, r.stdout + r.stderr
    text = box.override.read_text()
    assert "      PEOPLE_ROOT: /w\n" in text and "Which folder" not in r.stdout
    assert "WATCH_DIRS: /w\n" in text
    assert "People tab" in r.stdout
    again = box.run()  # update-bridge.sh: no variables
    assert again.returncode == 0, again.stdout + again.stderr
    assert box.override.read_text() == text


def test_people_root_in_a_subfolder_round_trips(box):
    r = box.run(env={"PEOPLE_ROOT": "Trips"})
    assert r.returncode == 0, r.stdout + r.stderr
    first = box.override.read_text()
    assert "PEOPLE_ROOT: /w/Trips\n" in first
    assert box.run().returncode == 0 and box.override.read_text() == first


def test_people_root_none_switches_it_off_and_default_has_none(box):
    box.run(env={"PEOPLE_ROOT": "Trips"})
    r = box.run(env={"PEOPLE_ROOT": "none", "APP_FOLDER": "Work"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PEOPLE_ROOT: not set" in box.override.read_text() and "      PEOPLE_ROOT: /w" not in box.override.read_text()
    plain = box.run(env={"APP_FOLDER": "Work"})
    assert plain.returncode == 0 and "PEOPLE_ROOT: not set" in box.override.read_text()


def test_people_root_with_yaml_specials_is_refused(box):
    r = box.run(env={"PEOPLE_ROOT": "x: [y]\n  evil: 1"})
    assert r.returncode != 0 and "unusual characters" in r.stderr
    assert not box.override.exists()
