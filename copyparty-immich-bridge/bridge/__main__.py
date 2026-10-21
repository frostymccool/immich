"""Entry point: wires config, state, Immich client, worker, sweep, HTTP server."""

from __future__ import annotations

import logging
import signal
import sys
import threading
import time

from bridge import __version__
from bridge.config import Config, ConfigError
from bridge.immich import DEFAULT_EXTENSIONS, ImmichClient, ImmichError
from bridge.server import serve
from bridge.state import StateStore
from bridge.worker import ImportWorker

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
    log.info("copyparty-immich-bridge %s starting", __version__)
    log.info("watching %s -> %s", cfg.watch_dirs, cfg.immich_url)

    state = StateStore(cfg.state_db)
    client = ImmichClient(cfg.immich_url, cfg.api_key, cfg.device_id, verify_tls=cfg.verify_tls)
    allowed = resolve_extensions(cfg, client)

    worker = ImportWorker(cfg, state, client, allowed)
    worker.start()

    stop_event = threading.Event()

    def sweep_loop() -> None:
        while not stop_event.is_set():
            try:
                worker.sweep()
            except Exception:
                log.exception("sweep failed")
            if cfg.sweep_interval <= 0:
                return  # startup sweep only
            stop_event.wait(cfg.sweep_interval)

    threading.Thread(target=sweep_loop, name="sweep", daemon=True).start()

    httpd = serve(cfg, state, worker)

    def shutdown(signum, frame) -> None:
        log.info("signal %d — shutting down", signum)
        stop_event.set()
        worker.stop()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    httpd.serve_forever()
    state.close()
    client.close()
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
