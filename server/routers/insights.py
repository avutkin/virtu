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

from ..models import InsightRequest, InsightResponse

router = APIRouter(tags=["insights"])

_SYSTEM_PROMPT = (
    "You are a physiologist explaining heart-rate-variability (HRV) changes "
    "around a logged activity. Interpret the before/during/after deltas the "
    "user provides, then end with exactly one concrete, forward-looking "
    "suggestion for their next session. Keep the whole reply to 2-3 sentences. "
    "Do not use markdown formatting."
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


@router.post("/insights", response_model=InsightResponse)
async def generate_insight(
    req: InsightRequest,
    client: AsyncOpenAI = Depends(get_openai_client),
):
    try:
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            max_tokens=150,
            temperature=0.6,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": _format_metrics(req)},
            ],
        )
    except OpenAIError as e:
        raise HTTPException(status_code=502, detail=str(e))

    text = response.choices[0].message.content
    if not text or not text.strip():
        raise HTTPException(status_code=502, detail="Empty response from OpenAI")
    return InsightResponse(text=text.strip())
