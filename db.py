"""
SQLite persistence layer for Polar H10 session data.

Schema
------
sessions       – one row per recording session
ecg_samples    – individual ECG samples (~130 Hz) with interpolated timestamps
accelerometer  – individual ACC samples (~200 Hz) with interpolated timestamps
pulse          – heart-rate readings (~1 Hz)
rr_intervals   – RR-interval values per pulse reading (key for RSA analysis)

Breathing pattern analysis
--------------------------
Two signals are useful:

1. Accelerometer Z-axis (direct chest movement):
   SELECT timestamp_ns, z_mG FROM accelerometer
   WHERE session_id = ? ORDER BY timestamp_ns;

   Apply a band-pass filter (0.1–0.8 Hz) and find the dominant frequency
   via FFT — that is the breathing rate in Hz (× 60 = breaths/min).

2. RR intervals (respiratory sinus arrhythmia — HR speeds up on inhale,
   slows on exhale):
   SELECT r.rr_ms, p.recorded_at
   FROM rr_intervals r JOIN pulse p ON r.pulse_id = p.id
   WHERE p.session_id = ? ORDER BY p.recorded_at;

   Resample to a uniform grid and apply FFT in the same band.
"""

import sqlite3

# ECG device sample rate (Hz)
ECG_RATE_HZ = 130
# ACC device sample rate (Hz)
ACC_RATE_HZ = 200

_NS_PER_SEC = 1_000_000_000
_ECG_NS_PER_SAMPLE = _NS_PER_SEC / ECG_RATE_HZ   # ≈ 7 692 308 ns
_ACC_NS_PER_SAMPLE = _NS_PER_SEC / ACC_RATE_HZ   # 5 000 000 ns

_DDL = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS sessions (
    id          INTEGER PRIMARY KEY,
    device      TEXT    NOT NULL,
    started_at  TEXT    NOT NULL,   -- ISO 8601 UTC
    ended_at    TEXT,               -- filled in after streaming stops
    duration_s  INTEGER
);

CREATE TABLE IF NOT EXISTS ecg_samples (
    id          INTEGER PRIMARY KEY,
    session_id  INTEGER NOT NULL REFERENCES sessions(id),
    timestamp_ns INTEGER NOT NULL,  -- nanoseconds (interpolated per sample)
    value_uV    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ecg_session_ts
    ON ecg_samples (session_id, timestamp_ns);

CREATE TABLE IF NOT EXISTS accelerometer (
    id          INTEGER PRIMARY KEY,
    session_id  INTEGER NOT NULL REFERENCES sessions(id),
    timestamp_ns INTEGER NOT NULL,  -- nanoseconds (interpolated per sample)
    x_mG        INTEGER NOT NULL,
    y_mG        INTEGER NOT NULL,
    z_mG        INTEGER NOT NULL    -- primary breathing movement signal
);
CREATE INDEX IF NOT EXISTS idx_acc_session_ts
    ON accelerometer (session_id, timestamp_ns);

CREATE TABLE IF NOT EXISTS pulse (
    id          INTEGER PRIMARY KEY,
    session_id  INTEGER NOT NULL REFERENCES sessions(id),
    recorded_at TEXT    NOT NULL,   -- ISO 8601 UTC
    bpm         INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS rr_intervals (
    id          INTEGER PRIMARY KEY,
    pulse_id    INTEGER NOT NULL REFERENCES pulse(id),
    rr_ms       INTEGER NOT NULL    -- milliseconds; used for RSA / HRV analysis
);
"""


def init_db(path: str) -> sqlite3.Connection:
    """Open (or create) the database and ensure the schema exists."""
    conn = sqlite3.connect(path)
    conn.executescript(_DDL)
    conn.commit()
    return conn


def insert_session(conn: sqlite3.Connection, device: str, started_at: str) -> int:
    """Insert a new session row and return its id."""
    cur = conn.execute(
        "INSERT INTO sessions (device, started_at) VALUES (?, ?)",
        (device, started_at),
    )
    conn.commit()
    return cur.lastrowid


def update_session_end(
    conn: sqlite3.Connection,
    session_id: int,
    ended_at: str,
    duration_s: int,
) -> None:
    conn.execute(
        "UPDATE sessions SET ended_at = ?, duration_s = ? WHERE id = ?",
        (ended_at, duration_s, session_id),
    )
    conn.commit()


def insert_ecg_batch(
    conn: sqlite3.Connection,
    session_id: int,
    frames: list[dict],
) -> int:
    """
    Expand ECG frames into individual samples with interpolated timestamps.

    Each frame carries the timestamp of its *last* sample.  We walk backwards
    to assign timestamps to earlier samples:
        sample_ts = frame_ts - (n - 1 - i) * NS_PER_SAMPLE
    """
    rows: list[tuple] = []
    for frame in frames:
        frame_ts: int = frame["timestamp_ns"]
        samples: list[int] = frame["samples_uV"]
        n = len(samples)
        for i, value in enumerate(samples):
            ts = int(frame_ts - (n - 1 - i) * _ECG_NS_PER_SAMPLE)
            rows.append((session_id, ts, value))

    conn.executemany(
        "INSERT INTO ecg_samples (session_id, timestamp_ns, value_uV) VALUES (?,?,?)",
        rows,
    )
    conn.commit()
    return len(rows)


def insert_acc_batch(
    conn: sqlite3.Connection,
    session_id: int,
    frames: list[dict],
) -> int:
    """
    Expand ACC frames into individual samples with interpolated timestamps.

    Each frame carries the timestamp of its *first* sample:
        sample_ts = frame_ts + i * NS_PER_SAMPLE
    """
    rows: list[tuple] = []
    # Group consecutive entries that share the same timestamp_ns into frames,
    # then interpolate within each frame.
    if not frames:
        return 0

    current_frame_ts = frames[0]["timestamp_ns"]
    frame_samples: list[dict] = []

    def _flush(frame_ts: int, samples: list[dict]) -> None:
        for i, s in enumerate(samples):
            ts = int(frame_ts + i * _ACC_NS_PER_SAMPLE)
            rows.append((session_id, ts, s["x_mG"], s["y_mG"], s["z_mG"]))

    for entry in frames:
        if entry["timestamp_ns"] != current_frame_ts:
            _flush(current_frame_ts, frame_samples)
            current_frame_ts = entry["timestamp_ns"]
            frame_samples = []
        frame_samples.append(entry)
    _flush(current_frame_ts, frame_samples)

    conn.executemany(
        "INSERT INTO accelerometer (session_id, timestamp_ns, x_mG, y_mG, z_mG)"
        " VALUES (?,?,?,?,?)",
        rows,
    )
    conn.commit()
    return len(rows)


def insert_pulse_batch(
    conn: sqlite3.Connection,
    session_id: int,
    pulses: list[dict],
) -> int:
    """Insert pulse readings and their associated RR intervals."""
    pulse_rows = 0
    rr_rows = 0
    for p in pulses:
        cur = conn.execute(
            "INSERT INTO pulse (session_id, recorded_at, bpm) VALUES (?,?,?)",
            (session_id, p["timestamp"], p["bpm"]),
        )
        pulse_id = cur.lastrowid
        pulse_rows += 1
        rr_data = [(pulse_id, rr) for rr in p.get("rr_intervals_ms", [])]
        if rr_data:
            conn.executemany(
                "INSERT INTO rr_intervals (pulse_id, rr_ms) VALUES (?,?)",
                rr_data,
            )
            rr_rows += len(rr_data)
    conn.commit()
    return pulse_rows
