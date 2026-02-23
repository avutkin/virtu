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
import traceback
from collections import deque
from datetime import datetime, timezone

import numpy as np
import dash
from dash import dcc, html, Input, Output, State, callback, ctx
import plotly.graph_objects as go

import metrics
from polar import PolarH10
from bleak import BleakScanner
from blink import BlinkDetector

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
C_BLINK     = "#2dd4bf"   # teal — eye blink
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
    )
    # use add_annotation — update_layout(annotations=[...]) removed in Plotly 6
    fig.add_annotation(
        text="waiting for data…", x=0.5, y=0.5,
        showarrow=False, xref="paper", yref="paper",
        font=dict(color=C_DIM, size=13),
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
    conn.execute("PRAGMA journal_mode=DELETE")  # no WAL sidecar files — safer under kill -9
    conn.executescript(_CREATE_METRICS)
    # Add columns to existing databases that predate them
    for col in ("vlf REAL DEFAULT 0", "mean_ie REAL DEFAULT 0"):
        try:
            conn.execute(f"ALTER TABLE biometric_metrics ADD COLUMN {col}")
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
        "(ts, ts_date, vti, cbi, rmssd, breath_bpm, bpm, lfhf, vlf, mean_ie) "
        "VALUES (?,?,?,?,?,?,?,?,?,?)",
        (now.isoformat(), now.strftime("%Y-%m-%d"),
         rec["vti"], rec["cbi"], rec["rmssd"],
         rec["breath_bpm"], rec["bpm"], rec["lfhf"], rec["vlf"], rec["mean_ie"]),
    )
    conn.commit()

def _load_today(conn: sqlite3.Connection) -> list[dict]:
    today = datetime.now().strftime("%Y-%m-%d")
    cur = conn.execute(
        "SELECT ts, vti, cbi, rmssd, breath_bpm, bpm, lfhf, vlf, mean_ie "
        "FROM biometric_metrics WHERE ts_date=? ORDER BY ts",
        (today,),
    )
    return [
        dict(t=row[0][11:16], vti=row[1], cbi=row[2], rmssd=row[3],
             breath_bpm=row[4], bpm=row[5], lfhf=row[6], vlf=row[7] or 0.0,
             mean_ie=row[8] or 0.0)
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
               lfhf: float | None, vlf: float | None,
               mean_ie: float | None = None) -> None:
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
                mean_ie=round(mean_ie, 2)       if mean_ie    is not None else 0.0,
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
        super().__init__(_target_device.get("name") or "Polar H10")
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
_db_lock       = threading.Lock()            # serialize all SQLite access across callbacks
_buf.preload_rr(_load_rr_window(_db))        # warm up RR buffer from last session
_history       = MetricsHistory()
_history.preload(_load_today(_db))           # restore today's charts across restarts
_sensor_status = {"state": "searching", "device": "", "since": time.time()}

# ── eye blink detector ────────────────────────────────────────────────────────
_blink = BlinkDetector()
_blink_rate_history: deque[dict] = deque(maxlen=2700)  # ≈ 90 min at 2 s cadence

# Recording toggle — when False, metrics are not saved to SQLite / history.
# Live waveforms and gauges still update so you can monitor without recording.
_measuring: dict = {"active": True}

# Last KPI values written by the slow callback, read by the fast callback.
# Avoids running Welch PSD in the 200 ms loop.
_kpi_cache: dict = {
    "bpm": "—", "rmssd": "—", "sdnn": "—",
    "breath": "—", "regularity": "—", "lfhf": "—",
}

# ── BLE scan + device-selection state ────────────────────────────────────────
_scan_state: dict  = {"status": "idle", "devices": [], "error": ""}
_target_device: dict = {"address": None, "name": "Polar H10"}
_ble_reconnect = threading.Event()  # set to interrupt keep-alive and reconnect


def _run_ble_scan() -> None:
    """Discover nearby BLE devices (8 s) in a daemon thread; populates _scan_state."""
    _scan_state.update(status="scanning", devices=[], error="")
    loop = asyncio.new_event_loop()
    try:
        found = loop.run_until_complete(BleakScanner.discover(timeout=8.0))
        _scan_state["devices"] = sorted(
            [{"name": d.name or "(unknown)", "address": d.address, "rssi": d.rssi or 0}
             for d in found],
            key=lambda x: -(x["rssi"] or -999),
        )
        _scan_state["status"] = "done"
    except Exception as exc:
        _scan_state["error"] = str(exc)
        _scan_state["status"] = "error"
    finally:
        loop.close()


def _start_ble(buf: DataBuffer) -> None:
    def _thread() -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        async def _run() -> None:
            delay = 0   # no wait on first attempt
            while True:
                # Interruptible delay between retries — wakes early on reconnect request
                for _ in range(delay * 2):
                    await asyncio.sleep(0.5)
                    if _ble_reconnect.is_set():
                        break
                _ble_reconnect.clear()
                delay = 5   # default retry wait after first attempt

                sensor = LivePolarH10(buf)
                addr = _target_device.get("address")
                try:
                    _sensor_status["state"] = (
                        f"connecting to {addr[:17]}…" if addr else "searching…"
                    )
                    await sensor.connect(timeout=20.0, device_address=addr)
                    _sensor_status.update(state="connected",
                                          device=sensor._device_label,
                                          since=time.time())
                    await sensor.start_streams()
                    # keep-alive: poll every 0.5 s for a user-requested reconnect
                    while not _ble_reconnect.is_set():
                        await asyncio.sleep(0.5)
                    _ble_reconnect.clear()
                    delay = 0   # user-requested → reconnect immediately
                except RuntimeError:
                    _sensor_status["state"] = (
                        "not found — check power / Bluetooth permission, retrying…"
                    )
                except Exception as exc:
                    _sensor_status["state"] = f"error: {str(exc)[:60]} — retrying…"
                finally:
                    try:
                        await sensor.stop_streams()
                        await sensor.disconnect()
                    except Exception:
                        pass

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
                  annotation_position="top left")
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
        domain=dict(x=[0, 1], y=[0, 1]),   # required in Plotly 6 / plotly.js 3
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


# ── Breathing phase figure helpers ───────────────────────────────────────────
def _vagal_label(ie: float) -> tuple[str, str]:
    """Return (text, colour) annotation for a given I:E ratio."""
    if ie >= 2.0:
        return f"I:E  1 : {ie:.2f}  ·  strong vagal activation",    C_GOOD
    if ie >= 1.5:
        return f"I:E  1 : {ie:.2f}  ·  vagal activation",           C_ACC
    if ie >= 1.0:
        return f"I:E  1 : {ie:.2f}  ·  balanced",                   C_WARN
    return     f"I:E  1 : {ie:.2f}  ·  extend exhale for vagal tone", C_BAD


def _breath_wave_fig(phases: dict | None) -> go.Figure:
    """
    Filtered breathing waveform with inhale (blue) / exhale (green) phase bands.

    Width of each band = duration.  Height of the waveform within the band = depth.
    An annotation in the top-right corner shows the mean I:E ratio and
    its interpretation for vagus nerve regulation.
    """
    TITLE = "Breathing Phases  ·  last 30 s  (■ inhale  ■ exhale)"
    if phases is None:
        return _empty_fig(TITLE)

    sig = np.array(phases['filtered'])
    t   = np.array(phases['filtered_t'])
    t0  = float(t[0])

    fig = go.Figure()

    # Shade inhale and exhale regions
    for b in phases['breaths']:
        ti0, ti1, te1 = b['t_inhale_start'], b['t_inhale_end'], b['t_exhale_end']
        if ti1 >= t0:
            fig.add_vrect(x0=max(ti0, t0), x1=ti1,
                          fillcolor="rgba(88,166,255,0.18)", line_width=0)
        if te1 >= t0:
            fig.add_vrect(x0=max(ti1, t0), x1=te1,
                          fillcolor="rgba(86,211,100,0.18)", line_width=0)

    # Breathing waveform
    fig.add_trace(go.Scatter(
        x=t, y=sig, mode='lines',
        line=dict(color=C_TEXT, width=1.5),
        hoverinfo='skip', showlegend=False,
    ))

    # Legend ghosts
    fig.add_trace(go.Scatter(x=[None], y=[None], mode='lines',
                             line=dict(color=C_RR,  width=10, dash='solid'),
                             name='inhale', showlegend=True))
    fig.add_trace(go.Scatter(x=[None], y=[None], mode='lines',
                             line=dict(color=C_ACC, width=10, dash='solid'),
                             name='exhale', showlegend=True))

    label, col = _vagal_label(phases['mean_ie'])
    fig.add_annotation(
        x=0.99, y=0.97, xref='paper', yref='paper',
        text=label, showarrow=False, align='right',
        font=dict(color=col, size=11, family="'JetBrains Mono', monospace"),
        bgcolor="rgba(22,27,34,0.85)", bordercolor=col, borderwidth=1, borderpad=5,
    )

    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision="breath-wave",
        title=dict(text=TITLE, font=dict(color=C_DIM, size=12), x=0.01),
        xaxis=_ax("seconds"),
        yaxis=_ax("amplitude (filtered mG)"),
        legend=dict(font=dict(size=10, color=C_DIM), bgcolor="rgba(0,0,0,0)",
                    orientation='h', x=0.01, y=0.05),
    )
    return fig


def _ie_ratio_fig(phases: dict | None) -> go.Figure:
    """
    Per-breath grouped bar chart: inhale duration (blue) vs exhale duration (green).

    Reference lines show the exhale length needed for mild (1.5×) and strong (2×)
    vagal activation relative to the mean inhale duration.
    """
    TITLE = "Inhale · Exhale Duration  per breath  (s)"
    if phases is None or not phases.get('breaths'):
        return _empty_fig(TITLE)

    breaths = phases['breaths']
    labels  = [f"#{i + 1}" for i in range(len(breaths))]
    inh     = [b['inhale_dur'] for b in breaths]
    exh     = [b['exhale_dur'] for b in breaths]

    # Colour each exhale bar: green when ≥ 1.5 × inhale, amber otherwise
    exh_colors = [
        C_ACC if b['ie_ratio'] >= 1.5 else C_WARN
        for b in breaths
    ]

    fig = go.Figure()
    fig.add_trace(go.Bar(
        name='inhale', x=labels, y=inh,
        marker_color=C_RR,
        hovertemplate="inhale  %{y:.1f} s<extra></extra>",
    ))
    fig.add_trace(go.Bar(
        name='exhale', x=labels, y=exh,
        marker_color=exh_colors,
        hovertemplate="exhale  %{y:.1f} s<extra></extra>",
    ))

    # Vagal activation reference lines (relative to mean inhale)
    mi = phases['mean_inhale']
    fig.add_hline(y=mi * 1.5, line_dash='dot', line_color=C_WARN, line_width=1,
                  annotation_text="1.5× inhale  mild vagal",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_WARN))
    fig.add_hline(y=mi * 2.0, line_dash='dot', line_color=C_GOOD, line_width=1,
                  annotation_text="2× inhale  strong vagal",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_GOOD))

    subtitle = (f"avg  ↑{phases['mean_inhale']:.1f} s  "
                f"↓{phases['mean_exhale']:.1f} s  ·  I:E 1:{phases['mean_ie']:.2f}")
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision="ie-ratio",
        barmode='group',
        title=dict(text=f"{TITLE}  ·  {subtitle}",
                   font=dict(color=C_DIM, size=12), x=0.01),
        xaxis=_ax("breath"),
        yaxis=_ax("seconds", rangemode="tozero"),
        legend=dict(font=dict(size=10, color=C_DIM), bgcolor="rgba(0,0,0,0)",
                    x=0.98, xanchor='right', y=0.98),
    )
    return fig


def _blink_rate_fig(history: list[dict], minutes: int = 60) -> go.Figure:
    """
    Rolling blink rate trend with attention-state reference zones.

    Normal range  : 12–20 blinks/min (green)
    Focused zone  : 5–12 blinks/min  (amber — less blinking, eye strain risk)
    Eye strain    : < 5 blinks/min   (red)
    Elevated      : > 20 blinks/min  (amber — fatigue / irritation)
    """
    TITLE = f"Eye Blink Rate  ·  last {_range_label(minutes)}  ·  blinks / min"
    n = minutes * 30
    window = history[-n:] if len(history) > n else history
    if not window:
        return _empty_fig(TITLE)

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("rate", 0)
        if v > 0:
            buckets.setdefault(r["t"], []).append(v)
    if not buckets:
        return _empty_fig(TITLE)

    ts    = list(buckets.keys())
    vals  = [float(np.mean(v)) for v in buckets.values()]
    max_y = max(max(vals) * 1.15, 25.0)

    fig = go.Figure()
    fig.add_hrect(y0=0,    y1=5,     fillcolor="rgba(248,81,73,0.10)",  line_width=0)
    fig.add_hrect(y0=5,    y1=12,    fillcolor="rgba(210,153,34,0.08)", line_width=0)
    fig.add_hrect(y0=12,   y1=20,    fillcolor="rgba(63,185,80,0.08)",  line_width=0)
    fig.add_hrect(y0=20,   y1=max_y, fillcolor="rgba(210,153,34,0.08)", line_width=0)

    fig.add_trace(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_BLINK, width=2),
        marker=dict(size=3, color=C_BLINK),
        hovertemplate="%{x}  %{y:.1f} blinks/min<extra></extra>",
    ))

    fig.add_hline(y=20, line_dash="dash", line_color=C_WARN, line_width=1,
                  annotation_text="elevated  > 20",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_WARN))
    fig.add_hline(y=12, line_dash="dot",  line_color=C_GOOD, line_width=1,
                  annotation_text="normal  12–20",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_GOOD))
    fig.add_hline(y=5,  line_dash="dash", line_color=C_BAD,  line_width=1,
                  annotation_text="eye strain risk  < 5",
                  annotation_position="bottom right",
                  annotation_font=dict(size=10, color=C_BAD))

    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"blink-rate-{minutes}",
        title=dict(text=TITLE, font=dict(color=C_BLINK, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("blinks / min", range=[0, max_y]),
    )
    return fig


def _blink_ibi_fig(ibis: list[float]) -> go.Figure:
    """
    Inter-Blink Interval tachogram — each point is the gap between two blinks.

    Short IBIs = frequent blinking (relaxed / distracted).
    Long IBIs  = infrequent blinking (deep focus / dry eyes).
    High BRV   = irregular blink rhythm → attention fluctuation.
    Low BRV    = steady blink rhythm → sustained focus.
    """
    TITLE = "Inter-Blink Intervals  ·  blink rhythm & attention variability"
    if not ibis:
        return _empty_fig(TITLE)

    fig = go.Figure(go.Scatter(
        x=list(range(1, len(ibis) + 1)), y=ibis,
        mode="lines+markers",
        line=dict(color=C_BLINK, width=1.5),
        marker=dict(size=4, color=C_BLINK),
        hovertemplate="blink #%{x}  IBI = %{y:.2f} s<extra></extra>",
    ))

    mean_ibi = float(np.mean(ibis))
    brv      = float(np.std(ibis)) if len(ibis) >= 3 else 0.0

    fig.add_hline(y=mean_ibi, line_dash="dot", line_color=C_DIM, line_width=1,
                  annotation_text=f"avg {mean_ibi:.1f} s  BRV={brv:.2f}",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_DIM))

    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision="blink-ibi",
        title=dict(text=TITLE, font=dict(color=C_BLINK, size=12), x=0.01),
        xaxis=_ax("blink #"),
        yaxis=_ax("seconds", rangemode="tozero"),
    )
    return fig


def _ie_trend_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """
    Rolling I:E ratio trend with vagal activation reference bands.

    I:E ≥ 2.0  → strong vagal (green)
    I:E ≥ 1.5  → mild vagal   (amber)
    I:E < 1.0  → inhale-dominant (red zone)
    """
    TITLE = "Breathing I:E Ratio  —  exhale / inhale  ·  1 min avg"
    n = minutes * 30
    window = records[-n:] if len(records) > n else records
    if not window:
        return _empty_fig(TITLE)

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("mean_ie", 0)
        if v > 0:
            key = r["t"]
            if key not in buckets:
                buckets[key] = []
            buckets[key].append(v)

    if not buckets:
        return _empty_fig(TITLE)

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]
    max_y = max(max(vals) * 1.15, 2.2)

    fig = go.Figure()

    # Background zones
    fig.add_hrect(y0=0,   y1=1.0, fillcolor="rgba(248,81,73,0.07)",  line_width=0)
    fig.add_hrect(y0=1.0, y1=1.5, fillcolor="rgba(210,153,34,0.07)", line_width=0)
    fig.add_hrect(y0=1.5, y1=2.0, fillcolor="rgba(63,185,80,0.07)",  line_width=0)
    fig.add_hrect(y0=2.0, y1=max_y, fillcolor="rgba(63,185,80,0.12)", line_width=0)

    fig.add_trace(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_ACC, width=2),
        marker=dict(size=3, color=C_ACC),
        hovertemplate="%{x}  I:E 1:%{y:.2f}<extra></extra>",
    ))

    fig.add_hline(y=2.0, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="strong vagal  ≥ 2.0",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_GOOD))
    fig.add_hline(y=1.5, line_dash="dot",  line_color=C_WARN, line_width=1,
                  annotation_text="mild vagal  ≥ 1.5",
                  annotation_position="top right",
                  annotation_font=dict(size=10, color=C_WARN))
    fig.add_hline(y=1.0, line_dash="dot",  line_color=C_BAD,  line_width=1,
                  annotation_text="balanced  1.0",
                  annotation_position="bottom right",
                  annotation_font=dict(size=10, color=C_BAD))

    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"ie-trend-{minutes}",
        title=dict(
            text=f"Breathing I:E Ratio  —  exhale / inhale  ·  last {_range_label(minutes)}  ·  1 min avg",
            font=dict(color=C_ACC, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("I:E ratio", range=[0, max_y]),
    )
    return fig


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


def _vti_zones(fig: go.Figure) -> go.Figure:
    """Overlay sympathetic / balanced / parasympathetic zone bands onto a VTI figure."""
    fig.add_hrect(y0=0,   y1=2.5, fillcolor="rgba(248,81,73,0.08)",   line_width=0,
                  annotation_text="sympathetic",     annotation_position="top left",
                  annotation_font=dict(color=C_BAD,  size=10))
    fig.add_hrect(y0=2.5, y1=3.5, fillcolor="rgba(210,153,34,0.08)",  line_width=0,
                  annotation_text="balanced",        annotation_position="top left",
                  annotation_font=dict(color=C_WARN, size=10))
    fig.add_hrect(y0=3.5, y1=6.0, fillcolor="rgba(63,185,80,0.08)",   line_width=0,
                  annotation_text="parasympathetic", annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hline(y=3.5, line_dash="dash", line_color=C_GOOD, line_width=1)
    fig.add_hline(y=2.5, line_dash="dash", line_color=C_BAD,  line_width=1)
    return fig


def _range_label(minutes: int) -> str:
    return f"{minutes // 60} h" if minutes >= 60 else f"{minutes} min"


def _rbtn_style(active: bool, color: str) -> dict:
    return {
        "backgroundColor": color if active else "transparent",
        "color": "#0d1117" if active else C_DIM,
        "border": f"1px solid {color if active else C_BORDER}",
        "borderRadius": "10px",
        "padding": "2px 10px",
        "fontSize": "10px",
        "fontWeight": "700",
        "letterSpacing": "1px",
        "cursor": "pointer",
        "fontFamily": "'JetBrains Mono', monospace",
    }


def _range_btn_group(store_id: str, b60: str, b120: str, b720: str,
                     color: str) -> html.Div:
    return html.Div([
        dcc.Store(id=store_id, data="60"),
        html.Button("60 m", id=b60,  n_clicks=0, style=_rbtn_style(True,  color)),
        html.Button("2 h",  id=b120, n_clicks=0, style=_rbtn_style(False, color)),
        html.Button("12 h", id=b720, n_clicks=0, style=_rbtn_style(False, color)),
    ], style={"display": "flex", "gap": "4px"})


def _vti_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """VTI rolling chart with ANS zone bands.  minutes controls the window."""
    n = minutes * 30   # 30 records/min at 2 s cadence
    window = records[-n:] if len(records) > n else records
    if not window:
        return _vti_zones(_empty_fig("Vagal Tone Index  —  ln(RMSSD)"))

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("vti", 0)
        if v > 0:
            key = r["t"]
            if key not in buckets:
                buckets[key] = []
            buckets[key].append(v)

    if not buckets:
        return _vti_zones(_empty_fig("Vagal Tone Index  —  ln(RMSSD)"))

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_VTI, width=2),
        marker=dict(size=3, color=C_VTI),
        hovertemplate="%{x}  VTI %{y:.3f}<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"vti-live-{minutes}",
        title=dict(text=f"Vagal Tone Index  —  ln(RMSSD)  ·  last {_range_label(minutes)}  ·  1 min avg",
                   font=dict(color=C_VTI, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("VTI", range=[0, 5.5]),
    )
    return _vti_zones(fig)


def _vti_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "vti", "Vagal Tone Index  —  ln(RMSSD)", C_VTI, "")
    fig.update_layout(yaxis=dict(range=[0, 5.5]))
    return _vti_zones(fig)


def _cbi_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "cbi", "Conscious Breathing Index", C_CBI, "")


def _rmssd_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "rmssd", "RMSSD", C_ACC, "ms")


def _breath_trend(records: list[dict]) -> go.Figure:
    return _trend_fig(records, "breath_bpm", "Breathing Rate", C_PSD_HF, "br/min")


C_LFHF = "#e8a838"   # warm amber — distinct from LF (blue) and HF (orange)

def _lfhf_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """LF/HF line chart — configurable window, 1-minute averages."""
    n = minutes * 30
    window = records[-n:] if len(records) > n else records
    if not window:
        return _empty_fig("LF / HF Ratio")

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
    fig.add_hline(y=2.0, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="sympathetic  > 2",
                  annotation_position="top right")
    fig.add_hline(y=0.5, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="balanced  0.5 – 2",
                  annotation_position="bottom right")
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"lfhf-live-{minutes}",
        title=dict(text=f"LF / HF Ratio  ·  last {_range_label(minutes)}  ·  1 min avg",
                   font=dict(color=C_LFHF, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("ratio", rangemode="tozero"),
    )
    return fig


def _lfhf_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "lfhf", "LF / HF Ratio  (sympathetic balance)", C_LFHF, "")
    fig.add_hline(y=2.0, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="sympathetic  > 2",
                  annotation_position="top right")
    fig.add_hline(y=0.5, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="balanced  0.5 – 2",
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
                  annotation_position="bottom right")
    fig.add_hline(y=100, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 100",
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
    dcc.Interval(id="tick-scan",   interval=500,   n_intervals=0, disabled=True),
    dcc.Interval(id="tick-minute", interval=1000,  n_intervals=0),
    dcc.Store(id="measure-store", data="recording"),

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

        # Connection status + session timer + device scanner toggle
        html.Div([
            html.Span(id="status-label", children="Searching for Polar H10…",
                      style={"color": C_DIM, "fontSize": "12px"}),
            html.Span("  ·  ", style={"color": C_BORDER}),
            html.Span(id="timer-label", children="00:00",
                      style={"color": C_DIM, "fontSize": "12px",
                             "fontFamily": "'JetBrains Mono', monospace"}),
            html.Span("  ·  ", style={"color": C_BORDER}),
            html.Button("⏹ STOP REC", id="btn-measure-toggle", n_clicks=0,
                        style={
                            "backgroundColor": "transparent",
                            "color": C_BAD,
                            "border": f"1px solid {C_BAD}",
                            "borderRadius": "12px",
                            "padding": "4px 14px",
                            "fontSize": "10px",
                            "fontWeight": "700",
                            "letterSpacing": "1px",
                            "cursor": "pointer",
                            "fontFamily": "'JetBrains Mono', monospace",
                        }),
            html.Span("  ·  ", style={"color": C_BORDER}),
            html.Button("⊕ DEVICES", id="btn-scan-toggle", n_clicks=0,
                        style={
                            "backgroundColor": "transparent",
                            "color": C_DIM,
                            "border": f"1px solid {C_BORDER}",
                            "borderRadius": "12px",
                            "padding": "4px 14px",
                            "fontSize": "10px",
                            "fontWeight": "700",
                            "letterSpacing": "1px",
                            "cursor": "pointer",
                            "fontFamily": "'JetBrains Mono', monospace",
                        }),
        ], style={"display": "flex", "alignItems": "center", "gap": "0px"}),
    ], style={**_CARD, "display": "flex", "justifyContent": "space-between",
              "alignItems": "center", "marginBottom": "10px"}),

    # ── Device scanner panel (hidden by default, toggled by ⊕ DEVICES) ────────
    html.Div([

        # Header row: title | scan controls | action buttons
        html.Div([
            html.Span("BLUETOOTH DEVICES",
                      style={"color": C_TEXT, "fontSize": "11px", "fontWeight": "700",
                             "letterSpacing": "2px",
                             "fontFamily": "'JetBrains Mono', monospace"}),
            html.Div([
                html.Button("SCAN  8 s", id="btn-scan-start", n_clicks=0, style={
                    "backgroundColor": C_BORDER,
                    "color": C_TEXT,
                    "border": "none",
                    "borderRadius": "6px",
                    "padding": "5px 14px",
                    "fontSize": "10px",
                    "fontWeight": "700",
                    "letterSpacing": "1px",
                    "cursor": "pointer",
                    "fontFamily": "'JetBrains Mono', monospace",
                }),
                html.Span(id="scan-status",
                          children="Press SCAN to discover nearby Bluetooth devices",
                          style={"color": C_DIM, "fontSize": "11px", "fontStyle": "italic"}),
            ], style={"display": "flex", "gap": "10px", "alignItems": "center"}),
            html.Div([
                html.Button("CONNECT", id="btn-connect", n_clicks=0, style={
                    "backgroundColor": C_NAV_ACT,
                    "color": "#0d1117",
                    "border": "none",
                    "borderRadius": "6px",
                    "padding": "5px 18px",
                    "fontSize": "10px",
                    "fontWeight": "700",
                    "letterSpacing": "1px",
                    "cursor": "pointer",
                    "fontFamily": "'JetBrains Mono', monospace",
                }),
                html.Button("↺ RESET", id="btn-reset-device", n_clicks=0, style={
                    "backgroundColor": "transparent",
                    "color": C_DIM,
                    "border": f"1px solid {C_BORDER}",
                    "borderRadius": "6px",
                    "padding": "5px 12px",
                    "fontSize": "10px",
                    "fontWeight": "700",
                    "letterSpacing": "1px",
                    "cursor": "pointer",
                    "fontFamily": "'JetBrains Mono', monospace",
                }),
            ], style={"display": "flex", "gap": "8px", "alignItems": "center"}),
        ], style={"display": "flex", "justifyContent": "space-between",
                  "alignItems": "center", "marginBottom": "12px"}),

        # Device list — populated by poll_scan callback
        # ★ = Polar device, auto-selected; sorted by RSSI (strongest first)
        dcc.RadioItems(
            id="device-radio",
            options=[],
            value=None,
            inputStyle={
                "marginRight": "8px",
                "accentColor": C_NAV_ACT,
                "width": "14px", "height": "14px",
                "cursor": "pointer",
            },
            labelStyle={
                "display": "block",
                "padding": "6px 8px",
                "cursor": "pointer",
                "fontFamily": "'JetBrains Mono', monospace",
                "color": C_TEXT,
                "fontSize": "12px",
                "whiteSpace": "pre",          # preserve spaces used for alignment
                "borderBottom": f"1px solid {C_BORDER}",
            },
            style={
                "maxHeight": "220px",
                "overflowY": "auto",
                "backgroundColor": C_BG,
                "borderRadius": "6px",
                "border": f"1px solid {C_BORDER}",
                "padding": "2px 0",
            },
        ),

        # Feedback line
        html.Div(
            html.Span(id="connect-feedback", children="",
                      style={"color": C_DIM, "fontSize": "11px", "fontStyle": "italic"}),
            style={"marginTop": "8px", "minHeight": "18px"},
        ),

    ], id="device-panel",
       style={"display": "none", **_CARD, "marginBottom": "10px"}),

    # ══════════════════════════ LIVE view ═════════════════════════════════════
    html.Div([

        # Row 1 — KPI chips
        html.Div([
            _kpi_card("kpi-bpm",    "Heart Rate",  C_ECG,    "bpm"),
            _kpi_card("kpi-rmssd",  "RMSSD",       C_ACC,    "ms"),
            _kpi_card("kpi-sdnn",   "SDNN",        C_RR,     "ms"),
            _kpi_card("kpi-breath", "Breathing",   C_PSD_HF, "br/m"),
            _kpi_card("kpi-regularity", "Regularity", C_COH,   ""),
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
            html.Div([
                html.Div(_range_btn_group("lfhf-range-store",
                                         "lfhf-btn-60", "lfhf-btn-120", "lfhf-btn-720",
                                         C_LFHF),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="lfhf-live-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
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
                html.Pre(id="ext-metrics",
                         style={"fontFamily": "'JetBrains Mono', monospace",
                                "fontSize": "12px", "color": C_TEXT, "lineHeight": "1.8",
                                "whiteSpace": "pre-wrap", "margin": "0"}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 5 — Breathing phases (waveform + I:E bar chart)
        html.Div([
            html.Div(dcc.Graph(id="breath-wave-graph", style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
            html.Div(dcc.Graph(id="ie-ratio-graph", style={"height": "220px"},
                               config={"displayModeBar": False}), style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "2fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 6 — I:E ratio trend (full width)
        html.Div([
            html.Div(_range_btn_group("ie-range-store",
                                     "ie-btn-60", "ie-btn-120", "ie-btn-720",
                                     C_ACC),
                     style={"display": "flex", "justifyContent": "flex-end",
                            "marginBottom": "4px"}),
            dcc.Graph(id="ie-trend-graph", style={"height": "185px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # Row 7 — VTI live trend (full width)
        html.Div([
            html.Div(_range_btn_group("vti-range-store",
                                     "vti-btn-60", "vti-btn-120", "vti-btn-720",
                                     C_VTI),
                     style={"display": "flex", "justifyContent": "flex-end",
                            "marginBottom": "4px"}),
            dcc.Graph(id="vti-live-graph", style={"height": "220px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # Row 8 — index gauges
        html.Div([
            html.Div([
                html.Div("Conscious Breathing Index",
                         style={"color": C_DIM, "fontSize": "11px",
                                "textTransform": "uppercase", "letterSpacing": "1px",
                                "marginBottom": "2px"}),
                html.Div("Peak coherence 35% · regularity 25% · frequency 25% · RMSSD 15%",
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

        # ── Eye Blink Monitoring ──────────────────────────────────────────────
        html.Div([

            # Sub-header
            html.Div([
                html.Span("👁  EYE BLINK MONITORING",
                          style={"color": C_BLINK, "fontSize": "11px",
                                 "fontWeight": "700", "letterSpacing": "2px",
                                 "fontFamily": "'JetBrains Mono', monospace"}),
                html.Span(id="blink-status",
                          children="initializing…",
                          style={"color": C_DIM, "fontSize": "11px",
                                 "fontStyle": "italic"}),
            ], style={"display": "flex", "justifyContent": "space-between",
                      "alignItems": "center", "marginBottom": "10px"}),

            # KPI row
            html.Div([
                _kpi_card("kpi-blink-rate", "Blink Rate",       C_BLINK, "/min"),
                _kpi_card("kpi-brv",        "Blink Variability", C_BLINK, "s BRV"),
                _kpi_card("kpi-ear",        "Eye Aspect Ratio",  C_DIM,   ""),
            ], style={"display": "grid", "gridTemplateColumns": "repeat(3, 1fr)",
                      "gap": "10px", "marginBottom": "10px"}),

            # Camera previews (updated once per minute)
            html.Div([
                html.Div([
                    html.Div("EYE OPEN  — last capture",
                             style={"color": C_DIM, "fontSize": "10px",
                                    "textTransform": "uppercase", "letterSpacing": "1px",
                                    "marginBottom": "6px"}),
                    html.Img(id="eye-open-img", src="",
                             style={"width": "100%", "maxHeight": "160px",
                                    "objectFit": "contain", "borderRadius": "4px",
                                    "display": "block", "backgroundColor": C_BG,
                                    "minHeight": "100px"}),
                ], style=_CARD),
                html.Div([
                    html.Div("BLINK  — last detected",
                             style={"color": C_DIM, "fontSize": "10px",
                                    "textTransform": "uppercase", "letterSpacing": "1px",
                                    "marginBottom": "6px"}),
                    html.Img(id="eye-closed-img", src="",
                             style={"width": "100%", "maxHeight": "160px",
                                    "objectFit": "contain", "borderRadius": "4px",
                                    "display": "block", "backgroundColor": C_BG,
                                    "minHeight": "100px"}),
                ], style=_CARD),
            ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                      "gap": "10px", "marginBottom": "10px"}),

            # Charts
            html.Div([
                html.Div([
                    html.Div(_range_btn_group("blink-range-store",
                                             "blink-btn-60", "blink-btn-120",
                                             "blink-btn-720", C_BLINK),
                             style={"display": "flex", "justifyContent": "flex-end",
                                    "marginBottom": "4px"}),
                    dcc.Graph(id="blink-rate-graph", style={"height": "200px"},
                              config={"displayModeBar": False}),
                ], style=_CARD),
                html.Div(dcc.Graph(id="blink-ibi-graph", style={"height": "220px"},
                                   config={"displayModeBar": False}),
                         style=_CARD),
            ], style={"display": "grid", "gridTemplateColumns": "2fr 1fr",
                      "gap": "10px"}),

        ], style={**_CARD, "marginTop": "10px",
                  "borderTop": f"3px solid {C_BLINK}"}),

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
    Output("kpi-regularity", "children"),
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
            k["bpm"], k["rmssd"], k["sdnn"], k["breath"], k["regularity"], k["lfhf"],
            dot_style, status_lbl, timer)


_SAFE_FIG: dict = {
    "data": [],
    "layout": {"paper_bgcolor": C_CARD, "plot_bgcolor": C_CARD,
               "font": {"color": C_TEXT}, "xaxis": {"visible": False},
               "yaxis": {"visible": False}},
}


# ── slow callback: analytics + gauges + history append (2 000 ms) ─────────────
@callback(
    Output("psd-graph",         "figure"),
    Output("coh-graph",         "figure"),
    Output("cbi-gauge",         "figure"),
    Output("vti-gauge",         "figure"),
    Output("ext-metrics",       "children"),
    Output("vlf-live-graph",    "figure"),
    Output("breath-wave-graph", "figure"),
    Output("ie-ratio-graph",    "figure"),
    Input("tick-slow", "n_intervals"),
)
def update_slow(_n: int):
    _ef = _empty_fig
    try:
        _, acc, rr, _ = _buf.snapshot()

        # Persist RR window so it survives process restarts and BLE reconnects
        if rr:
            try:
                with _db_lock:
                    _save_rr_window(_db, rr)
            except Exception:
                pass

        hrv       = metrics.compute_hrv(rr)
        breathing = metrics.compute_breathing(acc)
        phases    = metrics.compute_breath_phases(acc)
        coh_data  = metrics.compute_coherence(
            rr, acc,
            peak_hz=breathing["peak_hz"] if breathing else None,
        )

        cbi = metrics.compute_cbi(
            hrv["rmssd"]                    if hrv       else None,
            breathing["peak_hz"]            if breathing else None,
            coh_data["score"]               if coh_data  else 0.0,
            regularity=breathing["regularity"]          if breathing else 0.0,
            peak_coherence=coh_data["peak_coherence"]   if coh_data  else None,
        )
        vti     = hrv["vti"]       if hrv else 0.0
        vlf_val = (hrv["vlf_power"]
                   if hrv and hrv["vlf_power"] is not None else None)

        # ── update KPI cache (fast callback reads this) ──────────────────────────
        _kpi_cache["bpm"]        = f"{hrv['mean_bpm']:.0f}"         if hrv       else "—"
        _kpi_cache["rmssd"]      = f"{hrv['rmssd']:.1f}"            if hrv       else "—"
        _kpi_cache["sdnn"]       = f"{hrv['sdnn']:.1f}"             if hrv       else "—"
        _kpi_cache["breath"]     = f"{breathing['bpm']:.1f}"        if breathing else "—"
        _kpi_cache["regularity"] = f"{breathing['regularity']:.2f}" if breathing else "—"
        _kpi_cache["lfhf"]       = (f"{hrv['lf_hf']:.2f}"
                                    if hrv and hrv["lf_hf"] is not None else "—")

        lfhf_val = hrv["lf_hf"] if hrv and hrv["lf_hf"] is not None else None

        # ── persist to SQLite + history (only when recording is active) ─────────
        if _measuring["active"]:
            try:
                with _db_lock:
                    _save_metric(_db, dict(
                        vti=vti,
                        cbi=cbi,
                        rmssd=hrv["rmssd"]          if hrv       else 0.0,
                        breath_bpm=breathing["bpm"] if breathing else 0.0,
                        bpm=hrv["mean_bpm"]         if hrv       else 0.0,
                        lfhf=lfhf_val               if lfhf_val  else 0.0,
                        vlf=vlf_val                 if vlf_val   else 0.0,
                        mean_ie=phases["mean_ie"]   if phases    else 0.0,
                    ))
            except Exception:
                pass

            _history.append(
                vti=vti,
                cbi=cbi,
                rmssd=hrv["rmssd"]          if hrv       else None,
                breath_bpm=breathing["bpm"] if breathing else None,
                bpm=hrv["mean_bpm"]         if hrv       else None,
                lfhf=lfhf_val,
                vlf=vlf_val,
                mean_ie=phases["mean_ie"]   if phases    else None,
            )

        psd_fig = (_psd_figure(hrv)
                   if hrv and hrv["psd_freqs"] is not None
                   else _ef("HRV Power Spectrum (Welch)"))
        coh_fig = (_coherence_figure(coh_data)
                   if coh_data
                   else _ef("RR–Breathing Coherence"))
        cbi_fig = _cbi_gauge(cbi)
        vti_fig = _vti_gauge(vti)

        lf_nu_v    = f"{hrv['lf_nu']:.1f} nu"       if hrv and hrv["lf_nu"]     is not None else "—"
        hf_nu_v    = f"{hrv['hf_nu']:.1f} nu"       if hrv and hrv["hf_nu"]     is not None else "—"
        lf_abs_v   = f"{hrv['lf_power']:.2f} ms²"   if hrv and hrv["lf_power"]  is not None else "—"
        hf_abs_v   = f"{hrv['hf_power']:.2f} ms²"   if hrv and hrv["hf_power"]  is not None else "—"
        vlf_abs_v  = f"{hrv['vlf_power']:.2f} ms²"  if hrv and hrv["vlf_power"] is not None else "—"
        coh_v      = f"{coh_data['score']:.3f}"      if coh_data  else "—"
        peak_coh_v = f"{coh_data['peak_coherence']:.3f}" if coh_data else "—"
        vti_v      = f"{vti:.3f}"                    if hrv       else "—"
        breath_hz  = f"{breathing['peak_hz']:.3f} Hz"   if breathing else "—"
        reg_v      = f"{breathing['regularity']:.3f}"   if breathing else "—"
        pnn50_v    = f"{hrv['pnn50']:.1f} %"         if hrv       else "—"
        ie_v       = (f"1:{phases['mean_ie']:.2f}  ({phases['n_breaths']} breaths)"
                      if phases else "—")

        ext = (
            f"VTI  ln(RMSSD)   {vti_v}\n"
            f"VLF  power       {vlf_abs_v}\n"
            f"LF   power       {lf_abs_v}\n"
            f"HF   power       {hf_abs_v}\n"
            f"LF   norm        {lf_nu_v}\n"
            f"HF   norm        {hf_nu_v}\n"
            f"pNN50            {pnn50_v}\n"
            f"Coh  (band)      {coh_v}\n"
            f"Coh  (peak)      {peak_coh_v}\n"
            f"Regularity       {reg_v}\n"
            f"Breath           {breath_hz}\n"
            f"I:E  ratio       {ie_v}\n"
            f"CBI              {cbi:.3f}"
        )

        snap            = _history.snapshot()
        vlf_live_fig    = _vlf_live_fig(snap)
        breath_wave_fig = _breath_wave_fig(phases)
        ie_ratio_fig    = _ie_ratio_fig(phases)

        return (psd_fig, coh_fig, cbi_fig, vti_fig, ext,
                vlf_live_fig, breath_wave_fig, ie_ratio_fig)

    except Exception:
        tb = traceback.format_exc()
        print(f"\n[slow ERROR]\n{tb}", flush=True)
        sf = _SAFE_FIG
        return sf, sf, sf, sf, tb[-600:], sf, sf, sf


# ── VTI range button group ────────────────────────────────────────────────────
@callback(
    Output("vti-range-store", "data"),
    Output("vti-btn-60",  "style"),
    Output("vti-btn-120", "style"),
    Output("vti-btn-720", "style"),
    Input("vti-btn-60",   "n_clicks"),
    Input("vti-btn-120",  "n_clicks"),
    Input("vti-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_vti_range(_60, _120, _720):
    val = {"vti-btn-60": "60", "vti-btn-120": "120", "vti-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_VTI),
            _rbtn_style(val == "120", C_VTI),
            _rbtn_style(val == "720", C_VTI))


# ── LF/HF range button group ──────────────────────────────────────────────────
@callback(
    Output("lfhf-range-store", "data"),
    Output("lfhf-btn-60",  "style"),
    Output("lfhf-btn-120", "style"),
    Output("lfhf-btn-720", "style"),
    Input("lfhf-btn-60",   "n_clicks"),
    Input("lfhf-btn-120",  "n_clicks"),
    Input("lfhf-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_lfhf_range(_60, _120, _720):
    val = {"lfhf-btn-60": "60", "lfhf-btn-120": "120", "lfhf-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_LFHF),
            _rbtn_style(val == "120", C_LFHF),
            _rbtn_style(val == "720", C_LFHF))


# ── VTI live chart ────────────────────────────────────────────────────────────
@callback(
    Output("vti-live-graph",  "figure"),
    Input("tick-slow",        "n_intervals"),
    Input("vti-range-store",  "data"),
)
def update_vti_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _vti_live_fig(rows, minutes=minutes)


# ── LF/HF live chart ──────────────────────────────────────────────────────────
@callback(
    Output("lfhf-live-graph", "figure"),
    Input("tick-slow",        "n_intervals"),
    Input("lfhf-range-store", "data"),
)
def update_lfhf_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _lfhf_live_fig(rows, minutes=minutes)


# ── I:E trend range button group ─────────────────────────────────────────────
@callback(
    Output("ie-range-store", "data"),
    Output("ie-btn-60",  "style"),
    Output("ie-btn-120", "style"),
    Output("ie-btn-720", "style"),
    Input("ie-btn-60",   "n_clicks"),
    Input("ie-btn-120",  "n_clicks"),
    Input("ie-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_ie_range(_60, _120, _720):
    val = {"ie-btn-60": "60", "ie-btn-120": "120", "ie-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_ACC),
            _rbtn_style(val == "120", C_ACC),
            _rbtn_style(val == "720", C_ACC))


# ── I:E trend chart ───────────────────────────────────────────────────────────
@callback(
    Output("ie-trend-graph",  "figure"),
    Input("tick-slow",        "n_intervals"),
    Input("ie-range-store",   "data"),
)
def update_ie_trend(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _ie_trend_fig(rows, minutes=minutes)


# ── blink range button group ─────────────────────────────────────────────────
@callback(
    Output("blink-range-store", "data"),
    Output("blink-btn-60",  "style"),
    Output("blink-btn-120", "style"),
    Output("blink-btn-720", "style"),
    Input("blink-btn-60",   "n_clicks"),
    Input("blink-btn-120",  "n_clicks"),
    Input("blink-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_blink_range(_60, _120, _720):
    val = {"blink-btn-60": "60", "blink-btn-120": "120", "blink-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_BLINK),
            _rbtn_style(val == "120", C_BLINK),
            _rbtn_style(val == "720", C_BLINK))


# ── blink charts + KPIs (2 000 ms) ───────────────────────────────────────────
@callback(
    Output("blink-rate-graph", "figure"),
    Output("blink-ibi-graph",  "figure"),
    Output("kpi-blink-rate",   "children"),
    Output("kpi-brv",          "children"),
    Output("kpi-ear",          "children"),
    Output("blink-status",     "children"),
    Input("tick-slow",          "n_intervals"),
    Input("blink-range-store",  "data"),
)
def update_blink(_n, minutes_str):
    minutes = int(minutes_str or 60)
    stats   = _blink.get_stats(window_s=60.0)

    _blink_rate_history.append({
        "t":    datetime.now().strftime("%H:%M"),
        "rate": stats["rate"],
        "brv":  stats["brv"],
    })

    status_text = stats["status"]
    if stats["status"] == "running":
        status_text = f"running  ·  EAR {stats['ear']:.2f}  ·  {stats['n_blinks']} blinks/min"

    rate_str = f"{stats['rate']:.1f}" if stats["rate"] > 0 else "—"
    brv_str  = f"{stats['brv']:.2f}" if stats["brv"]  > 0 else "—"
    ear_str  = f"{stats['ear']:.2f}" if stats["ear"]  > 0 else "—"

    return (
        _blink_rate_fig(list(_blink_rate_history), minutes=minutes),
        _blink_ibi_fig(_blink.get_recent_ibis()),
        rate_str, brv_str, ear_str,
        status_text,
    )


# ── camera preview images (60 000 ms) ────────────────────────────────────────
@callback(
    Output("eye-open-img",   "src"),
    Output("eye-closed-img", "src"),
    Input("tick-minute",     "n_intervals"),
)
def update_eye_images(_n):
    open_img, closed_img = _blink.get_preview_images()
    return open_img or "", closed_img or ""


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
    # Always read from SQLite so Today shows all data for the day,
    # including from earlier sessions and across restarts.
    with _db_lock:
        records = _load_today(_db)

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
    with _db_lock:
        days = _load_week(_db)
    return (
        _week_bar(days, "vti",   "Vagal Tone Index — Daily Average",       C_VTI,  ""),
        _week_bar(days, "cbi",   "Conscious Breathing Index — Daily Average", C_CBI, ""),
        _week_bar(days, "rmssd", "RMSSD — Daily Average",                   C_ACC,  "ms"),
        _week_bar(days, "lfhf",  "LF / HF Ratio — Daily Average",           C_LFHF, ""),
    )


# ── recording toggle ──────────────────────────────────────────────────────────
@callback(
    Output("measure-store",       "data"),
    Output("btn-measure-toggle",  "children"),
    Output("btn-measure-toggle",  "style"),
    Input("btn-measure-toggle",   "n_clicks"),
    State("measure-store",        "data"),
    prevent_initial_call=True,
)
def toggle_measuring(_, state):
    _btn = {
        "backgroundColor": "transparent",
        "borderRadius": "12px",
        "padding": "4px 14px",
        "fontSize": "10px",
        "fontWeight": "700",
        "letterSpacing": "1px",
        "cursor": "pointer",
        "fontFamily": "'JetBrains Mono', monospace",
    }
    if state == "recording":
        _measuring["active"] = False
        return ("paused",
                "⏺ START REC",
                {**_btn, "color": C_GOOD, "border": f"1px solid {C_GOOD}"})
    else:
        _measuring["active"] = True
        return ("recording",
                "⏹ STOP REC",
                {**_btn, "color": C_BAD, "border": f"1px solid {C_BAD}"})


# ── device panel toggle ────────────────────────────────────────────────────────
@callback(
    Output("device-panel",    "style"),
    Output("btn-scan-toggle", "children"),
    Input("btn-scan-toggle",  "n_clicks"),
    State("device-panel",     "style"),
    prevent_initial_call=True,
)
def toggle_device_panel(_, panel_style):
    hidden = (panel_style or {}).get("display") == "none"
    if hidden:
        return {**_CARD, "marginBottom": "10px"}, "✕ DEVICES"
    return {"display": "none"}, "⊕ DEVICES"


# ── start BLE scan ─────────────────────────────────────────────────────────────
@callback(
    Output("tick-scan",   "disabled"),
    Output("scan-status", "children"),
    Input("btn-scan-start", "n_clicks"),
    prevent_initial_call=True,
)
def start_scan(_):
    threading.Thread(target=_run_ble_scan, daemon=True).start()
    return False, "Scanning… (8 s)"


# ── poll scan results ──────────────────────────────────────────────────────────
@callback(
    Output("device-radio", "options"),
    Output("device-radio", "value"),
    Output("scan-status",  "children",  allow_duplicate=True),
    Output("tick-scan",    "disabled",  allow_duplicate=True),
    Input("tick-scan",     "n_intervals"),
    State("device-radio",  "value"),
    prevent_initial_call=True,
)
def poll_scan(_, current_value):
    status = _scan_state["status"]
    if status == "scanning":
        return dash.no_update, dash.no_update, "Scanning… (8 s)", False
    if status == "error":
        return [], None, f"Error: {_scan_state['error']}", True
    if status != "done":
        return dash.no_update, dash.no_update, dash.no_update, True

    devices = _scan_state["devices"]
    options, auto_select = [], current_value
    for d in devices:
        name     = d["name"] or "(unknown)"
        addr     = d["address"]
        rssi     = d["rssi"]
        is_polar = "Polar" in name
        star     = "★" if is_polar else " "
        rssi_str = f"{rssi:>+4d} dBm" if rssi else "   ? dBm"
        label    = f"{star}  {name:<34} {rssi_str}"
        options.append({"label": label, "value": addr})
        if is_polar and auto_select is None:
            auto_select = addr

    n = len(devices)
    return options, auto_select, f"{n} device{'s' if n != 1 else ''} found", True


# ── connect to selected device ─────────────────────────────────────────────────
@callback(
    Output("connect-feedback", "children"),
    Input("btn-connect",       "n_clicks"),
    State("device-radio",      "value"),
    prevent_initial_call=True,
)
def do_connect(_, addr):
    if not addr:
        return "⚠  Select a device from the list first"
    _target_device["address"] = addr
    name = next(
        (d["name"] for d in _scan_state["devices"] if d["address"] == addr),
        addr,
    )
    _target_device["name"] = name or addr
    _ble_reconnect.set()
    return f"Connecting to {_target_device['name']}…"


# ── reset to default scan-by-name ─────────────────────────────────────────────
@callback(
    Output("connect-feedback", "children", allow_duplicate=True),
    Input("btn-reset-device",  "n_clicks"),
    prevent_initial_call=True,
)
def reset_device(_):
    _target_device["address"] = None
    _target_device["name"]    = "Polar H10"
    _ble_reconnect.set()
    return "Searching for Polar H10 by name…"


# ── entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    _start_ble(_buf)
    _blink.start()
    print("Just Breathe dashboard → http://127.0.0.1:8050")
    print("Put on your Polar H10.  Ctrl-C to quit.\n")
    app.run(debug=False, use_reloader=False, host="127.0.0.1", port=8050)
