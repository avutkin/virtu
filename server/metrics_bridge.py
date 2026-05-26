"""
Server-side HRV recompute using the existing metrics.py module.

Used when the admin wants to reprocess raw RR data from a session,
or to validate client-side metrics against the Python reference implementation.
"""
from __future__ import annotations

import sys
import os

# Allow importing metrics.py from the project root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import metrics  # noqa: E402  (root-level metrics.py)


def recompute_session(rr_ms: list[int | float],
                      acc_z: list[float]) -> dict:
    """
    Full recompute of all metrics from raw RR intervals and ACC Z samples.

    Parameters
    ----------
    rr_ms : list of RR intervals in milliseconds
    acc_z : list of ACC Z-axis samples at 200 Hz

    Returns
    -------
    dict with: hrv, breathing, rsa, coherence, cbi keys
    """
    hrv       = metrics.compute_hrv(rr_ms)
    breathing = metrics.compute_breathing(acc_z)
    rsa       = metrics.compute_rsa(rr_ms, breath_hz=breathing["peak_hz"] if breathing else None)
    coherence = metrics.compute_coherence(
        rr_ms, acc_z,
        peak_hz=breathing["peak_hz"] if breathing else None,
    )
    cbi = None
    if coherence and breathing:
        rmssd = hrv["rmssd"] if hrv else None
        cbi = metrics.compute_cbi(
            rmssd=rmssd,
            peak_hz=breathing["peak_hz"],
            coherence_score=coherence["score"],
            regularity=breathing["regularity"],
            peak_coherence=coherence.get("peak_coherence"),
        )

    return {
        "hrv":       hrv,
        "breathing": breathing,
        "rsa":       rsa,
        "coherence": coherence,
        "cbi":       cbi,
    }
