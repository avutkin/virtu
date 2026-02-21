"""
Just Breathe — Real-Time Biometric Dashboard
=============================================
Run:  python3 dashboard.py
Open: http://127.0.0.1:8050

Pages
-----
  LIVE   real-time ECG · ACC · RR · HRV · CBI · VTI
  TODAY  full-day trend charts (persisted across restarts)
  WEEK   daily averages for the last 7 days
"""

from __future__ import annotations

import asyncio
import sqlite3
import threading
import time
from collections import deque
from datetime import datetime, timezone

import numpy as np
import dash
from dash import dcc, html, Input, Output, callback, ctx
import plotly.graph_objects as go

import metrics
from polar import PolarH10

# ── colour palette ────────────────────────────────────────────────────────────
C_BG        = "#0d1117"
C_CARD      = "#161b22"
C_BORDER    = "#21262d"
C_TEXT      = "#e6edf3"
C_DIM       = "#8b949e"
C_ECG       = "#ff6b8a"
C_ACC       = "#56d364"
C_RR        = "#58a6ff"
C_PSD_LF    = "#58a6ff"
C_PSD_HF    = "#f0883e"
C_COH       = "#39d353"
C_CBI       = "#d2a8ff"
C_VTI       = "#79c0ff"
C_GOOD      = "#3fb950"
C_WARN      = "#d29922"
C_BAD       = "#f85149"
C_VLF       = "#22d3ee"   # cyan — VLF power
C_NAV_ACT   = "#58a6ff"   # active navigation pill

# ── shared style atoms ────────────────────────────────────────────────────────
_CARD = {
    "backgroundColor": C_CARD,
    "border": f"1px solid {C_BORDER}",
    "borderRadius": "8px",
    "padding": "14px",
}

_PLOT_LAYOUT = dict(
    paper_bgcolor=C_CARD,
    plot_bgcolor=C_CARD,
    font=dict(family="'JetBrains Mono', 'Courier New', monospace",
              color=C_TEXT, size=11),
    margin=dict(l=45, r=12, t=32, b=28),
)

_AX = dict(showgrid=True, gridcolor=C_BORDER, zeroline=False,
           tickfont=dict(color=C_DIM))


def _ax(title: str = "", **kw) -> dict:
    return dict(**_AX, title=title, **kw)


def _empty_fig(title: str = "") -> go.Figure:
    fig = go.Figure()
    fig.update_layout(
        **_PLOT_LAYOUT,
        title=dict(text=title, font=dict(color=C_DIM, size=12), x=0.01),
        annotations=[dict(
            text="waiting for data…", x=0.5, y=0.5, showarrow=False,
            font=dict(color=C_DIM, size=13), xref="paper", yref="paper",
        )],
    )
    return fig


def _nav_pill(active: bool) -> dict:
    return {
        "backgroundColor": C_NAV_ACT if active else "transparent",
        "color": C_TEXT if active else C_DIM,
        "border": "none",
        "borderRadius": "16px",
        "padding": "7px 22px",
        "fontSize": "11px",
        "fontWeight": "700",
        "letterSpacing": "1.5px",
        "cursor": "pointer",
        "fontFamily": "'JetBrains Mono', monospace",
        "transition": "background 0.2s",
    }


# ── SQLite metrics persistence ───────────────────────────────────────────────
_DB_PATH = "just-breathe.db"

_CREATE_METRICS = """
CREATE TABLE IF NOT EXISTS biometric_metrics (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         TEXT NOT NULL,
    ts_date    TEXT NOT NULL,
    vti        REAL DEFAULT 0,
    cbi        REAL DEFAULT 0,
    rmssd      REAL DEFAULT 0,
    breath_bpm REAL DEFAULT 0,
    bpm        REAL DEFAULT 0,
    lfhf       REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_bm_date ON biometric_metrics(ts_date);
CREATE TABLE IF NOT EXISTS rr_log (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    rr_ms INTEGER NOT NULL
);
"""

def _open_db() -> sqlite3.Connection:
    conn = sqlite3.connect(_DB_PATH, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")   # safe concurrent reads/writes
    conn.executescript(_CREATE_METRICS)
    # Add vlf column to existing databases that predate it
    try:
        conn.execute("ALTER TABLE biometric_metrics ADD COLUMN vlf REAL DEFAULT 0")
        conn.commit()
    except sqlite3.OperationalError:
        pass  # column already exists
    return conn


def _save_rr_window(conn: sqlite3.Connection, rr: list) -> None:
    """Overwrite stored RR window so it survives restarts and reconnects."""
    conn.execute("DELETE FROM rr_log")
    conn.executemany("INSERT INTO rr_log (rr_ms) VALUES (?)",
                     [(int(r),) for r in rr])
    conn.commit()


def _load_rr_window(conn: sqlite3.Connection) -> list[int]:
    """Load the last saved RR window (used to warm up DataBuffer on startup)."""
    cur = conn.execute("SELECT rr_ms FROM rr_log ORDER BY id")
    return [row[0] for row in cur.fetchall()]

def _save_metric(conn: sqlite3.Connection, rec: dict) -> None:
    now = datetime.now()
    conn.execute(
        "INSERT INTO biometric_metrics "
        "(ts, ts_date, vti, cbi, rmssd, breath_bpm, bpm, lfhf, vlf) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (now.isoformat(), now.strftime("%Y-%m-%d"),
         rec["vti"], rec["cbi"], rec["rmssd"],
         rec["breath_bpm"], rec["bpm"], rec["lfhf"], rec["vlf"]),
    )
    conn.commit()

def _load_today(conn: sqlite3.Connection) -> list[dict]:
    today = datetime.now().strftime("%Y-%m-%d")
    cur = conn.execute(
        "SELECT ts, vti, cbi, rmssd, breath_bpm, bpm, lfhf, vlf "
        "FROM biometric_metrics WHERE ts_date=? ORDER BY ts",
        (today,),
    )
    return [
        dict(t=row[0][11:16], vti=row[1], cbi=row[2], rmssd=row[3],
             breath_bpm=row[4], bpm=row[5], lfhf=row[6], vlf=row[7] or 0.0)
        for row in cur.fetchall()
    ]

def _load_week(conn: sqlite3.Connection) -> list[dict]:
    cur = conn.execute("""
        SELECT ts_date,
               AVG(CASE WHEN vti        > 0 THEN vti        END),
               AVG(CASE WHEN cbi        > 0 THEN cbi        END),
               AVG(CASE WHEN rmssd      > 0 THEN rmssd      END),
               AVG(CASE WHEN breath_bpm > 0 THEN breath_bpm END),
               AVG(CASE WHEN lfhf       > 0 THEN lfhf       END),
               COUNT(*)
        FROM biometric_metrics
        WHERE ts_date >= date('now','-6 days')
        GROUP BY ts_date
        ORDER BY ts_date
    """)
    rows = []
    for r in cur.fetchall():
        date, vti, cbi, rmssd, breath, lfhf, n = r
        label = datetime.strptime(date, "%Y-%m-%d").strftime("%a %d")
        rows.append(dict(
            date=date, label=label,
            vti=round(vti, 2)    if vti    else 0,
            cbi=round(cbi, 3)    if cbi    else 0,
            rmssd=round(rmssd,1) if rmssd  else 0,
            breath_bpm=round(breath,1) if breath else 0,
            lfhf=round(lfhf, 2)  if lfhf   else 0,
            n=n,
        ))
    return rows


# ── thread-safe data buffer ───────────────────────────────────────────────────
class DataBuffer:
    ECG_WIN = 8 * metrics.ECG_FS    # 1 040 samples  (8 s)
    ACC_WIN = 60 * metrics.ACC_FS   # 12 000 samples (60 s — gives ~15 Welch segments)
    RR_WIN  = 200                   # 200 beats

    def __init__(self) -> None:
        self._ecg  = deque(maxlen=self.ECG_WIN)
        self._acc  = deque(maxlen=self.ACC_WIN)
        self._rr   = deque(maxlen=self.RR_WIN)
        self._bpm  = deque(maxlen=60)
        self._lock = threading.Lock()

    def add_ecg(self, samples_uV: list[int]) -> None:
        with self._lock:
            self._ecg.extend(samples_uV)

    def add_acc(self, z_mG: int) -> None:
        with self._lock:
            self._acc.append(z_mG)

    def add_rr(self, rr_ms: list[int], bpm: int) -> None:
        with self._lock:
            self._rr.extend(rr_ms)
            self._bpm.append(bpm)

    def preload_rr(self, rr_ms: list[int]) -> None:
        """Seed the RR deque from a previously saved window (startup / reconnect)."""
        with self._lock:
            self._rr.extend(rr_ms)

    def snapshot(self) -> tuple[list, list, list, list]:
        with self._lock:
            return (list(self._ecg), list(self._acc),
                    list(self._rr),  list(self._bpm))


# ── metrics history — powers the Today view ───────────────────────────────────
class MetricsHistory:
    """Appended every 2 s by update_slow; drives Today aggregated charts."""
    MAX_PTS = 5400   # ≈ 3 h at 2 s intervals

    def __init__(self) -> None:
        self._rows: deque[dict] = deque(maxlen=self.MAX_PTS)
        self._lock = threading.Lock()

    def append(self, vti: float, cbi: float, rmssd: float | None,
               breath_bpm: float | None, bpm: float | None,
               lfhf: float | None, vlf: float | None) -> None:
        with self._lock:
            self._rows.append(dict(
                t=datetime.now().strftime("%H:%M"),
                vti=round(vti, 3),
                cbi=round(cbi, 3),
                rmssd=round(rmssd, 1)           if rmssd      is not None else 0.0,
                breath_bpm=round(breath_bpm, 1) if breath_bpm is not None else 0.0,
                bpm=round(bpm, 1)               if bpm        is not None else 0.0,
                lfhf=round(lfhf, 3)             if lfhf       is not None else 0.0,
                vlf=round(vlf, 2)               if vlf        is not None else 0.0,
            ))

    def preload(self, records: list[dict]) -> None:
        with self._lock:
            self._rows.extend(records)

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self._rows)


# ── live sensor subclass ──────────────────────────────────────────────────────
class LivePolarH10(PolarH10):
    def __init__(self, buf: DataBuffer) -> None:
        super().__init__("Polar H10")
        self._buf = buf

    def _parse_ecg(self, data: bytearray) -> None:
        samples: list[int] = []
        offset = 10
        while offset + 3 <= len(data):
            samples.append(int.from_bytes(data[offset:offset + 3], "little", signed=True))
            offset += 3
        if samples:
            self._buf.add_ecg(samples)

    def _parse_acc(self, data: bytearray) -> None:
        offset = 10
        while offset + 6 <= len(data):
            offset += 4   # skip X + Y
            z = int.from_bytes(data[offset:offset + 2], "little", signed=True)
            self._buf.add_acc(z)
            offset += 2

    def _hr_handler(self, _char, data: bytearray) -> None:
        flags = data[0]
        bpm = int.from_bytes(data[1:3], "little") if (flags & 0x01) else data[1]
        rr_intervals: list[int] = []
        offset = 3 if (flags & 0x01) else 2
        if flags & 0x10:
            while offset + 1 < len(data):
                raw = int.from_bytes(data[offset:offset + 2], "little")
                rr_intervals.append(round(raw * 1000 / 1024))
                offset += 2
        self._buf.add_rr(rr_intervals, bpm)


# ── BLE background thread ─────────────────────────────────────────────────────
_buf           = DataBuffer()
_db            = _open_db()
_buf.preload_rr(_load_rr_window(_db))        # warm up RR buffer from last session
_history       = MetricsHistory()
_history.preload(_load_today(_db))           # restore today's charts across restarts
_sensor_status = {"state": "searching", "device": "", "since": time.time()}

# Last KPI values written by the slow callback, read by the fast callback.
# Avoids running Welch PSD in the 200 ms loop.
_kpi_cache: dict = {
    "bpm": "—", "rmssd": "—", "sdnn": "—",
    "breath": "—", "pnn50": "—", "lfhf": "—",
}


def _start_ble(buf: DataBuffer) -> None:
    def _thread() -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        async def _run() -> None:
            attempt = 0
            while True:
                sensor = LivePolarH10(buf)
                attempt += 1
                try:
                    _sensor_status["state"] = (
                        "searching — disconnect H10 from macOS Bluetooth first"
                        if attempt > 1 else "searching"
                    )
                    await sensor.connect(timeout=20.0)
                    _sensor_status.update(state="connected",
                                          device=sensor._device_label,
                                          since=time.time())
                    await sensor.start_streams()
                    while True:
                        await asyncio.sleep(1)
                except RuntimeError:
                    _sensor_status["state"] = (
                        "not found — disconnect H10 from macOS Bluetooth, retrying in 5 s…"
                    )
                    try:
                        await sensor.stop_streams()
                        await sensor.disconnect()
                    except Exception:
                        pass
                    await asyncio.sleep(5)
                except Exception as exc:
                    _sensor_status["state"] = f"disconnected ({exc}) — retrying…"
                    try:
                        await sensor.stop_streams()
                        await sensor.disconnect()
                    except Exception:
                        pass
                    await asyncio.sleep(5)

        loop.run_until_complete(_run())
        loop.close()

    threading.Thread(target=_thread, daemon=True).start()


# ── Dash app ──────────────────────────────────────────────────────────────────
app = dash.Dash(__name__, title="Just Breathe")
app.server.config["SECRET_KEY"] = "just-breathe"


# ── reusable component builders ───────────────────────────────────────────────
def _kpi_card(card_id: str, label: str, color: str, unit: str = "") -> html.Div:
    return html.Div([
        html.Div(label, style={"color": C_DIM, "fontSize": "11px",
                               "textTransform": "uppercase", "letterSpacing": "1px",
                               "marginBottom": "6px"}),
        html.Div([
            html.Span("—", id=card_id,
                      style={"color": color, "fontSize": "28px", "fontWeight": "700",
                             "letterSpacing": "-1px",
                             "fontFamily": "'JetBrains Mono', monospace"}),
            html.Span(f" {unit}" if unit else "",
                      style={"color": C_DIM, "fontSize": "13px", "marginLeft": "3px"}),
        ]),
    ], style={**_CARD, "borderTop": f"3px solid {color}", "minWidth": "0"})


def _today_stat(stat_id: str, label: str, color: str, unit: str = "") -> html.Div:
    return html.Div([
        html.Div(label, style={"color": C_DIM, "fontSize": "11px",
                               "textTransform": "uppercase", "letterSpacing": "1px",
                               "marginBottom": "8px"}),
        html.Div([
            html.Span("—", id=stat_id,
                      style={"color": color, "fontSize": "40px", "fontWeight": "700",
                             "letterSpacing": "-2px",
                             "fontFamily": "'JetBrains Mono', monospace"}),
            html.Span(f" {unit}" if unit else "",
                      style={"color": C_DIM, "fontSize": "14px", "marginLeft": "4px"}),
        ]),
    ], style={**_CARD, "borderTop": f"3px solid {color}",
              "textAlign": "center", "minWidth": "0"})


# ── live figure helpers ───────────────────────────────────────────────────────
_ACC_DISPLAY = 10 * metrics.ACC_FS   # show last 10 s in chart; buffer holds 20 s


def _ecg_figure(ecg: list) -> go.Figure:
    t = np.linspace(-len(ecg) / metrics.ECG_FS, 0, len(ecg))
    fig = go.Figure(go.Scatter(x=t, y=ecg, mode="lines",
                               line=dict(color=C_ECG, width=1), hoverinfo="skip"))
    fig.update_layout(**_PLOT_LAYOUT, uirevision="ecg",
                      title=dict(text="ECG  (µV)", font=dict(color=C_ECG, size=12), x=0.01),
                      xaxis=_ax("seconds"), yaxis=_ax("µV"))
    return fig


def _acc_figure(acc: list) -> go.Figure:
    display = acc[-_ACC_DISPLAY:] if len(acc) > _ACC_DISPLAY else acc
    t = np.linspace(-len(display) / metrics.ACC_FS, 0, len(display))
    fig = go.Figure(go.Scatter(x=t, y=display, mode="lines",
                               line=dict(color=C_ACC, width=1.5),
                               fill="tozeroy", fillcolor="rgba(86,211,100,0.08)",
                               hoverinfo="skip"))
    fig.update_layout(**_PLOT_LAYOUT, uirevision="acc",
                      title=dict(text="ACC Z-axis — Breathing (mG)",
                                 font=dict(color=C_ACC, size=12), x=0.01),
                      xaxis=_ax("seconds"), yaxis=_ax("mG"))
    return fig


def _rr_figure(rr: list) -> go.Figure:
    fig = go.Figure(go.Scatter(x=list(range(len(rr))), y=rr, mode="lines+markers",
                               line=dict(color=C_RR, width=1.5),
                               marker=dict(size=3, color=C_RR),
                               hovertemplate="%{y} ms<extra></extra>"))
    fig.update_layout(**_PLOT_LAYOUT, uirevision="rr",
                      title=dict(text="RR Tachogram (ms)", font=dict(color=C_RR, size=12), x=0.01),
                      xaxis=_ax("beat"), yaxis=_ax("ms"))
    return fig


def _psd_figure(hrv: dict) -> go.Figure:
    freqs = np.array(hrv["psd_freqs"])
    psd   = np.array(hrv["psd_values"])
    lf_m  = (freqs >= 0.04) & (freqs <= 0.15)
    hf_m  = (freqs >= 0.15) & (freqs <= 0.40)
    fig = go.Figure()
    fig.add_trace(go.Scatter(x=freqs, y=psd, mode="lines",
                             line=dict(color=C_DIM, width=1),
                             showlegend=False, hoverinfo="skip"))
    fig.add_trace(go.Scatter(x=freqs[lf_m], y=psd[lf_m], mode="lines",
                             fill="tozeroy", fillcolor="rgba(88,166,255,0.25)",
                             line=dict(color=C_PSD_LF, width=1.5),
                             name=f"LF  {hrv['lf_nu']:.0f} nu"))
    fig.add_trace(go.Scatter(x=freqs[hf_m], y=psd[hf_m], mode="lines",
                             fill="tozeroy", fillcolor="rgba(240,136,62,0.25)",
                             line=dict(color=C_PSD_HF, width=1.5),
                             name=f"HF  {hrv['hf_nu']:.0f} nu"))
    fig.update_layout(**_PLOT_LAYOUT,
                      title=dict(text="HRV Power Spectrum (Welch)", font=dict(size=12), x=0.01),
                      xaxis=_ax("frequency (Hz)", range=[0, 0.5]),
                      yaxis=_ax("ms²/Hz"),
                      legend=dict(font=dict(size=10, color=C_DIM),
                                  bgcolor="rgba(0,0,0,0)", x=0.98, xanchor="right", y=0.98))
    return fig


def _coherence_figure(coh_data: dict) -> go.Figure:
    freqs = np.array(coh_data["freqs"])
    coh   = np.array(coh_data["coherence"])
    score = coh_data["score"]
    mask  = (freqs >= 0.1) & (freqs <= 0.8)
    fig = go.Figure()
    fig.add_trace(go.Scatter(x=freqs, y=coh, mode="lines",
                             line=dict(color=C_DIM, width=1),
                             showlegend=False, hoverinfo="skip"))
    if mask.any():
        fig.add_trace(go.Scatter(x=freqs[mask], y=coh[mask], mode="lines",
                                 fill="tozeroy", fillcolor="rgba(57,211,83,0.20)",
                                 line=dict(color=C_COH, width=2),
                                 name=f"breathing band  {score:.2f}"))
    fig.add_hrect(y0=0.7, y1=1.0, fillcolor="rgba(57,211,83,0.06)",
                  line_width=0, annotation_text="high coherence",
                  annotation_font=dict(size=9, color=C_COH))
    fig.update_layout(**_PLOT_LAYOUT,
                      title=dict(text="RR–Breathing Coherence", font=dict(size=12), x=0.01),
                      xaxis=_ax("frequency (Hz)", range=[0, 1.0]),
                      yaxis=_ax("coherence", range=[0, 1.05]),
                      legend=dict(font=dict(size=10, color=C_DIM),
                                  bgcolor="rgba(0,0,0,0)", x=0.98, xanchor="right", y=0.05))
    return fig


def _gauge(value: float, vmax: float, color: str, steps: list[dict]) -> go.Figure:
    fig = go.Figure(go.Indicator(
        mode="gauge+number",
        value=value,
        number=dict(font=dict(color=color, size=32,
                              family="'JetBrains Mono', monospace"),
                    valueformat=".2f"),
        gauge=dict(
            axis=dict(range=[0, vmax], tickfont=dict(color=C_DIM, size=9),
                      tickcolor=C_DIM, tickwidth=1),
            bar=dict(color=color, thickness=0.22),
            bgcolor=C_BG, borderwidth=1, bordercolor=C_BORDER,
            steps=steps,
            threshold=dict(line=dict(color=C_TEXT, width=2),
                           thickness=0.75, value=value),
        ),
    ))
    fig.update_layout(paper_bgcolor=C_CARD,
                      font=dict(color=C_TEXT, family="'JetBrains Mono', monospace", size=11),
                      margin=dict(l=20, r=20, t=10, b=10))
    return fig


def _cbi_gauge(cbi: float) -> go.Figure:
    return _gauge(cbi, 1.0, C_CBI, [
        dict(range=[0.0, 0.3], color="rgba(248,81,73,0.18)"),
        dict(range=[0.3, 0.6], color="rgba(210,153,34,0.18)"),
        dict(range=[0.6, 1.0], color="rgba(63,185,80,0.18)"),
    ])


def _vti_gauge(vti: float) -> go.Figure:
    return _gauge(max(vti, 0), 5.0, C_VTI, [
        dict(range=[0.0, 2.5], color="rgba(248,81,73,0.18)"),
        dict(range=[2.5, 3.5], color="rgba(210,153,34,0.18)"),
        dict(range=[3.5, 5.0], color="rgba(63,185,80,0.18)"),
    ])


# ── Today view figure helpers ─────────────────────────────────────────────────
def _trend_fig(records: list[dict], key: str, title: str,
               color: str, unit: str) -> go.Figure:
    if not records:
        return _empty_fig(title)

    # Aggregate into 1-minute buckets (t is "HH:MM"); skip zero/missing values
    buckets: dict[str, list] = {}
    for r in records:
        v = r.get(key, 0)
        if v > 0:
            t = r["t"]
            if t not in buckets:
                buckets[t] = []
            buckets[t].append(v)

    if not buckets:
        return _empty_fig(title)

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=color, width=1.5),
        marker=dict(size=3, color=color),
        hovertemplate=f"%{{y:.2f}} {unit}<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"today-{key}",
        title=dict(text=title, font=dict(color=color, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax(unit),
    )
    return fig


def _vti_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "vti", "Vagal Tone Index  —  ln(RMSSD)", C_VTI, "")


def _cbi_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "cbi", "Conscious Breathing Index", C_CBI, "")


def _rmssd_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "rmssd", "RMSSD", C_ACC, "ms")


def _breath_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "breath_bpm", "Breathing Rate", C_PSD_HF, "br/min")


C_LFHF = "#e8a838"   # warm amber — distinct from LF (blue) and HF (orange)

def _lfhf_live_fig(records: list[dict]) -> go.Figure:
    """LF/HF line chart — last 60 min, 1-minute averages."""
    # 60 min × 30 records/min (one per 2 s) = 1 800 records
    window = records[-1800:] if len(records) > 1800 else records
    if not window:
        return _empty_fig("LF / HF Ratio")

    # Group into 1-min buckets; t is already "HH:MM"
    buckets: dict[str, list] = {}
    for r in window:
        v = r["lfhf"]
        if v > 0:
            key = r["t"]
            if key not in buckets:
                buckets[key] = []
            buckets[key].append(v)

    if not buckets:
        return _empty_fig("LF / HF Ratio")

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_LFHF, width=1.5),
        marker=dict(size=3, color=C_LFHF),
        hovertemplate="%{x}  LF/HF %{y:.2f}<extra></extra>",
    ))
    # Reference guidelines
    fig.add_hline(y=2.0, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="sympathetic  > 2",
                  annotation_font=dict(color=C_BAD, size=9),
                  annotation_position="top right")
    fig.add_hline(y=0.5, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="balanced  0.5 – 2",
                  annotation_font=dict(color=C_GOOD, size=9),
                  annotation_position="bottom right")
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision="lfhf-live",
        title=dict(text="LF / HF Ratio  — last 60 min  ·  1 min avg",
                   font=dict(color=C_LFHF, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("ratio", rangemode="tozero"),
    )
    return fig


def _lfhf_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "lfhf", "LF / HF Ratio  (sympathetic balance)", C_LFHF, "")
    fig.add_hline(y=2.0, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="sympathetic  > 2",
                  annotation_font=dict(color=C_BAD, size=9),
                  annotation_position="top right")
    fig.add_hline(y=0.5, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="balanced  0.5 – 2",
                  annotation_font=dict(color=C_GOOD, size=9),
                  annotation_position="bottom right")
    return fig


def _vlf_live_fig(records: list[dict]) -> go.Figure:
    """VLF power line chart — last 60 min, 1-minute averages, with reference guidelines."""
    window = records[-1800:] if len(records) > 1800 else records
    if not window:
        return _empty_fig("VLF Power  (0.003–0.04 Hz)")

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("vlf", 0)
        if v > 0:
            key = r["t"]
            if key not in buckets:
                buckets[key] = []
            buckets[key].append(v)

    if not buckets:
        return _empty_fig("VLF Power  (0.003–0.04 Hz)")

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_VLF, width=1.5),
        marker=dict(size=3, color=C_VLF),
        hovertemplate="%{x}  VLF %{y:.1f} ms²<extra></extra>",
    ))
    # Guidelines: good ≥ 500 ms², low < 100 ms²
    fig.add_hline(y=500, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="good  ≥ 500",
                  annotation_font=dict(color=C_GOOD, size=9),
                  annotation_position="bottom right")
    fig.add_hline(y=100, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 100",
                  annotation_font=dict(color=C_BAD, size=9),
                  annotation_position="top right")
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision="vlf-live",
        title=dict(text="VLF Power  (0.003–0.04 Hz)  — last 60 min  ·  1 min avg",
                   font=dict(color=C_VLF, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("ms²", rangemode="tozero"),
    )
    return fig


# ── Week view figure helpers ──────────────────────────────────────────────────
def _week_bar(days: list[dict], key: str, title: str,
              color: str, unit: str) -> go.Figure:
    if not days:
        return _empty_fig(title)
    labels = [d["label"] for d in days]
    vals   = [d[key]     for d in days]
    fig = go.Figure(go.Bar(
        x=labels, y=vals,
        marker_color=color,
        marker_line_width=0,
        hovertemplate=f"%{{y:.2f}} {unit}<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        title=dict(text=title, font=dict(color=color, size=12), x=0.01),
        xaxis=_ax(""),
        yaxis=_ax(unit, rangemode="tozero"),
        bargap=0.35,
    )
    return fig


# ── layout ────────────────────────────────────────────────────────────────────
app.layout = html.Div([

    dcc.Interval(id="tick-fast",  interval=200,  n_intervals=0),
    dcc.Interval(id="tick-slow",  interval=2000, n_intervals=0),
    dcc.Interval(id="tick-today", interval=5000, n_intervals=0),

    # ── Navigation bar ────────────────────────────────────────────────────────
    html.Div([
        # Brand + status dot
        html.Div([
            html.Span("◉ ", id="status-dot",
                      style={"color": C_WARN, "fontSize": "18px"}),
            html.Span("JUST BREATHE",
                      style={"color": C_TEXT, "fontSize": "20px", "fontWeight": "700",
                             "letterSpacing": "3px",
                             "fontFamily": "'JetBrains Mono', monospace"}),
        ], style={"display": "flex", "alignItems": "center", "gap": "8px"}),

        # Navigation pills
        html.Div([
            html.Button("LIVE",  id="nav-live",  n_clicks=0,
                        style=_nav_pill(True)),
            html.Button("TODAY", id="nav-today", n_clicks=0,
                        style=_nav_pill(False)),
            html.Button("WEEK",  id="nav-week",  n_clicks=0,
                        style=_nav_pill(False)),
        ], style={"display": "flex", "gap": "4px",
                  "backgroundColor": C_BORDER,
                  "borderRadius": "20px", "padding": "4px"}),

        # Connection status + session timer
        html.Div([
            html.Span(id="status-label", children="Searching for Polar H10…",
                      style={"color": C_DIM, "fontSize": "12px"}),
            html.Span("  ·  ", style={"color": C_BORDER}),
            html.Span(id="timer-label", children="00:00",
                      style={"color": C_DIM, "fontSize": "12px",
                             "fontFamily": "'JetBrains Mono', monospace"}),
        ]),
    ], style={**_CARD, "display": "flex", "justifyContent": "space-between",
              "alignItems": "center", "marginBottom": "10px"}),

    # ══════════════════════════ LIVE view ═════════════════════════════════════
    html.Div([

        # Row 1 — KPI chips
        html.Div([
            _kpi_card("kpi-bpm",    "Heart Rate",  C_ECG,    "bpm"),
            _kpi_card("kpi-rmssd",  "RMSSD",       C_ACC,    "ms"),
            _kpi_card("kpi-sdnn",   "SDNN",        C_RR,     "ms"),
            _kpi_card("kpi-breath", "Breathing",   C_PSD_HF, "br/m"),
            _kpi_card("kpi-pnn50",  "pNN50",       C_COH,    "%"),
            _kpi_card("kpi-lfhf",   "LF / HF",     C_CBI,    ""),
        ], style={"display": "grid", "gridTemplateColumns": "repeat(6, 1fr)",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 2 — raw waveforms
        html.Div([
            html.Div(dcc.Graph(id="ecg-graph", style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="acc-graph", style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 3 — derived signals + LF/HF live trend
        html.Div([
            html.Div(dcc.Graph(id="rr-graph",       style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="psd-graph",      style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="lfhf-live-graph", style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 4 — coherence + VLF + extended metrics
        html.Div([
            html.Div(dcc.Graph(id="coh-graph", style={"height": "200px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="vlf-live-graph", style={"height": "200px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div([
                html.Div("Extended Metrics",
                         style={"color": C_DIM, "fontSize": "11px",
                                "textTransform": "uppercase", "letterSpacing": "1px",
                                "marginBottom": "10px"}),
                html.Div(id="ext-metrics",
                         style={"fontFamily": "'JetBrains Mono', monospace",
                                "fontSize": "13px", "color": C_TEXT, "lineHeight": "2"}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 5 — index gauges
        html.Div([
            html.Div([
                html.Div("Conscious Breathing Index",
                         style={"color": C_DIM, "fontSize": "11px",
                                "textTransform": "uppercase", "letterSpacing": "1px",
                                "marginBottom": "2px"}),
                html.Div("Peaks at 6 br/min · measures HRV–breath coherence + vagal tone",
                         style={"color": C_DIM, "fontSize": "10px", "marginBottom": "4px"}),
                dcc.Graph(id="cbi-gauge", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div("Vagal Tone Index  —  ln(RMSSD)",
                         style={"color": C_DIM, "fontSize": "11px",
                                "textTransform": "uppercase", "letterSpacing": "1px",
                                "marginBottom": "2px"}),
                html.Div("Parasympathetic nervous system activity · >3.5 = good · <2.5 = low",
                         style={"color": C_DIM, "fontSize": "10px", "marginBottom": "4px"}),
                dcc.Graph(id="vti-gauge", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr", "gap": "10px"}),

    ], id="content-live"),

    # ══════════════════════════ TODAY view ════════════════════════════════════
    html.Div([

        # Section header
        html.Div([
            html.Div("Today's Session", style={
                "color": C_TEXT, "fontSize": "16px", "fontWeight": "700",
                "letterSpacing": "1px", "fontFamily": "'JetBrains Mono', monospace",
            }),
            html.Div(id="today-session-time",
                     style={"color": C_DIM, "fontSize": "12px", "marginTop": "2px"}),
        ], style={"marginBottom": "14px"}),

        # Summary stat cards
        html.Div([
            _today_stat("today-avg-vti",    "Avg Vagal Tone",  C_VTI),
            _today_stat("today-peak-cbi",   "Peak CBI",        C_CBI),
            _today_stat("today-avg-rmssd",  "Avg RMSSD",       C_ACC,    "ms"),
            _today_stat("today-avg-breath", "Avg Breathing",   C_PSD_HF, "br/m"),
            _today_stat("today-avg-lfhf",   "Avg LF / HF",     C_LFHF),
        ], style={"display": "grid", "gridTemplateColumns": "repeat(5, 1fr)",
                  "gap": "10px", "marginBottom": "14px"}),

        # VTI trend (full width)
        html.Div(
            dcc.Graph(id="today-vti", style={"height": "240px"},
                      config={"displayModeBar": False}),
            style={**_CARD, "marginBottom": "10px"}),

        # CBI trend (full width)
        html.Div(
            dcc.Graph(id="today-cbi", style={"height": "240px"},
                      config={"displayModeBar": False}),
            style={**_CARD, "marginBottom": "10px"}),

        # RMSSD + Breathing side by side
        html.Div([
            html.Div(dcc.Graph(id="today-rmssd",  style={"height": "210px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="today-breath", style={"height": "210px"},
                               config={"displayModeBar": False}), style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # LF/HF trend (full width)
        html.Div(
            dcc.Graph(id="today-lfhf", style={"height": "230px"},
                      config={"displayModeBar": False}),
            style=_CARD),

    ], id="content-today", style={"display": "none"}),

    # ══════════════════════════ WEEK view ═════════════════════════════════════
    html.Div([

        # Section header
        html.Div([
            html.Div("This Week", style={
                "color": C_TEXT, "fontSize": "16px", "fontWeight": "700",
                "letterSpacing": "1px", "fontFamily": "'JetBrains Mono', monospace",
            }),
            html.Div("Daily averages — last 7 days",
                     style={"color": C_DIM, "fontSize": "12px", "marginTop": "2px"}),
        ], style={"marginBottom": "14px"}),

        # 2×2 bar chart grid
        html.Div([
            html.Div(dcc.Graph(id="week-vti",   style={"height": "260px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="week-cbi",   style={"height": "260px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="week-rmssd", style={"height": "260px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="week-lfhf",  style={"height": "260px"},
                               config={"displayModeBar": False}), style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px"}),

    ], id="content-week", style={"display": "none"}),

], style={"backgroundColor": C_BG, "padding": "14px",
          "fontFamily": "'JetBrains Mono', 'Courier New', monospace",
          "minHeight": "100vh"})


# ── navigation callback ───────────────────────────────────────────────────────
@callback(
    Output("content-live",  "style"),
    Output("content-today", "style"),
    Output("content-week",  "style"),
    Output("nav-live",  "style"),
    Output("nav-today", "style"),
    Output("nav-week",  "style"),
    Input("nav-live",  "n_clicks"),
    Input("nav-today", "n_clicks"),
    Input("nav-week",  "n_clicks"),
    prevent_initial_call=True,
)
def switch_page(_nl, _nt, _nw):
    tab = ctx.triggered_id   # "nav-live" | "nav-today" | "nav-week"
    return (
        {"display": "block"} if tab == "nav-live"  else {"display": "none"},
        {"display": "block"} if tab == "nav-today" else {"display": "none"},
        {"display": "block"} if tab == "nav-week"  else {"display": "none"},
        _nav_pill(tab == "nav-live"),
        _nav_pill(tab == "nav-today"),
        _nav_pill(tab == "nav-week"),
    )


# ── fast callback: waveforms + KPIs + status (100 ms) ────────────────────────
@callback(
    Output("ecg-graph",    "figure"),
    Output("acc-graph",    "figure"),
    Output("rr-graph",     "figure"),
    Output("kpi-bpm",      "children"),
    Output("kpi-rmssd",    "children"),
    Output("kpi-sdnn",     "children"),
    Output("kpi-breath",   "children"),
    Output("kpi-pnn50",    "children"),
    Output("kpi-lfhf",     "children"),
    Output("status-dot",   "style"),
    Output("status-label", "children"),
    Output("timer-label",  "children"),
    Input("tick-fast", "n_intervals"),
)
def update_fast(_n: int):
    ecg, acc, rr, _ = _buf.snapshot()

    # ── connection status (dict read only — no computation) ──────────────────
    state = _sensor_status["state"]
    if state == "connected":
        dot_style  = {"color": C_GOOD, "fontSize": "18px"}
        status_lbl = f"Connected · {_sensor_status['device']}"
    elif state == "searching":
        dot_style  = {"color": C_WARN, "fontSize": "18px"}
        status_lbl = "Searching for Polar H10…"
    else:
        dot_style  = {"color": C_BAD, "fontSize": "18px"}
        status_lbl = state

    elapsed = int(time.time() - _sensor_status["since"])
    timer   = f"{elapsed // 60:02d}:{elapsed % 60:02d}"

    # ── waveform figures (array slicing only — no FFT) ───────────────────────
    ecg_fig = _ecg_figure(ecg) if len(ecg) > 10 else _empty_fig("ECG  (µV)")
    acc_fig = _acc_figure(acc) if len(acc) > 10 else _empty_fig("ACC Z-axis — Breathing (mG)")
    rr_fig  = _rr_figure(rr)   if len(rr)  > 4  else _empty_fig("RR Tachogram (ms)")

    # ── KPI chips — read last values written by the slow callback ────────────
    k = _kpi_cache
    return (ecg_fig, acc_fig, rr_fig,
            k["bpm"], k["rmssd"], k["sdnn"], k["breath"], k["pnn50"], k["lfhf"],
            dot_style, status_lbl, timer)


# ── slow callback: analytics + gauges + history append (2 000 ms) ─────────────
@callback(
    Output("psd-graph",       "figure"),
    Output("coh-graph",       "figure"),
    Output("cbi-gauge",       "figure"),
    Output("vti-gauge",       "figure"),
    Output("ext-metrics",     "children"),
    Output("lfhf-live-graph", "figure"),
    Output("vlf-live-graph",  "figure"),
    Input("tick-slow", "n_intervals"),
)
def update_slow(_n: int):
    _, acc, rr, _ = _buf.snapshot()

    # Persist RR window so it survives process restarts and BLE reconnects
    if rr:
        _save_rr_window(_db, rr)

    hrv       = metrics.compute_hrv(rr)
    breathing = metrics.compute_breathing(acc)
    coh_data  = metrics.compute_coherence(rr, acc)

    cbi = metrics.compute_cbi(
        hrv["rmssd"]         if hrv       else None,
        breathing["peak_hz"] if breathing else None,
        coh_data["score"]    if coh_data  else 0.0,
    )
    vti     = hrv["vti"]       if hrv else 0.0
    vlf_val = (hrv["vlf_power"]
               if hrv and hrv["vlf_power"] is not None else None)

    # ── update KPI cache (fast callback reads this) ──────────────────────────
    _kpi_cache["bpm"]    = f"{hrv['mean_bpm']:.0f}"  if hrv       else "—"
    _kpi_cache["rmssd"]  = f"{hrv['rmssd']:.1f}"     if hrv       else "—"
    _kpi_cache["sdnn"]   = f"{hrv['sdnn']:.1f}"      if hrv       else "—"
    _kpi_cache["breath"] = f"{breathing['bpm']:.1f}" if breathing else "—"
    _kpi_cache["pnn50"]  = f"{hrv['pnn50']:.1f}"     if hrv       else "—"
    _kpi_cache["lfhf"]   = (f"{hrv['lf_hf']:.2f}"
                            if hrv and hrv["lf_hf"] is not None else "—")

    lfhf_val = hrv["lf_hf"] if hrv and hrv["lf_hf"] is not None else None

    # ── persist to SQLite (survives restarts; drives Today + Week views) ─────
    _save_metric(_db, dict(
        vti=vti,
        cbi=cbi,
        rmssd=hrv["rmssd"]          if hrv       else 0.0,
        breath_bpm=breathing["bpm"] if breathing else 0.0,
        bpm=hrv["mean_bpm"]         if hrv       else 0.0,
        lfhf=lfhf_val               if lfhf_val  else 0.0,
        vlf=vlf_val                 if vlf_val   else 0.0,
    ))

    # Persist to in-memory history for the Today view
    _history.append(
        vti=vti,
        cbi=cbi,
        rmssd=hrv["rmssd"]          if hrv       else None,
        breath_bpm=breathing["bpm"] if breathing else None,
        bpm=hrv["mean_bpm"]         if hrv       else None,
        lfhf=lfhf_val,
        vlf=vlf_val,
    )

    psd_fig = (_psd_figure(hrv)
               if hrv and hrv["psd_freqs"] is not None
               else _empty_fig("HRV Power Spectrum (Welch)"))
    coh_fig = (_coherence_figure(coh_data)
               if coh_data
               else _empty_fig("RR–Breathing Coherence"))
    cbi_fig = _cbi_gauge(cbi)
    vti_fig = _vti_gauge(vti)

    def _row(label: str, value: str, color: str = C_TEXT) -> html.Div:
        return html.Div([
            html.Span(f"{label:<14}", style={"color": C_DIM}),
            html.Span(value, style={"color": color, "fontWeight": "600"}),
        ], style={"marginBottom": "4px"})

    lf_nu_v  = f"{hrv['lf_nu']:.1f} nu"     if hrv and hrv["lf_nu"]    is not None else "—"
    hf_nu_v  = f"{hrv['hf_nu']:.1f} nu"     if hrv and hrv["hf_nu"]    is not None else "—"
    lf_abs_v  = f"{hrv['lf_power']:.2f} ms²"  if hrv and hrv["lf_power"]  is not None else "—"
    hf_abs_v  = f"{hrv['hf_power']:.2f} ms²"  if hrv and hrv["hf_power"]  is not None else "—"
    vlf_abs_v = f"{hrv['vlf_power']:.2f} ms²" if hrv and hrv["vlf_power"] is not None else "—"
    coh_v     = f"{coh_data['score']:.3f}"     if coh_data else "—"
    vti_v     = f"{vti:.3f}"                   if hrv      else "—"
    breath_hz = f"{breathing['peak_hz']:.3f} Hz" if breathing else "—"

    ext = html.Div([
        _row("VTI  ln(RMSSD)", vti_v,        C_VTI),
        _row("VLF power",      vlf_abs_v,     C_VLF),
        _row("LF power",       lf_abs_v,      C_PSD_LF),
        _row("HF power",       hf_abs_v,      C_PSD_HF),
        _row("LF norm",        lf_nu_v,       C_PSD_LF),
        _row("HF norm",        hf_nu_v,       C_PSD_HF),
        _row("Coherence",      coh_v,         C_COH),
        _row("Breath freq",    breath_hz,     C_ACC),
        _row("CBI",            f"{cbi:.3f}",  C_CBI),
    ])

    snap          = _history.snapshot()
    lfhf_live_fig = _lfhf_live_fig(snap)
    vlf_live_fig  = _vlf_live_fig(snap)

    return psd_fig, coh_fig, cbi_fig, vti_fig, ext, lfhf_live_fig, vlf_live_fig


# ── today view callback (5 000 ms) ────────────────────────────────────────────
@callback(
    Output("today-avg-vti",      "children"),
    Output("today-peak-cbi",     "children"),
    Output("today-avg-rmssd",    "children"),
    Output("today-avg-breath",   "children"),
    Output("today-avg-lfhf",     "children"),
    Output("today-session-time", "children"),
    Output("today-vti",          "figure"),
    Output("today-cbi",          "figure"),
    Output("today-rmssd",        "figure"),
    Output("today-breath",       "figure"),
    Output("today-lfhf",         "figure"),
    Input("tick-today", "n_intervals"),
)
def update_today(_n: int):
    records = _history.snapshot()

    if not records:
        ef = _empty_fig
        return ("—", "—", "—", "—", "—", "No data yet — start recording",
                ef("Vagal Tone Index  —  ln(RMSSD)"),
                ef("Conscious Breathing Index"),
                ef("RMSSD"),
                ef("Breathing Rate"),
                ef("LF / HF Ratio  (sympathetic balance)"))

    # Summary aggregates (exclude zero-padded gaps)
    vti_vals    = [r["vti"]        for r in records if r["vti"]        > 0]
    cbi_vals    = [r["cbi"]        for r in records]
    rmssd_vals  = [r["rmssd"]      for r in records if r["rmssd"]      > 0]
    breath_vals = [r["breath_bpm"] for r in records if r["breath_bpm"] > 0]
    lfhf_vals   = [r["lfhf"]       for r in records if r["lfhf"]       > 0]

    avg_vti    = f"{np.mean(vti_vals):.2f}"    if vti_vals    else "—"
    peak_cbi   = f"{max(cbi_vals):.2f}"         if cbi_vals    else "—"
    avg_rmssd  = f"{np.mean(rmssd_vals):.1f}"  if rmssd_vals  else "—"
    avg_breath = f"{np.mean(breath_vals):.1f}" if breath_vals else "—"
    avg_lfhf   = f"{np.mean(lfhf_vals):.2f}"  if lfhf_vals   else "—"

    dur_s   = len(records) * 2
    session = f"Duration  {dur_s // 60} min {dur_s % 60} s  ·  {len(records)} data points"

    return (avg_vti, peak_cbi, avg_rmssd, avg_breath, avg_lfhf, session,
            _vti_trend(records), _cbi_trend(records),
            _rmssd_trend(records), _breath_trend(records),
            _lfhf_trend(records))


# ── week view callback (5 000 ms) ─────────────────────────────────────────────
@callback(
    Output("week-vti",   "figure"),
    Output("week-cbi",   "figure"),
    Output("week-rmssd", "figure"),
    Output("week-lfhf",  "figure"),
    Input("tick-today",  "n_intervals"),
)
def update_week(_n: int):
    days = _load_week(_db)
    return (
        _week_bar(days, "vti",   "Vagal Tone Index — Daily Average",       C_VTI,  ""),
        _week_bar(days, "cbi",   "Conscious Breathing Index — Daily Average", C_CBI, ""),
        _week_bar(days, "rmssd", "RMSSD — Daily Average",                   C_ACC,  "ms"),
        _week_bar(days, "lfhf",  "LF / HF Ratio — Daily Average",           C_LFHF, ""),
    )


# ── entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    _start_ble(_buf)
    print("Just Breathe dashboard → http://127.0.0.1:8050")
    print("Put on your Polar H10.  Ctrl-C to quit.\n")
    app.run(debug=False, use_reloader=False, host="127.0.0.1", port=8050)
