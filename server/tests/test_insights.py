"""
Tests for POST /insights — the OpenAI client is swapped for a fake via
FastAPI's dependency_overrides, so no real API calls are made.
"""
from __future__ import annotations

import pytest
from httpx import AsyncClient, ASGITransport
from openai import OpenAIError

from server.main import app
from server.routers.insights import get_openai_client


class _FakeMessage:
    def __init__(self, content):
        self.content = content


class _FakeChoice:
    def __init__(self, content):
        self.message = _FakeMessage(content)


class _FakeCompletion:
    def __init__(self, content):
        self.choices = [_FakeChoice(content)]


class _FakeChatCompletions:
    def __init__(self, content=None, raise_error=False):
        self._content = content
        self._raise_error = raise_error

    async def create(self, **kwargs):
        if self._raise_error:
            raise OpenAIError("boom")
        return _FakeCompletion(self._content)


class _FakeChat:
    def __init__(self, completions):
        self.completions = completions


class _FakeOpenAIClient:
    def __init__(self, content=None, raise_error=False):
        self.chat = _FakeChat(_FakeChatCompletions(content=content, raise_error=raise_error))


_PAYLOAD = {
    "activity_type": "Breathwork",
    "activity_subtype": "Box Breathing",
    "duration_min": 10,
    "before_rsa": 20.0,
    "during_rsa": 32.0,
    "after_rsa": 28.0,
}

_LIVE_STATE_PAYLOAD = {
    "mode": "live_state",
    "window_minutes": 10,
    "metrics": {
        "hr":  {"start": 68.0, "end": 62.0, "min": 60.0, "max": 70.0, "mean": 65.0, "direction": "falling"},
        "rsa": {"start": 22.0, "end": 34.0, "min": 20.0, "max": 36.0, "mean": 28.0, "direction": "rising"},
    },
}


@pytest.mark.asyncio
async def test_generate_insight_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Solid session — your RSA improved nicely.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Solid session — your RSA improved nicely."


@pytest.mark.asyncio
async def test_generate_insight_openai_error_returns_502():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(raise_error=True)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 502


@pytest.mark.asyncio
async def test_generate_insight_empty_response_returns_502():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 502


def test_get_openai_client_requires_api_key(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        get_openai_client()


@pytest.mark.asyncio
async def test_generate_live_state_insight_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Your heart rate has been gradually settling over the last 10 minutes.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_LIVE_STATE_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Your heart rate has been gradually settling over the last 10 minutes."


@pytest.mark.asyncio
async def test_generate_live_state_insight_missing_metrics_returns_422():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "live_state", "window_minutes": 10})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
    assert r.status_code == 422


@pytest.mark.asyncio
async def test_generate_activity_insight_missing_activity_type_returns_422():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "activity"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
    assert r.status_code == 422
