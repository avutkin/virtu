"""
JustBreathe Sync Server
=======================
Run:   uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload
Prod:  uvicorn server.main:app --host 0.0.0.0 --port 8000 --workers 4
"""
from __future__ import annotations

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .db import init_pool, close_pool, create_schema
from .routers import sessions, stream, admin


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

app.include_router(sessions.router)
app.include_router(stream.router)
app.include_router(admin.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
