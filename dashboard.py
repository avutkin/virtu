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
from flask import request as _flask_req

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
C_ULF       = "#a78bfa"   # violet — ULF power
C_BLINK     = "#2dd4bf"   # teal — eye blink
C_PNN50     = "#f472b6"   # pink/rose — pNN50
C_SDNN      = "#58a6ff"   # blue — SDNN (same as C_RR for KPI consistency)
C_NAV_ACT   = "#58a6ff"   # active navigation pill
C_RSA       = "#fb923c"   # amber — RSA amplitude
C_RSA_IDX   = "#fbbf24"   # yellow-gold — RSA Index (ln band power)

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


# ── per-metric info content ───────────────────────────────────────────────────
_METRIC_INFO: dict[str, dict] = {
    "hr": {
        "title": "Heart Rate  —  Beats per Minute (bpm)",
        "nervous": "Heart rate is set by the sinoatrial node under competing sympathetic (accelerator) and parasympathetic (vagal brake) inputs. Resting HR reflects chronic autonomic tone — lower resting HR generally indicates stronger vagal modulation and higher cardiovascular reserve.",
        "psychological": "Acute stress, anxiety, and emotional arousal raise HR within seconds via sympathetic activation and vagal withdrawal. Sustained elevated HR (> 90 bpm at rest) is a reliable marker of chronic stress load. Calm, meditative states push HR toward 55–65 bpm in most adults.",
        "exercise": "HR rises linearly with exercise intensity up to VO₂max. Training zones are defined as percentages of HRmax. Zone 2 (60–70% HRmax) is optimal for aerobic base building. Recovery HR — how fast it drops in the first minute post-exercise — is a direct fitness marker.",
        "improve": "Consistent Zone 2 aerobic training lowers resting HR by 5–15 bpm over months. Slow resonance breathing (5–6 br/min) produces beat-to-beat HR oscillations (RSA) and strengthens the vagal brake. Adequate sleep, hydration, and low caffeine reduce the resting sympathetic drive that keeps HR elevated.",
    },
    "ecg": {
        "title": "ECG  —  Electrocardiogram (µV)",
        "nervous": "Captures the electrical depolarisation/repolarisation cycle of the heart. QRS-complex spacing is the raw source of all HRV metrics. Beat-to-beat variation visible in peak spacing directly reflects autonomic regulation — wider spacing variation = stronger parasympathetic (vagal) tone.",
        "psychological": "Autonomic state shapes ECG morphology in real time. Stress flattens beat-to-beat variation. Calm, focused states produce rhythmically varying R-R intervals (respiratory sinus arrhythmia). Emotional arousal shortens the RR interval and reduces variance.",
        "exercise": "Heart rate rises linearly with exercise intensity; RR intervals compress. High-intensity effort produces near-uniform, rapid QRS sequences. Recovery rate back to resting rhythm is a key fitness indicator — faster recovery = better cardiovascular conditioning.",
        "improve": "Aerobic conditioning (Zone 2, 150+ min/week) broadens the HRV range visible in ECG. Electrolyte balance (Mg²⁺, K⁺) stabilises conduction. Slow diaphragmatic breathing makes RSA oscillations visible as rhythmic peak-spacing variation.",
    },
    "acc": {
        "title": "ACC Z-axis  —  Breathing Waveform (mG)",
        "nervous": "Chest-wall movement captured by the accelerometer. Peak-to-trough amplitude reflects tidal volume; cycle frequency reflects breathing rate. Slow, deep, regular oscillations activate the vagus nerve via pulmonary stretch receptors and baroreflex coupling.",
        "psychological": "Breathing pattern is the most direct lever for real-time autonomic state change. Shallow, rapid breathing (>20 br/min) sustains stress activation. Slow, diaphragmatic breathing (5–7 br/min) immediately shifts the autonomic balance toward parasympathetic dominance.",
        "exercise": "Amplitude and rate increase with exercise intensity. Recovery rate to resting pattern (slow, regular oscillations) reflects aerobic fitness. Elite athletes show complete respiratory recovery within 2–3 minutes of stopping.",
        "improve": "Practise 3D diaphragmatic breathing: inhale expands belly first, then lateral ribcage, then chest. Target 5–6 breaths/min. Box breathing (4:4:4:4) or 4:7:8 patterns develop breath control. Yoga, Pilates, and freediving training all improve respiratory mechanics.",
    },
    "rr": {
        "title": "RR Tachogram  —  Beat-to-Beat Intervals (ms)",
        "nervous": "Sequential plot of time between each heartbeat. Higher variance = stronger HRV. Rhythmic oscillations (respiratory sinus arrhythmia, RSA) — the heart speeding on inhale and slowing on exhale — are the direct signature of healthy vagal-cardiac coupling.",
        "psychological": "A flattened tachogram (low variance, uniform intervals) indicates stress, fatigue, over-arousal, or excess sympathetic drive. Wave-like RSA oscillations indicate a relaxed, regulated state. Trauma and chronic anxiety consistently suppress RR variability.",
        "exercise": "Variance collapses during vigorous exercise as sympathetic drive dominates. Post-exercise recovery of RR variance speed is proportional to aerobic fitness level and recovery quality.",
        "improve": "Slow deliberate breathing (5–7 br/min) makes RSA oscillations visible in the tachogram — this is the real-time marker of vagal-cardiac coupling. HRV biofeedback training, meditation, and progressive relaxation all increase resting RR variance.",
    },
    "psd": {
        "title": "HRV Power Spectrum  —  Welch PSD",
        "nervous": "Full frequency decomposition of heart-rate variability. VLF (0.003–0.04 Hz) reflects long-range autonomic regulation and neuroendocrine activity. LF (0.04–0.15 Hz) reflects baroreflex and mixed sympathetic/parasympathetic activity. HF (0.15–0.40 Hz) reflects pure parasympathetic (vagal) modulation coupled to respiration.",
        "psychological": "A sharp, tall HF peak centred on your breathing frequency indicates resonance — the optimal HRV biofeedback state characterised by calm, focused attention and emotional stability. Broad, flat spectra indicate autonomic dysregulation. Dominant LF with suppressed HF is the typical stress/anxiety signature.",
        "exercise": "Hard exercise shifts power into LF and suppresses HF. Resonance breathing at rest produces a prominent, narrow HF peak. Regular endurance training progressively increases total spectral power and shifts the baseline toward HF dominance.",
        "improve": "Breathe at your resonance frequency (~0.1 Hz, about 6 breaths/min) to maximise the HF peak and create LF-HF synchrony. HRV biofeedback training using this chart as feedback is the gold-standard method for increasing total HRV power.",
    },
    "coh": {
        "title": "RR–Breathing Coherence",
        "nervous": "Measures synchronisation between heart rhythm oscillations and breathing rhythm. High coherence (score > 0.7) means the baroreflex is strongly activated — each breath cycle is perfectly entraining the heart via the vagus nerve. This is the physiological state targeted by HRV biofeedback.",
        "psychological": "High coherence is associated with calm, focused, emotionally stable states. It predicts better decision-making, emotional regulation, and cognitive performance. The coherence state is used clinically for anxiety, PTSD, and performance training.",
        "exercise": "Vigorous exercise disrupts coherence by introducing noise into both RR and ACC signals. Elite athletes can maintain moderate coherence at moderate intensities. Coherence training at rest translates to better autonomic recovery post-exercise.",
        "improve": "Breathe at your personal resonance frequency (typically 4.5–7 br/min). Find your resonance: start at 6 br/min and adjust ±0.5 br/min until coherence peaks. Consistent daily HRV biofeedback practice (20 min/day) trains the baroreflex. Slow exhale (longer than inhale) amplifies the effect.",
    },
    "vti": {
        "title": "Vagal Tone Index  —  ln(RMSSD)",
        "nervous": "Natural log of RMSSD — a dimensionless index of parasympathetic (vagal) activity. Log transformation normalises the skewed distribution of RMSSD. VTI > 3.5 indicates robust vagal tone. VTI < 2.5 indicates sympathetic dominance and increased cardiovascular risk.",
        "psychological": "VTI is the strongest single-number predictor of emotional regulation capacity, resilience under stress, and cognitive flexibility. Athletes and meditators consistently show VTI > 4.0. Burnout, chronic stress, and anxiety disorders reliably suppress VTI.",
        "exercise": "Rises during aerobic conditioning and recovery. Drops acutely after hard training (normal) and chronically with overtraining (warning). Use morning resting VTI as the primary readiness-to-train indicator: >10% drop from baseline = reduce load.",
        "improve": "Coherent breathing (5–6 br/min), cold-water immersion, regular Zone 2 cardio, strength training, quality sleep (>7h), time in nature, social connection, and mindfulness meditation all reliably increase resting VTI over weeks.",
    },
    "rmssd": {
        "title": "RMSSD  —  Root Mean Square of Successive Differences (ms)",
        "nervous": "Gold-standard time-domain marker of cardiac parasympathetic (high-frequency vagal) modulation. Computed from beat-to-beat differences — large successive changes mean the vagus nerve is actively modulating heart rate. Normal range: 20–100 ms; athletes commonly exceed 100 ms.",
        "psychological": "Higher resting RMSSD correlates with better emotional regulation, reduced anxiety, greater frustration tolerance, and higher working-memory capacity. Low RMSSD is a biomarker for depression, PTSD, and chronic stress disorders.",
        "exercise": "Increases with sustained aerobic training over weeks. Acutely decreases after hard sessions. Morning RMSSD is the most widely used HRV readiness metric in sports science — track the 7-day rolling average and flag days >10% below baseline.",
        "improve": "Slow diaphragmatic breathing, yoga, endurance training, stress management techniques, cold showers, limiting alcohol, consistent sleep schedule. Gains from lifestyle change typically visible within 4–8 weeks of consistent effort.",
    },
    "sdnn": {
        "title": "SDNN  —  Standard Deviation of NN Intervals (ms)",
        "nervous": "Overall autonomic variability — captures contributions from both sympathetic and parasympathetic branches across all frequency bands. Reflects the total regulatory capacity of the autonomic nervous system. SDNN > 50 ms is the clinical threshold for adequate HRV; < 20 ms is associated with significantly elevated cardiovascular risk.",
        "psychological": "Chronic low SDNN is associated with depression, anxiety disorders, burnout, and poor stress recovery. Higher SDNN is linked to adaptive coping, psychological flexibility, and resilience. SDNN responds to both physical training and mind-body practices.",
        "exercise": "Improves progressively with consistent aerobic and mixed-intensity training. Acutely suppressed by high-intensity effort. Long-term endurance athletes show SDNN values 30–50% above population norms.",
        "improve": "Consistent aerobic exercise (especially Zone 2), stress-reduction practices (meditation, nature exposure), sleep optimisation, reduced alcohol, balanced training load with adequate recovery. SDNN improves more slowly than RMSSD — track monthly trends.",
    },
    "pnn50": {
        "title": "pNN50  —  % of RR differences > 50 ms",
        "nervous": "Percentage of consecutive RR intervals differing by more than 50 ms. Very sensitive to high-frequency parasympathetic (vagal) activity. Normal resting range: 3–25%. Athletes commonly exceed 25%. Extremely sensitive to recovery state — more so than SDNN.",
        "psychological": "Strong correlation with positive affect, psychological safety, and parasympathetic dominance. Anxiety and chronic stress reliably drive pNN50 toward zero. Improvement in pNN50 after mind-body intervention is one of the fastest-responding HRV biomarkers.",
        "exercise": "Highly sensitive to training load. A pNN50 drop >50% from personal baseline is a reliable signal of insufficient recovery. Use weekly averages rather than single-day values to track fitness trends.",
        "improve": "Long slow distance (LSD) training, breathing exercises, cold-water immersion, mindfulness. Responds quickly to acute interventions (single slow-breathing session raises pNN50 within minutes) and builds with consistent training over weeks.",
    },
    "lfhf": {
        "title": "LF / HF Ratio  —  Sympathetic Balance",
        "nervous": "Ratio of low-frequency (0.04–0.15 Hz) to high-frequency (0.15–0.40 Hz) HRV power. LF reflects combined baroreflex and sympathetic modulation; HF reflects pure vagal respiratory coupling. Ratio < 0.5 = parasympathetic dominance (recovery/rest). 0.5–2.0 = balanced. > 2.0 = sympathetic dominance (stress/arousal).",
        "psychological": "Elevated LF/HF is the autonomic signature of acute stress, anticipatory anxiety, cognitive load, and fight-or-flight activation. Sustained high ratio is seen in burnout, PTSD, and cardiovascular disease. Ratio responds rapidly to slow breathing — a single coherent breath cycle can shift it measurably.",
        "exercise": "Rises sharply with exercise intensity. Returns to baseline during recovery — rate of return reflects autonomic flexibility and fitness. Caffeine, stimulants, and poor sleep all chronically elevate resting LF/HF.",
        "improve": "Coherent breathing at 0.1 Hz is the fastest and most reliable method. Reduce stimulants and screen exposure before sleep. Cold exposure, progressive muscle relaxation, and biofeedback training all shift ratio toward parasympathetic dominance.",
    },
    "vlf": {
        "title": "VLF Power  —  Very Low Frequency (0.003–0.04 Hz)",
        "nervous": "Power in the 0.003–0.04 Hz band, reflecting long-range autonomic regulation — renin-angiotensin-aldosterone system (RAAS) activity, thermoregulation, gut-brain axis, and metabolic regulation. The strongest predictor of long-term all-cause mortality in clinical studies. Requires at least 5–30 minutes of recording for reliable estimation.",
        "psychological": "Strongly linked to PTSD severity, depression, and dissociation. Trauma reliably suppresses VLF. Low VLF is associated with poor emotion regulation and interoceptive deficits. Mind-body practices that improve gut-brain coherence (breathwork, yoga) raise VLF over months.",
        "exercise": "Improves with sustained aerobic training (> 150 min/week). Reflects mitochondrial health, metabolic flexibility, and neuroendocrine regulation. Sauna and cold-water immersion both acutely and chronically raise VLF through thermoregulatory stress adaptation.",
        "improve": "Regular aerobic exercise is the primary driver. Sauna (3–5×/week, 15+ min), cold immersion, quality sleep (particularly deep slow-wave sleep), and gut microbiome health (fibre, probiotic foods) all contribute. VLF improves over months — track 30-day rolling trends.",
    },
    "ulf": {
        "title": "ULF Power  —  Ultra Low Frequency (< 0.003 Hz)",
        "nervous": "Power in the < 0.003 Hz band, reflecting the slowest autonomic fluctuations: circadian rhythms, neuroendocrine cycles (cortisol, melatonin), thermoregulatory oscillations, and inflammatory system dynamics. ULF is only meaningful from recordings ≥ 30 minutes. Requires at least 30 min of continuous heart-rate data for estimation.",
        "psychological": "Chronically low ULF is associated with burnout, chronic fatigue syndrome, and impaired hormonal circadian rhythm. High ULF correlates with emotional resilience, hormonal balance, and adaptive autonomic regulation across the day. Trauma and PTSD selectively suppress ultra-low frequency autonomic variability.",
        "exercise": "Sustained aerobic training (> 150 min/week) increases ULF over weeks by improving neuroendocrine regulation. Morning sessions (aligning with cortisol peak) produce the strongest ULF stimulus. Sleep quality directly gates overnight ULF restoration — deep sleep stages produce the largest slow autonomic oscillations.",
        "improve": "Consistent sleep timing (same bedtime/wake time) is the single strongest driver — circadian alignment maximises overnight hormonal cycling visible in ULF. Regular aerobic exercise, stress reduction, and sunlight exposure in the morning all support ULF. Track weekly trends rather than daily values — ULF changes on a timescale of days to weeks.",
    },
    "cbi": {
        "title": "CBI  —  Conscious Breathing Index",
        "nervous": "Composite score (0–1) combining peak coherence (35%), breathing regularity (25%), breathing frequency (25%), and RMSSD (15%). Captures the overall quality of vagal activation through deliberate breath control. CBI > 0.6 indicates a high-quality parasympathetic state.",
        "psychological": "High CBI reflects the physiological substrate of the calm, focused, high-performance state — the autonomic equivalent of 'flow'. Sustained CBI > 0.6 during a session correlates with reduced cortisol, improved working memory, and better emotional regulation.",
        "exercise": "CBI drops during and immediately after vigorous exercise. Use CBI to monitor the quality of active recovery, cool-down breathing, and between-set rest intervals. A rapid CBI rebound is a fitness indicator.",
        "improve": "Conscious slow breathing (5–7 br/min) with extended exhale. Prioritise a 2:1+ exhale-to-inhale ratio. Box breathing, 4:7:8, and coherent breathing protocols all raise CBI. Consistency matters — daily 10–20 min practice produces the fastest gains.",
    },
    "breath_wave": {
        "title": "Breathing Phases  —  Inhale (blue) / Exhale (green)",
        "nervous": "Filtered breathing waveform with each phase shaded. Inhale (sympathetic): thoracic expansion stretches baroreceptors, briefly accelerating heart rate. Exhale (parasympathetic): compression activates the vagus nerve, decelerating heart rate. This alternation is the mechanism of respiratory sinus arrhythmia (RSA).",
        "psychological": "Visible regularity indicates a well-regulated autonomic state. Irregular, shallow phases suggest stress, distraction, or poor breath awareness. Consciously matching inhale to exhale and then extending exhale produces immediate parasympathetic shift.",
        "exercise": "Breathing phases are barely visible during high-intensity exercise as rate accelerates. During cool-down, watching phase regularity return is a direct readback of autonomic recovery.",
        "improve": "Aim for slow (5–6 br/min), deep, diaphragmatic breathing with exhale ≥ inhale. Use this waveform as visual biofeedback: smooth, regular, symmetrical cycles with gentle exhale elongation are the target pattern.",
    },
    "ie_ratio": {
        "title": "Inhale · Exhale Duration  —  I:E Ratio per Breath",
        "nervous": "Per-breath bar chart of inhale (blue) and exhale (green) durations. Exhale directly activates the vagus nerve via baroreceptor unloading. I:E ≥ 1.5 (exhale 50% longer than inhale) activates mild vagal tone. I:E ≥ 2.0 (exhale twice as long) produces strong parasympathetic activation.",
        "psychological": "Extended exhale is the single most direct, evidence-based breath intervention for shifting from sympathetic to parasympathetic dominance. 4:8 breathing (4 s inhale, 8 s exhale) can reduce acute anxiety within 2–3 minutes.",
        "exercise": "During recovery or between exercise sets, actively extending exhale accelerates HR recovery and reduces perceived exertion. Elite athletes and special forces personnel use this deliberately during tactical rest intervals.",
        "improve": "Practise 4:8 (inhale:exhale), 4:7:8, or box breathing with extended exhale phase. Pursed-lip exhale, humming (vagal vibration), and sighing (deep inhale + long exhale) are simple, anytime-anywhere vagal activation techniques.",
    },
    "ie_trend": {
        "title": "I:E Ratio Trend  —  Exhale / Inhale (rolling 1-min avg)",
        "nervous": "Rolling time-series of the mean I:E ratio, showing how consistently you maintain vagal-activating exhale dominance across the session. Sustained ratio > 1.5 over 20+ minutes indicates a meaningful shift in autonomic baseline toward parasympathetic tone.",
        "psychological": "This chart answers: are you maintaining your breath discipline over time, or drifting back to stress-pattern breathing? Sustained high I:E is correlated with lower cortisol, improved mood, and cognitive performance at the session level.",
        "exercise": "Monitor I:E trend during rest intervals in circuit or interval training. A rising trend during recovery indicates effective use of breath to accelerate between-set recovery.",
        "improve": "Set an I:E ratio intention at the start of each session (e.g., 1:2). Use the breath-wave chart for real-time feedback and this chart to confirm the pattern is holding over time. Nasal breathing naturally promotes longer, more controlled exhales.",
    },
    "blink_rate": {
        "title": "Eye Blink Rate  —  Blinks per Minute",
        "nervous": "Spontaneous blink rate is regulated by dopaminergic circuits in the striatum and modulated by the autonomic nervous system. Normal range 12–20 blinks/min. Very low rate (< 5) indicates strong cognitive engagement or sympathetic arousal (fight-or-flight reduces blink rate). Very high rate (> 25) indicates fatigue or emotional distress.",
        "psychological": "< 5 blinks/min: deep focus or dry-eye strain. 5–12: focused concentration with some strain risk. 12–20: optimal alert-relaxed state. > 20: fatigue, distraction, high emotional arousal. Blink rate tracks the balance between task engagement and cognitive fatigue.",
        "exercise": "Physical exertion can transiently reduce blink rate during focus-intensive movement (e.g., sports, climbing). Post-exercise fatigue increases blink rate. Screen-heavy cognitive work suppresses blink rate and dries the cornea — a common occupational hazard.",
        "improve": "20-20-20 rule: every 20 minutes, look 20 feet away for 20 seconds. Optimise ambient lighting (no glare, not too bright). Conscious blink exercises. Reduce screen brightness. Lubricating eye drops if working in dry environments.",
    },
    "blink_ibi": {
        "title": "Inter-Blink Intervals  —  Blink Rhythm & Attention Variability",
        "nervous": "Time between successive blinks (seconds). Short, regular IBIs indicate relaxed baseline blink rhythm. Long IBIs indicate sustained focal attention or sympathetic activation. High BRV (blink-rate variability, equivalent of HRV for blinks) indicates attention fluctuation — the mind is switching between engagement and disengagement.",
        "psychological": "Low BRV = sustained, stable focus. High BRV = attention is wandering or fluctuating — possibly due to fatigue, mind-wandering, or emotional distraction. Monitoring BRV alongside blink rate gives a two-dimensional view of attentional state.",
        "exercise": "Fatigue from intense physical or cognitive work increases BRV as attentional control degrades. Skilled performance in sports requiring sustained visual attention (archery, shooting, tennis) correlates with low BRV during competition.",
        "improve": "Attention training protocols (e.g., sustained attention to response task, SART). Mindfulness meditation specifically trains the meta-awareness needed to detect and recover attention lapses. Optimised sleep significantly reduces BRV.",
    },
    "rsa": {
        "title": "RSA  —  Respiratory Sinus Arrhythmia (ms)",
        "nervous": "The natural cyclic oscillation of RR intervals that is phase-locked to respiration: the heart accelerates during inhalation (sympathetic withdrawal) and decelerates during exhalation (vagal activation). RSA amplitude is the peak-to-trough swing of RR intervals within each breath cycle, in milliseconds. It is the direct time-domain signature of vagal-cardiac coupling — sometimes called 'cardiac vagal tone'. Healthy resting range: 30–120 ms.",
        "psychological": "RSA is one of the most sensitive real-time markers of psychological state. Anxiety, rumination, and acute stress suppress RSA within seconds. Calm, mindful, or meditative states amplify it. RSA amplitude correlates strongly with emotional regulation capacity, attentional flexibility, and social engagement behaviour (Porges' polyvagal theory). Sustained RSA < 20 ms at rest is a clinical marker for autonomic dysregulation.",
        "exercise": "RSA collapses during vigorous exercise as sympathetic drive dominates. Slow, deliberate breathing between sets or during warm-up/cool-down maximises RSA and accelerates cardiovascular recovery. Elite endurance athletes show exceptionally high resting RSA — often 100–200 ms — reflecting lifelong vagal conditioning. Post-exercise RSA recovery speed is a direct fitness marker.",
        "improve": "Slow resonance breathing (5–6 br/min) at your personal resonance frequency produces the largest RSA amplitudes — this is the biofeedback target state. Longer exhale relative to inhale (I:E ≥ 1.5) further amplifies the vagal phase. Regular endurance training, cold immersion, and quality sleep all raise baseline RSA over weeks. Use the RSA chart during breathing sessions: maximising the amplitude directly maximises vagal activation.",
    },
    "rsa_idx": {
        "title": "RSA Index  —  ln(RSA band power)  [Porges]",
        "nervous": "Natural log of the heart-rate variability power concentrated at the detected breathing frequency — the Porges RSA index. Unlike raw amplitude, the log scale compresses outliers and normalises the skewed distribution, making it directly comparable to VTI (ln RMSSD). RSA Index > 4 indicates strong vagal-respiratory coupling. < 2 indicates poor coupling or insufficient data.",
        "psychological": "The RSA Index is the spectral-domain counterpart of RSA amplitude and correlates with the same vagal markers: emotional regulation, social engagement, and stress resilience. The Porges polyvagal framework identifies RSA Index as a core metric of the 'ventral vagal' (safe, calm) state. Tracking it over time reveals whether mind-body practices are producing durable autonomic shifts.",
        "exercise": "Collapses during intense effort, rises sharply with recovery breathing. The rate of RSA Index restoration after a hard set or sprint is a sensitive marker of cardiovascular fitness. Athletes in optimal training show rapid RSA Index recovery (full restoration within 2–3 minutes post-effort).",
        "improve": "Same interventions as RSA amplitude: resonance breathing, extended exhale, aerobic conditioning, sleep. The Index responds faster than SDNN or VLF to acute breathing interventions — you can see a 0.5–1.0 point rise within a single 10-minute slow-breathing session.",
    },
}

_ACTIVITY_CATS: dict[str, dict] = {
    "food":       {"icon": "🍽",  "color": "#f97316",
                   "presets": ["Breakfast", "Lunch", "Dinner", "Snack", "Heavy meal", "Light meal"]},
    "caffeine":   {"icon": "☕",  "color": "#ca8a04",
                   "presets": ["Coffee", "Espresso", "Tea", "Green tea", "Energy drink", "Pre-workout"]},
    "supplement": {"icon": "💊",  "color": "#7c3aed",
                   "presets": ["Magnesium", "Omega-3", "Vitamin D", "L-theanine", "Ashwagandha", "Creatine"]},
    "exercise":   {"icon": "🏃",  "color": "#16a34a",
                   "presets": ["Running", "Cycling", "Strength / Gym", "HIIT", "Yoga", "Swimming", "Walking"]},
    "breathwork": {"icon": "🌬",  "color": "#0ea5e9",
                   "presets": ["Box breathing", "4-7-8", "Wim Hof", "Coherent breathing", "Custom"]},
    "meditation": {"icon": "🧘",  "color": "#8b5cf6",
                   "presets": ["Mindfulness", "Body scan", "Guided", "NSDR / Yoga nidra"]},
    "work":       {"icon": "💼",  "color": "#64748b",
                   "presets": ["Deep work", "Meeting", "Email / Admin", "Creative", "Break"]},
    "sleep":      {"icon": "😴",  "color": "#3b82f6",
                   "presets": ["Sleep onset", "Woke up", "Nap"]},
    "stress":     {"icon": "⚡",  "color": "#dc2626",
                   "presets": ["Stressful event", "Conflict", "High-pressure task", "Deadline"]},
    "social":     {"icon": "👥",  "color": "#059669",
                   "presets": ["Social", "Call", "Family time"]},
    "other":      {"icon": "📌",  "color": "#6b7280",   "presets": []},
}

_INFO_BTN_STYLE = {
    "backgroundColor": "transparent",
    "color": C_DIM,
    "border": f"1px solid {C_BORDER}",
    "borderRadius": "50%",
    "width": "18px",
    "height": "18px",
    "fontSize": "10px",
    "lineHeight": "17px",
    "cursor": "pointer",
    "padding": "0",
    "textAlign": "center",
    "fontFamily": "'JetBrains Mono', monospace",
    "flexShrink": "0",
    "marginLeft": "6px",
}


def _info_btn(metric: str, section: str = "live") -> html.Button:
    return html.Button(
        "?",
        id={"type": "info-btn", "metric": metric, "section": section},
        n_clicks=0,
        style=_INFO_BTN_STYLE,
        title=_METRIC_INFO.get(metric, {}).get("title", ""),
    )


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
CREATE TABLE IF NOT EXISTS activities (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           TEXT NOT NULL,
    ts_date      TEXT NOT NULL,
    ts_time      TEXT NOT NULL,
    category     TEXT NOT NULL,
    name         TEXT NOT NULL,
    notes        TEXT DEFAULT '',
    duration_min INTEGER DEFAULT 0,
    intensity    INTEGER DEFAULT 0,
    source       TEXT DEFAULT 'manual'
);
CREATE INDEX IF NOT EXISTS idx_act_date ON activities(ts_date);
CREATE TABLE IF NOT EXISTS custom_categories (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    key    TEXT UNIQUE NOT NULL,
    icon   TEXT NOT NULL DEFAULT '📌',
    color  TEXT NOT NULL DEFAULT '#6b7280',
    label  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS custom_presets (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    category TEXT NOT NULL,
    name     TEXT NOT NULL,
    UNIQUE(category, name)
);
"""

def _open_db() -> sqlite3.Connection:
    conn = sqlite3.connect(_DB_PATH, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=DELETE")  # no WAL sidecar files — safer under kill -9
    conn.executescript(_CREATE_METRICS)
    # Add columns to existing databases that predate them
    for col in ("vlf REAL DEFAULT 0", "mean_ie REAL DEFAULT 0",
                "pnn50 REAL DEFAULT 0", "sdnn REAL DEFAULT 0",
                "ulf REAL DEFAULT 0",
                "rsa_ms REAL DEFAULT 0", "rsa_idx REAL DEFAULT 0"):
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
        "(ts, ts_date, vti, cbi, rmssd, breath_bpm, bpm, lfhf, vlf, mean_ie, pnn50, sdnn, ulf, rsa_ms, rsa_idx) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (now.isoformat(), now.strftime("%Y-%m-%d"),
         rec["vti"], rec["cbi"], rec["rmssd"],
         rec["breath_bpm"], rec["bpm"], rec["lfhf"], rec["vlf"], rec["mean_ie"],
         rec["pnn50"], rec["sdnn"], rec.get("ulf") or 0.0,
         rec.get("rsa_ms") or 0.0, rec.get("rsa_idx") or 0.0),
    )
    conn.commit()

def _load_today(conn: sqlite3.Connection) -> list[dict]:
    today = datetime.now().strftime("%Y-%m-%d")
    cur = conn.execute(
        "SELECT ts, vti, cbi, rmssd, breath_bpm, bpm, lfhf, vlf, mean_ie, pnn50, sdnn, ulf, rsa_ms, rsa_idx "
        "FROM biometric_metrics WHERE ts_date=? ORDER BY ts",
        (today,),
    )
    return [
        dict(t=row[0][11:16], vti=row[1], cbi=row[2], rmssd=row[3],
             breath_bpm=row[4], bpm=row[5], lfhf=row[6], vlf=row[7] or 0.0,
             mean_ie=row[8] or 0.0, pnn50=row[9] or 0.0, sdnn=row[10] or 0.0,
             ulf=row[11] or 0.0, rsa_ms=row[12] or 0.0, rsa_idx=row[13] or 0.0)
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
               AVG(CASE WHEN pnn50      > 0 THEN pnn50      END),
               AVG(CASE WHEN sdnn       > 0 THEN sdnn       END),
               AVG(CASE WHEN bpm        > 0 THEN bpm        END),
               AVG(CASE WHEN vlf        > 0 THEN vlf        END),
               AVG(CASE WHEN ulf        > 0 THEN ulf        END),
               AVG(CASE WHEN rsa_ms     > 0 THEN rsa_ms     END),
               AVG(CASE WHEN rsa_idx    > 0 THEN rsa_idx    END),
               COUNT(*)
        FROM biometric_metrics
        WHERE ts_date >= date('now','-6 days')
        GROUP BY ts_date
        ORDER BY ts_date
    """)
    rows = []
    for r in cur.fetchall():
        date, vti, cbi, rmssd, breath, lfhf, pnn50, sdnn, bpm, vlf, ulf, rsa_ms, rsa_idx, n = r
        label = datetime.strptime(date, "%Y-%m-%d").strftime("%a %d")
        rows.append(dict(
            date=date, label=label,
            vti=round(vti, 2)    if vti    else 0,
            cbi=round(cbi, 3)    if cbi    else 0,
            rmssd=round(rmssd,1) if rmssd  else 0,
            breath_bpm=round(breath,1) if breath else 0,
            lfhf=round(lfhf, 2)  if lfhf   else 0,
            pnn50=round(pnn50,1) if pnn50  else 0,
            sdnn=round(sdnn, 1)  if sdnn   else 0,
            bpm=round(bpm, 1)    if bpm    else 0,
            vlf=round(vlf, 1)          if vlf     else 0,
            ulf=round(ulf, 1)          if ulf     else 0,
            rsa_ms=round(rsa_ms, 1)   if rsa_ms  else 0,
            rsa_idx=round(rsa_idx, 3) if rsa_idx else 0,
            n=n,
        ))
    return rows


def _save_activity(conn: sqlite3.Connection, rec: dict) -> None:
    conn.execute(
        "INSERT INTO activities (ts, ts_date, ts_time, category, name, notes, duration_min, intensity, source) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (rec["ts"], rec["ts_date"], rec["ts_time"], rec["category"], rec["name"],
         rec.get("notes", ""), rec.get("duration_min", 0), rec.get("intensity", 0),
         rec.get("source", "manual")),
    )
    conn.commit()


def _load_activities_today(conn: sqlite3.Connection) -> list[dict]:
    today = datetime.now().strftime("%Y-%m-%d")
    cur = conn.execute(
        "SELECT id, ts, ts_date, ts_time, category, name, notes, duration_min, intensity, source "
        "FROM activities WHERE ts_date=? ORDER BY ts DESC",
        (today,),
    )
    return [
        dict(id=r[0], ts=r[1], ts_date=r[2], ts_time=r[3], category=r[4],
             name=r[5], notes=r[6], duration_min=r[7], intensity=r[8], source=r[9])
        for r in cur.fetchall()
    ]


def _load_activities_week(conn: sqlite3.Connection) -> list[dict]:
    cur = conn.execute(
        "SELECT id, ts, ts_date, ts_time, category, name, notes, duration_min, intensity, source "
        "FROM activities WHERE ts_date >= date('now','-6 days') ORDER BY ts",
    )
    return [
        dict(id=r[0], ts=r[1], ts_date=r[2], ts_time=r[3], category=r[4],
             name=r[5], notes=r[6], duration_min=r[7], intensity=r[8], source=r[9])
        for r in cur.fetchall()
    ]


def _load_activities_14d(conn: sqlite3.Connection) -> list[dict]:
    cur = conn.execute(
        "SELECT id, ts, ts_date, ts_time, category, name, notes, duration_min, intensity, source "
        "FROM activities WHERE ts_date >= date('now','-13 days') ORDER BY ts",
    )
    return [
        dict(id=r[0], ts=r[1], ts_date=r[2], ts_time=r[3], category=r[4],
             name=r[5], notes=r[6], duration_min=r[7], intensity=r[8], source=r[9])
        for r in cur.fetchall()
    ]


def _delete_activity(conn: sqlite3.Connection, activity_id: int) -> None:
    conn.execute("DELETE FROM activities WHERE id=?", (activity_id,))
    conn.commit()


def _load_custom_categories(conn: sqlite3.Connection) -> list[dict]:
    cur = conn.execute(
        "SELECT id, key, icon, color, label FROM custom_categories ORDER BY label"
    )
    return [dict(id=r[0], key=r[1], icon=r[2], color=r[3], label=r[4])
            for r in cur.fetchall()]


def _load_custom_presets(conn: sqlite3.Connection) -> list[dict]:
    cur = conn.execute(
        "SELECT id, category, name FROM custom_presets ORDER BY category, name"
    )
    return [dict(id=r[0], category=r[1], name=r[2]) for r in cur.fetchall()]


def _save_custom_category(conn: sqlite3.Connection, key: str, icon: str,
                           color: str, label: str) -> None:
    conn.execute(
        "INSERT OR IGNORE INTO custom_categories (key, icon, color, label) VALUES (?,?,?,?)",
        (key, icon, color, label),
    )
    conn.commit()


def _save_custom_preset(conn: sqlite3.Connection, category: str, name: str) -> None:
    conn.execute(
        "INSERT OR IGNORE INTO custom_presets (category, name) VALUES (?,?)",
        (category, name),
    )
    conn.commit()


def _delete_custom_category(conn: sqlite3.Connection, cat_id: int) -> None:
    # Cascade-delete its custom presets too
    conn.execute(
        "DELETE FROM custom_presets WHERE category = "
        "(SELECT key FROM custom_categories WHERE id=?)", (cat_id,)
    )
    conn.execute("DELETE FROM custom_categories WHERE id=?", (cat_id,))
    conn.commit()


def _delete_custom_preset(conn: sqlite3.Connection, preset_id: int) -> None:
    conn.execute("DELETE FROM custom_presets WHERE id=?", (preset_id,))
    conn.commit()


import re as _re


def _slugify(text: str) -> str:
    return _re.sub(r"[^a-z0-9_]", "_", text.lower().strip())[:32].strip("_") or "custom"


def _get_all_cats(conn: sqlite3.Connection) -> dict:
    """Return merged dict of built-in _ACTIVITY_CATS + DB custom categories/presets."""
    merged = {k: dict(v) for k, v in _ACTIVITY_CATS.items()}
    # Collect custom presets for all categories (built-in + custom)
    extra_presets: dict[str, list[str]] = {}
    for p in _load_custom_presets(conn):
        extra_presets.setdefault(p["category"], []).append(p["name"])
    # Append custom presets to built-in categories
    for key in list(_ACTIVITY_CATS.keys()):
        if key in extra_presets:
            merged[key] = dict(merged[key])
            merged[key]["presets"] = list(_ACTIVITY_CATS[key]["presets"]) + extra_presets[key]
    # Add custom categories
    for cat in _load_custom_categories(conn):
        key = cat["key"]
        merged[key] = {
            "icon":    cat["icon"],
            "color":   cat["color"],
            "presets": extra_presets.get(key, []),
        }
    return merged


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
               mean_ie: float | None = None,
               pnn50: float | None = None,
               sdnn: float | None = None,
               ulf: float | None = None,
               rsa_ms: float | None = None,
               rsa_idx: float | None = None) -> None:
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
                pnn50=round(pnn50, 1)           if pnn50      is not None else 0.0,
                sdnn=round(sdnn, 1)             if sdnn       is not None else 0.0,
                ulf=round(ulf, 1)               if ulf        is not None else 0.0,
                rsa_ms=round(rsa_ms, 2)         if rsa_ms     is not None else 0.0,
                rsa_idx=round(rsa_idx, 3)       if rsa_idx    is not None else 0.0,
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

    def _on_disconnect(self, _client) -> None:
        """Called by Bleak when the device drops unexpectedly.
        Wake the keep-alive loop immediately so it can reconnect."""
        print("Device disconnected — triggering reconnect.", flush=True)
        _sensor_status["state"] = "disconnected — reconnecting…"
        _ble_reconnect.set()

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
_sensor_status = {"state": "searching", "device": "", "since": time.time(), "battery": None}

# ── eye blink detector ────────────────────────────────────────────────────────
_blink = BlinkDetector()
_blink_rate_history: deque[dict] = deque(maxlen=2700)  # ≈ 90 min at 2 s cadence

# Recording toggle — when False, metrics are not saved to SQLite / history.
# Live waveforms and gauges still update so you can monitor without recording.
_measuring: dict = {"active": True}

# Auto-detect state for exercise detection from ACC / HR signals.
_auto_detect: dict = {"exercise_streak": 0, "pending_exercise_ts": None,
                      "hr_streak": 0, "pending_hr_ts": None}

# Last KPI values written by the slow callback, read by the fast callback.
# Avoids running Welch PSD in the 200 ms loop.
_kpi_cache: dict = {
    "bpm": "—", "rmssd": "—", "sdnn": "—", "pnn50": "—",
    "breath": "—", "regularity": "—", "lfhf": "—",
    "rsa_ms": "—", "rsa_idx": "—",
}

# ── BLE scan + device-selection state ────────────────────────────────────────
_scan_state: dict  = {"status": "idle", "devices": [], "error": ""}
_target_device: dict = {"address": None, "name": "Polar H10"}
_ble_reconnect = threading.Event()  # set to interrupt keep-alive and reconnect
_ble_stopped   = threading.Event()  # set to disconnect and stop reconnect loop
_ble_sensor_ref: dict = {"sensor": None}  # live sensor handle for disconnect


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
                # If intentionally disconnected, wait here until reconnect is requested.
                while _ble_stopped.is_set():
                    await asyncio.sleep(0.5)

                # Interruptible delay between retries — wakes early on reconnect request
                for _ in range(delay * 2):
                    await asyncio.sleep(0.5)
                    if _ble_reconnect.is_set() or _ble_stopped.is_set():
                        break
                _ble_reconnect.clear()
                if _ble_stopped.is_set():
                    continue   # go back to the stopped-wait loop above
                delay = 5   # default retry wait after first attempt

                sensor = LivePolarH10(buf)
                _ble_sensor_ref["sensor"] = sensor
                addr = _target_device.get("address")
                try:
                    _sensor_status["state"] = (
                        f"connecting to {addr[:17]}…" if addr else "searching…"
                    )
                    await sensor.connect(timeout=20.0, device_address=addr)
                    _sensor_status.update(state="connected",
                                          device=sensor._device_label,
                                          since=time.time())
                    # 15-second hard timeout — catches the post-reconnect PMD hang
                    await asyncio.wait_for(sensor.start_streams(), timeout=15.0)
                    # Read battery once after streams are up
                    _sensor_status["battery"] = await sensor.read_battery()
                    # keep-alive: exit on disconnect, user reconnect, or stop request
                    while not _ble_reconnect.is_set() and not _ble_stopped.is_set():
                        await asyncio.sleep(0.5)
                        # Belt-and-suspenders: detect silent drop if callback didn't fire
                        if sensor._client and not sensor._client.is_connected:
                            _sensor_status["state"] = "disconnected — reconnecting…"
                            break
                    _ble_reconnect.clear()
                    delay = 0   # fast reconnect on disconnect or user request
                except asyncio.TimeoutError:
                    print("start_streams() timed out — reconnecting", flush=True)
                    _sensor_status["state"] = "stream start timed out — reconnecting…"
                except RuntimeError:
                    _sensor_status["state"] = (
                        "not found — check power / Bluetooth permission, retrying…"
                    )
                except Exception as exc:
                    _sensor_status["state"] = f"error: {str(exc)[:60]} — retrying…"
                finally:
                    _sensor_status["battery"] = None
                    # Hard 5-second timeouts on teardown — prevents the loop from
                    # hanging indefinitely if Bleak blocks writing to a dead device.
                    try:
                        await asyncio.wait_for(sensor.stop_streams(), timeout=5.0)
                    except Exception:
                        pass
                    try:
                        await asyncio.wait_for(sensor.disconnect(), timeout=5.0)
                    except Exception:
                        pass

        loop.run_until_complete(_run())
        loop.close()

    threading.Thread(target=_thread, daemon=True).start()


# ── Dash app ──────────────────────────────────────────────────────────────────
app = dash.Dash(__name__, title="Just Breathe")
app.server.config["SECRET_KEY"] = "just-breathe"


@app.server.after_request
def _no_cache_dash_internal(response):
    """Prevent browser from caching Dash's callback map so stale signatures never persist."""
    if _flask_req.path in ("/_dash-dependencies", "/_dash-layout"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        response.headers["Pragma"] = "no-cache"
    return response


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


def _add_activity_overlays(fig: go.Figure, activities: list[dict],
                           cats: dict = _ACTIVITY_CATS) -> go.Figure:
    """Add dotted vertical lines for each logged activity onto a time-series figure."""
    _fallback = cats.get("other", _ACTIVITY_CATS["other"])
    for act in activities:
        cat_info = cats.get(act["category"], _fallback)
        color = cat_info["color"]
        icon  = cat_info["icon"]
        # Use add_shape + add_annotation separately — add_vline with string x values
        # triggers a Plotly bug where it tries to sum strings when computing annotation position.
        fig.add_shape(
            type="line",
            x0=act["ts_time"], x1=act["ts_time"],
            y0=0, y1=1, yref="paper", xref="x",
            line=dict(color=color, width=1.5, dash="dot"),
            opacity=0.6,
        )
        fig.add_annotation(
            x=act["ts_time"], y=1, yref="paper", xref="x",
            text=f"{icon} {act['name'][:10]}",
            showarrow=False,
            font=dict(size=8, color=color),
            xanchor="left", yanchor="top",
            bgcolor="rgba(0,0,0,0)",
        )
    return fig


def _activity_timeline_fig(activities: list[dict], records: list[dict],
                           cats: dict = _ACTIVITY_CATS) -> go.Figure:
    """Swim-lane activity markers with VTI overlay on secondary y-axis."""
    _fallback = cats.get("other", _ACTIVITY_CATS["other"])
    fig = go.Figure()

    if not activities and not records:
        fig.update_layout(
            **_PLOT_LAYOUT,
            title=dict(text="Activity Timeline", font=dict(color=C_DIM, size=12), x=0.01),
        )
        fig.add_annotation(text="no activities logged yet", x=0.5, y=0.5,
                           showarrow=False, xref="paper", yref="paper",
                           font=dict(color=C_DIM, size=13))
        return fig

    # Primary y-axis: swim lanes per category
    cats_present = list(dict.fromkeys(a["category"] for a in activities))
    cat_y = {cat: i for i, cat in enumerate(cats_present)}

    for cat in cats_present:
        acts = [a for a in activities if a["category"] == cat]
        info = cats.get(cat, _fallback)
        fig.add_trace(go.Scatter(
            x=[a["ts_time"] for a in acts],
            y=[cat_y[cat]] * len(acts),
            mode="markers+text",
            marker=dict(size=14, color=info["color"], symbol="circle",
                        line=dict(color=C_CARD, width=1)),
            text=[f"{info['icon']} {a['name'][:8]}" for a in acts],
            textposition="top center",
            textfont=dict(size=8, color=info["color"]),
            name=f"{info['icon']} {cat}",
            hovertemplate="<b>%{text}</b><br>%{x}<extra></extra>",
            yaxis="y",
        ))

    # Secondary y-axis: VTI trend
    if records:
        buckets: dict[str, list] = {}
        for r in records:
            v = r.get("vti", 0)
            if v > 0:
                t = r["t"]
                buckets.setdefault(t, []).append(v)
        if buckets:
            vts = list(buckets.keys())
            vvals = [float(np.mean(v)) for v in buckets.values()]
            fig.add_trace(go.Scatter(
                x=vts, y=vvals, mode="lines",
                line=dict(color=C_VTI, width=1.5, dash="solid"),
                name="VTI", yaxis="y2",
                hovertemplate="VTI %{y:.2f}<extra></extra>",
                opacity=0.7,
            ))

    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision="activity-timeline",
        title=dict(text="Activity Timeline  ·  today", font=dict(color=C_DIM, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=dict(
            tickmode="array",
            tickvals=list(cat_y.values()),
            ticktext=[f"{cats.get(c, _fallback)['icon']} {c}" for c in cats_present],
            showgrid=True, gridcolor=C_BORDER, zeroline=False,
            tickfont=dict(color=C_DIM, size=10),
        ),
        yaxis2=dict(
            overlaying="y", side="right",
            title="VTI", showgrid=False,
            tickfont=dict(color=C_VTI, size=9),
            zeroline=False,
        ),
        legend=dict(font=dict(size=9, color=C_DIM), bgcolor="rgba(0,0,0,0)",
                    orientation="h", y=-0.2),
        showlegend=True,
    )
    return fig


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
                     color: str, metric: str | None = None,
                     section: str = "live") -> html.Div:
    children = [
        dcc.Store(id=store_id, data="60"),
        html.Button("60 m", id=b60,  n_clicks=0, style=_rbtn_style(True,  color)),
        html.Button("2 h",  id=b120, n_clicks=0, style=_rbtn_style(False, color)),
        html.Button("12 h", id=b720, n_clicks=0, style=_rbtn_style(False, color)),
    ]
    if metric:
        children.append(_info_btn(metric, section))
    return html.Div(children, style={"display": "flex", "gap": "4px"})


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


def _vlf_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "vlf", "VLF Power  (0.003–0.04 Hz)", C_VLF, "ms²")
    fig.add_hline(y=500, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="good  ≥ 500", annotation_position="bottom right")
    fig.add_hline(y=100, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 100", annotation_position="top right")
    return fig


def _ulf_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "ulf", "ULF Power  (< 0.003 Hz)  ·  needs ≥ 30 min", C_ULF, "ms²")
    fig.add_hline(y=800, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="good  ≥ 800", annotation_position="bottom right")
    fig.add_hline(y=200, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 200", annotation_position="top right")
    return fig


def _rsa_zones(fig: go.Figure) -> go.Figure:
    """Overlay low / moderate / good / strong RSA amplitude bands."""
    fig.add_hrect(y0=0,   y1=20,  fillcolor="rgba(248,81,73,0.10)",  line_width=0,
                  annotation_text="low",      annotation_position="top left",
                  annotation_font=dict(color=C_BAD,  size=10))
    fig.add_hrect(y0=20,  y1=50,  fillcolor="rgba(210,153,34,0.10)", line_width=0,
                  annotation_text="moderate", annotation_position="top left",
                  annotation_font=dict(color=C_WARN, size=10))
    fig.add_hrect(y0=50,  y1=100, fillcolor="rgba(251,146,60,0.07)", line_width=0,
                  annotation_text="good",     annotation_position="top left",
                  annotation_font=dict(color=C_RSA,  size=10))
    fig.add_hrect(y0=100, y1=250, fillcolor="rgba(63,185,80,0.10)",  line_width=0,
                  annotation_text="strong",   annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hline(y=20,  line_dash="dash", line_color=C_BAD,  line_width=1)
    fig.add_hline(y=50,  line_dash="dash", line_color=C_WARN, line_width=1)
    fig.add_hline(y=100, line_dash="dash", line_color=C_GOOD, line_width=1)
    return fig


def _rsa_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """RSA amplitude rolling chart with vagal-coupling zone bands."""
    n      = minutes * 30
    window = records[-n:] if len(records) > n else records
    if not window:
        return _rsa_zones(_empty_fig("RSA  —  Respiratory Sinus Arrhythmia (ms)"))

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("rsa_ms", 0)
        if v > 0:
            buckets.setdefault(r["t"], []).append(v)

    if not buckets:
        return _rsa_zones(_empty_fig("RSA  —  Respiratory Sinus Arrhythmia (ms)"))

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_RSA, width=2),
        marker=dict(size=3, color=C_RSA),
        hovertemplate="%{x}  RSA %{y:.1f} ms<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"rsa-live-{minutes}",
        title=dict(
            text=f"RSA  —  Respiratory Sinus Arrhythmia  ·  last {_range_label(minutes)}  ·  1 min avg",
            font=dict(color=C_RSA, size=12), x=0.01,
        ),
        xaxis=_ax("time"),
        yaxis=_ax("ms", rangemode="tozero"),
    )
    return _rsa_zones(fig)


def _rsa_idx_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """RSA Index rolling live chart with reference lines."""
    n      = minutes * 30
    window = records[-n:] if len(records) > n else records
    title  = f"RSA Index  —  ln(RSA band power)  ·  last {_range_label(minutes)}  ·  1 min avg"
    if not window:
        return _empty_fig(title)

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("rsa_idx", 0)
        if v and v != 0:
            buckets.setdefault(r["t"], []).append(v)

    if not buckets:
        return _empty_fig(title)

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_RSA_IDX, width=2),
        marker=dict(size=3, color=C_RSA_IDX),
        hovertemplate="%{x}  RSA idx %{y:.2f}<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"rsa-idx-live-{minutes}",
        title=dict(text=title, font=dict(color=C_RSA_IDX, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax(""),
    )
    fig.add_hline(y=4.0, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="strong  ≥ 4", annotation_position="bottom right",
                  annotation_font=dict(color=C_GOOD, size=9))
    fig.add_hline(y=2.0, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 2", annotation_position="top right",
                  annotation_font=dict(color=C_BAD, size=9))
    return fig


def _rsa_ms_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "rsa_ms", "RSA  —  Respiratory Sinus Arrhythmia (ms)", C_RSA, "ms")
    return _rsa_zones(fig)


def _rsa_idx_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "rsa_idx", "RSA Index  —  ln(RSA band power)  [Porges]", C_RSA, "")
    fig.add_hline(y=4.0, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="strong  ≥ 4", annotation_position="bottom right")
    fig.add_hline(y=2.0, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 2", annotation_position="top right")
    return fig


def _sdnn_zones(fig: go.Figure) -> go.Figure:
    """Overlay low / moderate / good / strong HRV bands onto an SDNN figure."""
    fig.add_hrect(y0=0,   y1=20,  fillcolor="rgba(248,81,73,0.10)",  line_width=0,
                  annotation_text="low",      annotation_position="top left",
                  annotation_font=dict(color=C_BAD,  size=10))
    fig.add_hrect(y0=20,  y1=50,  fillcolor="rgba(210,153,34,0.10)", line_width=0,
                  annotation_text="moderate", annotation_position="top left",
                  annotation_font=dict(color=C_WARN, size=10))
    fig.add_hrect(y0=50,  y1=100, fillcolor="rgba(63,185,80,0.07)",  line_width=0,
                  annotation_text="good",     annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hrect(y0=100, y1=220, fillcolor="rgba(63,185,80,0.14)",  line_width=0,
                  annotation_text="strong",   annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hline(y=20,  line_dash="dash", line_color=C_BAD,  line_width=1)
    fig.add_hline(y=50,  line_dash="dash", line_color=C_WARN, line_width=1)
    fig.add_hline(y=100, line_dash="dash", line_color=C_GOOD, line_width=1)
    return fig


def _pnn50_zones(fig: go.Figure) -> go.Figure:
    """Overlay low / moderate / good / strong parasympathetic bands onto a pNN50 figure."""
    fig.add_hrect(y0=0,  y1=3,   fillcolor="rgba(248,81,73,0.10)",  line_width=0,
                  annotation_text="low",      annotation_position="top left",
                  annotation_font=dict(color=C_BAD,  size=10))
    fig.add_hrect(y0=3,  y1=10,  fillcolor="rgba(210,153,34,0.10)", line_width=0,
                  annotation_text="moderate", annotation_position="top left",
                  annotation_font=dict(color=C_WARN, size=10))
    fig.add_hrect(y0=10, y1=25,  fillcolor="rgba(63,185,80,0.07)",  line_width=0,
                  annotation_text="good",     annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hrect(y0=25, y1=105, fillcolor="rgba(63,185,80,0.14)",  line_width=0,
                  annotation_text="strong",   annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hline(y=3,  line_dash="dash", line_color=C_BAD,  line_width=1)
    fig.add_hline(y=10, line_dash="dash", line_color=C_WARN, line_width=1)
    fig.add_hline(y=25, line_dash="dash", line_color=C_GOOD, line_width=1)
    return fig


def _hrv_live_fig(records: list[dict], key: str, title: str,
                  color: str, unit: str, minutes: int,
                  zone_fn) -> go.Figure:
    """Generic live HRV trend with configurable zone overlay."""
    n = minutes * 30
    window = records[-n:] if len(records) > n else records
    if not window:
        return zone_fn(_empty_fig(title))
    buckets: dict[str, list] = {}
    for r in window:
        v = r.get(key, 0)
        if v > 0:
            t = r["t"]
            if t not in buckets:
                buckets[t] = []
            buckets[t].append(v)
    if not buckets:
        return zone_fn(_empty_fig(title))
    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]
    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=color, width=2),
        marker=dict(size=3, color=color),
        hovertemplate=f"%{{x}}  {key.upper()} %{{y:.1f}} {unit}<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"{key}-live-{minutes}",
        title=dict(text=f"{title}  ·  last {_range_label(minutes)}  ·  1 min avg",
                   font=dict(color=color, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax(unit, rangemode="tozero"),
    )
    return zone_fn(fig)


def _sdnn_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    return _hrv_live_fig(records, "sdnn",  "SDNN",  C_SDNN,  "ms", minutes, _sdnn_zones)


def _pnn50_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    return _hrv_live_fig(records, "pnn50", "pNN50", C_PNN50, "%",  minutes, _pnn50_zones)


def _rmssd_zones(fig: go.Figure) -> go.Figure:
    """Overlay low / moderate / good / strong parasympathetic bands onto an RMSSD figure."""
    fig.add_hrect(y0=0,   y1=20,  fillcolor="rgba(248,81,73,0.10)",  line_width=0,
                  annotation_text="low",      annotation_position="top left",
                  annotation_font=dict(color=C_BAD,  size=10))
    fig.add_hrect(y0=20,  y1=50,  fillcolor="rgba(210,153,34,0.10)", line_width=0,
                  annotation_text="moderate", annotation_position="top left",
                  annotation_font=dict(color=C_WARN, size=10))
    fig.add_hrect(y0=50,  y1=100, fillcolor="rgba(63,185,80,0.07)",  line_width=0,
                  annotation_text="good",     annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hrect(y0=100, y1=250, fillcolor="rgba(63,185,80,0.14)",  line_width=0,
                  annotation_text="strong",   annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hline(y=20,  line_dash="dash", line_color=C_BAD,  line_width=1)
    fig.add_hline(y=50,  line_dash="dash", line_color=C_WARN, line_width=1)
    fig.add_hline(y=100, line_dash="dash", line_color=C_GOOD, line_width=1)
    return fig


def _rmssd_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    return _hrv_live_fig(records, "rmssd", "RMSSD  (parasympathetic activity)",
                         C_ACC, "ms", minutes, _rmssd_zones)


def _sdnn_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "sdnn", "SDNN  (overall HRV)", C_SDNN, "ms")
    fig.update_layout(yaxis=dict(rangemode="tozero"))
    return _sdnn_zones(fig)


def _pnn50_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "pnn50", "pNN50  (parasympathetic activity)", C_PNN50, "%")
    fig.update_layout(yaxis=dict(rangemode="tozero"))
    return _pnn50_zones(fig)


def _hr_zones(fig: go.Figure) -> go.Figure:
    """Overlay bradycardia / normal / elevated / high HR bands."""
    fig.add_hrect(y0=0,   y1=60,  fillcolor="rgba(88,166,255,0.08)",  line_width=0,
                  annotation_text="low",      annotation_position="top left",
                  annotation_font=dict(color=C_RR,   size=10))
    fig.add_hrect(y0=60,  y1=100, fillcolor="rgba(63,185,80,0.07)",   line_width=0,
                  annotation_text="normal",   annotation_position="top left",
                  annotation_font=dict(color=C_GOOD, size=10))
    fig.add_hrect(y0=100, y1=140, fillcolor="rgba(210,153,34,0.10)",  line_width=0,
                  annotation_text="elevated", annotation_position="top left",
                  annotation_font=dict(color=C_WARN, size=10))
    fig.add_hrect(y0=140, y1=220, fillcolor="rgba(248,81,73,0.10)",   line_width=0,
                  annotation_text="high",     annotation_position="top left",
                  annotation_font=dict(color=C_BAD,  size=10))
    fig.add_hline(y=60,  line_dash="dash", line_color=C_RR,   line_width=1)
    fig.add_hline(y=100, line_dash="dash", line_color=C_WARN, line_width=1)
    fig.add_hline(y=140, line_dash="dash", line_color=C_BAD,  line_width=1)
    return fig


def _hr_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """Heart rate live trend with zone bands — configurable window, 1-min avg."""
    n = minutes * 30
    window = records[-n:] if len(records) > n else records
    if not window:
        return _hr_zones(_empty_fig("Heart Rate  (bpm)"))
    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("bpm", 0)
        if v > 0:
            t = r["t"]
            if t not in buckets:
                buckets[t] = []
            buckets[t].append(v)
    if not buckets:
        return _hr_zones(_empty_fig("Heart Rate  (bpm)"))
    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]
    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_ECG, width=2),
        marker=dict(size=3, color=C_ECG),
        hovertemplate="%{x}  %{y:.0f} bpm<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"hr-live-{minutes}",
        title=dict(text=f"Heart Rate  ·  last {_range_label(minutes)}  ·  1 min avg",
                   font=dict(color=C_ECG, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("bpm", rangemode="tozero"),
    )
    return _hr_zones(fig)


def _hr_trend(records: list[dict]) -> go.Figure:
    fig = _trend_fig(records, "bpm", "Heart Rate", C_ECG, "bpm")
    return _hr_zones(fig)


def _vlf_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """VLF power line chart — configurable window, 1-min averages, 24 h mean line."""
    n = minutes * 30
    window = records[-n:] if len(records) > n else records
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

    # 24 h mean — computed from ALL today's records, not just the window
    all_vlf = [r.get("vlf", 0) for r in records if r.get("vlf", 0) > 0]
    mean_24h = float(np.mean(all_vlf)) if all_vlf else None

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_VLF, width=1.5),
        marker=dict(size=3, color=C_VLF),
        hovertemplate="%{x}  VLF %{y:.1f} ms²<extra></extra>",
    ))
    # Reference lines
    fig.add_hline(y=500, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="good  ≥ 500",
                  annotation_position="bottom right")
    fig.add_hline(y=100, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 100",
                  annotation_position="top right")
    # 24 h mean
    if mean_24h is not None:
        fig.add_hline(y=mean_24h, line_dash="dot", line_color=C_DIM, line_width=1.5,
                      annotation_text=f"24 h mean  {mean_24h:.0f}",
                      annotation_position="top left",
                      annotation_font=dict(color=C_DIM, size=10))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"vlf-live-{minutes}",
        title=dict(text=f"VLF Power  (0.003–0.04 Hz)  ·  last {_range_label(minutes)}  ·  1 min avg",
                   font=dict(color=C_VLF, size=12), x=0.01),
        xaxis=_ax("time"),
        yaxis=_ax("ms²", rangemode="tozero"),
    )
    return fig


def _ulf_live_fig(records: list[dict], minutes: int = 60) -> go.Figure:
    """ULF power line chart — configurable window, 1-min averages, 24 h mean line."""
    n = minutes * 30
    window = records[-n:] if len(records) > n else records
    if not window:
        return _empty_fig("ULF Power  (< 0.003 Hz)  ·  needs ≥ 30 min data")

    buckets: dict[str, list] = {}
    for r in window:
        v = r.get("ulf", 0)
        if v > 0:
            key = r["t"]
            if key not in buckets:
                buckets[key] = []
            buckets[key].append(v)

    if not buckets:
        return _empty_fig("ULF Power  (< 0.003 Hz)  ·  needs ≥ 30 min data")

    ts   = list(buckets.keys())
    vals = [float(np.mean(v)) for v in buckets.values()]

    # 24 h mean — computed from ALL today's records, not just the window
    all_ulf = [r.get("ulf", 0) for r in records if r.get("ulf", 0) > 0]
    mean_24h = float(np.mean(all_ulf)) if all_ulf else None

    fig = go.Figure(go.Scatter(
        x=ts, y=vals, mode="lines+markers",
        line=dict(color=C_ULF, width=1.5),
        marker=dict(size=3, color=C_ULF),
        hovertemplate="%{x}  ULF %{y:.1f} ms²<extra></extra>",
    ))
    # Physiological guidelines
    fig.add_hline(y=800, line_dash="dash", line_color=C_GOOD, line_width=1,
                  annotation_text="good  ≥ 800",
                  annotation_position="bottom right")
    fig.add_hline(y=200, line_dash="dash", line_color=C_BAD, line_width=1,
                  annotation_text="low  < 200",
                  annotation_position="top right")
    # 24 h mean
    if mean_24h is not None:
        fig.add_hline(y=mean_24h, line_dash="dot", line_color=C_DIM, line_width=1.5,
                      annotation_text=f"24 h mean  {mean_24h:.0f}",
                      annotation_position="top left",
                      annotation_font=dict(color=C_DIM, size=10))
    fig.update_layout(
        **_PLOT_LAYOUT,
        uirevision=f"ulf-live-{minutes}",
        title=dict(text=f"ULF Power  (< 0.003 Hz)  ·  last {_range_label(minutes)}  ·  1 min avg",
                   font=dict(color=C_ULF, size=12), x=0.01),
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
    dcc.Store(id="measure-store",     data="recording"),
    dcc.Store(id="eye-track-store",   data="on"),
    dcc.Store(id="info-modal-key",    data=None),
    dcc.Store(id="log-cat-store",      data=None),
    dcc.Store(id="log-refresh-store",  data=0),
    dcc.Store(id="manage-cats-refresh", data=0),

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
            html.Button("LOG",   id="nav-log",   n_clicks=0,
                        style=_nav_pill(False)),
        ], style={"display": "flex", "gap": "4px",
                  "backgroundColor": C_BORDER,
                  "borderRadius": "20px", "padding": "4px"}),

        # Connection status + session timer + device scanner toggle
        html.Div([
            html.Span(id="status-label", children="Searching for Polar H10…",
                      style={"color": C_DIM, "fontSize": "12px"}),
            html.Span(id="battery-label", children="",
                      style={"fontSize": "12px", "marginLeft": "6px"}),
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
            html.Button("👁 STOP EYE", id="btn-eye-toggle", n_clicks=0,
                        style={
                            "backgroundColor": "transparent",
                            "color": C_BLINK,
                            "border": f"1px solid {C_BLINK}",
                            "borderRadius": "12px",
                            "padding": "4px 14px",
                            "fontSize": "10px",
                            "fontWeight": "700",
                            "letterSpacing": "1px",
                            "cursor": "pointer",
                            "fontFamily": "'JetBrains Mono', monospace",
                        }),
            html.Span("  ·  ", style={"color": C_BORDER}),
            html.Button("↺ RECONNECT", id="btn-reconnect", n_clicks=0,
                        style={
                            "backgroundColor": "transparent",
                            "color": C_WARN,
                            "border": f"1px solid {C_WARN}",
                            "borderRadius": "12px",
                            "padding": "4px 14px",
                            "fontSize": "10px",
                            "fontWeight": "700",
                            "letterSpacing": "1px",
                            "cursor": "pointer",
                            "fontFamily": "'JetBrains Mono', monospace",
                        }),
            html.Span("  ·  ", style={"color": C_BORDER}),
            html.Button("⊗ DISCONNECT", id="btn-disconnect", n_clicks=0,
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
            _kpi_card("kpi-bpm",       "Heart Rate",  C_ECG,    "bpm"),
            _kpi_card("kpi-rmssd",     "RMSSD",       C_ACC,    "ms"),
            _kpi_card("kpi-sdnn",      "SDNN",        C_SDNN,   "ms"),
            _kpi_card("kpi-pnn50",     "pNN50",       C_PNN50,  "%"),
            _kpi_card("kpi-breath",    "Breathing",   C_PSD_HF, "br/m"),
            _kpi_card("kpi-regularity","Regularity",  C_COH,    ""),
            _kpi_card("kpi-lfhf",      "LF / HF",     C_CBI,    ""),
        ], style={"display": "grid", "gridTemplateColumns": "repeat(7, 1fr)",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 2 — raw waveforms
        html.Div([
            html.Div([
                html.Div([_info_btn("ecg")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="ecg-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("acc")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="acc-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 3 — derived signals + LF/HF live trend
        html.Div([
            html.Div([
                html.Div([_info_btn("rr")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="rr-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("psd")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="psd-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div(_range_btn_group("lfhf-range-store",
                                         "lfhf-btn-60", "lfhf-btn-120", "lfhf-btn-720",
                                         C_LFHF, metric="lfhf"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="lfhf-live-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 4 — coherence + VLF + ULF + extended metrics
        html.Div([
            html.Div([
                html.Div([_info_btn("coh")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="coh-graph", style={"height": "180px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div(_range_btn_group("vlf-range-store",
                                         "vlf-btn-60", "vlf-btn-120", "vlf-btn-720",
                                         C_VLF, metric="vlf"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="vlf-live-graph", style={"height": "170px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div(_range_btn_group("ulf-range-store",
                                         "ulf-btn-60", "ulf-btn-120", "ulf-btn-720",
                                         C_ULF, metric="ulf"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="ulf-live-graph", style={"height": "170px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
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
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr 1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 5 — Breathing phases (waveform + I:E bar chart)
        html.Div([
            html.Div([
                html.Div([_info_btn("breath_wave")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="breath-wave-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("ie_ratio")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="ie-ratio-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "2fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 6 — I:E ratio trend (full width)
        html.Div([
            html.Div(_range_btn_group("ie-range-store",
                                     "ie-btn-60", "ie-btn-120", "ie-btn-720",
                                     C_ACC, metric="ie_trend"),
                     style={"display": "flex", "justifyContent": "flex-end",
                            "marginBottom": "4px"}),
            dcc.Graph(id="ie-trend-graph", style={"height": "185px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # Row 7 — VTI · RMSSD · RSA amplitude · RSA Index  (four vagal metrics)
        html.Div([
            html.Div([
                html.Div(_range_btn_group("vti-range-store",
                                         "vti-btn-60", "vti-btn-120", "vti-btn-720",
                                         C_VTI, metric="vti"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="vti-live-graph", style={"height": "220px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([
                    dcc.Store(id="rmssd-range-store", data="60"),
                    html.Button("60 m", id="rmssd-btn-60",   n_clicks=0,
                                style=_rbtn_style(True,  C_ACC)),
                    html.Button("2 h",  id="rmssd-btn-120",  n_clicks=0,
                                style=_rbtn_style(False, C_ACC)),
                    html.Button("24 h", id="rmssd-btn-1440", n_clicks=0,
                                style=_rbtn_style(False, C_ACC)),
                    _info_btn("rmssd"),
                ], style={"display": "flex", "gap": "4px",
                          "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="rmssd-live-graph", style={"height": "220px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div(_range_btn_group("rsa-range-store",
                                         "rsa-btn-60", "rsa-btn-120", "rsa-btn-720",
                                         C_RSA, metric="rsa"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="rsa-live-graph", style={"height": "220px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div(_range_btn_group("rsa-idx-range-store",
                                         "rsa-idx-btn-60", "rsa-idx-btn-120", "rsa-idx-btn-720",
                                         C_RSA_IDX, metric="rsa_idx"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="rsa-idx-live-graph", style={"height": "220px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr 1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 8 — SDNN + pNN50 live trends (side by side)
        html.Div([
            html.Div([
                html.Div(_range_btn_group("sdnn-range-store",
                                         "sdnn-btn-60", "sdnn-btn-120", "sdnn-btn-720",
                                         C_SDNN, metric="sdnn"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="sdnn-live-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div(_range_btn_group("pnn50-range-store",
                                         "pnn50-btn-60", "pnn50-btn-120", "pnn50-btn-720",
                                         C_PNN50, metric="pnn50"),
                         style={"display": "flex", "justifyContent": "flex-end",
                                "marginBottom": "4px"}),
                dcc.Graph(id="pnn50-live-graph", style={"height": "200px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Row 9 — Heart Rate live trend (full width)
        html.Div([
            html.Div([
                dcc.Store(id="hr-range-store", data="60"),
                html.Button("60 m", id="hr-btn-60",   n_clicks=0,
                            style=_rbtn_style(True,  C_ECG)),
                html.Button("2 h",  id="hr-btn-120",  n_clicks=0,
                            style=_rbtn_style(False, C_ECG)),
                html.Button("24 h", id="hr-btn-1440", n_clicks=0,
                            style=_rbtn_style(False, C_ECG)),
                _info_btn("hr"),
            ], style={"display": "flex", "gap": "4px",
                      "justifyContent": "flex-end", "marginBottom": "4px"}),
            dcc.Graph(id="hr-live-graph", style={"height": "200px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # Row 10 — index gauges (CBI + VTI)
        html.Div([
            html.Div([
                html.Div("Conscious Breathing Index",
                         style={"color": C_DIM, "fontSize": "11px",
                                "textTransform": "uppercase", "letterSpacing": "1px",
                                "marginBottom": "2px"}),
                html.Div("Peak coherence 35% · regularity 25% · frequency 25% · RMSSD 15%",
                         style={"color": C_DIM, "fontSize": "10px", "marginBottom": "4px"}),
                html.Div([_info_btn("cbi")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="cbi-gauge", style={"height": "180px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div("Vagal Tone Index  —  ln(RMSSD)",
                         style={"color": C_DIM, "fontSize": "11px",
                                "textTransform": "uppercase", "letterSpacing": "1px",
                                "marginBottom": "2px"}),
                html.Div("Parasympathetic nervous system activity · >3.5 = good · <2.5 = low",
                         style={"color": C_DIM, "fontSize": "10px", "marginBottom": "4px"}),
                dcc.Graph(id="vti-gauge", style={"height": "180px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr", "gap": "10px"}),

        # ── Eye Blink Monitoring ──────────────────────────────────────────────
        html.Div(id="eye-section-wrapper", children=[html.Div([

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
                                             "blink-btn-720", C_BLINK, metric="blink_rate"),
                             style={"display": "flex", "justifyContent": "flex-end",
                                    "marginBottom": "4px"}),
                    dcc.Graph(id="blink-rate-graph", style={"height": "200px"},
                              config={"displayModeBar": False}),
                ], style=_CARD),
                html.Div([
                    html.Div([_info_btn("blink_ibi")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                    dcc.Graph(id="blink-ibi-graph", style={"height": "200px"},
                              config={"displayModeBar": False}),
                ], style=_CARD),
            ], style={"display": "grid", "gridTemplateColumns": "2fr 1fr",
                      "gap": "10px"}),

        ], style={**_CARD, "marginTop": "10px",
                  "borderTop": f"3px solid {C_BLINK}"})]),

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
            _today_stat("today-avg-hr",     "Avg Heart Rate",  C_ECG,    "bpm"),
            _today_stat("today-avg-vti",    "Avg Vagal Tone",  C_VTI),
            _today_stat("today-peak-cbi",   "Peak CBI",        C_CBI),
            _today_stat("today-avg-rmssd",  "Avg RMSSD",       C_ACC,    "ms"),
            _today_stat("today-avg-sdnn",   "Avg SDNN",        C_SDNN,   "ms"),
            _today_stat("today-avg-pnn50",  "Avg pNN50",       C_PNN50,  "%"),
            _today_stat("today-avg-breath", "Avg Breathing",   C_PSD_HF, "br/m"),
            _today_stat("today-avg-lfhf",   "Avg LF / HF",     C_LFHF),
            _today_stat("today-avg-rsa",    "Avg RSA",         C_RSA,    "ms"),
        ], style={"display": "grid", "gridTemplateColumns": "repeat(9, 1fr)",
                  "gap": "10px", "marginBottom": "14px"}),

        # VTI trend (full width)
        html.Div([
            html.Div([_info_btn("vti", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
            dcc.Graph(id="today-vti", style={"height": "220px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # CBI trend (full width)
        html.Div([
            html.Div([_info_btn("cbi", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
            dcc.Graph(id="today-cbi", style={"height": "220px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # RMSSD + RSA amplitude side by side  (both vagal-coupling time-domain metrics)
        html.Div([
            html.Div([
                html.Div([_info_btn("rmssd", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-rmssd",  style={"height": "210px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("rsa", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-rsa-ms", style={"height": "210px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # RSA Index + Breathing side by side
        html.Div([
            html.Div([
                html.Div([_info_btn("rsa_idx", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-rsa-idx", style={"height": "210px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("acc", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-breath", style={"height": "210px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # LF/HF trend (full width)
        html.Div([
            html.Div([_info_btn("lfhf", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
            dcc.Graph(id="today-lfhf", style={"height": "210px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # SDNN + pNN50 side by side
        html.Div([
            html.Div([
                html.Div([_info_btn("sdnn", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-sdnn",  style={"height": "210px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("pnn50", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-pnn50", style={"height": "210px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # VLF + ULF side by side
        html.Div([
            html.Div([
                html.Div([_info_btn("vlf", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-vlf", style={"height": "190px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("ulf", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="today-ulf", style={"height": "190px"},
                          config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Heart Rate trend (full width)
        html.Div([
            html.Div([_info_btn("hr", "today")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
            dcc.Graph(id="today-hr", style={"height": "200px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD}),

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

        # 3×2 bar chart grid
        html.Div([
            html.Div([
                html.Div([_info_btn("vti", "week")],   style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-vti",   style={"height": "240px"}, config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("cbi", "week")],   style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-cbi",   style={"height": "240px"}, config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("rmssd", "week")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-rmssd", style={"height": "240px"}, config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("lfhf", "week")],  style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-lfhf",  style={"height": "240px"}, config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("sdnn", "week")],  style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-sdnn",  style={"height": "240px"}, config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("pnn50", "week")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-pnn50", style={"height": "240px"}, config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # VLF + ULF side by side
        html.Div([
            html.Div([
                html.Div([_info_btn("vlf", "week")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-vlf", style={"height": "220px"}, config={"displayModeBar": False}),
            ], style=_CARD),
            html.Div([
                html.Div([_info_btn("ulf", "week")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
                dcc.Graph(id="week-ulf", style={"height": "220px"}, config={"displayModeBar": False}),
            ], style=_CARD),
        ], style={"display": "grid", "gridTemplateColumns": "1fr 1fr",
                  "gap": "10px", "marginBottom": "10px"}),

        # Heart Rate daily average (full width)
        html.Div([
            html.Div([_info_btn("hr", "week")], style={"display": "flex", "justifyContent": "flex-end", "marginBottom": "4px"}),
            dcc.Graph(id="week-hr", style={"height": "220px"}, config={"displayModeBar": False}),
        ], style=_CARD),

        # ── WEEK: activity frequency + impact (populated by update_week) ────────
        html.Div(id="week-activity-freq-wrap", children=[
            html.Div("Activity Frequency  —  Last 7 Days", style={
                "color": C_TEXT, "fontSize": "13px", "fontWeight": "700",
                "letterSpacing": "1px", "fontFamily": "'JetBrains Mono', monospace",
                "marginBottom": "10px", "marginTop": "14px",
            }),
            dcc.Graph(id="week-activity-freq", style={"height": "220px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginTop": "10px"}),

        html.Div(id="week-impact-table", style={"marginTop": "10px"}),

    ], id="content-week", style={"display": "none"}),

    # ══════════════════════════ LOG view ═══════════════════════════════════════
    html.Div([

        # Section header + auto-detect banner
        html.Div([
            html.Div("Activity Log", style={
                "color": C_TEXT, "fontSize": "16px", "fontWeight": "700",
                "letterSpacing": "1px", "fontFamily": "'JetBrains Mono', monospace",
            }),
            html.Div(id="today-log-count",
                     style={"color": C_DIM, "fontSize": "12px", "marginTop": "2px"}),
        ], style={"marginBottom": "14px"}),

        # Auto-detect banner (hidden unless movement/HR detected)
        html.Div(id="auto-detect-banner", style={"display": "none"}),

        # ── 4A: Quick-Log Panel ────────────────────────────────────────────────
        html.Div([
            # Header
            html.Div("LOG ACTIVITY", style={
                "color": C_DIM, "fontSize": "11px", "fontWeight": "700",
                "letterSpacing": "1.5px", "textTransform": "uppercase",
                "marginBottom": "12px",
            }),

            # Category row
            html.Div("CATEGORY", style={
                "color": C_DIM, "fontSize": "10px", "letterSpacing": "1px",
                "textTransform": "uppercase", "marginBottom": "8px",
            }),
            html.Div([
                html.Button(
                    f"{info['icon']} {cat.upper()}",
                    id={"type": "cat-btn", "cat": cat},
                    n_clicks=0,
                    style={
                        "backgroundColor": "transparent",
                        "color": C_DIM,
                        "border": f"1px solid {C_BORDER}",
                        "borderRadius": "12px",
                        "padding": "4px 12px",
                        "fontSize": "10px",
                        "fontWeight": "700",
                        "letterSpacing": "1px",
                        "cursor": "pointer",
                        "fontFamily": "'JetBrains Mono', monospace",
                    },
                )
                for cat, info in _ACTIVITY_CATS.items()
            ], style={"display": "flex", "flexWrap": "wrap", "gap": "6px",
                      "marginBottom": "6px"}),

            # Custom category buttons (populated dynamically)
            html.Div(id="custom-cat-row",
                     style={"display": "flex", "flexWrap": "wrap", "gap": "6px",
                            "marginBottom": "8px"}),

            html.Hr(style={"border": f"1px solid {C_BORDER}", "margin": "8px 0"}),

            # Preset chips (rendered dynamically)
            html.Div([
                html.Div("ACTIVITY", style={
                    "color": C_DIM, "fontSize": "10px", "letterSpacing": "1px",
                    "textTransform": "uppercase", "marginBottom": "6px",
                }),
                html.Div(id="log-preset-chips",
                         children=[html.Span("← select a category",
                                             style={"color": C_DIM, "fontSize": "11px"})]),
            ], style={"marginBottom": "12px"}),

            # Custom name input
            dcc.Input(
                id="log-custom-name",
                placeholder="custom name (or pick a preset above)",
                type="text",
                debounce=True,
                style={
                    "backgroundColor": C_BG,
                    "color": C_TEXT,
                    "border": f"1px solid {C_BORDER}",
                    "borderRadius": "6px",
                    "padding": "7px 12px",
                    "fontSize": "11px",
                    "fontFamily": "'JetBrains Mono', monospace",
                    "width": "100%",
                    "boxSizing": "border-box",
                    "marginBottom": "12px",
                },
            ),

            # Time + duration + notes row
            html.Div([
                html.Div([
                    html.Div("TIME", style={"color": C_DIM, "fontSize": "10px",
                                           "letterSpacing": "1px", "marginBottom": "4px"}),
                    dcc.Input(
                        id="log-time-input", type="text",
                        placeholder="HH:MM",
                        style={
                            "backgroundColor": C_BG, "color": C_TEXT,
                            "border": f"1px solid {C_BORDER}", "borderRadius": "6px",
                            "padding": "7px 10px", "fontSize": "11px", "width": "100px",
                            "fontFamily": "'JetBrains Mono', monospace",
                        },
                    ),
                ]),
                html.Div([
                    html.Div("DURATION (min)", style={"color": C_DIM, "fontSize": "10px",
                                                      "letterSpacing": "1px", "marginBottom": "4px"}),
                    dcc.Input(
                        id="log-duration", type="number", min=0, placeholder="0",
                        style={
                            "backgroundColor": C_BG, "color": C_TEXT,
                            "border": f"1px solid {C_BORDER}", "borderRadius": "6px",
                            "padding": "7px 10px", "fontSize": "11px", "width": "100px",
                            "fontFamily": "'JetBrains Mono', monospace",
                        },
                    ),
                ]),
                html.Div([
                    html.Div("NOTES", style={"color": C_DIM, "fontSize": "10px",
                                            "letterSpacing": "1px", "marginBottom": "4px"}),
                    dcc.Textarea(
                        id="log-notes",
                        placeholder="optional notes…",
                        style={
                            "backgroundColor": C_BG, "color": C_TEXT,
                            "border": f"1px solid {C_BORDER}", "borderRadius": "6px",
                            "padding": "7px 10px", "fontSize": "11px",
                            "fontFamily": "'JetBrains Mono', monospace",
                            "height": "38px", "resize": "none", "width": "100%",
                        },
                    ),
                ], style={"flex": "1"}),
            ], style={"display": "flex", "gap": "14px", "alignItems": "flex-start",
                      "marginBottom": "12px"}),

            # Action buttons + feedback
            html.Div([
                html.Button("＋ LOG", id="btn-log-submit", n_clicks=0, style={
                    "backgroundColor": C_GOOD, "color": C_BG,
                    "border": "none", "borderRadius": "10px",
                    "padding": "8px 22px", "fontSize": "11px", "fontWeight": "700",
                    "letterSpacing": "1.5px", "cursor": "pointer",
                    "fontFamily": "'JetBrains Mono', monospace",
                }),
                html.Button("✕ CLEAR", id="btn-log-clear", n_clicks=0, style={
                    "backgroundColor": "transparent", "color": C_DIM,
                    "border": f"1px solid {C_BORDER}", "borderRadius": "10px",
                    "padding": "8px 18px", "fontSize": "11px", "fontWeight": "700",
                    "letterSpacing": "1.5px", "cursor": "pointer",
                    "fontFamily": "'JetBrains Mono', monospace",
                }),
                html.Div(id="log-feedback",
                         style={"color": C_GOOD, "fontSize": "11px", "marginLeft": "10px",
                                "fontFamily": "'JetBrains Mono', monospace"}),
            ], style={"display": "flex", "alignItems": "center", "gap": "8px",
                      "marginBottom": "10px"}),

            # Smart suggestions
            html.Div(id="log-suggestions"),

        ], style={**_CARD, "marginBottom": "10px"}),

        # ── Manage Categories & Activities (collapsible) ───────────────────────
        html.Div([
            html.Button(
                "⚙ MANAGE CATEGORIES & ACTIVITIES",
                id="btn-manage-toggle", n_clicks=0,
                style={
                    "backgroundColor": "transparent", "color": C_DIM,
                    "border": f"1px solid {C_BORDER}", "borderRadius": "10px",
                    "padding": "7px 18px", "fontSize": "10px", "fontWeight": "700",
                    "letterSpacing": "1.5px", "cursor": "pointer",
                    "fontFamily": "'JetBrains Mono', monospace", "width": "100%",
                    "textAlign": "left",
                },
            ),
            html.Div(
                id="manage-panel",
                children=[html.Div(id="manage-panel-content")],
                style={"display": "none"},
            ),
        ], style={**_CARD, "marginBottom": "10px", "padding": "8px 16px"}),

        # ── 4B: Activity timeline chart ────────────────────────────────────────
        html.Div([
            dcc.Graph(id="activity-timeline-graph", style={"height": "220px"},
                      config={"displayModeBar": False}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # ── 4C: Today's activity list ──────────────────────────────────────────
        html.Div([
            html.Div("TODAY'S ACTIVITIES", style={
                "color": C_DIM, "fontSize": "11px", "fontWeight": "700",
                "letterSpacing": "1.5px", "textTransform": "uppercase",
                "marginBottom": "10px",
            }),
            html.Div(id="activity-list",
                     style={"maxHeight": "260px", "overflowY": "auto"}),
        ], style={**_CARD, "marginBottom": "10px"}),

        # ── 4D: Impact analysis table ──────────────────────────────────────────
        html.Div([
            html.Div("IMPACT ANALYSIS  —  30 min before vs after", style={
                "color": C_DIM, "fontSize": "11px", "fontWeight": "700",
                "letterSpacing": "1.5px", "textTransform": "uppercase",
                "marginBottom": "10px",
            }),
            html.Div(id="impact-table"),
        ], style={**_CARD}),

    ], id="content-log", style={"display": "none"}),

    # ── Info modal overlay ─────────────────────────────────────────────────────
    html.Div(id="info-modal-overlay", children=[
        html.Div([
            # Header
            html.Div([
                html.Span(id="info-modal-title",
                          style={"color": C_TEXT, "fontSize": "13px",
                                 "fontWeight": "700", "letterSpacing": "1px",
                                 "fontFamily": "'JetBrains Mono', monospace"}),
                html.Button("×", id="info-close-btn", n_clicks=0,
                            style={"backgroundColor": "transparent", "color": C_DIM,
                                   "border": "none", "fontSize": "20px", "cursor": "pointer",
                                   "lineHeight": "1", "padding": "0"}),
            ], style={"display": "flex", "justifyContent": "space-between",
                      "alignItems": "center", "marginBottom": "18px",
                      "borderBottom": f"1px solid {C_BORDER}", "paddingBottom": "12px"}),
            # Body
            html.Div(id="info-modal-body"),
        ], style={
            "backgroundColor": C_CARD,
            "border": f"1px solid {C_BORDER}",
            "borderRadius": "12px",
            "padding": "24px",
            "maxWidth": "620px",
            "width": "90%",
            "maxHeight": "80vh",
            "overflowY": "auto",
        }),
    ], style={"display": "none", "position": "fixed", "top": "0", "left": "0",
              "width": "100%", "height": "100%",
              "backgroundColor": "rgba(0,0,0,0.75)",
              "zIndex": "9999", "justifyContent": "center", "alignItems": "center"}),

], style={"backgroundColor": C_BG, "padding": "14px",
          "fontFamily": "'JetBrains Mono', 'Courier New', monospace",
          "minHeight": "100vh"})


# ── navigation callback ───────────────────────────────────────────────────────
@callback(
    Output("content-live",  "style"),
    Output("content-today", "style"),
    Output("content-week",  "style"),
    Output("content-log",   "style"),
    Output("nav-live",  "style"),
    Output("nav-today", "style"),
    Output("nav-week",  "style"),
    Output("nav-log",   "style"),
    Input("nav-live",  "n_clicks"),
    Input("nav-today", "n_clicks"),
    Input("nav-week",  "n_clicks"),
    Input("nav-log",   "n_clicks"),
    prevent_initial_call=True,
)
def switch_page(_nl, _nt, _nw, _nlog):
    tab = ctx.triggered_id   # "nav-live" | "nav-today" | "nav-week" | "nav-log"
    return (
        {"display": "block"} if tab == "nav-live"  else {"display": "none"},
        {"display": "block"} if tab == "nav-today" else {"display": "none"},
        {"display": "block"} if tab == "nav-week"  else {"display": "none"},
        {"display": "block"} if tab == "nav-log"   else {"display": "none"},
        _nav_pill(tab == "nav-live"),
        _nav_pill(tab == "nav-today"),
        _nav_pill(tab == "nav-week"),
        _nav_pill(tab == "nav-log"),
    )


# ── fast callback: waveforms + KPIs + status (100 ms) ────────────────────────
@callback(
    Output("ecg-graph",    "figure"),
    Output("acc-graph",    "figure"),
    Output("rr-graph",     "figure"),
    Output("kpi-bpm",        "children"),
    Output("kpi-rmssd",      "children"),
    Output("kpi-sdnn",       "children"),
    Output("kpi-pnn50",      "children"),
    Output("kpi-breath",     "children"),
    Output("kpi-regularity", "children"),
    Output("kpi-lfhf",       "children"),
    Output("status-dot",     "style"),
    Output("status-label",   "children"),
    Output("battery-label",  "children"),
    Output("battery-label",  "style"),
    Output("timer-label",    "children"),
    Output("btn-reconnect",  "style"),
    Input("tick-fast", "n_intervals"),
)
def update_fast(_n: int):
    ecg, acc, rr, _ = _buf.snapshot()

    # ── connection status (dict read only — no computation) ──────────────────
    state = _sensor_status["state"]
    _reconnect_base = {
        "backgroundColor": "transparent",
        "borderRadius": "12px",
        "padding": "4px 14px",
        "fontSize": "10px",
        "fontWeight": "700",
        "letterSpacing": "1px",
        "cursor": "pointer",
        "fontFamily": "'JetBrains Mono', monospace",
    }
    if state == "connected":
        dot_style      = {"color": C_GOOD, "fontSize": "18px"}
        status_lbl     = f"Connected · {_sensor_status['device']}"
        reconnect_style = {**_reconnect_base, "color": C_DIM,
                           "border": f"1px solid {C_BORDER}"}
    elif "reconnect" in state:
        dot_style      = {"color": C_WARN, "fontSize": "18px"}
        status_lbl     = state
        reconnect_style = {**_reconnect_base, "color": C_WARN,
                           "border": f"1px solid {C_WARN}"}
    else:
        dot_style      = {"color": C_BAD, "fontSize": "18px"}
        status_lbl     = state
        reconnect_style = {**_reconnect_base, "color": C_BAD,
                           "border": f"1px solid {C_BAD}"}

    # ── battery indicator ─────────────────────────────────────────────────────
    battery = _sensor_status.get("battery")
    if battery is not None:
        if battery >= 60:
            bat_color = C_GOOD
        elif battery >= 25:
            bat_color = C_WARN
        else:
            bat_color = C_BAD
        bat_text  = f"🔋 {battery}%"
        bat_style = {"color": bat_color, "fontSize": "12px", "marginLeft": "6px"}
    else:
        bat_text  = ""
        bat_style = {"display": "none"}

    elapsed = int(time.time() - _sensor_status["since"])
    timer   = f"{elapsed // 60:02d}:{elapsed % 60:02d}"

    # ── waveform figures (array slicing only — no FFT) ───────────────────────
    ecg_fig = _ecg_figure(ecg) if len(ecg) > 10 else _empty_fig("ECG  (µV)")
    acc_fig = _acc_figure(acc) if len(acc) > 10 else _empty_fig("ACC Z-axis — Breathing (mG)")
    rr_fig  = _rr_figure(rr)   if len(rr)  > 4  else _empty_fig("RR Tachogram (ms)")

    # ── KPI chips — read last values written by the slow callback ────────────
    k = _kpi_cache
    return (ecg_fig, acc_fig, rr_fig,
            k["bpm"], k["rmssd"], k["sdnn"], k["pnn50"], k["breath"], k["regularity"], k["lfhf"],
            dot_style, status_lbl, bat_text, bat_style, timer, reconnect_style)


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
        _kpi_cache["pnn50"]      = f"{hrv['pnn50']:.1f}"            if hrv       else "—"
        _kpi_cache["breath"]     = f"{breathing['bpm']:.1f}"        if breathing else "—"
        _kpi_cache["regularity"] = f"{breathing['regularity']:.2f}" if breathing else "—"
        _kpi_cache["lfhf"]       = (f"{hrv['lf_hf']:.2f}"
                                    if hrv and hrv["lf_hf"] is not None else "—")

        lfhf_val = hrv["lf_hf"] if hrv and hrv["lf_hf"] is not None else None

        pnn50_val = hrv["pnn50"] if hrv else None
        sdnn_val  = hrv["sdnn"]  if hrv else None

        # RSA: amplitude (ms) and Porges index from RR + detected breathing freq
        rsa_data  = metrics.compute_rsa(
            rr,
            breath_hz=breathing["peak_hz"] if breathing else None,
        )
        rsa_ms_val  = rsa_data["rsa_ms"]  if rsa_data else None
        rsa_idx_val = rsa_data["rsa_idx"] if rsa_data else None
        _kpi_cache["rsa_ms"]  = f"{rsa_ms_val:.1f}"  if rsa_ms_val  is not None else "—"
        _kpi_cache["rsa_idx"] = f"{rsa_idx_val:.3f}" if rsa_idx_val is not None else "—"

        # ULF: computed from full accumulated bpm series (needs ≥ 30 min of data)
        hist_rows  = _history.snapshot()
        bpm_series = [r["bpm"] for r in hist_rows if r.get("bpm", 0) > 20]
        ulf_val    = metrics.compute_ulf_power(bpm_series)

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
                        pnn50=pnn50_val             if pnn50_val else 0.0,
                        sdnn=sdnn_val               if sdnn_val  else 0.0,
                        ulf=ulf_val,
                        rsa_ms=rsa_ms_val,
                        rsa_idx=rsa_idx_val,
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
                pnn50=pnn50_val,
                sdnn=sdnn_val,
                ulf=ulf_val,
                rsa_ms=rsa_ms_val,
                rsa_idx=rsa_idx_val,
            )

        # ── Auto-detect exercise from ACC RMS ────────────────────────────────
        acc_rms = float(np.sqrt(np.mean(np.array(list(acc)) ** 2))) if acc else 0.0
        if acc_rms > 800:
            _auto_detect["exercise_streak"] += 1
        else:
            _auto_detect["exercise_streak"] = 0
        if _auto_detect["exercise_streak"] == 30:  # 30 × 2 s = 60 s sustained
            _auto_detect["pending_exercise_ts"] = datetime.now().strftime("%H:%M")

        # ── Auto-detect high-HR exercise ─────────────────────────────────────
        mean_bpm = hrv["mean_bpm"] if hrv else 0.0
        if mean_bpm > 130:
            _auto_detect["hr_streak"] += 1
        else:
            _auto_detect["hr_streak"] = 0
        if _auto_detect["hr_streak"] == 5:  # 5 × 2 s = 10 s sustained high HR
            _auto_detect["pending_hr_ts"] = datetime.now().strftime("%H:%M")

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

        rsa_ms_v  = f"{rsa_ms_val:.1f} ms"   if rsa_ms_val  is not None else "—"
        rsa_idx_v = f"{rsa_idx_val:.3f}"     if rsa_idx_val is not None else "—"

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
            f"RSA  amplitude   {rsa_ms_v}\n"
            f"RSA  index       {rsa_idx_v}\n"
            f"CBI              {cbi:.3f}"
        )

        breath_wave_fig = _breath_wave_fig(phases)
        ie_ratio_fig    = _ie_ratio_fig(phases)

        return (psd_fig, coh_fig, cbi_fig, vti_fig, ext,
                breath_wave_fig, ie_ratio_fig)

    except Exception:
        tb = traceback.format_exc()
        print(f"\n[slow ERROR]\n{tb}", flush=True)
        sf = _SAFE_FIG
        return sf, sf, sf, sf, tb[-600:], sf, sf


# ── RSA range button group ────────────────────────────────────────────────────
@callback(
    Output("rsa-range-store", "data"),
    Output("rsa-btn-60",  "style"),
    Output("rsa-btn-120", "style"),
    Output("rsa-btn-720", "style"),
    Input("rsa-btn-60",   "n_clicks"),
    Input("rsa-btn-120",  "n_clicks"),
    Input("rsa-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_rsa_range(_60, _120, _720):
    val = {"rsa-btn-60": "60", "rsa-btn-120": "120", "rsa-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_RSA),
            _rbtn_style(val == "120", C_RSA),
            _rbtn_style(val == "720", C_RSA))


# ── RSA live chart ─────────────────────────────────────────────────────────────
@callback(
    Output("rsa-live-graph",  "figure"),
    Input("tick-slow",        "n_intervals"),
    Input("rsa-range-store",  "data"),
)
def update_rsa_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _rsa_live_fig(rows, minutes=minutes)


# ── RSA Index range button group ──────────────────────────────────────────────
@callback(
    Output("rsa-idx-range-store", "data"),
    Output("rsa-idx-btn-60",  "style"),
    Output("rsa-idx-btn-120", "style"),
    Output("rsa-idx-btn-720", "style"),
    Input("rsa-idx-btn-60",   "n_clicks"),
    Input("rsa-idx-btn-120",  "n_clicks"),
    Input("rsa-idx-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_rsa_idx_range(_60, _120, _720):
    val = {"rsa-idx-btn-60": "60", "rsa-idx-btn-120": "120", "rsa-idx-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_RSA_IDX),
            _rbtn_style(val == "120", C_RSA_IDX),
            _rbtn_style(val == "720", C_RSA_IDX))


# ── RSA Index live chart ───────────────────────────────────────────────────────
@callback(
    Output("rsa-idx-live-graph",   "figure"),
    Input("tick-slow",             "n_intervals"),
    Input("rsa-idx-range-store",   "data"),
)
def update_rsa_idx_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _rsa_idx_live_fig(rows, minutes=minutes)


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


# ── VLF range button group ────────────────────────────────────────────────────
@callback(
    Output("vlf-range-store", "data"),
    Output("vlf-btn-60",  "style"),
    Output("vlf-btn-120", "style"),
    Output("vlf-btn-720", "style"),
    Input("vlf-btn-60",   "n_clicks"),
    Input("vlf-btn-120",  "n_clicks"),
    Input("vlf-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_vlf_range(_60, _120, _720):
    val = {"vlf-btn-60": "60", "vlf-btn-120": "120", "vlf-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_VLF),
            _rbtn_style(val == "120", C_VLF),
            _rbtn_style(val == "720", C_VLF))


# ── VLF live chart ─────────────────────────────────────────────────────────────
@callback(
    Output("vlf-live-graph",  "figure"),
    Input("tick-slow",        "n_intervals"),
    Input("vlf-range-store",  "data"),
)
def update_vlf_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _vlf_live_fig(rows, minutes=minutes)


# ── ULF range button group ────────────────────────────────────────────────────
@callback(
    Output("ulf-range-store", "data"),
    Output("ulf-btn-60",  "style"),
    Output("ulf-btn-120", "style"),
    Output("ulf-btn-720", "style"),
    Input("ulf-btn-60",   "n_clicks"),
    Input("ulf-btn-120",  "n_clicks"),
    Input("ulf-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_ulf_range(_60, _120, _720):
    val = {"ulf-btn-60": "60", "ulf-btn-120": "120", "ulf-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_ULF),
            _rbtn_style(val == "120", C_ULF),
            _rbtn_style(val == "720", C_ULF))


# ── ULF live chart ─────────────────────────────────────────────────────────────
@callback(
    Output("ulf-live-graph",  "figure"),
    Input("tick-slow",        "n_intervals"),
    Input("ulf-range-store",  "data"),
)
def update_ulf_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _ulf_live_fig(rows, minutes=minutes)


# ── SDNN range button group ───────────────────────────────────────────────────
@callback(
    Output("sdnn-range-store", "data"),
    Output("sdnn-btn-60",  "style"),
    Output("sdnn-btn-120", "style"),
    Output("sdnn-btn-720", "style"),
    Input("sdnn-btn-60",   "n_clicks"),
    Input("sdnn-btn-120",  "n_clicks"),
    Input("sdnn-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_sdnn_range(_60, _120, _720):
    val = {"sdnn-btn-60": "60", "sdnn-btn-120": "120", "sdnn-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_SDNN),
            _rbtn_style(val == "120", C_SDNN),
            _rbtn_style(val == "720", C_SDNN))


# ── SDNN live chart ────────────────────────────────────────────────────────────
@callback(
    Output("sdnn-live-graph",  "figure"),
    Input("tick-slow",         "n_intervals"),
    Input("sdnn-range-store",  "data"),
)
def update_sdnn_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _sdnn_live_fig(rows, minutes=minutes)


# ── pNN50 range button group ───────────────────────────────────────────────────
@callback(
    Output("pnn50-range-store", "data"),
    Output("pnn50-btn-60",  "style"),
    Output("pnn50-btn-120", "style"),
    Output("pnn50-btn-720", "style"),
    Input("pnn50-btn-60",   "n_clicks"),
    Input("pnn50-btn-120",  "n_clicks"),
    Input("pnn50-btn-720",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_pnn50_range(_60, _120, _720):
    val = {"pnn50-btn-60": "60", "pnn50-btn-120": "120", "pnn50-btn-720": "720"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",  C_PNN50),
            _rbtn_style(val == "120", C_PNN50),
            _rbtn_style(val == "720", C_PNN50))


# ── pNN50 live chart ───────────────────────────────────────────────────────────
@callback(
    Output("pnn50-live-graph",  "figure"),
    Input("tick-slow",          "n_intervals"),
    Input("pnn50-range-store",  "data"),
)
def update_pnn50_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _pnn50_live_fig(rows, minutes=minutes)


# ── RMSSD range button group ───────────────────────────────────────────────────
@callback(
    Output("rmssd-range-store", "data"),
    Output("rmssd-btn-60",   "style"),
    Output("rmssd-btn-120",  "style"),
    Output("rmssd-btn-1440", "style"),
    Input("rmssd-btn-60",    "n_clicks"),
    Input("rmssd-btn-120",   "n_clicks"),
    Input("rmssd-btn-1440",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_rmssd_range(_60, _120, _1440):
    val = {"rmssd-btn-60": "60", "rmssd-btn-120": "120", "rmssd-btn-1440": "1440"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",   C_ACC),
            _rbtn_style(val == "120",  C_ACC),
            _rbtn_style(val == "1440", C_ACC))


# ── RMSSD live chart ────────────────────────────────────────────────────────────
@callback(
    Output("rmssd-live-graph",  "figure"),
    Input("tick-slow",          "n_intervals"),
    Input("rmssd-range-store",  "data"),
)
def update_rmssd_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _rmssd_live_fig(rows, minutes=minutes)


# ── Heart Rate range button group ─────────────────────────────────────────────
@callback(
    Output("hr-range-store", "data"),
    Output("hr-btn-60",   "style"),
    Output("hr-btn-120",  "style"),
    Output("hr-btn-1440", "style"),
    Input("hr-btn-60",    "n_clicks"),
    Input("hr-btn-120",   "n_clicks"),
    Input("hr-btn-1440",  "n_clicks"),
    prevent_initial_call=True,
)
def handle_hr_range(_60, _120, _1440):
    val = {"hr-btn-60": "60", "hr-btn-120": "120", "hr-btn-1440": "1440"}.get(
        ctx.triggered_id, "60")
    return (val,
            _rbtn_style(val == "60",   C_ECG),
            _rbtn_style(val == "120",  C_ECG),
            _rbtn_style(val == "1440", C_ECG))


# ── Heart Rate live chart ──────────────────────────────────────────────────────
@callback(
    Output("hr-live-graph",  "figure"),
    Input("tick-slow",       "n_intervals"),
    Input("hr-range-store",  "data"),
)
def update_hr_live(_n, minutes_str):
    minutes = int(minutes_str or 60)
    with _db_lock:
        rows = _load_today(_db)
    return _hr_live_fig(rows, minutes=minutes)


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
    Output("today-avg-hr",       "children"),
    Output("today-avg-vti",      "children"),
    Output("today-peak-cbi",     "children"),
    Output("today-avg-rmssd",    "children"),
    Output("today-avg-sdnn",     "children"),
    Output("today-avg-pnn50",    "children"),
    Output("today-avg-breath",   "children"),
    Output("today-avg-lfhf",     "children"),
    Output("today-avg-rsa",      "children"),
    Output("today-session-time", "children"),
    Output("today-vti",          "figure"),
    Output("today-cbi",          "figure"),
    Output("today-rmssd",        "figure"),
    Output("today-breath",       "figure"),
    Output("today-lfhf",         "figure"),
    Output("today-sdnn",         "figure"),
    Output("today-pnn50",        "figure"),
    Output("today-vlf",          "figure"),
    Output("today-ulf",          "figure"),
    Output("today-rsa-ms",       "figure"),
    Output("today-rsa-idx",      "figure"),
    Output("today-hr",           "figure"),
    Input("tick-today", "n_intervals"),
)
def update_today(_n: int):
    # Always read from SQLite so Today shows all data for the day,
    # including from earlier sessions and across restarts.
    with _db_lock:
        records    = _load_today(_db)
        activities = _load_activities_today(_db)
        all_cats   = _get_all_cats(_db)

    if not records:
        ef = _empty_fig
        return ("—", "—", "—", "—", "—", "—", "—", "—", "—",
                "No data yet — start recording",
                ef("Vagal Tone Index  —  ln(RMSSD)"),
                ef("Conscious Breathing Index"),
                ef("RMSSD"),
                ef("Breathing Rate"),
                ef("LF / HF Ratio  (sympathetic balance)"),
                ef("SDNN  (overall HRV)"),
                ef("pNN50  (parasympathetic activity)"),
                ef("VLF Power  (0.003–0.04 Hz)"),
                ef("ULF Power  (< 0.003 Hz)  ·  needs ≥ 30 min"),
                ef("RSA  —  Respiratory Sinus Arrhythmia (ms)"),
                ef("RSA Index  —  ln(RSA band power)  [Porges]"),
                ef("Heart Rate"))

    # Summary aggregates (exclude zero-padded gaps)
    hr_vals     = [r["bpm"]        for r in records if r["bpm"]        > 0]
    vti_vals    = [r["vti"]        for r in records if r["vti"]        > 0]
    cbi_vals    = [r["cbi"]        for r in records]
    rmssd_vals  = [r["rmssd"]      for r in records if r["rmssd"]      > 0]
    sdnn_vals   = [r["sdnn"]       for r in records if r["sdnn"]       > 0]
    pnn50_vals  = [r["pnn50"]      for r in records if r["pnn50"]      > 0]
    breath_vals = [r["breath_bpm"] for r in records if r["breath_bpm"] > 0]
    lfhf_vals   = [r["lfhf"]       for r in records if r["lfhf"]       > 0]
    rsa_vals    = [r["rsa_ms"]     for r in records if r.get("rsa_ms", 0) > 0]

    avg_hr     = f"{np.mean(hr_vals):.0f}"     if hr_vals     else "—"
    avg_vti    = f"{np.mean(vti_vals):.2f}"    if vti_vals    else "—"
    peak_cbi   = f"{max(cbi_vals):.2f}"         if cbi_vals    else "—"
    avg_rmssd  = f"{np.mean(rmssd_vals):.1f}"  if rmssd_vals  else "—"
    avg_sdnn   = f"{np.mean(sdnn_vals):.1f}"   if sdnn_vals   else "—"
    avg_pnn50  = f"{np.mean(pnn50_vals):.1f}"  if pnn50_vals  else "—"
    avg_breath = f"{np.mean(breath_vals):.1f}" if breath_vals else "—"
    avg_lfhf   = f"{np.mean(lfhf_vals):.2f}"  if lfhf_vals   else "—"
    avg_rsa    = f"{np.mean(rsa_vals):.1f}"    if rsa_vals    else "—"

    dur_s   = len(records) * 2
    session = f"Duration  {dur_s // 60} min {dur_s % 60} s  ·  {len(records)} data points"

    vti_fig   = _add_activity_overlays(_vti_trend(records),   activities, cats=all_cats)
    cbi_fig   = _add_activity_overlays(_cbi_trend(records),   activities, cats=all_cats)
    rmssd_fig = _add_activity_overlays(_rmssd_trend(records), activities, cats=all_cats)
    lfhf_fig  = _add_activity_overlays(_lfhf_trend(records),  activities, cats=all_cats)
    hr_fig    = _add_activity_overlays(_hr_trend(records),     activities, cats=all_cats)

    return (avg_hr, avg_vti, peak_cbi, avg_rmssd, avg_sdnn, avg_pnn50,
            avg_breath, avg_lfhf, avg_rsa, session,
            vti_fig, cbi_fig,
            rmssd_fig, _breath_trend(records),
            lfhf_fig, _sdnn_trend(records), _pnn50_trend(records),
            _vlf_trend(records), _ulf_trend(records),
            _rsa_ms_trend(records), _rsa_idx_trend(records),
            hr_fig)


def _compute_impact(activity: dict, records: list[dict],
                    window_min: int = 30) -> dict | None:
    """Return {metric: (before, after, delta)} for vti/rmssd/bpm/lfhf.
    Returns None if < 5 records in either window."""
    t_act = activity["ts_time"]  # "HH:MM"
    before, after = [], []
    for r in records:
        t = r["t"]  # "HH:MM"
        diff_min = (int(t[:2]) * 60 + int(t[3:])) - (int(t_act[:2]) * 60 + int(t_act[3:]))
        if -window_min <= diff_min < 0:
            before.append(r)
        elif 0 < diff_min <= window_min:
            after.append(r)
    if len(before) < 5 or len(after) < 5:
        return None
    result = {}
    for key, higher_is_good in [("vti", True), ("rmssd", True), ("bpm", False), ("lfhf", False)]:
        b_vals = [r[key] for r in before if r.get(key, 0) > 0]
        a_vals = [r[key] for r in after  if r.get(key, 0) > 0]
        if b_vals and a_vals:
            b_mean = float(np.mean(b_vals))
            a_mean = float(np.mean(a_vals))
            delta  = a_mean - b_mean
            result[key] = (b_mean, a_mean, delta, higher_is_good)
    return result if result else None


def _week_activity_freq_fig(week_acts: list[dict],
                            cats: dict = _ACTIVITY_CATS) -> go.Figure:
    """Horizontal bar chart of activity frequency over the past 7 days."""
    _fallback = cats.get("other", _ACTIVITY_CATS["other"])
    if not week_acts:
        fig = go.Figure()
        fig.update_layout(**_PLOT_LAYOUT,
                          title=dict(text="Activity Frequency  —  Last 7 Days",
                                     font=dict(color=C_DIM, size=12), x=0.01))
        fig.add_annotation(text="no activities logged in the last 7 days",
                           x=0.5, y=0.5, showarrow=False, xref="paper", yref="paper",
                           font=dict(color=C_DIM, size=13))
        return fig

    from collections import Counter
    counts = Counter((a["category"], a["name"]) for a in week_acts)
    items  = sorted(counts.items(), key=lambda x: x[1])
    labels = [f"{cats.get(c, _fallback)['icon']} {n}" for (c, n), _ in items]
    values = [v for _, v in items]
    colors = [cats.get(c, _fallback)["color"] for (c, _), _ in items]

    fig = go.Figure(go.Bar(
        x=values, y=labels, orientation="h",
        marker_color=colors, marker_line_width=0,
        hovertemplate="%{y}: %{x} times<extra></extra>",
    ))
    fig.update_layout(
        **_PLOT_LAYOUT,
        title=dict(text="Activity Frequency  —  Last 7 Days",
                   font=dict(color=C_DIM, size=12), x=0.01),
        xaxis=_ax("count", rangemode="tozero"),
        yaxis=dict(showgrid=False, tickfont=dict(color=C_TEXT, size=10)),
        bargap=0.35,
        height=max(200, 30 * len(labels)),
    )
    return fig


def _week_impact_table_html(week_acts: list[dict], week_records: list[dict],
                            cats: dict = _ACTIVITY_CATS) -> html.Div:
    """Average impact table for activities logged >= 2 times in last 7 days."""
    _fallback = cats.get("other", _ACTIVITY_CATS["other"])
    if not week_acts or not week_records:
        return html.Div()

    from collections import defaultdict
    grouped: dict[tuple, list] = defaultdict(list)
    for act in week_acts:
        grouped[(act["category"], act["name"])].append(act)

    rows = []
    _th = {"color": C_DIM, "fontSize": "10px", "fontWeight": "700",
           "letterSpacing": "1px", "textTransform": "uppercase",
           "padding": "4px 10px", "textAlign": "right",
           "fontFamily": "'JetBrains Mono', monospace"}
    _td_base = {"fontSize": "11px", "padding": "4px 10px", "textAlign": "right",
                "fontFamily": "'JetBrains Mono', monospace"}

    for (cat, name), acts in grouped.items():
        if len(acts) < 2:
            continue
        deltas: dict[str, list] = {"vti": [], "rmssd": [], "bpm": []}
        for act in acts:
            imp = _compute_impact(act, week_records)
            if imp:
                for key in deltas:
                    if key in imp:
                        deltas[key].append(imp[key][2])

        if not any(deltas.values()):
            continue

        cat_info = cats.get(cat, _fallback)
        cells = [html.Td(
            f"{cat_info['icon']} {name}  ×{len(acts)}",
            style={**_td_base, "textAlign": "left", "color": cat_info["color"],
                   "borderLeft": f"3px solid {cat_info['color']}", "paddingLeft": "8px"},
        )]
        for key, higher_is_good in [("vti", True), ("rmssd", True), ("bpm", False)]:
            vs = deltas[key]
            if vs:
                mean_d = float(np.mean(vs))
                good   = (mean_d > 0) == higher_is_good
                color  = C_GOOD if good else C_BAD
                sign   = "+" if mean_d > 0 else ""
                cells.append(html.Td(f"{sign}{mean_d:.2f}",
                                     style={**_td_base, "color": color}))
            else:
                cells.append(html.Td("—", style={**_td_base, "color": C_DIM}))
        rows.append(html.Tr(cells))

    if not rows:
        return html.Div()

    return html.Div([
        html.Div("AVERAGE IMPACT  —  Before vs After (30 min windows)", style={
            "color": C_DIM, "fontSize": "11px", "fontWeight": "700",
            "letterSpacing": "1.5px", "textTransform": "uppercase",
            "marginBottom": "10px", "marginTop": "14px",
        }),
        html.Table([
            html.Thead(html.Tr([
                html.Th("Activity", style={**_th, "textAlign": "left"}),
                html.Th("VTI Δ",   style=_th),
                html.Th("RMSSD Δ", style=_th),
                html.Th("HR Δ",    style=_th),
            ])),
            html.Tbody(rows),
        ], style={"width": "100%", "borderCollapse": "collapse",
                  "color": C_TEXT, "fontFamily": "'JetBrains Mono', monospace"}),
    ], style={**_CARD, "marginTop": "10px"})


# ── week view callback (5 000 ms) ─────────────────────────────────────────────
@callback(
    Output("week-vti",              "figure"),
    Output("week-cbi",              "figure"),
    Output("week-rmssd",            "figure"),
    Output("week-lfhf",             "figure"),
    Output("week-sdnn",             "figure"),
    Output("week-pnn50",            "figure"),
    Output("week-vlf",              "figure"),
    Output("week-ulf",              "figure"),
    Output("week-hr",               "figure"),
    Output("week-activity-freq",    "figure"),
    Output("week-impact-table",     "children"),
    Input("tick-today",             "n_intervals"),
)
def update_week(_n: int):
    with _db_lock:
        days      = _load_week(_db)
        week_acts = _load_activities_week(_db)
        week_recs = _load_today(_db)   # use today's records for same-day impact; week records need full date
        all_cats  = _get_all_cats(_db)
    # Build a pseudo week_records list with correct "t" field for _compute_impact
    with _db_lock:
        cur = _db.execute(
            "SELECT ts, vti, rmssd, bpm, lfhf FROM biometric_metrics "
            "WHERE ts_date >= date('now','-6 days') ORDER BY ts"
        )
        all_week_rows = [
            dict(t=r[0][11:16], vti=r[1] or 0.0, rmssd=r[2] or 0.0,
                 bpm=r[3] or 0.0, lfhf=r[4] or 0.0)
            for r in cur.fetchall()
        ]
    return (
        _week_bar(days, "vti",   "Vagal Tone Index — Daily Average",          C_VTI,   ""),
        _week_bar(days, "cbi",   "Conscious Breathing Index — Daily Average",  C_CBI,   ""),
        _week_bar(days, "rmssd", "RMSSD — Daily Average",                      C_ACC,   "ms"),
        _week_bar(days, "lfhf",  "LF / HF Ratio — Daily Average",              C_LFHF,  ""),
        _week_bar(days, "sdnn",  "SDNN — Daily Average",                       C_SDNN,  "ms"),
        _week_bar(days, "pnn50", "pNN50 — Daily Average",                      C_PNN50, "%"),
        _week_bar(days, "vlf",   "VLF Power — Daily Average",                  C_VLF,   "ms²"),
        _week_bar(days, "ulf",   "ULF Power — Daily Average",                  C_ULF,   "ms²"),
        _week_bar(days, "bpm",   "Heart Rate — Daily Average",                 C_ECG,   "bpm"),
        _week_activity_freq_fig(week_acts, cats=all_cats),
        _week_impact_table_html(week_acts, all_week_rows, cats=all_cats),
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


# ── eye tracking toggle ────────────────────────────────────────────────────────
@callback(
    Output("eye-track-store",     "data"),
    Output("btn-eye-toggle",      "children"),
    Output("btn-eye-toggle",      "style"),
    Output("eye-section-wrapper", "style"),
    Input("btn-eye-toggle",       "n_clicks"),
    State("eye-track-store",      "data"),
    prevent_initial_call=True,
)
def toggle_eye_tracking(_, state):
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
    if state == "on":
        _blink.stop()
        return ("off",
                "👁 START EYE",
                {**_btn, "color": C_DIM, "border": f"1px solid {C_BORDER}"},
                {"display": "none"})
    else:
        _blink.start()
        return ("on",
                "👁 STOP EYE",
                {**_btn, "color": C_BLINK, "border": f"1px solid {C_BLINK}"},
                {"display": "block"})


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
    _ble_stopped.clear()
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
    _ble_stopped.clear()
    _ble_reconnect.set()
    return "Searching for Polar H10 by name…"


# ── disconnect from device ────────────────────────────────────────────────────
@callback(
    Output("connect-feedback", "children", allow_duplicate=True),
    Input("btn-disconnect",    "n_clicks"),
    prevent_initial_call=True,
)
def disconnect_device(_):
    """Halt the reconnect loop; BLE thread's finally block cleans up streams/disconnect."""
    _ble_stopped.set()
    _ble_reconnect.set()   # wake the retry delay so the loop sees _ble_stopped promptly
    _sensor_status.update(state="disconnected", device="", battery=None)
    return "Disconnected."


# ── quick navbar reconnect ─────────────────────────────────────────────────────
@callback(
    Output("connect-feedback", "children", allow_duplicate=True),
    Input("btn-reconnect",     "n_clicks"),
    prevent_initial_call=True,
)
def reconnect_now(_):
    """Trigger immediate reconnect to the last known device (or scan by name)."""
    _sensor_status["state"] = "reconnecting…"
    _ble_stopped.clear()
    _ble_reconnect.set()
    name = _target_device.get("name") or "Polar H10"
    addr = _target_device.get("address")
    if addr:
        return f"Reconnecting to {name} ({addr[:17]})…"
    return f"Reconnecting — scanning for {name}…"


# ── Info modal callbacks ───────────────────────────────────────────────────────
@callback(
    Output("info-modal-key", "data"),
    Input({"type": "info-btn", "metric": dash.ALL, "section": dash.ALL}, "n_clicks"),
    prevent_initial_call=True,
)
def open_info_modal(n_clicks_list):
    triggered = ctx.triggered_id
    if triggered and isinstance(triggered, dict):
        return triggered["metric"]
    return dash.no_update


@callback(
    Output("info-modal-key", "data", allow_duplicate=True),
    Input("info-close-btn", "n_clicks"),
    prevent_initial_call=True,
)
def close_info_modal(_):
    return None


def _info_section(icon: str, heading: str, text: str) -> html.Div:
    return html.Div([
        html.Div(f"{icon}  {heading}", style={
            "color": C_DIM, "fontSize": "10px", "fontWeight": "700",
            "textTransform": "uppercase", "letterSpacing": "1.5px",
            "marginBottom": "6px", "marginTop": "14px",
        }),
        html.Div(text, style={
            "color": C_TEXT, "fontSize": "12px", "lineHeight": "1.7",
            "fontFamily": "'JetBrains Mono', monospace",
        }),
    ])


@callback(
    Output("info-modal-overlay", "style"),
    Output("info-modal-title",   "children"),
    Output("info-modal-body",    "children"),
    Input("info-modal-key", "data"),
)
def render_info_modal(key):
    _hidden = {"display": "none"}
    _visible = {
        "display": "flex", "position": "fixed", "top": "0", "left": "0",
        "width": "100%", "height": "100%",
        "backgroundColor": "rgba(0,0,0,0.75)",
        "zIndex": "9999", "justifyContent": "center", "alignItems": "center",
    }
    if not key or key not in _METRIC_INFO:
        return _hidden, "", []
    info = _METRIC_INFO[key]
    body = html.Div([
        _info_section("🧠", "Nervous System",        info["nervous"]),
        _info_section("🧘", "Psychological Activity", info["psychological"]),
        _info_section("🏃", "Exercise Activity",      info["exercise"]),
        _info_section("💡", "How to Improve",         info["improve"]),
    ])
    return _visible, info["title"], body


# ── LOG tab: category selection ───────────────────────────────────────────────
def _cat_btn_style(cat: str, selected: str | None) -> dict:
    info    = _ACTIVITY_CATS.get(cat, _ACTIVITY_CATS["other"])
    active  = selected == cat
    return {
        "backgroundColor": info["color"] if active else "transparent",
        "color": C_BG if active else C_DIM,
        "border": f"1px solid {info['color'] if active else C_BORDER}",
        "borderRadius": "12px",
        "padding": "4px 12px",
        "fontSize": "10px",
        "fontWeight": "700",
        "letterSpacing": "1px",
        "cursor": "pointer",
        "fontFamily": "'JetBrains Mono', monospace",
    }


@callback(
    Output("log-cat-store",     "data"),
    Output("log-preset-chips",  "children"),
    Input({"type": "cat-btn", "cat": dash.ALL}, "n_clicks"),
    State("log-cat-store",        "data"),
    State("manage-cats-refresh",  "data"),
    prevent_initial_call=True,
)
def select_category(n_clicks_list, current_cat, _mcr):
    triggered = ctx.triggered_id
    if not triggered or not isinstance(triggered, dict):
        return dash.no_update, dash.no_update
    cat = triggered["cat"]
    with _db_lock:
        all_cats = _get_all_cats(_db)
    info = all_cats.get(cat, all_cats.get("other", _ACTIVITY_CATS["other"]))
    chips = []
    for preset in info["presets"]:
        chips.append(html.Button(
            preset,
            id={"type": "preset-btn", "name": preset},
            n_clicks=0,
            style={
                "backgroundColor": "transparent",
                "color": info["color"],
                "border": f"1px solid {info['color']}",
                "borderRadius": "10px",
                "padding": "3px 10px",
                "fontSize": "10px",
                "cursor": "pointer",
                "fontFamily": "'JetBrains Mono', monospace",
                "margin": "2px",
            },
        ))
    if not chips:
        chips = [html.Span("no presets — type a custom name below",
                           style={"color": C_DIM, "fontSize": "11px"})]
    return cat, chips


@callback(
    Output("log-custom-name", "value"),
    Input({"type": "preset-btn", "name": dash.ALL}, "n_clicks"),
    prevent_initial_call=True,
)
def select_preset(n_clicks_list):
    triggered = ctx.triggered_id
    if triggered and isinstance(triggered, dict):
        return triggered["name"]
    return dash.no_update


@callback(
    Output("log-time-input", "value"),
    Input("tick-minute", "n_intervals"),
)
def fill_log_time(_n):
    return datetime.now().strftime("%H:%M")


@callback(
    Output("log-feedback",      "children"),
    Output("log-feedback",      "style"),
    Output("log-refresh-store", "data"),
    Input("btn-log-submit",   "n_clicks"),
    State("log-cat-store",    "data"),
    State("log-custom-name",  "value"),
    State("log-time-input",   "value"),
    State("log-duration",     "value"),
    State("log-notes",        "value"),
    State("log-refresh-store", "data"),
    prevent_initial_call=True,
)
def submit_log(_, cat, name, time_str, duration, notes, refresh_count):
    _feedback_style = {"fontSize": "11px", "marginLeft": "10px",
                       "fontFamily": "'JetBrains Mono', monospace"}
    if not cat:
        return ("⚠ select a category first",
                {**_feedback_style, "color": C_WARN},
                dash.no_update)
    if not name or not name.strip():
        return ("⚠ enter an activity name",
                {**_feedback_style, "color": C_WARN},
                dash.no_update)
    time_str = (time_str or "").strip()
    if not time_str:
        time_str = datetime.now().strftime("%H:%M")
    now   = datetime.now()
    today = now.strftime("%Y-%m-%d")
    ts    = f"{today}T{time_str}:00"
    rec = dict(
        ts=ts, ts_date=today, ts_time=time_str,
        category=cat, name=name.strip(),
        notes=notes or "",
        duration_min=int(duration) if duration else 0,
        intensity=0,
        source="manual",
    )
    try:
        with _db_lock:
            _save_activity(_db, rec)
    except Exception as exc:
        return (f"⚠ DB error: {str(exc)[:60]}",
                {**_feedback_style, "color": C_BAD},
                dash.no_update)
    return (f"✓ logged {name.strip()} at {time_str}",
            {**_feedback_style, "color": C_GOOD},
            (refresh_count or 0) + 1)


@callback(
    Output("log-cat-store",   "data",     allow_duplicate=True),
    Output("log-custom-name", "value",    allow_duplicate=True),
    Output("log-time-input",  "value",    allow_duplicate=True),
    Output("log-duration",    "value",    allow_duplicate=True),
    Output("log-notes",       "value",    allow_duplicate=True),
    Output("log-feedback",    "children", allow_duplicate=True),
    Output("log-preset-chips","children", allow_duplicate=True),
    Input("btn-log-clear", "n_clicks"),
    prevent_initial_call=True,
)
def clear_log_form(_):
    return (None, "", datetime.now().strftime("%H:%M"), None, "",
            "", [html.Span("← select a category",
                           style={"color": C_DIM, "fontSize": "11px"})])


@callback(
    Output("log-refresh-store", "data", allow_duplicate=True),
    Input({"type": "del-act", "id": dash.ALL}, "n_clicks"),
    State("log-refresh-store", "data"),
    prevent_initial_call=True,
)
def delete_activity(n_clicks_list, refresh_count):
    triggered = ctx.triggered_id
    if not triggered or not isinstance(triggered, dict):
        return dash.no_update
    if not any(n_clicks_list):
        return dash.no_update
    act_id = triggered["id"]
    try:
        with _db_lock:
            _delete_activity(_db, act_id)
    except Exception:
        pass
    return (refresh_count or 0) + 1


@callback(
    Output("auto-detect-banner",  "style",    allow_duplicate=True),
    Input("btn-dismiss-detect",   "n_clicks"),
    prevent_initial_call=True,
)
def dismiss_autodetect(_):
    _auto_detect["pending_exercise_ts"] = None
    _auto_detect["pending_hr_ts"]       = None
    _auto_detect["exercise_streak"]     = 0
    _auto_detect["hr_streak"]           = 0
    return {"display": "none"}


@callback(
    Output("log-cat-store",   "data",     allow_duplicate=True),
    Output("log-custom-name", "value",    allow_duplicate=True),
    Output("auto-detect-banner", "style", allow_duplicate=True),
    Input("btn-confirm-detect", "n_clicks"),
    prevent_initial_call=True,
)
def confirm_autodetect(_):
    _auto_detect["pending_exercise_ts"] = None
    _auto_detect["pending_hr_ts"]       = None
    _auto_detect["exercise_streak"]     = 0
    _auto_detect["hr_streak"]           = 0
    return "exercise", "Exercise", {"display": "none"}


# ── LOG tab view callback (5 000 ms + refresh store) ─────────────────────────
@callback(
    Output("activity-timeline-graph", "figure"),
    Output("activity-list",           "children"),
    Output("impact-table",            "children"),
    Output("log-suggestions",         "children"),
    Output("auto-detect-banner",      "children"),
    Output("auto-detect-banner",      "style"),
    Output("today-log-count",         "children"),
    Input("tick-today",          "n_intervals"),
    Input("log-refresh-store",   "data"),
    Input("manage-cats-refresh", "data"),
)
def update_log_view(_n, _refresh, _mcr):
    with _db_lock:
        activities = _load_activities_today(_db)
        records    = _load_today(_db)
        hist14     = _load_activities_14d(_db)
        all_cats   = _get_all_cats(_db)
    _fallback = all_cats.get("other", _ACTIVITY_CATS["other"])

    # ── 4B: timeline figure ───────────────────────────────────────────────────
    timeline_fig = _activity_timeline_fig(activities, records, cats=all_cats)

    # ── 4C: activity list ─────────────────────────────────────────────────────
    if not activities:
        act_list = [html.Div("No activities logged today.",
                             style={"color": C_DIM, "fontSize": "12px"})]
    else:
        act_list = []
        for act in activities:   # already newest-first from DB query
            cat_info = all_cats.get(act["category"], _fallback)
            dur_str  = f"  ·  {act['duration_min']} min" if act["duration_min"] else ""
            act_list.append(html.Div([
                html.Div([
                    html.Span(f"{cat_info['icon']} {act['category'].upper()}",
                              style={"color": cat_info["color"], "fontSize": "10px",
                                     "fontWeight": "700", "letterSpacing": "1px",
                                     "marginRight": "10px"}),
                    html.Span(act["name"],
                              style={"color": C_TEXT, "fontSize": "12px", "fontWeight": "600"}),
                    html.Span(f"  {act['ts_time']}{dur_str}  ·  {act['source']}",
                              style={"color": C_DIM, "fontSize": "11px", "marginLeft": "8px"}),
                ], style={"flex": "1"}),
                html.Button("✕", id={"type": "del-act", "id": act["id"]}, n_clicks=0,
                            style={
                                "backgroundColor": "transparent", "color": C_DIM,
                                "border": "none", "fontSize": "14px", "cursor": "pointer",
                                "padding": "0 4px",
                            }),
            ], style={
                "display": "flex", "alignItems": "center", "justifyContent": "space-between",
                "padding": "8px 10px", "marginBottom": "6px",
                "borderLeft": f"3px solid {cat_info['color']}",
                "backgroundColor": C_BG, "borderRadius": "4px",
            }))

    # ── 4D: impact table ──────────────────────────────────────────────────────
    if not activities or not records:
        impact_div = html.Div("No impact data yet — need ≥ 5 biometric records on each side of an activity.",
                              style={"color": C_DIM, "fontSize": "12px"})
    else:
        _th = {"color": C_DIM, "fontSize": "10px", "fontWeight": "700",
               "letterSpacing": "1px", "textTransform": "uppercase",
               "padding": "4px 10px", "textAlign": "right",
               "fontFamily": "'JetBrains Mono', monospace"}
        _td_base = {"fontSize": "11px", "padding": "4px 10px", "textAlign": "right",
                    "fontFamily": "'JetBrains Mono', monospace"}
        rows = []
        for act in reversed(activities):  # chronological order
            imp = _compute_impact(act, records)
            if not imp:
                continue
            cat_info = all_cats.get(act["category"], _fallback)
            cells = [html.Td(
                f"{cat_info['icon']} {act['name']}",
                style={**_td_base, "textAlign": "left", "color": cat_info["color"],
                       "borderLeft": f"3px solid {cat_info['color']}", "paddingLeft": "8px"},
            ), html.Td(act["ts_time"], style={**_td_base, "color": C_DIM})]
            for key, higher_is_good in [("vti", True), ("rmssd", True), ("bpm", False), ("lfhf", False)]:
                if key in imp:
                    _, _, delta, hig = imp[key]
                    good  = (delta > 0) == hig
                    color = C_GOOD if good else C_BAD
                    sign  = "+" if delta > 0 else ""
                    cells.append(html.Td(f"{sign}{delta:.2f}",
                                         style={**_td_base, "color": color}))
                else:
                    cells.append(html.Td("—", style={**_td_base, "color": C_DIM}))
            rows.append(html.Tr(cells))

        if rows:
            impact_div = html.Table([
                html.Thead(html.Tr([
                    html.Th("Activity", style={**_th, "textAlign": "left"}),
                    html.Th("Time",     style=_th),
                    html.Th("VTI Δ",   style=_th),
                    html.Th("RMSSD Δ", style=_th),
                    html.Th("HR Δ",    style=_th),
                    html.Th("LF/HF Δ", style=_th),
                ])),
                html.Tbody(rows),
            ], style={"width": "100%", "borderCollapse": "collapse",
                      "color": C_TEXT, "fontFamily": "'JetBrains Mono', monospace"})
        else:
            impact_div = html.Div("Not enough data yet (need 30+ min of biometrics on each side of an activity).",
                                  style={"color": C_DIM, "fontSize": "12px"})

    # ── Smart suggestions from last 14 days ───────────────────────────────────
    suggestions_div = html.Div()
    if hist14:
        from collections import Counter
        now_hour = datetime.now().hour
        nearby = [a for a in hist14
                  if abs(int(a["ts_time"][:2]) - now_hour) <= 1]
        if nearby:
            top3 = Counter((a["category"], a["name"]) for a in nearby).most_common(3)
            chips = []
            for (cat, name), _ in top3:
                cat_info = all_cats.get(cat, _fallback)
                chips.append(html.Button(
                    f"{cat_info['icon']} {name}",
                    id={"type": "suggest-btn", "cat": cat, "name": name},
                    n_clicks=0,
                    style={
                        "backgroundColor": "transparent",
                        "color": cat_info["color"],
                        "border": f"1px solid {cat_info['color']}",
                        "borderRadius": "10px", "padding": "3px 10px",
                        "fontSize": "10px", "cursor": "pointer",
                        "fontFamily": "'JetBrains Mono', monospace", "margin": "2px",
                    },
                ))
            if chips:
                suggestions_div = html.Div([
                    html.Span("💡 Typical at this time:  ",
                              style={"color": C_DIM, "fontSize": "11px"}),
                    *chips,
                ], style={"marginTop": "8px"})

    # ── Auto-detect banner ────────────────────────────────────────────────────
    ex_ts = _auto_detect.get("pending_exercise_ts")
    hr_ts = _auto_detect.get("pending_hr_ts")
    banner_ts   = ex_ts or hr_ts
    banner_src  = "ACC movement" if ex_ts else "elevated HR"
    banner_style = {"display": "none"}
    banner_children = []
    if banner_ts:
        banner_style = {
            **_CARD,
            "backgroundColor": "#1a1f2e",
            "border": f"1px solid {C_WARN}",
            "display": "flex", "alignItems": "center", "gap": "14px",
            "marginBottom": "10px", "padding": "10px 14px",
        }
        banner_children = [
            html.Span(f"⚡ High {banner_src} detected at {banner_ts}",
                      style={"color": C_WARN, "fontSize": "12px", "flex": "1",
                             "fontFamily": "'JetBrains Mono', monospace"}),
            html.Button("Log as Exercise ▼", id="btn-confirm-detect", n_clicks=0,
                        style={
                            "backgroundColor": C_WARN, "color": C_BG,
                            "border": "none", "borderRadius": "10px",
                            "padding": "5px 14px", "fontSize": "10px", "fontWeight": "700",
                            "cursor": "pointer", "fontFamily": "'JetBrains Mono', monospace",
                        }),
            html.Button("Dismiss", id="btn-dismiss-detect", n_clicks=0,
                        style={
                            "backgroundColor": "transparent", "color": C_DIM,
                            "border": f"1px solid {C_BORDER}", "borderRadius": "10px",
                            "padding": "5px 12px", "fontSize": "10px",
                            "cursor": "pointer", "fontFamily": "'JetBrains Mono', monospace",
                        }),
        ]

    # ── log count label ───────────────────────────────────────────────────────
    n = len(activities)
    count_label = f"{n} activit{'ies' if n != 1 else 'y'} logged today" if n else "No activities logged today"

    return (timeline_fig, act_list, impact_div, suggestions_div,
            banner_children, banner_style, count_label)


# ── LOG suggestion chip pre-fill ──────────────────────────────────────────────
@callback(
    Output("log-cat-store",   "data",  allow_duplicate=True),
    Output("log-custom-name", "value", allow_duplicate=True),
    Input({"type": "suggest-btn", "cat": dash.ALL, "name": dash.ALL}, "n_clicks"),
    prevent_initial_call=True,
)
def fill_from_suggestion(n_clicks_list):
    triggered = ctx.triggered_id
    if not triggered or not isinstance(triggered, dict):
        return dash.no_update, dash.no_update
    if not any(n_clicks_list):
        return dash.no_update, dash.no_update
    return triggered["cat"], triggered["name"]



# ── custom category row (renders dynamic cat buttons from DB) ─────────────────
@callback(
    Output("custom-cat-row", "children"),
    Input("manage-cats-refresh", "data"),
)
def update_custom_cat_row(_refresh):
    with _db_lock:
        custom_cats = _load_custom_categories(_db)
    if not custom_cats:
        return []
    btns = []
    for cat in custom_cats:
        key = cat["key"]
        btns.append(
            html.Button(
                f"{cat['icon']} {cat['label'].upper()}",
                id={"type": "cat-btn", "cat": key},
                n_clicks=0,
                style={
                    "background": "transparent",
                    "border": f"1px solid {cat['color']}",
                    "color": cat["color"],
                    "borderRadius": "4px",
                    "padding": "4px 10px",
                    "cursor": "pointer",
                    "fontSize": "11px",
                    "fontFamily": "monospace",
                    "fontWeight": "600",
                },
            )
        )
    return btns


# ── manage panel toggle ───────────────────────────────────────────────────────
@callback(
    Output("manage-panel", "style"),
    Input("btn-manage-toggle", "n_clicks"),
    State("manage-panel", "style"),
    prevent_initial_call=True,
)
def toggle_manage_panel(n, current_style):
    if not n:
        return dash.no_update
    hidden = current_style.get("display") == "none" if current_style else True
    new_style = dict(current_style or {})
    new_style["display"] = "block" if hidden else "none"
    return new_style


# ── manage panel content ──────────────────────────────────────────────────────
@callback(
    Output("manage-panel-content", "children"),
    Input("manage-cats-refresh", "data"),
)
def update_manage_panel_content(_refresh):
    with _db_lock:
        custom_cats    = _load_custom_categories(_db)
        custom_presets = _load_custom_presets(_db)

    # Group custom presets by category
    presets_by_cat: dict[str, list] = {}
    for p in custom_presets:
        presets_by_cat.setdefault(p["category"], []).append(p)

    sections = []

    # ── Add new category ──────────────────────────────────────────────────────
    sections.append(
        html.Div([
            html.Div("ADD CATEGORY", style={"color": C_DIM, "fontSize": "10px",
                                            "fontFamily": "monospace", "fontWeight": "700",
                                            "marginBottom": "6px"}),
            html.Div([
                dcc.Input(id="new-cat-icon",  placeholder="icon (emoji)",
                          style={"width": "90px", "marginRight": "6px",
                                 "background": C_CARD, "color": C_TEXT,
                                 "border": f"1px solid {C_BORDER}", "borderRadius": "4px",
                                 "padding": "4px 8px", "fontFamily": "monospace"}),
                dcc.Input(id="new-cat-label", placeholder="category name",
                          style={"width": "160px", "marginRight": "6px",
                                 "background": C_CARD, "color": C_TEXT,
                                 "border": f"1px solid {C_BORDER}", "borderRadius": "4px",
                                 "padding": "4px 8px", "fontFamily": "monospace"}),
                dcc.Input(id="new-cat-color", placeholder="color (#hex)",
                          style={"width": "110px", "marginRight": "6px",
                                 "background": C_CARD, "color": C_TEXT,
                                 "border": f"1px solid {C_BORDER}", "borderRadius": "4px",
                                 "padding": "4px 8px", "fontFamily": "monospace"}),
                html.Button("＋ ADD", id="btn-save-cat", n_clicks=0,
                            style={"background": C_GOOD, "color": "#000",
                                   "border": "none", "borderRadius": "4px",
                                   "padding": "4px 12px", "cursor": "pointer",
                                   "fontFamily": "monospace", "fontWeight": "700",
                                   "fontSize": "11px"}),
            ], style={"display": "flex", "flexWrap": "wrap", "gap": "4px", "alignItems": "center"}),
            html.Div(id="new-cat-feedback", style={"color": C_GOOD, "fontSize": "11px",
                                                    "fontFamily": "monospace", "marginTop": "4px"}),
        ], style={**_CARD, "marginBottom": "8px", "padding": "10px 14px"})
    )

    # ── Add preset to existing category ──────────────────────────────────────
    all_cat_options = (
        [{"label": f"{v['icon']} {k}", "value": k} for k, v in _ACTIVITY_CATS.items()] +
        [{"label": f"{c['icon']} {c['label']}", "value": c['key']} for c in custom_cats]
    )
    sections.append(
        html.Div([
            html.Div("ADD ACTIVITY PRESET", style={"color": C_DIM, "fontSize": "10px",
                                                    "fontFamily": "monospace", "fontWeight": "700",
                                                    "marginBottom": "6px"}),
            html.Div([
                dcc.Dropdown(
                    id="new-preset-cat",
                    options=all_cat_options,
                    placeholder="select category",
                    style={"width": "200px", "marginRight": "6px",
                           "background": C_CARD, "color": C_TEXT,
                           "fontFamily": "monospace", "fontSize": "12px"},
                    className="dark-dropdown",
                ),
                dcc.Input(id="new-preset-name", placeholder="activity name",
                          style={"width": "180px", "marginRight": "6px",
                                 "background": C_CARD, "color": C_TEXT,
                                 "border": f"1px solid {C_BORDER}", "borderRadius": "4px",
                                 "padding": "4px 8px", "fontFamily": "monospace"}),
                html.Button("＋ ADD", id="btn-save-preset", n_clicks=0,
                            style={"background": C_GOOD, "color": "#000",
                                   "border": "none", "borderRadius": "4px",
                                   "padding": "4px 12px", "cursor": "pointer",
                                   "fontFamily": "monospace", "fontWeight": "700",
                                   "fontSize": "11px"}),
            ], style={"display": "flex", "flexWrap": "wrap", "gap": "4px", "alignItems": "center"}),
            html.Div(id="new-preset-feedback", style={"color": C_GOOD, "fontSize": "11px",
                                                       "fontFamily": "monospace", "marginTop": "4px"}),
        ], style={**_CARD, "marginBottom": "8px", "padding": "10px 14px"})
    )

    # ── Existing custom categories list ───────────────────────────────────────
    if custom_cats:
        cat_rows = []
        for cat in custom_cats:
            presets = presets_by_cat.get(cat["key"], [])
            preset_chips = [
                html.Span([
                    preset["name"],
                    html.Button("×",
                                id={"type": "del-preset", "id": preset["id"]},
                                n_clicks=0,
                                style={"background": "transparent", "border": "none",
                                       "color": C_BAD, "cursor": "pointer",
                                       "fontSize": "11px", "marginLeft": "3px",
                                       "padding": "0", "lineHeight": "1"}),
                ], style={"background": C_BG, "borderRadius": "4px",
                          "padding": "2px 6px", "fontSize": "11px",
                          "fontFamily": "monospace", "marginRight": "4px",
                          "marginBottom": "4px", "display": "inline-flex",
                          "alignItems": "center"})
                for preset in presets
            ]
            cat_rows.append(
                html.Div([
                    html.Div([
                        html.Span(f"{cat['icon']}  ", style={"fontSize": "14px"}),
                        html.Span(cat["label"].upper(),
                                  style={"fontWeight": "700", "fontSize": "12px",
                                         "fontFamily": "monospace",
                                         "color": cat["color"]}),
                        html.Button("✕ delete category",
                                    id={"type": "del-cat", "key": cat["key"]},
                                    n_clicks=0,
                                    style={"background": "transparent",
                                           "border": f"1px solid {C_BAD}",
                                           "color": C_BAD, "borderRadius": "4px",
                                           "padding": "2px 8px", "cursor": "pointer",
                                           "fontSize": "10px", "fontFamily": "monospace",
                                           "marginLeft": "12px"}),
                    ], style={"display": "flex", "alignItems": "center",
                              "marginBottom": "6px"}),
                    html.Div(preset_chips + [html.Span("no presets",
                                                        style={"color": C_DIM,
                                                               "fontSize": "11px",
                                                               "fontFamily": "monospace"})
                                             ] if not preset_chips else preset_chips,
                             style={"display": "flex", "flexWrap": "wrap"}),
                ], style={"borderLeft": f"3px solid {cat['color']}",
                           "paddingLeft": "10px", "marginBottom": "10px"})
            )
        sections.append(
            html.Div([
                html.Div("CUSTOM CATEGORIES", style={"color": C_DIM, "fontSize": "10px",
                                                      "fontFamily": "monospace",
                                                      "fontWeight": "700",
                                                      "marginBottom": "8px"}),
                html.Div(cat_rows),
            ], style={**_CARD, "padding": "10px 14px"})
        )
    else:
        sections.append(
            html.Div("No custom categories yet — add one above.",
                     style={"color": C_DIM, "fontSize": "12px",
                            "fontFamily": "monospace", "padding": "8px"})
        )

    return sections


# ── save new custom category ──────────────────────────────────────────────────
@callback(
    Output("new-cat-feedback",    "children"),
    Output("manage-cats-refresh", "data",     allow_duplicate=True),
    Output("new-cat-icon",        "value"),
    Output("new-cat-label",       "value"),
    Output("new-cat-color",       "value"),
    Input("btn-save-cat",         "n_clicks"),
    State("new-cat-icon",         "value"),
    State("new-cat-label",        "value"),
    State("new-cat-color",        "value"),
    State("manage-cats-refresh",  "data"),
    prevent_initial_call=True,
)
def save_custom_category_cb(n, icon, label, color, refresh):
    if not n:
        return dash.no_update, dash.no_update, dash.no_update, dash.no_update, dash.no_update
    icon  = (icon  or "📌").strip()
    label = (label or "").strip()
    color = (color or "#6b7280").strip()
    if not label:
        return "Category name is required.", dash.no_update, dash.no_update, dash.no_update, dash.no_update
    key = _slugify(label)
    if key in _ACTIVITY_CATS:
        return f"'{label}' conflicts with a built-in category.", dash.no_update, dash.no_update, dash.no_update, dash.no_update
    try:
        with _db_lock:
            _save_custom_category(_db, {"key": key, "icon": icon, "color": color, "label": label})
        return f"✓ Category '{label}' added.", (refresh or 0) + 1, "", "", ""
    except Exception as exc:
        return f"Error: {exc}", dash.no_update, dash.no_update, dash.no_update, dash.no_update


# ── save new custom preset ────────────────────────────────────────────────────
@callback(
    Output("new-preset-feedback",  "children"),
    Output("manage-cats-refresh",  "data",     allow_duplicate=True),
    Output("new-preset-name",      "value"),
    Input("btn-save-preset",       "n_clicks"),
    State("new-preset-cat",        "value"),
    State("new-preset-name",       "value"),
    State("manage-cats-refresh",   "data"),
    prevent_initial_call=True,
)
def save_custom_preset_cb(n, cat_key, name, refresh):
    if not n:
        return dash.no_update, dash.no_update, dash.no_update
    cat_key = (cat_key or "").strip()
    name    = (name    or "").strip()
    if not cat_key:
        return "Select a category first.", dash.no_update, dash.no_update
    if not name:
        return "Activity name is required.", dash.no_update, dash.no_update
    try:
        with _db_lock:
            _save_custom_preset(_db, {"category": cat_key, "name": name})
        return f"✓ '{name}' added to {cat_key}.", (refresh or 0) + 1, ""
    except Exception as exc:
        return f"Error: {exc}", dash.no_update, dash.no_update


# ── delete custom category ────────────────────────────────────────────────────
@callback(
    Output("manage-cats-refresh", "data", allow_duplicate=True),
    Input({"type": "del-cat", "key": dash.ALL}, "n_clicks"),
    State("manage-cats-refresh", "data"),
    prevent_initial_call=True,
)
def delete_custom_cat_cb(n_clicks_list, refresh):
    triggered = ctx.triggered_id
    if not triggered or not isinstance(triggered, dict):
        return dash.no_update
    if not any(n_clicks_list):
        return dash.no_update
    key = triggered.get("key")
    if not key:
        return dash.no_update
    with _db_lock:
        _delete_custom_category(_db, key)
    return (refresh or 0) + 1


# ── delete custom preset ──────────────────────────────────────────────────────
@callback(
    Output("manage-cats-refresh", "data", allow_duplicate=True),
    Input({"type": "del-preset", "id": dash.ALL}, "n_clicks"),
    State("manage-cats-refresh", "data"),
    prevent_initial_call=True,
)
def delete_custom_preset_cb(n_clicks_list, refresh):
    triggered = ctx.triggered_id
    if not triggered or not isinstance(triggered, dict):
        return dash.no_update
    if not any(n_clicks_list):
        return dash.no_update
    preset_id = triggered.get("id")
    if preset_id is None:
        return dash.no_update
    with _db_lock:
        _delete_custom_preset(_db, preset_id)
    return (refresh or 0) + 1


# ── entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    _start_ble(_buf)
    _blink.start()
    print("Just Breathe dashboard → http://127.0.0.1:8050")
    print("Put on your Polar H10.  Ctrl-C to quit.\n")
    app.run(debug=False, use_reloader=False, host="127.0.0.1", port=8050)
