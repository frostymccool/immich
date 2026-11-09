"""Runs update-bridge.sh against fake docker/git/curl (no Docker or network needed)."""

import os
import shutil
import stat
import subprocess

import pytest

SCRIPT = os.environ.get("UPDATE_BRIDGE_SH") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "update-bridge.sh")

FAKE_DOCKER = r"""#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  inspect*Config.Env*) [ -n "${FAKE_BUILD_ID:-}" ] && printf 'PATH=/x\nBRIDGE_BUILD=%s\n' "$FAKE_BUILD_ID"; exit 0;;
esac
exit 0
"""
FAKE_GIT = r"""#!/usr/bin/env bash
echo "git $*" >> "$FAKE_LOG"
case "$*" in ls-remote*) [ -n "${FAKE_LATEST:-}" ] && printf '%s\trefs/heads/x\n' "$FAKE_LATEST000";; esac
exit 0
"""
FAKE_CURL = r"""#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
case "$*" in
  *update-bridge.sh*)
    [ -n "${FAKE_OFFLINE:-}" ] && exit 22
    out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && [ -n "${FAKE_REMOTE:-}" ] && cp "$FAKE_REMOTE" "$out"
    exit 0;;
  *install.sh*) printf 'echo "the-installer-ran" >> "$FAKE_LOG"\n'; exit 0;;
esac
exit 0
"""


@pytest.fixture
def box(tmp_path):
    bin_dir = tmp_path / "bin"
    home = tmp_path / "home"
    (home / "copyparty").mkdir(parents=True)
    (home / "copyparty" / "docker-compose.yml").write_text("services: {}\n")
    bin_dir.mkdir()
    for name, body in (("docker", FAKE_DOCKER), ("git", FAKE_GIT.replace("$FAKE_LATEST000", "${FAKE_LATEST}0000000000000000000000000000000000")), ("curl", FAKE_CURL)):
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod((bin_dir / name).stat().st_mode | stat.S_IEXEC)
    saved = home / "copyparty" / "update-bridge.sh"
    shutil.copy(SCRIPT, saved)

    def run(*args, env=None, script=None):
        full = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", HOME=str(home), FAKE_LOG=str(tmp_path / "calls.log"))
        full.update(env or {})
        return subprocess.run(["bash", script or str(saved), *args], env=full, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)

    b = type("Box", (), {})()
    b.run, b.saved, b.tmp = run, saved, tmp_path
    b.calls = lambda: (tmp_path / "calls.log").read_text() if (tmp_path / "calls.log").exists() else ""
    return b


def test_update_runs_the_latest_installer_and_reports_before_and_after(box):
    r = box.run(env={"FAKE_BUILD_ID": "aaa1111 2026-10-01", "FAKE_LATEST": "bbb2222"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Installed now:   aaa1111 2026-10-01" in r.stdout and "Latest on GitHub: bbb2222" in r.stdout
    assert "the-installer-ran" in box.calls()


def test_check_only_looks_and_never_installs(box):
    r = box.run("--check", env={"FAKE_BUILD_ID": "aaa1111 2026-10-01", "FAKE_LATEST": "bbb2222"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "A newer version is available" in r.stdout
    assert "the-installer-ran" not in box.calls()


def test_check_says_when_already_current(box):
    r = box.run("--check", env={"FAKE_BUILD_ID": "bbb2222 2026-11-01", "FAKE_LATEST": "bbb2222"})
    assert r.returncode == 0 and "Already on the latest version" in r.stdout
    assert "the-installer-ran" not in box.calls()


def test_saved_copy_replaces_itself_with_the_latest_first(box):
    box.saved.write_text(box.saved.read_text() + "\n# OLD-COPY-MARKER\n")
    r = box.run(env={"FAKE_REMOTE": SCRIPT, "FAKE_LATEST": "bbb2222"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Updating update-bridge.sh to the latest version" in r.stdout
    assert "OLD-COPY-MARKER" not in box.saved.read_text()
    assert "the-installer-ran" in box.calls()


def test_offline_or_bad_download_keeps_the_saved_copy_and_still_updates(box, tmp_path):
    box.saved.write_text(box.saved.read_text() + "\n# OLD-COPY-MARKER\n")
    r = box.run(env={"FAKE_OFFLINE": "1"})
    assert r.returncode == 0 and "could not check for a newer update-bridge.sh" in r.stdout
    assert "OLD-COPY-MARKER" in box.saved.read_text() and "the-installer-ran" in box.calls()
    bad = tmp_path / "bad.html"
    bad.write_text("<html>404</html>")
    r = box.run(env={"FAKE_REMOTE": str(bad)})
    assert r.returncode == 0 and "looks wrong" in r.stdout
    assert "OLD-COPY-MARKER" in box.saved.read_text()


def test_unknown_option_is_refused(box):
    r = box.run("--bogus")
    assert r.returncode == 2 and "unknown option" in r.stderr
