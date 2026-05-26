"""
Server API tests — require a running PostgreSQL instance.
Set DATABASE_URL env var before running:
  DATABASE_URL=postgresql://... pytest server/tests/ -v
"""
from __future__ import annotations

import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app


@pytest.mark.asyncio
async def test_health():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
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
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.post("/sessions", json=payload,
                              headers={"X-User-ID": "test-device-001"})
    assert r.status_code == 200
    assert "id" in r.json()


@pytest.mark.asyncio
async def test_list_sessions():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/sessions", headers={"X-User-ID": "test-device-001"})
    assert r.status_code == 200
    assert isinstance(r.json(), list)
