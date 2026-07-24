"""
JustBreathe Sync Server
=======================
Run:   uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload
Prod:  uvicorn server.main:app --host 0.0.0.0 --port 8000 --workers 4
"""
from __future__ import annotations

from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .db import init_pool, close_pool, create_schema
from .auth import key_ok
from .routers import sessions, stream, admin, insights


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    await create_schema()
    yield
    await close_pool()


app = FastAPI(
    title="JustBreathe Sync API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def api_key_gate(request: Request, call_next):
    # /health stays open for uptime checks; everything else needs the key
    # (only enforced when API_KEY is configured — see server/auth.py).
    if request.url.path != "/health" and not key_ok(request.headers.get("x-api-key")):
        return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)


app.include_router(sessions.router)
app.include_router(stream.router)
app.include_router(admin.router)
app.include_router(insights.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
