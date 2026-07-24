"""
POST /insights — generates a short OpenAI-backed interpretation +
recommendation for one completed activity's HRV response.

Fully stateless: nothing here is persisted. The request carries no user
or device identifier because nothing needs to associate the response
with anyone.
"""
from __future__ import annotations

import os
from fastapi import APIRouter, Depends, HTTPException
from openai import AsyncOpenAI, OpenAIError

from ..models import InsightRequest, InsightResponse, MetricTrend

router = APIRouter(tags=["insights"])

_SYSTEM_PROMPT = (
    "You are a sports coach and physiologist reviewing one logged session of a "
    "specific activity (e.g. yoga, meditation, breathwork, a run, strength work, "
    "cold exposure). The activity type and subtype are given — treat them as "
    "central; a good session looks different for meditation than for a hard "
    "workout. You are given the person's heart-rate and HRV metrics before, "
    "during, and after the session.\n"
    "\n"
    "Reply in EXACTLY this plain-text structure — no markdown, no bold, nothing "
    "before or after:\n"
    "\n"
    "<3-6 word headline: how this session went>\n"
    "<1-2 sentences: the major insight from the metrics — what the body did, and "
    "whether that fits the goal of THIS activity. For calming practices (yoga, "
    "meditation, breathwork) the aim is heart rate down and RSA/SDNN up with "
    "stress balance falling; for a hard workout the aim is a strong sympathetic "
    "push during and good recovery after.>\n"
    "Next session: <one specific, calibrated recommendation for the next similar "
    "session — for example go slower and lengthen the exhale, focus on the "
    "breath, hold the pose longer, or push harder / add load — chosen from what "
    "the numbers actually show.>\n"
    "\n"
    "Keep the whole reply under 60 words. Base everything only on the metrics "
    "provided. Speak directly to the person as their coach ('you')."
)

_LIVE_STATE_SYSTEM_PROMPT = (
    "You are an expert physiologist reading a person's live heart-rate-"
    "variability (HRV) metrics from a wearable, labeled with what each one means. Interpret "
    "the trends and reply in EXACTLY this plain-text structure — no markdown, no "
    "bold, no extra text before or after:\n"
    "\n"
    "<2-3 word current state>\n"
    "• <plain-language interpretation of a key trend>\n"
    "• <another key trend>\n"
    "→ <the single best thing to do right now, matched to the state>\n"
    "\n"
    "Example reply:\n"
    "Calm & Present\n"
    "• Heart rate is easing and RSA rising — your body is settling into rest\n"
    "• Inner noise is dropping — your rhythm is getting smoother\n"
    "→ A good moment for focused work, or a slow breath to deepen the calm.\n"
    "\n"
    "The state is 2-3 words (e.g. Calm & Present, Focused, Wired & Tense, "
    "Anxious, Low & Fatigued). Use 2-3 bullets. The '→' recommendation must fit "
    "the state — e.g. lean into focused work, a slow breath to settle inner "
    "noise, or a walk / light movement to lift a low or flat state. Keep the "
    "whole reply under 60 words. Only rely on the metrics provided.\n"
    "\n"
    "Pay special attention to Inner noise (PIP) and DFA alpha-1 as a proxy for "
    "mental focus: low, falling inner noise together with DFA alpha-1 near 1.0 "
    "signals sharp, absorbed focus (a good time for deep work); rising inner "
    "noise or DFA alpha-1 drifting toward 0.5 signals scattered, restless "
    "attention (suggest a reset — a few slow breaths or a short movement break). "
    "When these two are present, make one bullet about focus and let it steer "
    "the recommendation.\n"
    "\n"
    "Classify the person into EXACTLY ONE of the 9 nervous-system states below. "
    "First read two axes:\n"
    "— STRESS / OVERLOAD is higher when Inner Noise (PIP), LF/HF and HR are high.\n"
    "— RECOVERY / REGULATION is higher when HRV (RMSSD/SDNN), RSA, Vagal Tone "
    "(DC) and Calm Power (VTI) are high.\n"
    "Energy / activation is higher when HRV, HR and Adaptive Capacity (RCMSE) are "
    "higher. IMPORTANT: a high or rising HR with GOOD recovery metrics (solid "
    "RSA/RMSSD/DC/VTI, balanced LF/HF) is high ENERGY, not stress — do not call "
    "it a stress state.\n"
    "\n"
    "The 9 states — use the state's name (2-3 words) as your first line:\n"
    "1. Overloaded & Exhausted — high stress, low energy, low recovery; drained, "
    "overwhelmed, unable to cope. Signature: Inner Noise ↑↑, HRV/DC ↓↓. "
    "Focus: rest, downshift, restore safety.\n"
    "2. Stressed & Activated — high stress, high energy, low recovery; tense, "
    "wired, pushed. Signature: LF/HF ↑↑, Inner Noise ↑. Focus: regulate stress, "
    "balance effort.\n"
    "3. Engaged & Performing — moderate stress, high energy, good recovery; "
    "focused, motivated, in control. Signature: DFA alpha-1 ~1.0, VTI optimal. "
    "Focus: sustain, flow, stay balanced.\n"
    "4. Depleted & Numb — low energy, moderate stress, low recovery; flat, "
    "unmotivated, disconnected. Signature: HR ↓, VTI ↓. Focus: gentle "
    "activation, rebuild energy.\n"
    "5. Stable & Neutral — balanced stress, energy and recovery; calm, steady, "
    "functional. Signature: all metrics near baseline. Focus: maintain, small "
    "positive habits.\n"
    "6. Calm & Alert — low stress, high energy, high recovery; clear, calm, "
    "capable. Signature: RSA ↑, DC ↑. Focus: grow, learn, create.\n"
    "7. Shutdown & Burnout — very low energy, high stress, very low recovery; "
    "stuck, drained. Signature: HRV/DC ↓↓↓, Inner Noise ↑↑↑. Focus: deep rest; "
    "suggest seeking help if this persists.\n"
    "8. Recovering & Resetting — low energy, low stress, improving recovery; "
    "recharging, resetting. Signature: HR ↓, HRV/DC ↑. Focus: rest, nourish, be "
    "patient.\n"
    "9. Renewed & Thriving — low stress, high energy, very high recovery; alive, "
    "present, resilient. Signature: RSA ↑↑, VTI ↑↑. Focus: purpose, connection, "
    "contribute.\n"
    "\n"
    "Your first line is the chosen state's name. The bullets interpret the "
    "strongest trends (include focus when Inner Noise / DFA alpha-1 are telling). "
    "The '→' line turns that state's Focus into one concrete action for right now."
)


def get_openai_client() -> AsyncOpenAI:
    """FastAPI dependency — overridden with a fake in tests."""
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    return AsyncOpenAI(api_key=api_key)


def _format_metrics(req: InsightRequest) -> str:
    lines = [f"Activity: {req.activity_type}"]
    if req.activity_subtype:
        lines.append(f"Subtype: {req.activity_subtype}")
    if req.duration_min is not None:
        lines.append(f"Duration: {req.duration_min} min")

    def metric(label: str, unit: str, before, during, after):
        if before is None and during is None and after is None:
            return
        lines.append(f"{label}: before={before}{unit} during={during}{unit} after={after}{unit}")

    metric("HR", "bpm", req.before_hr, req.during_hr, req.after_hr)
    metric("RSA", "ms", req.before_rsa, req.during_rsa, req.after_rsa)
    metric("SDNN", "ms", req.before_sdnn, req.during_sdnn, req.after_sdnn)
    metric("LF/HF", "", req.before_lf_hf, req.during_lf_hf, req.after_lf_hf)
    return "\n".join(lines)


# Human-readable names so the model interprets each metric correctly instead of
# guessing from the abbreviation (e.g. it must not read PIP as "peripheral").
_METRIC_NAMES = {
    "hr":         "Heart rate (bpm)",
    "rmssd":      "RMSSD — short-term HRV / vagal tone (ms)",
    "rsa":        "RSA — breathing-driven heart-rate swing / vagal tone (ms)",
    "sdnn":       "SDNN — overall HRV (ms)",
    "lf_hf":      "LF/HF — stress-vs-rest balance (higher = more stress)",
    "coherence":  "Coherence — heart–breath synchronization (0–1)",
    "breath_bpm": "Breathing rate (breaths/min)",
    "cbi":        "Cardiac balance index",
    "dc":         "Vagal Tone (deceleration capacity, ms) — relaxation & recovery "
                  "capacity; higher = stronger parasympathetic brake",
    "rcmse":      "Adaptive Capacity (multiscale entropy) — flexibility/resilience "
                  "across timescales; higher = more adaptable",
    "vti":        "Calm Power (vagal tone index, ln RMSSD) — total restorative "
                  "parasympathetic drive; higher = stronger recovery drive",
    "pip":        "Inner noise — beat-to-beat fragmentation; a focus proxy "
                  "(lower = smoother, more settled attention; higher = scattered/restless)",
    "dfa1":       "DFA alpha-1 — fractal organization of the rhythm; a focus proxy "
                  "(near 1.0 = well-ordered, absorbed/focused; drifting toward 0.5 = "
                  "random/uncoupled; above ~1.2 = overly rigid)",
}


def _format_live_state(req: InsightRequest) -> str:
    lines = [f"Window: last {req.window_minutes} minutes"]
    for name, trend in (req.metrics or {}).items():
        label = _METRIC_NAMES.get(name, name)
        lines.append(
            f"{label}: start={trend.start} end={trend.end} "
            f"min={trend.min} max={trend.max} mean={trend.mean} "
            f"direction={trend.direction}"
        )
    return "\n".join(lines)


@router.post("/insights", response_model=InsightResponse)
async def generate_insight(
    req: InsightRequest,
    client: AsyncOpenAI = Depends(get_openai_client),
):
    if req.mode == "live_state":
        if not req.metrics:
            raise HTTPException(status_code=422, detail="metrics is required for live_state mode")
        system_prompt = _LIVE_STATE_SYSTEM_PROMPT
        user_content = _format_live_state(req)
        max_tokens = 220   # room for the state line + bullets + recommendation
    else:
        if not req.activity_type:
            raise HTTPException(status_code=422, detail="activity_type is required for activity mode")
        system_prompt = _SYSTEM_PROMPT
        user_content = _format_metrics(req)
        max_tokens = 150

    try:
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            max_tokens=max_tokens,
            temperature=0.6,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
        )
    except OpenAIError as e:
        raise HTTPException(status_code=502, detail=str(e))

    text = response.choices[0].message.content
    if not text or not text.strip():
        raise HTTPException(status_code=502, detail="Empty response from OpenAI")
    return InsightResponse(text=text.strip())
