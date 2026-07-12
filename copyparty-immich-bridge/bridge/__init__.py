"""copyparty → Immich auto-import bridge.

A small standalone service that watches a copyparty volume for completed
uploads (event-hook driven, with a periodic reconciliation sweep) and imports
Immich-compatible media into Immich via its HTTP API.
"""

__version__ = "0.1.0"
