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
    "You are a physiologist reviewing one logged activity's heart-rate-"
    "variability (HRV) response. The activity's type (and subtype) is given — "
    "treat it as central. In 2-3 sentences: briefly interpret the "
    "before/during/after deltas, then end with exactly ONE concrete, forward-"
    "looking recommendation that is specifically tailored to THIS activity type "
    "and subtype — a technique, timing, intensity, breathing, or recovery tip "
    "that genuinely fits that particular practice (e.g. breath pacing for "
    "breathwork, load/rest for a workout, exposure duration for cold, wind-down "
    "for sleep). Avoid generic advice that would apply to any activity. Do not "
    "use markdown formatting."
)

_LIVE_STATE_SYSTEM_PROMPT = (
    "You are a physiology expert reading a person's live heart-rate-variability "
    "(HRV) metrics from a wearable. Using the trend of each metric over the last "
    "few minutes, reply in EXACTLY this plain-text structure — no markdown, no "
    "bold, no headers:\n"
    "First line: their current state in 2-3 words (e.g. Calm & Present, Focused, "
    "Wired & Tense, Anxious, Low & Fatigued).\n"
    "Then 2-3 lines, each starting with '• ', each interpreting one key trend in "
    "plain, non-clinical language.\n"
    "Then one final line starting with '→ ' with the single best thing to do "
    "right now, matched to the state — e.g. lean into focused work, a slow breath "
    "to settle inner noise, or a walk / light movement to lift a low or flat "
    "state. Keep the whole reply under 60 words."
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


def _format_live_state(req: InsightRequest) -> str:
    lines = [f"Window: last {req.window_minutes} minutes"]
    for name, trend in (req.metrics or {}).items():
        lines.append(
            f"{name}: start={trend.start} end={trend.end} "
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
