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
    "<state_key> | <fresh 2-3 word title>\n"
    "• <plain-language interpretation of a key trend>\n"
    "• <another key trend>\n"
    "→ <the single best thing to do right now, matched to the state>\n"
    "\n"
    "The first line has TWO parts separated by ' | ':\n"
    "(1) state_key — EXACTLY one of the nine snake_case keys listed below "
    "(the app uses it to choose an icon, so it must match exactly);\n"
    "(2) a fresh, natural 2-3 word title for how the person is right now. Vary "
    "it so it feels personal and never repetitive — do NOT just echo the state "
    "name every time (e.g. for engaged_performing: 'Locked In', 'In The Zone', "
    "'Firing Well').\n"
    "\n"
    "Example reply:\n"
    "engaged_performing | Locked In\n"
    "• Heart rate is rising, yet your HRV is climbing too — this is real energy, not stress\n"
    "• Inner noise is falling — your attention is sharpening\n"
    "→ Ride it: start your most demanding task now while the focus is here.\n"
    "\n"
    "BULLETS (2-3) — make them dynamic and specific to what actually changed. "
    "Scan ALL nine metrics and call out the ones that VISIBLY MOVED this window "
    "(direction rising or falling, or a wide min-max spread), not the flat ones. "
    "Each bullet names ONE metric in plain language, says what it did, and what "
    "that means for the person (e.g. 'Inner noise jumped — your attention is "
    "starting to fragment', 'Vagal tone is climbing — your recovery brake is "
    "engaging', 'Heart rate ticked up while HRV held — mild activation'). Choose "
    "the 2-3 most meaningful movers, each about a DIFFERENT metric, and vary them "
    "from reading to reading so it never feels canned. If almost nothing moved, "
    "say the picture is steady and name the single metric that shifted most.\n"
    "\n"
    "'→' RIGHT NOW — one concrete, immediately-doable action, VARIED each time and "
    "grounded in evidence-based self-regulation. Match it to the state and rotate "
    "across the options below; never default to 'take a slow breath' every time. "
    "Give the specific technique and, when useful, how long:\n"
    "— Down-shift stress / overload: a physiological sigh (double inhale, long "
    "exhale) x3; 4-in / 6-8-out breathing for 2 min; box breathing; cool water on "
    "the face; a 5-minute walk; or close extra tabs and single-task one thing.\n"
    "— Lift low / depleted energy: a brisk 5-minute walk; step into daylight; a "
    "splash of cold water; 10 bodyweight movements; or a glass of water.\n"
    "— Use a strong / engaged window: start your hardest task now, silence "
    "notifications to protect it, and hydrate.\n"
    "— Deepen recovery / rest: 10 min of NSDR or yoga nidra; gentle stretching; "
    "warmth; time outside; or protect an earlier night's sleep.\n"
    "Keep the whole reply under 60 words. Only rely on the metrics provided.\n"
    "\n"
    "Match your TONE to the state:\n"
    "— Struggling states (overloaded_exhausted, stressed_activated, "
    "depleted_numb, shutdown_burnout): be warm, empathetic and reassuring; "
    "suggest gentle, low-effort steps and never pressure them.\n"
    "— Strong states (engaged_performing, calm_alert, renewed_thriving): be "
    "encouraging and motivating; nudge them to make the most of this window.\n"
    "— Steady states (stable_neutral, recovering_resetting): be calm and "
    "grounding; reinforce small, consistent habits.\n"
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
    "The 9 states — the key on the left is what you put first on line 1:\n"
    "1. overloaded_exhausted — Overloaded & Exhausted — high stress, low energy, "
    "low recovery; drained, overwhelmed, unable to cope. Signature: Inner Noise "
    "↑↑, HRV/DC ↓↓. Focus: rest, downshift, restore safety.\n"
    "2. stressed_activated — Stressed & Activated — high stress, high energy, low "
    "recovery; tense, wired, pushed. Signature: LF/HF ↑↑, Inner Noise ↑. Focus: "
    "regulate stress, balance effort.\n"
    "3. engaged_performing — Engaged & Performing — moderate stress, high energy, "
    "good recovery; focused, motivated, in control. Signature: DFA alpha-1 ~1.0, "
    "VTI optimal. Focus: sustain, flow, stay balanced.\n"
    "4. depleted_numb — Depleted & Numb — low energy, moderate stress, low "
    "recovery; flat, unmotivated, disconnected. Signature: HR ↓, VTI ↓. Focus: "
    "gentle activation, rebuild energy.\n"
    "5. stable_neutral — Stable & Neutral — balanced stress, energy and recovery; "
    "calm, steady, functional. Signature: all metrics near baseline. Focus: "
    "maintain, small positive habits.\n"
    "6. calm_alert — Calm & Alert — low stress, high energy, high recovery; "
    "clear, calm, capable. Signature: RSA ↑, DC ↑. Focus: grow, learn, create.\n"
    "7. shutdown_burnout — Shutdown & Burnout — very low energy, high stress, "
    "very low recovery; stuck, drained. Signature: HRV/DC ↓↓↓, Inner Noise ↑↑↑. "
    "Focus: deep rest; suggest seeking help if this persists.\n"
    "8. recovering_resetting — Recovering & Resetting — low energy, low stress, "
    "improving recovery; recharging, resetting. Signature: HR ↓, HRV/DC ↑. "
    "Focus: rest, nourish, be patient.\n"
    "9. renewed_thriving — Renewed & Thriving — low stress, high energy, very "
    "high recovery; alive, present, resilient. Signature: RSA ↑↑, VTI ↑↑. Focus: "
    "purpose, connection, contribute.\n"
    "\n"
    "Line 1 is '<state_key> | <fresh title>'. The bullets interpret the strongest "
    "trends (include focus when Inner Noise / DFA alpha-1 are telling). The '→' "
    "line turns that state's Focus into one concrete action for right now, in the "
    "tone that matches the state."
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
