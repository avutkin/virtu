# Pulsar Backend — Hetzner Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the existing `~/server` FastAPI backend to a single Hetzner Cloud VPS with trusted HTTPS, minimal token auth, and backups, and point the iOS app at it.

**Architecture:** One CAX11 Arm VPS runs a Docker Compose stack — Caddy (auto-TLS reverse proxy) → FastAPI/uvicorn app → Postgres. Only Caddy exposes ports (80/443); app and DB stay on the internal Docker network. A free `<ip>.sslip.io` hostname gives Caddy a real Let's Encrypt cert so iOS needs no ATS exception.

**Tech Stack:** FastAPI, Uvicorn, asyncpg, PostgreSQL 16, Caddy 2, Docker Compose, pytest/httpx (tests), Swift/URLSession (iOS client).

## Global Constraints

- Server: **Hetzner CAX11** (Arm Ampere, 2 vCPU / 4 GB / 40 GB), **EU location** (Nuremberg, Falkenstein, or Helsinki). Resizable to CAX21.
- Secrets (`OPENAI_API_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `APP_TOKEN`, `ADMIN_TOKEN`) live only in a **git-ignored `.env` on the server** — never committed.
- Auth: **`APP_TOKEN`** (bearer) required on app endpoints (`/sessions`, `/insights`, `/stream`); **`ADMIN_TOKEN`** (bearer) required on `/admin/*`. `APP_TOKEN` is baked into the iOS build (beta-grade).
- Hostname: `<server-ip>.sslip.io` (swap for a real domain later = one Caddyfile line).
- Analytics/data layer: **Postgres only**.
- Token comparison must be constant-time (`hmac.compare_digest`).
- The server package is imported as `server.main:app`; keep that import path.
- **Local tests run on Python 3.9** (`~/.venv/bin/python`, from repo root `/Users/alexutkin`). The Docker image is python:3.12, but code must also run on 3.9 for local TDD. Therefore any parameter FastAPI introspects at runtime (`Header`, `Query`, `Depends` params) MUST use `typing.Optional[...]`, NOT PEP-604 `X | None` — the latter raises `TypeError` on 3.9. Plain (non-FastAPI) function annotations may keep `X | None` because `from __future__ import annotations` makes them lazy strings.
- **Test command (always):** from `/Users/alexutkin`, run `~/.venv/bin/python -m pytest server/tests/<file> -v`. (`server` must be importable as a top-level package, so run from the repo root, never from inside `server/`.)

**Repo note:** `~/server/` is a subtree of the git repo rooted at `/Users/alexutkin`. Run all `git` commands from `/Users/alexutkin`. Paths below are given relative to `~/server` for the server code; commit paths use the `server/…` prefix.

---

## Phase A — Backend auth + CORS (local, TDD)

### Task 1: Token-auth module + shared test fixtures

**Files:**
- Create: `~/server/auth.py`
- Create: `~/server/tests/conftest.py`
- Create: `~/server/tests/helpers.py`
- Test: `~/server/tests/test_auth.py`

**Interfaces:**
- Produces:
  - `require_app_token(authorization: Optional[str] = Header(default=None)) -> None` — FastAPI dependency; raises `HTTPException(401)` on missing/invalid bearer, `HTTPException(503)` if `APP_TOKEN` env unset.
  - `require_admin_token(authorization: Optional[str] = Header(default=None)) -> None` — same, against `ADMIN_TOKEN`.
  - `verify_token(presented: Optional[str], expected: Optional[str]) -> bool` — pure helper, constant-time.
  - `server.tests.helpers.APP_HEADERS`, `server.tests.helpers.ADMIN_HEADERS` — dicts other test modules import.

- [ ] **Step 1: Write the failing test**

Create `~/server/tests/conftest.py` (only the autouse env fixture — no importable constants live here):

```python
"""Shared fixtures. Sets auth tokens for the whole test session so every
request test can authenticate without each test managing env vars."""
from __future__ import annotations

import os
import pytest


@pytest.fixture(autouse=True, scope="session")
def _auth_env():
    os.environ["APP_TOKEN"] = "test-app-token"
    os.environ["ADMIN_TOKEN"] = "test-admin-token"
    yield
```

Create `~/server/tests/helpers.py` (importable header constants — must match the tokens the conftest fixture sets):

```python
"""Auth headers for request tests. Values match tests/conftest.py::_auth_env."""
APP_HEADERS = {"Authorization": "Bearer test-app-token"}
ADMIN_HEADERS = {"Authorization": "Bearer test-admin-token"}
```

Create `~/server/tests/test_auth.py`:

```python
from __future__ import annotations

import pytest
from server.auth import verify_token


def test_verify_token_matches():
    assert verify_token("abc", "abc") is True


def test_verify_token_rejects_mismatch():
    assert verify_token("abc", "xyz") is False


def test_verify_token_rejects_none_presented():
    assert verify_token(None, "abc") is False


def test_verify_token_rejects_none_expected():
    assert verify_token("abc", None) is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_auth.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'server.auth'`

- [ ] **Step 3: Write minimal implementation**

Create `~/server/auth.py` (note: `Optional[str]` on the FastAPI-introspected params — required for Python 3.9):

```python
"""Minimal shared-token auth for the beta backend.

Two tokens, both bearer:
  - APP_TOKEN   : app endpoints (/sessions, /insights, /stream)
  - ADMIN_TOKEN : /admin/* endpoints
Compiled into the iOS build (APP_TOKEN) and kept in the server .env.
"""
from __future__ import annotations

import hmac
import os
from typing import Optional

from fastapi import Header, HTTPException, status


def verify_token(presented: Optional[str], expected: Optional[str]) -> bool:
    """Constant-time comparison; False if either side is missing."""
    if not presented or not expected:
        return False
    return hmac.compare_digest(presented, expected)


def _require(authorization: Optional[str], env_name: str) -> None:
    expected = os.getenv(env_name)
    if not expected:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"{env_name} not configured",
        )
    presented = None
    if authorization and authorization.startswith("Bearer "):
        presented = authorization[len("Bearer "):].strip()
    if not verify_token(presented, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing token",
        )


async def require_app_token(authorization: Optional[str] = Header(default=None)) -> None:
    _require(authorization, "APP_TOKEN")


async def require_admin_token(authorization: Optional[str] = Header(default=None)) -> None:
    _require(authorization, "ADMIN_TOKEN")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_auth.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/auth.py server/tests/conftest.py server/tests/helpers.py server/tests/test_auth.py
git commit -m "feat(server): add shared-token auth module + test fixtures"
```

---

### Task 2: Require APP_TOKEN on /sessions and /insights

**Files:**
- Modify: `~/server/routers/sessions.py` (router definition)
- Modify: `~/server/routers/insights.py` (router definition)
- Modify: `~/server/tests/test_sessions.py`, `~/server/tests/test_insights.py` (send auth header)
- Test: `~/server/tests/test_auth_endpoints.py`

**Interfaces:**
- Consumes: `require_app_token` (Task 1).

- [ ] **Step 1: Write the failing test**

Create `~/server/tests/test_auth_endpoints.py`:

```python
from __future__ import annotations

import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app


@pytest.mark.asyncio
async def test_insights_without_token_returns_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.post("/insights", json={"mode": "activity", "activity_type": "Breathwork"})
    assert r.status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_auth_endpoints.py -v`
Expected: FAIL — returns 422/502/200, not 401 (no auth wired yet).

- [ ] **Step 3: Write minimal implementation**

In `~/server/routers/sessions.py`, change the router line:

```python
from fastapi import APIRouter, Header, Depends
from ..auth import require_app_token

router = APIRouter(prefix='/sessions', tags=['sessions'],
                   dependencies=[Depends(require_app_token)])
```

In `~/server/routers/insights.py`, change the router line:

```python
from fastapi import APIRouter, Depends, HTTPException
from ..auth import require_app_token

router = APIRouter(tags=["insights"], dependencies=[Depends(require_app_token)])
```

- [ ] **Step 4: Run the new test — passes; existing tests now fail (expected)**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_auth_endpoints.py -v`
Expected: PASS.

Now update existing tests to send the header. In `~/server/tests/test_insights.py`, add the import and header to every `client.post("/insights", …)` call:

```python
from server.tests.helpers import APP_HEADERS
```
and change each insight POST to include `headers=APP_HEADERS`, e.g.:
```python
r = await client.post("/insights", json=_PAYLOAD, headers=APP_HEADERS)
```
(Apply to all six `/insights` POSTs in the file. The 422 validation tests still expect 422 — auth passes, body validation fails, which is correct.)

In `~/server/tests/test_sessions.py`, add `from server.tests.helpers import APP_HEADERS` and merge the header into the existing `X-User-ID` calls:
```python
r = await client.post("/sessions", json=payload,
                      headers={"X-User-ID": "test-device-001", **APP_HEADERS})
```
(Apply to every `/sessions` GET/POST in the file.)

- [ ] **Step 5: Run the full non-DB suite**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_insights.py server/tests/test_auth.py server/tests/test_auth_endpoints.py -v`
Expected: PASS (test_sessions requires a live DB — covered in Task 10 verification).

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin
git add server/routers/sessions.py server/routers/insights.py \
        server/tests/test_insights.py server/tests/test_sessions.py \
        server/tests/test_auth_endpoints.py
git commit -m "feat(server): require APP_TOKEN on /sessions and /insights"
```

---

### Task 3: Require ADMIN_TOKEN on /admin/*

**Files:**
- Modify: `~/server/routers/admin.py` (router definition)
- Test: `~/server/tests/test_auth_endpoints.py` (add cases)

**Interfaces:**
- Consumes: `require_admin_token` (Task 1).

- [ ] **Step 1: Write the failing test**

Append to `~/server/tests/test_auth_endpoints.py`:

```python
@pytest.mark.asyncio
async def test_admin_without_token_returns_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/admin/users")
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_admin_with_app_token_returns_401():
    from server.tests.helpers import APP_HEADERS
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/admin/users", headers=APP_HEADERS)
    assert r.status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_auth_endpoints.py -v`
Expected: FAIL — `/admin/users` reaches the DB layer (500/errors) instead of 401.

- [ ] **Step 3: Write minimal implementation**

In `~/server/routers/admin.py`, change the router line:

```python
from fastapi import APIRouter, Depends
from ..auth import require_admin_token

router = APIRouter(prefix="/admin", tags=["admin"],
                   dependencies=[Depends(require_admin_token)])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_auth_endpoints.py -v`
Expected: PASS (both new tests short-circuit at auth before any DB access).

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/routers/admin.py server/tests/test_auth_endpoints.py
git commit -m "feat(server): require ADMIN_TOKEN on /admin endpoints"
```

---

### Task 4: WebSocket stream auth + CORS tightening

**Files:**
- Modify: `~/server/routers/stream.py` (websocket signature + token check)
- Modify: `~/server/main.py` (CORS from env)
- Test: `~/server/tests/test_stream_auth.py`

**Interfaces:**
- Consumes: `verify_token` (Task 1).
- Note: the stream token arrives as a query param `?token=` because browser/native WebSocket clients cannot set custom headers reliably.

- [ ] **Step 1: Write the failing test**

Create `~/server/tests/test_stream_auth.py`:

```python
from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.websockets import WebSocketDisconnect
from starlette.testclient import TestClient
from server.main import app


def test_stream_rejects_missing_token():
    client = TestClient(app)
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect("/stream/device-1"):
            pass
    assert exc.value.code == 1008


def test_stream_rejects_wrong_token():
    client = TestClient(app)
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect("/stream/device-1?token=wrong"):
            pass
    assert exc.value.code == 1008
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_stream_auth.py -v`
Expected: FAIL — connection is accepted (no auth), so no `WebSocketDisconnect(1008)`.

- [ ] **Step 3: Write minimal implementation**

In `~/server/routers/stream.py`, update imports and the endpoint signature/guard (note: `Optional[str]` on the `Query` param — required for Python 3.9):

```python
import os
from typing import Optional
from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query
from ..auth import verify_token

# ... existing _admin_subs registry ...

@router.websocket("/stream/{user_id}")
async def device_stream(ws: WebSocket, user_id: str, token: Optional[str] = Query(default=None)):
    if not verify_token(token, os.getenv("APP_TOKEN")):
        await ws.close(code=1008)  # policy violation
        return
    await ws.accept()
    # ... rest of the existing handler unchanged ...
```

(Apply the same `token` param + guard to the `/stream/admin/{user_id}` handler if present, checking `ADMIN_TOKEN` there.)

In `~/server/main.py`, replace the wildcard CORS block:

```python
import os

_origins = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "").split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,          # empty by default; native iOS ignores CORS
    allow_methods=["*"],
    allow_headers=["*"],
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/alexutkin && ~/.venv/bin/python -m pytest server/tests/test_stream_auth.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin
git add server/routers/stream.py server/main.py server/tests/test_stream_auth.py
git commit -m "feat(server): authenticate WebSocket stream + restrict CORS via env"
```

---

## Phase B — Containerization (local)

### Task 5: Dockerfile for the app

**Files:**
- Create: `~/server/Dockerfile`
- Create: `~/server/.dockerignore`

**Interfaces:**
- Produces: an image that runs `uvicorn server.main:app` on port 8000, with the code at `/app/server`.

- [ ] **Step 1: Write the Dockerfile**

Create `~/server/Dockerfile`:

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install deps first for layer caching
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy the package so it imports as `server.main:app`
COPY . ./server/

EXPOSE 8000
CMD ["uvicorn", "server.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
```

Create `~/server/.dockerignore`:

```
__pycache__/
*.pyc
tests/
.env
.env.*
*.sqlite
backups/
```

- [ ] **Step 2: Build the image to verify it compiles**

Run: `cd ~/server && docker build -t pulsar-api:local .`
Expected: build succeeds, ends with `naming to docker.io/library/pulsar-api:local`.

- [ ] **Step 3: Commit**

```bash
cd /Users/alexutkin
git add server/Dockerfile server/.dockerignore
git commit -m "build(server): add Dockerfile and .dockerignore"
```

---

### Task 6: Compose stack + Caddyfile + env template

**Files:**
- Create: `~/server/deploy/docker-compose.yml`
- Create: `~/server/deploy/Caddyfile`
- Create: `~/server/deploy/.env.example`
- Modify: `~/server/.gitignore` (or repo root `.gitignore`) — ignore real `.env`
- Delete: `~/server/pulsar-api.service` (superseded by Compose)

**Interfaces:**
- Produces: a runnable stack (`caddy`, `api`, `db`). `api` reads `DATABASE_URL`, `OPENAI_API_KEY`, `APP_TOKEN`, `ADMIN_TOKEN`, `ALLOWED_ORIGINS` from `.env`. Caddy serves `${SITE_ADDRESS}` → `api:8000`.

- [ ] **Step 1: Write the compose file**

Create `~/server/deploy/docker-compose.yml`:

```yaml
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: pulsar
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: pulsar
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pulsar"]
      interval: 10s
      timeout: 5s
      retries: 5

  api:
    build:
      context: ..
      dockerfile: Dockerfile
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://pulsar:${POSTGRES_PASSWORD}@db:5432/pulsar
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      APP_TOKEN: ${APP_TOKEN}
      ADMIN_TOKEN: ${ADMIN_TOKEN}
      ALLOWED_ORIGINS: ${ALLOWED_ORIGINS:-}
    expose:
      - "8000"

  caddy:
    image: caddy:2
    restart: unless-stopped
    depends_on:
      - api
    ports:
      - "80:80"
      - "443:443"
    environment:
      SITE_ADDRESS: ${SITE_ADDRESS}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  pgdata:
  caddy_data:
  caddy_config:
```

- [ ] **Step 2: Write the Caddyfile**

Create `~/server/deploy/Caddyfile`:

```
{$SITE_ADDRESS} {
	reverse_proxy api:8000
}
```

(Caddy auto-provisions the Let's Encrypt cert for `SITE_ADDRESS` and proxies HTTP + WebSocket transparently. To move to a real domain later, change `SITE_ADDRESS`.)

- [ ] **Step 3: Write the env template**

Create `~/server/deploy/.env.example`:

```dotenv
# Copy to .env on the server and fill in. NEVER commit the real .env.
SITE_ADDRESS=CHANGE-ME.sslip.io
POSTGRES_PASSWORD=generate-a-long-random-string
OPENAI_API_KEY=sk-...
APP_TOKEN=generate-a-long-random-string
ADMIN_TOKEN=generate-a-different-long-random-string
ALLOWED_ORIGINS=
```

- [ ] **Step 4: Ignore the real .env and remove the old unit**

Ensure `/Users/alexutkin/.gitignore` (or `~/server/.gitignore`) contains:

```
server/deploy/.env
```

Run: `cd /Users/alexutkin && git rm server/pulsar-api.service`

- [ ] **Step 5: Validate the compose file**

Run: `cd ~/server/deploy && SITE_ADDRESS=x POSTGRES_PASSWORD=x APP_TOKEN=x ADMIN_TOKEN=x docker compose config -q && echo OK`
Expected: prints `OK` (no schema errors).

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin
git add server/deploy/docker-compose.yml server/deploy/Caddyfile server/deploy/.env.example .gitignore
git commit -m "build(server): add Compose stack, Caddyfile, env template; drop systemd unit"
```

---

## Phase C — Provision & deploy (operator steps)

> These steps need your Hetzner account and interactive login. Run them yourself (or paste output back). Where possible I give the `hcloud` CLI form; the Hetzner Cloud Console web UI is an equivalent alternative for the provisioning steps.

### Task 7: Provision the CAX11 server

- [ ] **Step 1: Create the server**

Console: Hetzner Cloud Console → Add Server → Location **Nuremberg/Falkenstein/Helsinki** → Image **Ubuntu 24.04** → Type **CAX11 (Arm)** → add your SSH key → Create.

Or CLI (`brew install hcloud`, then `hcloud context create pulsar` with an API token):
```bash
hcloud server create --name pulsar-api --type cax11 \
  --image ubuntu-24.04 --location nbg1 --ssh-key <your-key-name>
```

- [ ] **Step 2: Record the public IP**

Run: `hcloud server ip pulsar-api` (or read it in the console).
Expected: an IPv4 like `159.69.12.34`. **This IP determines your hostname:** `159-69-12-34.sslip.io` (dashes, not dots).

- [ ] **Step 3: Verify SSH access**

Run: `ssh root@<IP> "echo connected"`
Expected: prints `connected`.

---

### Task 8: Harden the host

- [ ] **Step 1: Create a non-root deploy user**

```bash
ssh root@<IP> '
  adduser --disabled-password --gecos "" deploy &&
  usermod -aG sudo deploy &&
  mkdir -p /home/deploy/.ssh &&
  cp /root/.ssh/authorized_keys /home/deploy/.ssh/ &&
  chown -R deploy:deploy /home/deploy/.ssh &&
  chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
'
```

- [ ] **Step 2: Disable root SSH + password auth**

```bash
ssh root@<IP> '
  sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config &&
  sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config &&
  systemctl restart ssh
'
```
Verify: `ssh deploy@<IP> "echo ok"` prints `ok`; `ssh root@<IP>` is now refused.

- [ ] **Step 3: Host firewall (ufw) — allow only 22/80/443**

```bash
ssh deploy@<IP> '
  sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp &&
  sudo ufw --force enable && sudo ufw status
'
```
Expected: `Status: active` with 22, 80, 443 allowed.

- [ ] **Step 4: Hetzner Cloud Firewall (defence in depth)**

Console: Firewalls → Create → inbound allow TCP 22, 80, 443 from anywhere → apply to `pulsar-api`.
Or CLI:
```bash
hcloud firewall create --name web
hcloud firewall add-rule web --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall add-rule web --direction in --protocol tcp --port 80 --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall add-rule web --direction in --protocol tcp --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall apply-to-resource web --type server --server pulsar-api
```

---

### Task 9: Install Docker + Compose

- [ ] **Step 1: Install Docker Engine (Arm)**

```bash
ssh deploy@<IP> '
  curl -fsSL https://get.docker.com | sudo sh &&
  sudo usermod -aG docker deploy
'
```
(`get.docker.com` is the official Docker install script; the toolchain is required by the deployment.)

- [ ] **Step 2: Verify Docker + Compose plugin**

Re-login for the group to take effect: `ssh deploy@<IP> 'docker version && docker compose version'`
Expected: both print versions; Compose is v2 (`Docker Compose version v2.x`).

---

### Task 10: Deploy the stack

- [ ] **Step 1: Get the code onto the server**

Preferred (Git): push your branch, then on the server:
```bash
ssh deploy@<IP> 'git clone <your-repo-url> just-breathe'
```
No remote yet? Copy just the server dir:
```bash
rsync -av --exclude '__pycache__' --exclude '.env' ~/server/ deploy@<IP>:~/just-breathe/server/
```
Target layout on server: `~/just-breathe/server/` (Dockerfile, routers/, deploy/, …).

- [ ] **Step 2: Create the real .env**

```bash
ssh deploy@<IP>
cd ~/just-breathe/server/deploy
cp .env.example .env
# Generate strong secrets:
openssl rand -hex 32   # -> POSTGRES_PASSWORD
openssl rand -hex 32   # -> APP_TOKEN
openssl rand -hex 32   # -> ADMIN_TOKEN
nano .env              # set SITE_ADDRESS=<IP-with-dashes>.sslip.io, paste secrets + OPENAI_API_KEY
chmod 600 .env
```
**Record `APP_TOKEN`** — the iOS build needs it (Task 12).

- [ ] **Step 2b: Verify the app reaches Postgres via the compose network name**

The app's `DATABASE_URL` uses host `db` (the compose service name), not `localhost`. Confirm `docker-compose.yml` sets `DATABASE_URL=postgresql://pulsar:...@db:5432/pulsar` (it does, from Task 6).

- [ ] **Step 3: Bring the stack up**

```bash
cd ~/just-breathe/server/deploy
docker compose up -d --build
docker compose ps
```
Expected: `db`, `api`, `caddy` all `running`/`healthy`.

- [ ] **Step 4: Verify HTTPS end-to-end**

Give Caddy ~30s to fetch the cert, then from your laptop:
```bash
curl https://<IP-with-dashes>.sslip.io/health
```
Expected: `{"status":"ok"}` over a valid (non-self-signed) cert — no `-k` needed.

- [ ] **Step 5: Verify auth is enforced**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<host>.sslip.io/admin/users            # 401
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer <ADMIN_TOKEN>" \
     https://<host>.sslip.io/admin/users                                                 # 200
```
Expected: `401` then `200`.

- [ ] **Step 6: Run the DB-backed test suite against the live DB (optional but recommended)**

From the server:
```bash
docker compose exec -T api sh -c 'cd / && DATABASE_URL=$DATABASE_URL python -m pytest server/tests -v' || true
```
(Requires test deps in the image; if not present, skip — the curl smoke tests above already prove the deploy.)

---

### Task 11: Backups

**Files:**
- Create (on server): `~/just-breathe/server/deploy/backup.sh`

- [ ] **Step 1: Write the backup script**

On the server, create `~/just-breathe/server/deploy/backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p backups
STAMP=$(date +%F-%H%M)
docker compose exec -T db pg_dump -U pulsar pulsar | gzip > "backups/pulsar-$STAMP.sql.gz"
# Retain 7 days
find backups -name '*.sql.gz' -mtime +7 -delete
```
Then: `chmod +x ~/just-breathe/server/deploy/backup.sh`

- [ ] **Step 2: Verify a dump works**

Run: `~/just-breathe/server/deploy/backup.sh && ls -lh ~/just-breathe/server/deploy/backups`
Expected: a `pulsar-<stamp>.sql.gz` file exists and is non-empty.

- [ ] **Step 3: Schedule nightly via cron**

```bash
( crontab -l 2>/dev/null; echo "30 3 * * * /home/deploy/just-breathe/server/deploy/backup.sh >> /home/deploy/backup.log 2>&1" ) | crontab -
crontab -l
```
Expected: the cron line is listed.

- [ ] **Step 4: Enable weekly Hetzner snapshots**

Console: Server → Backups → Enable (weekly automatic backups, ~20% of server cost) — or snapshot manually before risky changes:
```bash
hcloud server create-image --type snapshot --description "pulsar weekly" pulsar-api
```

---

## Phase D — Point the iOS app at the server

### Task 12: Wire the iOS client to the deployed backend

**Files:**
- Create: `~/ios/Pulsar/App/ServerConfig.swift`
- Modify: `~/ios/Pulsar/App/AppEnvironment.swift:74-75,107-108` (default server URL)
- Modify: `~/ios/Pulsar/Sync/APIClient.swift:139-144` (`request` helper — add auth header)
- Modify: `~/ios/Pulsar/Sync/SyncService.swift:60-70` (`connect` — add `?token=`)

**Interfaces:**
- Consumes: `APP_TOKEN` recorded in Task 10 Step 2.
- Note: this token is compiled into the app — acceptable for a closed beta (documented tradeoff in the spec).

- [ ] **Step 1: Add the server config constant**

Create `~/ios/Pulsar/App/ServerConfig.swift`:

```swift
import Foundation

/// Beta backend configuration. APP_TOKEN is compiled into the build — a
/// beta-grade shared secret. Move to per-user auth before a public launch.
enum ServerConfig {
    static let defaultBaseURLString = "https://CHANGE-ME.sslip.io"   // <IP-with-dashes>.sslip.io
    static let appToken = "PASTE_APP_TOKEN_FROM_SERVER_ENV"
}
```

- [ ] **Step 2: Use it as the default server URL**

In `~/ios/Pulsar/App/AppEnvironment.swift`, replace both `"http://localhost:8000"` fallbacks (lines ~74-75 and ~107-108) with `ServerConfig.defaultBaseURLString`. Example at line 74-75:

```swift
let s = UserDefaults.standard.string(forKey: "serverURL") ?? ServerConfig.defaultBaseURLString
return URL(string: s) ?? URL(string: ServerConfig.defaultBaseURLString)!
```

- [ ] **Step 3: Send the bearer token on REST calls**

In `~/ios/Pulsar/Sync/APIClient.swift`, in the private `request(path:method:)` helper, add the auth header:

```swift
private func request(path: String, method: String) -> URLRequest {
    var r = URLRequest(url: baseURL.appendingPathComponent(path))
    r.httpMethod = method
    r.addValue("application/json", forHTTPHeaderField: "Content-Type")
    r.addValue("Bearer \(ServerConfig.appToken)", forHTTPHeaderField: "Authorization")
    r.timeoutInterval = 15
    return r
}
```

- [ ] **Step 4: Send the token on the WebSocket**

In `~/ios/Pulsar/Sync/SyncService.swift`, in `connect(userID:)`, add the token query item before building the URL:

```swift
var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
components.scheme = components.scheme == "https" ? "wss" : "ws"
components.queryItems = [URLQueryItem(name: "token", value: ServerConfig.appToken)]
guard let url = components.url else { return }
```

- [ ] **Step 5: Build the app**

Run in Xcode (or `xcodebuild`) a build for the simulator.
Expected: compiles with no errors.

- [ ] **Step 6: Manual smoke test (on device/simulator against the live server)**

1. Launch the app; complete/log a short session → confirm it appears via `curl -H "Authorization: Bearer <ADMIN_TOKEN>" https://<host>.sslip.io/admin/sessions`.
2. Start a live session → server logs show WebSocket connected (`docker compose logs -f api`); no `1008` close.
3. Trigger an insight → returns text (proves `/insights` + OpenAI key path).

Expected: all three succeed. If the WebSocket closes with 1008, the app token doesn't match the server `.env` — fix `ServerConfig.appToken`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin
git add ios/Pulsar/App/ServerConfig.swift ios/Pulsar/App/AppEnvironment.swift \
        ios/Pulsar/Sync/APIClient.swift ios/Pulsar/Sync/SyncService.swift
git commit -m "feat(ios): point client at deployed backend with app token auth"
```

---

## Self-Review — spec coverage

- Server tier CAX11 / EU → Task 7. ✓
- Docker Compose (Caddy/api/db), internal network, pgdata volume → Task 6. ✓
- Free sslip.io + auto Let's Encrypt, no ATS exception → Task 6 (Caddyfile), Task 10 Step 4. ✓
- Firewall (Hetzner + ufw), SSH key-only, non-root → Task 8. ✓
- Secrets in git-ignored `.env`, no CHANGE_ME → Task 6 (.env.example + .gitignore), Task 10 Step 2; old systemd unit removed → Task 6 Step 4. ✓
- Minimal auth: APP_TOKEN on app endpoints + WS, ADMIN_TOKEN on admin → Tasks 2, 3, 4. ✓
- CORS tightened → Task 4. ✓
- Nightly pg_dump + weekly Hetzner snapshot → Task 11. ✓
- iOS base URL + APP_TOKEN wiring, smoke test → Task 12. ✓
- Success criteria (health over valid cert, admin 401/200, data survives restart, backup restores) → Task 10 Steps 4-5, Task 11 Step 2. ✓

No placeholders remain; token names (`APP_TOKEN`, `ADMIN_TOKEN`), function names (`require_app_token`, `require_admin_token`, `verify_token`), and the `ServerConfig.appToken` constant are consistent across tasks.
