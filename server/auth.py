"""
Optional shared-secret API-key gate.

When the API_KEY environment variable is set, every request (except /health)
must send a matching `X-API-Key` header. When it is unset/empty, the gate is
disabled — so local dev and the test suite run without a key.
"""
from __future__ import annotations

import os

API_KEY = os.getenv("API_KEY")


def key_ok(provided: str | None) -> bool:
    """True if the gate is disabled, or the provided key matches."""
    return (not API_KEY) or provided == API_KEY
