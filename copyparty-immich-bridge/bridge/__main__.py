"""Entry point: wires config, state, Immich client, worker, sweep, HTTP server."""

from __future__ import annotations

import logging
import os
import signal
import sys
import threading
import time

from bridge import __version__
from bridge.config import Config, ConfigError
from bridge.immich import DEFAULT_EXTENSIONS, ImmichClient, ImmichError
from bridge.logbuffer import RingLogHandler
from bridge.manager import UserManager
from bridge.router import Router
from bridge.server import serve
from bridge.settings import SettingsStore
from bridge.state import StateStore
from bridge.users import UsersError, UsersStore

log = logging.getLogger("bridge")


def resolve_extensions(cfg: Config, client: ImmichClient) -> set[str]:
    """Explicit config wins; otherwise ask Immich, with retries, then fall
    back to a builtin list so a temporarily-down Immich doesn't stop startup
    (failed imports are retried by the sweep anyway)."""
    if cfg.include_extensions:
        log.info("using configured extensions: %s", sorted(cfg.include_extensions))
        return cfg.include_extensions
    for attempt in range(3):
        try:
            exts = client.supported_extensions()
            log.info("Immich reports %d supported media extensions", len(exts))
            return exts
        except ImmichError as ex:
            log.warning("media-types fetch failed (attempt %d/3): %s", attempt + 1, ex)
            time.sleep(2 * (attempt + 1))
    log.warning("falling back to builtin extension list (%d entries)", len(DEFAULT_EXTENSIONS))
    return set(DEFAULT_EXTENSIONS)


def main() -> int:
    try:
        cfg = Config.from_env()
    except ConfigError as ex:
        print(f"config error: {ex}", file=sys.stderr)
        return 2

    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    # Recent log lines are also kept in memory for the web page's log viewer. The
    # handler takes everything; the root logger's level still decides what exists.
    logs = RingLogHandler()
    logging.getLogger().addHandler(logs)
    log.info("copyparty-immich-bridge %s (build %s) starting", __version__, cfg.build or "unknown")
    log.info("watching %s -> %s", cfg.watch_dirs, cfg.immich_url)

    # The other people (empty/absent file = the single-user install this has always been). An unreadable file
    # stops the start on purpose: guessing "no users" would pour everybody's files into the main account.
    data_dir = os.path.dirname(cfg.state_db) or "."
    users = UsersStore(cfg.users_file or os.path.join(data_dir, "users.json"), cfg.browse_roots)
    try:
        users.load()
    except UsersError as ex:
        print(f"users file error: {ex}", file=sys.stderr)
        return 2
    if users.users() and not cfg.token:
        log.error("several users are configured but BRIDGE_TOKEN is not set: /hook is refused until it is")

    state = StateStore(cfg.state_db)
    client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id, verify_tls=cfg.verify_tls, upload_timeout=cfg.upload_timeout)
    allowed = resolve_extensions(cfg, client)

    stop_event = threading.Event()
    wake_sweep = threading.Event()  # "scan now", or settings changed

    # Saved settings must be applied BEFORE the first sweep, so it uses them.
    settings = SettingsStore(cfg, cfg.settings_file, cfg.browse_roots, on_change=wake_sweep.set)
    settings.load()
    if cfg.token:
        log.info("web page: http://<host>:%d/ (token required)", cfg.bind_port)
    else:
        log.warning("BRIDGE_TOKEN is not set: the settings web page is switched off; /hook is unauthenticated")

    router = Router(lambda: cfg.watch_dirs, users, claims_db=os.path.join(data_dir, "router.db"))
    manager = UserManager(cfg, users, router, allowed)
    worker = manager.start_main(state, client).worker
    manager.start_all()
    threading.Thread(target=manager.check_identities, name="immich-checks", daemon=True).start()
    for u in users.users():
        log.info("user %s: %s (%s)", u.id, ", ".join(u.folders), "paused" if u.paused else "running")

    def sweep_loop() -> None:
        while not stop_event.is_set():
            try:
                manager.sweep_all()
            except Exception:
                log.exception("sweep failed")
            # interval 0 = no periodic sweep: only wake on "scan now" / a settings change
            wake_sweep.wait(cfg.sweep_interval if cfg.sweep_interval > 0 else None)
            wake_sweep.clear()

    threading.Thread(target=sweep_loop, name="sweep", daemon=True).start()

    if cfg.paused:
        log.warning("imports are PAUSED (saved setting) - press Resume on the web page to continue")
    httpd = serve(cfg, state, worker, settings, logs, scan_now=wake_sweep.set, manager=manager)

    def shutdown(signum, frame) -> None:
        log.info("signal %d — shutting down", signum)
        stop_event.set()
        wake_sweep.set()
        manager.stop_all()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    httpd.serve_forever()
    manager.close_all()
    router.close()
    state.close()
    client.close()
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
