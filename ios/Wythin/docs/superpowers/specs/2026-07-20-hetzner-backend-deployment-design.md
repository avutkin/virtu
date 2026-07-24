# Wythin Backend — Hetzner Deployment Design

**Date:** 2026-07-20
**Status:** Approved (design), pending implementation plan
**Scope:** Deploy the existing `~/server` FastAPI sync/insights backend to a single Hetzner Cloud VPS for a private beta (tens–low hundreds of EU users).

## Goal

Get the existing FastAPI backend (session sync, live HRV WebSocket streaming, OpenAI-backed insights, admin endpoints) running on the public internet with trusted HTTPS, so TestFlight beta testers' iOS apps can reach it. Keep it cheap, reproducible, and easy to scale up later.

## Existing system (already scaffolded in `~/server`)

- **FastAPI + Uvicorn** app (`server.main:app`).
- **PostgreSQL** via asyncpg (schema auto-created on startup); a SQLite bridge also exists.
- **WebSocket** `/stream/{user_id}` — iOS pushes live HRV ticks; admins can subscribe.
- **`/insights`** — stateless, proxies to OpenAI (keeps `OPENAI_API_KEY` server-side).
- **`/admin/*`** — list users, list sessions, CSV export.
- **`/sessions`** — upload/upsert completed sessions.
- A `wythin-api.service` systemd unit (to be superseded by Docker Compose).

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| Scale | Small private beta (tens–low hundreds) → single VPS |
| Server tier | **Hetzner CAX11** (Arm Ampere, 2 vCPU / 4 GB / 40 GB, ~€4/mo), EU location (Nuremberg / Falkenstein / Helsinki). Resizable to CAX21 with no rebuild. |
| Deployment | **Docker Compose** — 3 services (Caddy, api, db) |
| Domain / TLS | **No purchased domain.** Use free `<ip>.sslip.io` hostname + Caddy auto Let's Encrypt. Real trusted cert, no iOS ATS exceptions. Swap for a real domain later = one line. |
| Auth | **Minimal.** Shared app token (baked into iOS build) required on all app endpoints; separate admin secret required on `/admin/*`. Closes the open-data hole without building user accounts. |
| Data residency | EU datacenter (HRV = health data, EU testers → GDPR-friendly). |

## Architecture

```
        Internet (iOS app / TestFlight testers)
                  │ HTTPS :443 / WSS
        ┌─────────▼──────────┐
        │  Caddy             │  auto Let's Encrypt cert for <ip>.sslip.io
        │  (reverse proxy)   │  terminates TLS, proxies HTTP + WS
        └─────────┬──────────┘
                  │ http :8000  (internal docker network only)
        ┌─────────▼──────────┐
        │  api (FastAPI /    │  ~/server code, 2 uvicorn workers
        │  uvicorn)          │  reads OPENAI_API_KEY, DATABASE_URL, tokens from env
        └─────────┬──────────┘
                  │ :5432  (internal docker network only)
        ┌─────────▼──────────┐
        │  db (Postgres 16)  │  named volume `pgdata`, persisted
        └────────────────────┘
```

- Only Caddy publishes host ports (80, 443). `api` and `db` are on an internal Docker network, never exposed to the host or internet.
- Postgres data in a named volume so `docker compose down`/rebuild does not lose data.
- Compose file, Caddyfile, and a git-ignored `.env` live on the server (repo checked out to `/opt/wythin` or `~/just-breathe`).

## Networking & TLS

- Hostname: `<server-ip>.sslip.io` (sslip.io resolves the embedded IP; no DNS to manage).
- Caddy obtains and auto-renews the Let's Encrypt certificate; iOS trusts it with no `NSAllowsArbitraryLoads` / ATS exception.
- WebSocket upgrade (`/stream/...`) proxied as WSS transparently by Caddy.
- iOS app base URL becomes `https://<server-ip>.sslip.io`.

## Security & secrets

- **Firewall (defence in depth):** Hetzner Cloud Firewall + host `ufw`, allowing only 22 (SSH), 80, 443. Postgres port never opened.
- **SSH:** key-only, root login disabled, app/deploy runs as a non-root user.
- **Secrets** in a git-ignored `.env` on the server: `OPENAI_API_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `APP_TOKEN`, `ADMIN_TOKEN`. The `CHANGE_ME` placeholder in the old systemd unit is removed.
- **App auth (code change):** FastAPI dependency that requires `Authorization: Bearer <APP_TOKEN>` on app endpoints (`/sessions`, `/insights`, `/stream`), and a stricter `<ADMIN_TOKEN>` check on `/admin/*`. `APP_TOKEN` is compiled into the iOS build. CORS tightened from `allow_origins=["*"]`.
- **Note / future work:** shared tokens are a beta-grade measure. If the beta becomes the product, move to per-user auth (device-issued tokens). Explicitly out of scope here.

## Data & backups

- **Nightly `pg_dump`** (cron or a small compose sidecar) to `/opt/wythin/backups`, retained ~7 days.
- **Weekly Hetzner snapshot** of the server volume (~€0.50/mo) for whole-box restore.
- Restore procedure documented in the runbook.

## Deployment flow (to be detailed in the plan)

1. Provision CAX11 in an EU location; add SSH key; note the public IP.
2. Harden host: non-root user, SSH key-only, `ufw` + Hetzner Cloud Firewall (22/80/443).
3. Install Docker + Compose plugin (Arm build).
4. Check out the repo to the server; create `.env` with real secrets.
5. Add `docker-compose.yml` (caddy/api/db), `Caddyfile`, and an app `Dockerfile`.
6. Add the minimal-auth FastAPI dependency + tighten CORS (code change in `~/server`).
7. `docker compose up -d`; verify `/health` over HTTPS at `<ip>.sslip.io`.
8. Point the iOS app's base URL at the new hostname; add `APP_TOKEN` to the build; smoke-test session upload, live stream, and an insight.
9. Set up nightly `pg_dump` + weekly Hetzner snapshot.

## Success criteria

- `curl https://<ip>.sslip.io/health` returns `{"status":"ok"}` with a valid (non-self-signed) cert.
- iOS app (with `APP_TOKEN`) uploads a session, streams live ticks over WSS, and receives an insight.
- `/admin/*` returns 401 without the admin token, 200 with it.
- Postgres data survives a `docker compose down && up`.
- A `pg_dump` backup file exists and restores cleanly in a test.

## Out of scope

- Per-user authentication / accounts.
- Multi-region, load balancing, CDN, managed Postgres.
- CI/CD pipeline (manual `git pull` + `docker compose up -d` for the beta).
- A purchased custom domain (trivial to add later).
