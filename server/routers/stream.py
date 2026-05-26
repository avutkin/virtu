"""
WS /stream/{user_id}  — live tick streaming from iOS app.
Admin connections can subscribe to any user's stream via /stream/admin/{user_id}.
"""
from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from ..models import TickPayload
from ..db import get_or_create_user, get_pool
from ..sqlite_bridge import write_tick as _sqlite_write_tick

router = APIRouter(tags=["stream"])

# In-memory broadcast registry: user_id → set of admin WebSockets watching them
_admin_subs: dict[str, set[WebSocket]] = defaultdict(set)


@router.websocket("/stream/{user_id}")
async def device_stream(ws: WebSocket, user_id: str):
    """
    iOS app connects here to stream live ticks.
    Each message is a JSON-encoded TickPayload.
    The server:
      1. Persists the tick as an hrv_sample row (if a session is open)
      2. Broadcasts to any admin WebSockets watching this user
    """
    await ws.accept()
    pool = get_pool()
    try:
        while True:
            raw = await ws.receive_bytes()
            try:
                data    = json.loads(raw)
                tick    = TickPayload(**data)
                user_db_id = await get_or_create_user(user_id)

                # Persist to latest open session (best-effort, no error if none)
                async with pool.acquire() as conn:
                    session_row = await conn.fetchrow(
                        """
                        SELECT id FROM sessions
                        WHERE user_id = $1 AND ended_at IS NULL
                        ORDER BY started_at DESC LIMIT 1
                        """,
                        user_db_id,
                    )
                    if session_row:
                        await conn.execute(
                            """
                            INSERT INTO hrv_samples
                                (session_id, ts, mean_bpm, rmssd, rsa_ms, coherence,
                                 cbi, breath_bpm)
                            VALUES ($1, $2::timestamptz, $3, $4, $5, $6, $7, $8)
                            """,
                            str(session_row["id"]),
                            tick.ts,
                            tick.mean_bpm, tick.rmssd, tick.rsa_ms,
                            tick.coherence, tick.cbi, tick.breath_bpm,
                        )

                # Mirror to SQLite so dashboard.py sees live ticks
                loop = asyncio.get_running_loop()
                loop.run_in_executor(None, _sqlite_write_tick, {
                    "ts":         tick.ts,
                    "mean_bpm":   tick.mean_bpm,
                    "rmssd":      tick.rmssd,
                    "rsa_ms":     tick.rsa_ms,
                    "cbi":        tick.cbi,
                    "breath_bpm": tick.breath_bpm,
                })

                # Broadcast to admin subscribers
                if user_id in _admin_subs:
                    dead: set[WebSocket] = set()
                    for admin_ws in list(_admin_subs[user_id]):
                        try:
                            await admin_ws.send_bytes(raw)
                        except Exception:
                            dead.add(admin_ws)
                    _admin_subs[user_id] -= dead

            except Exception:
                pass   # malformed tick — skip silently

    except WebSocketDisconnect:
        pass


@router.websocket("/stream/admin/{user_id}")
async def admin_stream(ws: WebSocket, user_id: str):
    """Admin dashboard subscribes to a device user's live stream."""
    await ws.accept()
    _admin_subs[user_id].add(ws)
    try:
        while True:
            # Keep connection alive; admin only receives, doesn't send
            await asyncio.sleep(30)
            await ws.send_text("ping")
    except WebSocketDisconnect:
        pass
    finally:
        _admin_subs[user_id].discard(ws)
