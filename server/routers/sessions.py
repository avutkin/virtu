from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from fastapi import APIRouter, Header

from ..db import get_pool, get_or_create_user
from ..models import SessionSchema, UploadResponse, SessionListItem
from ..sqlite_bridge import write_session as _sqlite_write_session

router = APIRouter(prefix='/sessions', tags=['sessions'])


def _parse_dt(s: str | None):
    if s is None:
        return None
    # Handle both 'Z' suffix and '+00:00'
    s = s.replace('Z', '+00:00')
    return datetime.fromisoformat(s)


@router.post('', response_model=UploadResponse)
async def save_session(
    session: SessionSchema,
    x_user_id: str = Header(..., alias='X-User-ID'),
):
    user_db_id = await get_or_create_user(x_user_id)
    pool = get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                '''
                INSERT INTO sessions
                    (client_session_id, user_id, started_at, ended_at,
                     avg_rsa_ms, avg_coherence, notes)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                ON CONFLICT (client_session_id) DO UPDATE SET
                    ended_at      = EXCLUDED.ended_at,
                    avg_rsa_ms    = EXCLUDED.avg_rsa_ms,
                    avg_coherence = EXCLUDED.avg_coherence,
                    notes         = EXCLUDED.notes
                RETURNING id
                ''',
                session.id, user_db_id,
                _parse_dt(session.started_at), _parse_dt(session.ended_at),
                session.avg_rsa_ms, session.avg_coherence, session.notes,
            )
            db_session_id = str(row['id'])
            if session.samples:
                await conn.executemany(
                    '''
                    INSERT INTO hrv_samples
                        (session_id, ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf,
                         rsa_ms, rsa_idx, coherence, cbi, breath_bpm)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
                    ''',
                    [
                        (
                            db_session_id, _parse_dt(s.ts),
                            s.mean_bpm, s.rmssd, s.sdnn, s.pnn50, s.lf_hf,
                            s.rsa_ms, s.rsa_idx, s.coherence, s.cbi, s.breath_bpm,
                        )
                        for s in session.samples
                    ],
                )

    # Mirror to SQLite so dashboard.py sees iOS data
    samples_dicts = [
        dict(
            ts=s.ts,
            mean_bpm=s.mean_bpm,
            rmssd=s.rmssd,
            sdnn=s.sdnn,
            pnn50=s.pnn50,
            lf_hf=s.lf_hf,
            rsa_ms=s.rsa_ms,
            rsa_idx=s.rsa_idx,
            cbi=s.cbi,
            breath_bpm=s.breath_bpm,
        )
        for s in session.samples
    ]
    loop = asyncio.get_running_loop()
    loop.run_in_executor(
        None,
        _sqlite_write_session,
        session.id, x_user_id,
        session.started_at, session.ended_at,
        session.avg_rsa_ms, session.avg_coherence, session.notes,
        samples_dicts,
    )

    return UploadResponse(id=db_session_id)


@router.get('', response_model=list[SessionListItem])
async def list_sessions(
    x_user_id: str = Header(..., alias='X-User-ID'),
    limit: int = 50,
):
    user_db_id = await get_or_create_user(x_user_id)
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            '''
            SELECT id, started_at, ended_at, avg_rsa_ms, avg_coherence
            FROM sessions WHERE user_id = $1
            ORDER BY started_at DESC LIMIT $2
            ''',
            user_db_id, limit,
        )
    return [
        SessionListItem(
            id=str(r['id']),
            started_at=r['started_at'].isoformat(),
            ended_at=r['ended_at'].isoformat() if r['ended_at'] else None,
            avg_rsa_ms=r['avg_rsa_ms'],
            avg_coherence=r['avg_coherence'],
        )
        for r in rows
    ]
