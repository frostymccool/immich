import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def _immich_not_overloaded():
    """The backoff state is shared by the whole bridge; a test that saw an HTTP 500 must not hold up the next one."""
    from bridge.pressure import PRESSURE

    PRESSURE.busy, PRESSURE.reason, PRESSURE.since, PRESSURE.until, PRESSURE.level = False, "", 0.0, 0.0, 0
    yield
    PRESSURE.busy, PRESSURE.reason, PRESSURE.since, PRESSURE.until, PRESSURE.level = False, "", 0.0, 0.0, 0
