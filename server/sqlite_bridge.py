"""
SQLite bridge — writes iOS data to ~/just-breathe.db so dashboard.py sees it.

The dashboard uses a synchronous sqlite3 connection with a threading.Lock.
This module mirrors incoming iOS ticks/sessions into the same DB file and
table schema that dashboard.py reads from.
"""
from __future__ import annotations

import math
import os
import sqlite3
import threading
from datetime import datetime, timezone

_DB_PATH = os.path.expanduser("~/just-breathe.db")
_lock = threading.Lock()
_conn: sqlite3.Connection | None = None


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(_DB_PATH, check_same_thread=False)
        _conn.execute("PRAGMA journal_mode=WAL")
        _ensure_tables(_conn)
    return _conn


def _ensure_tables(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS ios_sessions (
            id           TEXT PRIMARY KEY,
            user_id      TEXT NOT NULL,
            started_at   TEXT NOT NULL,
            ended_at     TEXT,
            avg_rsa_ms   REAL,
            avg_coherence REAL,
            notes        TEXT,
            synced_at    TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_ios_sessions_user
            ON ios_sessions(user_id, started_at DESC);
    """)
    # Add ios_session_id column to biometric_metrics if it doesn't exist yet
    for col in ("ios_session_id TEXT",):
        try:
            conn.execute(f"ALTER TABLE biometric_metrics ADD COLUMN {col}")
            conn.commit()
        except sqlite3.OperationalError:
            pass  # column already exists


def _vti(rmssd: float | None) -> float:
    """Compute VTI = ln(RMSSD), matching dashboard.py convention."""
    if rmssd and rmssd > 0:
        return math.log(rmssd)
    return 0.0


def _parse_ts(ts_str: str) -> tuple[str, str]:
    """Return (ts_iso_local, ts_date) from an ISO8601 string."""
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        local = dt.astimezone().replace(tzinfo=None)
        return local.isoformat(), local.strftime("%Y-%m-%d")
    except Exception:
        now = datetime.now()
        return now.isoformat(), now.strftime("%Y-%m-%d")


def write_tick(tick: dict) -> None:
    """
    Insert a single live tick into biometric_metrics.

    Expected keys (all optional except ts):
        ts, mean_bpm, rmssd, rsa_ms, rsa_idx, coherence, cbi,
        breath_bpm, sdnn, pnn50, lf_hf
    """
    ts_iso, ts_date = _parse_ts(tick.get("ts", ""))
    rmssd = tick.get("rmssd") or 0.0

    with _lock:
        conn = _get_conn()
        try:
            conn.execute(
                """
                INSERT INTO biometric_metrics
                    (ts, ts_date, vti, cbi, rmssd, breath_bpm, bpm,
                     lfhf, vlf, mean_ie, pnn50, sdnn, ulf, rsa_ms, rsa_idx)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    ts_iso, ts_date,
                    _vti(rmssd),
                    tick.get("cbi") or 0.0,
                    rmssd,
                    tick.get("breath_bpm") or 0.0,
                    tick.get("mean_bpm") or 0.0,
                    tick.get("lf_hf") or 0.0,
                    0.0,  # vlf — not available in tick summary
                    0.0,  # mean_ie — not available in tick summary
                    tick.get("pnn50") or 0.0,
                    tick.get("sdnn") or 0.0,
                    0.0,  # ulf — not available in tick summary
                    tick.get("rsa_ms") or 0.0,
                    tick.get("rsa_idx") or 0.0,
                ),
            )
            conn.commit()
        except Exception:
            pass  # biometric_metrics table may not exist yet — dashboard creates it


def write_session(session_id: str, user_id: str, started_at: str,
                  ended_at: str | None, avg_rsa_ms: float | None,
                  avg_coherence: float | None, notes: str | None,
                  samples: list[dict]) -> None:
    """
    Upsert a session into ios_sessions and insert all samples into
    biometric_metrics, tagged with the session id.
    """
    with _lock:
        conn = _get_conn()
        try:
            conn.execute(
                """
                INSERT INTO ios_sessions
                    (id, user_id, started_at, ended_at, avg_rsa_ms, avg_coherence, notes)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    ended_at      = excluded.ended_at,
                    avg_rsa_ms    = excluded.avg_rsa_ms,
                    avg_coherence = excluded.avg_coherence,
                    notes         = excluded.notes,
                    synced_at     = datetime('now')
                """,
                (session_id, user_id, started_at, ended_at,
                 avg_rsa_ms, avg_coherence, notes),
            )
            for s in samples:
                ts_iso, ts_date = _parse_ts(s.get("ts", ""))
                rmssd = s.get("rmssd") or 0.0
                try:
                    conn.execute(
                        """
                        INSERT INTO biometric_metrics
                            (ts, ts_date, vti, cbi, rmssd, breath_bpm, bpm,
                             lfhf, vlf, mean_ie, pnn50, sdnn, ulf,
                             rsa_ms, rsa_idx, ios_session_id)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                        (
                            ts_iso, ts_date,
                            _vti(rmssd),
                            s.get("cbi") or 0.0,
                            rmssd,
                            s.get("breath_bpm") or 0.0,
                            s.get("mean_bpm") or 0.0,
                            s.get("lf_hf") or 0.0,
                            0.0,  # vlf
                            0.0,  # mean_ie
                            s.get("pnn50") or 0.0,
                            s.get("sdnn") or 0.0,
                            0.0,  # ulf
                            s.get("rsa_ms") or 0.0,
                            s.get("rsa_idx") or 0.0,
                            session_id,
                        ),
                    )
                except Exception:
                    pass
            conn.commit()
        except Exception:
            pass
