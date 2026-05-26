"""
GET /admin/users           — list all users + last-seen
GET /admin/users/{id}      — per-user summary
GET /admin/sessions        — all sessions (recent)
GET /admin/sessions/{id}/export  — CSV download
"""
from __future__ import annotations

import csv
import io
from fastapi import APIRouter
from fastapi.responses import StreamingResponse
from ..db import get_pool
from ..models import AdminUserRow

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/users", response_model=list[AdminUserRow])
async def list_users():
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                u.id,
                u.device_id,
                MAX(s.started_at) AS last_seen,
                COUNT(s.id)       AS session_count
            FROM users u
            LEFT JOIN sessions s ON s.user_id = u.id
            GROUP BY u.id
            ORDER BY last_seen DESC NULLS LAST
            """
        )
    return [
        AdminUserRow(
            id=str(r["id"]),
            device_id=r["device_id"],
            last_seen=r["last_seen"].isoformat() if r["last_seen"] else None,
            session_count=r["session_count"],
        )
        for r in rows
    ]


@router.get("/sessions")
async def list_all_sessions(limit: int = 100):
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                s.id, s.started_at, s.ended_at,
                s.avg_rsa_ms, s.avg_coherence,
                u.device_id
            FROM sessions s
            JOIN users u ON u.id = s.user_id
            ORDER BY s.started_at DESC
            LIMIT $1
            """,
            limit,
        )
    return [
        {
            "id":            str(r["id"]),
            "started_at":    r["started_at"].isoformat(),
            "ended_at":      r["ended_at"].isoformat() if r["ended_at"] else None,
            "avg_rsa_ms":    r["avg_rsa_ms"],
            "avg_coherence": r["avg_coherence"],
            "device_id":     r["device_id"],
        }
        for r in rows
    ]


@router.get("/sessions/{session_id}/export")
async def export_session_csv(session_id: str):
    """Download all hrv_samples for a session as CSV."""
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf,
                   rsa_ms, rsa_idx, coherence, cbi, breath_bpm
            FROM hrv_samples
            WHERE session_id = $1::uuid
            ORDER BY ts
            """,
            session_id,
        )

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["ts", "mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf",
                     "rsa_ms", "rsa_idx", "coherence", "cbi", "breath_bpm"])
    for r in rows:
        writer.writerow([
            r["ts"].isoformat(),
            r["mean_bpm"], r["rmssd"], r["sdnn"], r["pnn50"], r["lf_hf"],
            r["rsa_ms"], r["rsa_idx"], r["coherence"], r["cbi"], r["breath_bpm"],
        ])

    buf.seek(0)
    return StreamingResponse(
        iter([buf.read()]),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename=session_{session_id[:8]}.csv"},
    )
