"""
Pydantic request/response schemas.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field
import uuid


class SampleSchema(BaseModel):
    ts:         str           # ISO8601
    mean_bpm:   Optional[float] = None
    rmssd:      Optional[float] = None
    sdnn:       Optional[float] = None
    pnn50:      Optional[float] = None
    lf_hf:      Optional[float] = None
    rsa_ms:     Optional[float] = None
    rsa_idx:    Optional[float] = None
    coherence:  Optional[float] = None
    cbi:        Optional[float] = None
    breath_bpm: Optional[float] = None


class SessionSchema(BaseModel):
    id:                str   = Field(default_factory=lambda: str(uuid.uuid4()))
    started_at:        str
    ended_at:          Optional[str]   = None
    avg_rsa_ms:        Optional[float] = None
    avg_coherence:     Optional[float] = None
    notes:             Optional[str]   = None
    samples:           list[SampleSchema] = []


class UploadResponse(BaseModel):
    id: str


class SessionListItem(BaseModel):
    id:            str
    started_at:    str
    ended_at:      Optional[str]
    avg_rsa_ms:    Optional[float]
    avg_coherence: Optional[float]


class TickPayload(BaseModel):
    user_id:   str
    ts:        str
    mean_bpm:  Optional[float] = None
    rmssd:     Optional[float] = None
    rsa_ms:    Optional[float] = None
    coherence: Optional[float] = None
    cbi:       Optional[float] = None
    breath_bpm: Optional[float] = None


class AdminUserRow(BaseModel):
    id:          str
    device_id:   Optional[str]
    last_seen:   Optional[str]
    session_count: int
