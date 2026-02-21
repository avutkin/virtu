"""
Biometric signal processing for breathing and HRV analysis.

All functions accept plain Python lists and return dicts (or None when
insufficient data is available).  No side effects.

Physiological constants
-----------------------
- RR artifact filter  : 300–2000 ms  (30–200 bpm)
- HRV time-domain min : 10 RR intervals
- HRV freq-domain min : 30 RR intervals (~2 min of data recommended)
- Breathing min data  : 6 s of ACC Z  (1 200 samples at 200 Hz)
- Coherence min data  : 15 s ACC + 20 RR intervals

HRV frequency bands
-------------------
- VLF : 0.003–0.04 Hz   (excluded from LF/HF ratio)
- LF  : 0.04–0.15  Hz   (sympathetic + parasympathetic, baroreceptor)
- HF  : 0.15–0.40  Hz   (parasympathetic, respiratory)
"""

from __future__ import annotations
import numpy as np
from scipy import signal as spsig

ECG_FS: int   = 130   # Hz  (Polar H10 ECG sample rate)
ACC_FS: int   = 200   # Hz  (Polar H10 accelerometer sample rate)
RR_FS: float  = 4.0   # Hz  (tachogram interpolation rate)

_VLF = (0.003, 0.04)
_LF  = (0.04, 0.15)
_HF  = (0.15, 0.40)
_BREATH = (0.10, 0.50)   # 6–30 br/min — excludes motion-artifact peaks above 0.5 Hz

_MIN_RR_TIME   = 10
_MIN_RR_FREQ   = 30
_MIN_ACC_BREATH = int(ACC_FS * 6)   # 6 s
_MIN_ACC_COH    = int(ACC_FS * 15)  # 15 s for coherence


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _clean_rr(rr_ms: list[int | float]) -> np.ndarray:
    """Remove physiologically implausible RR values (artifacts)."""
    rr = np.asarray(rr_ms, dtype=float)
    return rr[(rr >= 300) & (rr <= 2000)]


def _interp_tachogram(rr: np.ndarray, fs: float = RR_FS) -> np.ndarray | None:
    """Interpolate irregular RR tachogram onto a uniform grid at *fs* Hz."""
    if len(rr) < 4:
        return None
    cum = np.cumsum(rr) / 1000.0      # cumulative time in seconds
    t = np.arange(cum[0], cum[-1], 1.0 / fs)
    if len(t) < 8:
        return None
    return np.interp(t, cum, rr)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def compute_hrv(rr_ms: list) -> dict | None:
    """
    Full HRV analysis from a list of RR intervals (milliseconds).

    Returns
    -------
    dict with keys:
        mean_bpm, sdnn, rmssd, pnn50, vti,
        lf_power, hf_power, lf_hf, lf_nu, hf_nu,   (None if < 30 RRs)
        psd_freqs, psd_values                        (None if < 30 RRs)
    or None if fewer than MIN_RR_TIME clean intervals.
    """
    rr = _clean_rr(rr_ms)
    if len(rr) < _MIN_RR_TIME:
        return None

    diffs = np.diff(rr)
    sdnn  = float(np.std(rr))
    rmssd = float(np.sqrt(np.mean(diffs ** 2))) if len(diffs) else 0.0
    pnn50 = float(100 * np.sum(np.abs(diffs) > 50) / len(diffs)) if len(diffs) else 0.0
    vti   = float(np.log(rmssd)) if rmssd > 0 else 0.0
    mean_bpm = float(60_000 / np.mean(rr))

    out = dict(
        mean_bpm=mean_bpm, sdnn=sdnn, rmssd=rmssd,
        pnn50=pnn50, vti=vti,
        vlf_power=None,
        lf_power=None, hf_power=None, lf_hf=None,
        lf_nu=None, hf_nu=None,
        psd_freqs=None, psd_values=None,
    )

    if len(rr) >= _MIN_RR_FREQ:
        interp = _interp_tachogram(rr)
        if interp is not None:
            detrended = interp - np.mean(interp)
            nperseg = min(256, len(detrended))
            freqs, psd = spsig.welch(
                detrended, fs=RR_FS, nperseg=nperseg,
                noverlap=nperseg // 2, window="hann",
            )
            vlf_m = (freqs >= _VLF[0]) & (freqs <= _VLF[1])
            lf_m  = (freqs >= _LF[0])  & (freqs <= _LF[1])
            hf_m  = (freqs >= _HF[0])  & (freqs <= _HF[1])
            vlf_p = float(np.trapz(psd[vlf_m], freqs[vlf_m])) if vlf_m.any() else 0.0
            lf_p  = float(np.trapz(psd[lf_m],  freqs[lf_m]))  if lf_m.any()  else 0.0
            hf_p  = float(np.trapz(psd[hf_m],  freqs[hf_m]))  if hf_m.any()  else 0.0
            tp    = lf_p + hf_p
            out.update(dict(
                vlf_power=vlf_p,
                lf_power=lf_p, hf_power=hf_p,
                lf_hf=lf_p / hf_p if hf_p > 0 else 0.0,
                lf_nu=100 * lf_p / tp if tp > 0 else 0.0,
                hf_nu=100 * hf_p / tp if tp > 0 else 0.0,
                psd_freqs=freqs.tolist(),
                psd_values=psd.tolist(),
            ))

    return out


def compute_breathing(acc_z: list) -> dict | None:
    """
    Estimate breathing rate from ACC Z-axis via Welch PSD.

    Returns dict with: peak_hz, bpm, psd_freqs, psd_values
    or None if insufficient data.
    """
    if len(acc_z) < _MIN_ACC_BREATH:
        return None

    z = np.asarray(acc_z, dtype=float)
    z = z - np.mean(z)
    std = np.std(z)
    if std > 0:
        z = z / std

    nperseg = min(4096, len(z))
    freqs, psd = spsig.welch(
        z, fs=ACC_FS, nperseg=nperseg,
        noverlap=nperseg // 2, window="hann",
    )
    mask = (freqs >= _BREATH[0]) & (freqs <= _BREATH[1])
    if not mask.any():
        return None

    peak_hz = float(freqs[mask][np.argmax(psd[mask])])
    return dict(
        peak_hz=peak_hz,
        bpm=peak_hz * 60,
        psd_freqs=freqs[mask].tolist(),
        psd_values=psd[mask].tolist(),
    )


def compute_coherence(rr_ms: list, acc_z: list) -> dict | None:
    """
    Spectral coherence between the RR tachogram and ACC Z breathing signal.

    Both are resampled/downsampled to RR_FS (4 Hz) before comparison.
    Coherence score is the mean coherence in the 0.1–0.8 Hz band.

    Returns dict with: freqs, coherence, score
    or None if insufficient data.
    """
    if len(rr_ms) < 20 or len(acc_z) < _MIN_ACC_COH:
        return None

    rr = _clean_rr(rr_ms)
    interp = _interp_tachogram(rr, fs=RR_FS)
    if interp is None:
        return None

    # Downsample ACC to RR_FS (200 → 4 Hz: take every 50th sample)
    step = max(1, int(ACC_FS / RR_FS))
    acc_down = np.asarray(acc_z[::step], dtype=float)

    n = min(len(interp), len(acc_down))
    if n < 16:
        return None

    rr_seg = interp[-n:] - np.mean(interp[-n:])
    ac_seg = acc_down[-n:] - np.mean(acc_down[-n:])

    # Target ≥10 Welch segments for a reliable coherence estimate.
    # nperseg = n // 10 gives ~10 segments; clamp between 8 and 64.
    nperseg = max(8, min(n // 10, 64))
    freqs, coh = spsig.coherence(
        rr_seg, ac_seg, fs=RR_FS,
        nperseg=nperseg, noverlap=nperseg // 2,
    )
    mask = (freqs >= _BREATH[0]) & (freqs <= _BREATH[1])
    score = float(np.mean(coh[mask])) if mask.any() else 0.0

    return dict(freqs=freqs.tolist(), coherence=coh.tolist(), score=score)


def compute_cbi(rmssd: float | None, peak_hz: float | None, coherence_score: float) -> float:
    """
    Conscious Breathing Index (CBI), range 0–1.

    Increases when:
    - Breathing slows toward 6 breaths/min (0.10 Hz)
    - RMSSD (vagal tone) is high (reference: 60 ms)
    - HRV and breathing oscillate coherently at the same frequency

    Weights: coherence 40%, RMSSD 30%, breathing frequency 30%.
    """
    breath_score = float(np.exp(-0.5 * ((peak_hz - 0.10) / 0.03) ** 2)) \
        if peak_hz is not None else 0.0
    rmssd_score  = min(rmssd / 60.0, 1.0) if rmssd is not None and rmssd > 0 else 0.0

    return round(0.40 * coherence_score + 0.30 * rmssd_score + 0.30 * breath_score, 3)
