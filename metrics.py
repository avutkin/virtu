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

_MIN_RR_TIME    = 10
_MIN_RR_FREQ    = 30
_MIN_ACC_BREATH = int(ACC_FS * 6)   # 6 s
_MIN_ACC_COH    = int(ACC_FS * 15)  # 15 s for coherence
_MIN_ACC_PHASES = int(ACC_FS * 20)  # 20 s — need ≥ 2 complete cycles


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
            vlf_p = float(np.trapezoid(psd[vlf_m], freqs[vlf_m])) if vlf_m.any() else 0.0
            lf_p  = float(np.trapezoid(psd[lf_m],  freqs[lf_m]))  if lf_m.any()  else 0.0
            hf_p  = float(np.trapezoid(psd[hf_m],  freqs[hf_m]))  if hf_m.any()  else 0.0
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

    Returns dict with: peak_hz, bpm, regularity, psd_freqs, psd_values
    or None if insufficient data.

    regularity (0–1): peak prominence ratio normalised to 6×.
    A sharp, rhythmic breathing peak gives a high ratio vs the band
    noise floor.  Random or shallow breathing yields a flat PSD (ratio ≈ 1).
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

    band_psd  = psd[mask]
    peak_idx  = np.argmax(band_psd)
    peak_hz   = float(freqs[mask][peak_idx])
    peak_psd  = float(band_psd[peak_idx])
    mean_psd  = float(np.mean(band_psd))

    # Prominence ratio: how much the peak stands above the band average.
    # Ratio of 6× → regularity = 1.0; perfectly flat spectrum → ~0.17.
    ratio      = peak_psd / mean_psd if mean_psd > 0 else 1.0
    regularity = float(min(ratio / 6.0, 1.0))

    return dict(
        peak_hz=peak_hz,
        bpm=peak_hz * 60,
        regularity=regularity,
        psd_freqs=freqs[mask].tolist(),
        psd_values=band_psd.tolist(),
    )


def compute_coherence(rr_ms: list, acc_z: list,
                      peak_hz: float | None = None) -> dict | None:
    """
    Spectral coherence between the RR tachogram and ACC Z breathing signal.

    Both are resampled/downsampled to RR_FS (4 Hz) before comparison.

    Parameters
    ----------
    peak_hz : float | None
        Breathing peak frequency from compute_breathing.  When provided,
        peak_coherence is the mean coherence in a tight ±0.02 Hz window
        around that frequency — a precise measure of RSA lock.
        Falls back to band-average when None.

    Returns dict with: freqs, coherence, score, peak_coherence
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
    freqs_arr = np.asarray(freqs)
    coh_arr   = np.asarray(coh)

    band_mask = (freqs_arr >= _BREATH[0]) & (freqs_arr <= _BREATH[1])
    score     = float(np.mean(coh_arr[band_mask])) if band_mask.any() else 0.0

    # Coherence at the breathing peak: ±0.02 Hz window around peak_hz.
    if peak_hz is not None:
        peak_mask    = (freqs_arr >= peak_hz - 0.02) & (freqs_arr <= peak_hz + 0.02)
        peak_coherence = float(np.mean(coh_arr[peak_mask])) if peak_mask.any() else score
    else:
        peak_coherence = score

    return dict(freqs=freqs.tolist(), coherence=coh.tolist(),
                score=score, peak_coherence=peak_coherence)


def compute_cbi(rmssd: float | None, peak_hz: float | None, coherence_score: float,
                regularity: float = 0.0,
                peak_coherence: float | None = None) -> float:
    """
    Conscious Breathing Index (CBI), range 0–1.

    Increases when:
    - Breathing slows toward 6 breaths/min (0.10 Hz) — wider tolerance (σ=0.05)
    - Heart rate and breathing oscillate coherently at the same frequency
    - Breathing rhythm is regular and prominent (not shallow/erratic)
    - Vagal tone (RMSSD) is elevated

    Weights: peak coherence 35%, regularity 25%, frequency 25%, RMSSD 15%.

    Parameters
    ----------
    coherence_score : float
        Band-average coherence (0.1–0.8 Hz) — used as fallback when
        peak_coherence is unavailable.
    regularity : float
        Breathing peak prominence score from compute_breathing (0–1).
    peak_coherence : float | None
        Coherence at the breathing peak frequency (±0.02 Hz).
        More precise than band-average; preferred when available.
    """
    # Frequency: Gaussian centred at 6 br/min (0.10 Hz), σ widened to 0.05
    # so the good zone (4.5–7.5 br/min) stays above 0.60.
    freq_score = float(np.exp(-0.5 * ((peak_hz - 0.10) / 0.05) ** 2)) \
        if peak_hz is not None else 0.0

    # RMSSD: sigmoid centred at 40 ms — soft ceiling, works across all ages.
    # rmssd=20 → 0.27,  rmssd=40 → 0.50,  rmssd=70 → 0.82,  rmssd=100 → 0.95
    rmssd_score = float(1.0 / (1.0 + np.exp(-0.05 * (rmssd - 40)))) \
        if rmssd is not None and rmssd > 0 else 0.0

    # Coherence: use peak-frequency coherence when available
    coh_score = peak_coherence if peak_coherence is not None else coherence_score

    return round(
        0.35 * coh_score +
        0.25 * regularity +
        0.25 * freq_score +
        0.15 * rmssd_score,
        3,
    )


def compute_breath_phases(acc_z: list) -> dict | None:
    """
    Segment breathing into inhale / exhale phases from ACC Z-axis.

    Algorithm
    ---------
    1. Bandpass-filter the signal (0.05–0.8 Hz) to isolate breathing movement.
    2. Detect peaks (end of inhale) and troughs (end of exhale) with adaptive
       prominence so noise and shallow sighs are rejected.
    3. For each trough→peak→trough triplet, record:
         - inhale_dur   : seconds from trough to peak
         - exhale_dur   : seconds from peak to next trough
         - depth        : peak amplitude minus trough amplitude
         - ie_ratio     : exhale_dur / inhale_dur
         - t_inhale_start, t_inhale_end, t_exhale_end : seconds relative to now
           (negative = in the past; 0 = current sample)

    Vagus nerve context
    -------------------
    Extended exhale activates the vagus nerve via baroreflex modulation:
      I:E ≥ 1.5  →  mild parasympathetic activation
      I:E ≥ 2.0  →  strong vagal / HRV boost (e.g. 4-7-8 breathing)
      I:E < 1.0  →  sympathetic dominance, inhale-longer pattern

    Returns dict or None if fewer than 20 s of ACC data or < 2 complete cycles.
    """
    if len(acc_z) < _MIN_ACC_PHASES:
        return None

    z = np.asarray(acc_z, dtype=float)

    # Bandpass filter: 0.05–0.8 Hz  (3–48 br/min)
    sos      = spsig.butter(4, [0.05, 0.8], btype='bandpass', fs=ACC_FS, output='sos')
    filtered = spsig.sosfiltfilt(sos, z)

    # Adaptive prominence: 30 % of signal SD — suppresses noise, keeps real breaths
    min_dist = int(ACC_FS * 1.5)                       # ≥ 1.5 s → max 40 br/min
    min_prom = max(float(np.std(filtered)) * 0.30, 1e-6)

    peaks,   _ = spsig.find_peaks( filtered, distance=min_dist, prominence=min_prom)
    troughs, _ = spsig.find_peaks(-filtered, distance=min_dist, prominence=min_prom)

    if len(peaks) < 2 or len(troughs) < 2:
        return None

    t_arr  = np.arange(len(filtered)) / float(ACC_FS)
    t_now  = t_arr[-1]
    breaths: list[dict] = []

    for i in range(len(troughs) - 1):
        idx_t1 = troughs[i]
        idx_t2 = troughs[i + 1]
        mid    = peaks[(peaks > idx_t1) & (peaks < idx_t2)]
        if len(mid) == 0:
            continue
        idx_p = int(mid[0])

        inh = float(idx_p  - idx_t1) / ACC_FS
        exh = float(idx_t2 - idx_p)  / ACC_FS
        dep = float(filtered[idx_p] - filtered[idx_t1])

        # Physiological sanity: 1–40 br/min → cycle 1.5–60 s; half-phases ≥ 0.4 s
        if not (1.5 <= inh + exh <= 60.0) or inh < 0.4 or exh < 0.4:
            continue

        breaths.append({
            'inhale_dur':      round(inh, 2),
            'exhale_dur':      round(exh, 2),
            'depth':           round(dep, 4),
            'ie_ratio':        round(exh / inh, 2),
            't_inhale_start':  round(t_arr[idx_t1] - t_now, 2),
            't_inhale_end':    round(t_arr[idx_p]  - t_now, 2),
            't_exhale_end':    round(t_arr[idx_t2] - t_now, 2),
        })

    if not breaths:
        return None

    # Waveform slice: last 30 s for display
    win       = int(ACC_FS * 30)
    sig_slice = filtered[-win:]
    t_rel     = (np.arange(len(sig_slice)) - len(sig_slice)) / float(ACC_FS)

    ie_vals  = [b['ie_ratio']   for b in breaths]
    inh_vals = [b['inhale_dur'] for b in breaths]
    exh_vals = [b['exhale_dur'] for b in breaths]
    dep_vals = [abs(b['depth']) for b in breaths]

    return dict(
        breaths     =breaths[-12:],
        mean_ie     =round(float(np.mean(ie_vals)),  2),
        mean_inhale =round(float(np.mean(inh_vals)), 2),
        mean_exhale =round(float(np.mean(exh_vals)), 2),
        mean_depth  =round(float(np.mean(dep_vals)), 4),
        n_breaths   =len(breaths),
        filtered    =sig_slice.tolist(),
        filtered_t  =t_rel.tolist(),
    )
