"""
Database connection pool and schema helpers.
"""
from __future__ import annotations

import asyncpg
import os
from contextlib import asynccontextmanager

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/justbreathe",
)

_pool: asyncpg.Pool | None = None


async def init_pool() -> None:
    global _pool
    _pool = await asyncpg.create_pool(DATABASE_URL, min_size=2, max_size=10)


async def close_pool() -> None:
    if _pool:
        await _pool.close()


def get_pool() -> asyncpg.Pool:
    assert _pool is not None, "DB pool not initialised"
    return _pool


# ---------------------------------------------------------------------------
# Schema creation (run once on startup or via migration)
# ---------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS users (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    apple_sub    TEXT UNIQUE,
    device_id    TEXT UNIQUE,
    display_name TEXT,
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sessions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID REFERENCES users(id) ON DELETE CASCADE,
    client_session_id    TEXT UNIQUE,           -- UUID from iOS client
    started_at           TIMESTAMPTZ NOT NULL,
    ended_at             TIMESTAMPTZ,
    best_resonance_bpm   REAL,
    avg_rsa_ms           REAL,
    avg_coherence        REAL,
    notes                TEXT,
    created_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS hrv_samples (
    id          BIGSERIAL PRIMARY KEY,
    session_id  UUID REFERENCES sessions(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL,
    mean_bpm    REAL,
    rmssd       REAL,
    sdnn        REAL,
    pnn50       REAL,
    lf_hf       REAL,
    rsa_ms      REAL,
    rsa_idx     REAL,
    coherence   REAL,
    cbi         REAL,
    breath_bpm  REAL
);

CREATE INDEX IF NOT EXISTS hrv_samples_session_ts ON hrv_samples(session_id, ts);
CREATE INDEX IF NOT EXISTS sessions_user_started   ON sessions(user_id, started_at DESC);
"""


async def create_schema() -> None:
    async with get_pool().acquire() as conn:
        await conn.execute(SCHEMA_SQL)


async def get_or_create_user(device_id: str) -> str:
    """Return user UUID for a device_id, creating the user row if needed."""
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id FROM users WHERE device_id = $1", device_id
        )
        if row:
            return str(row["id"])
        row = await conn.fetchrow(
            "INSERT INTO users (device_id) VALUES ($1) RETURNING id", device_id
        )
        return str(row["id"])
