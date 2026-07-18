"""
Server API tests — require a running PostgreSQL instance.
Set DATABASE_URL env var before running:
  DATABASE_URL=postgresql://... pytest server/tests/ -v
"""
from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
from asgi_lifespan import LifespanManager
from httpx import AsyncClient, ASGITransport
from server.main import app


@asynccontextmanager
async def _client():
    """
    httpx's ASGITransport does not drive the ASGI lifespan protocol on its
    own, so FastAPI's `lifespan` (which calls init_pool()) never runs unless
    something else triggers it — LifespanManager does that explicitly.
    """
    async with LifespanManager(app) as manager:
        async with AsyncClient(transport=ASGITransport(app=manager.app), base_url="http://test") as client:
            yield client


@pytest.mark.asyncio
async def test_health():
    async with _client() as client:
        r = await client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_upload_session():
    payload = {
        "id":         "00000000-0000-0000-0000-000000000001",
        "started_at": "2025-01-01T10:00:00Z",
        "ended_at":   "2025-01-01T10:10:00Z",
        "avg_rsa_ms": 28.5,
        "avg_coherence": 0.72,
        "samples": [
            {
                "ts":      "2025-01-01T10:00:02Z",
                "mean_bpm": 62.0,
                "rmssd":   35.0,
                "coherence": 0.68,
            }
        ],
    }
    async with _client() as client:
        r = await client.post("/sessions", json=payload,
                              headers={"X-User-ID": "test-device-001"})
    assert r.status_code == 200
    assert "id" in r.json()


@pytest.mark.asyncio
async def test_list_sessions():
    async with _client() as client:
        r = await client.get("/sessions", headers={"X-User-ID": "test-device-001"})
    assert r.status_code == 200
    assert isinstance(r.json(), list)
