# Deploying the Pulsar API to Hetzner

A one-box setup: FastAPI (uvicorn) + PostgreSQL + Caddy (automatic HTTPS) on a
single Hetzner Cloud server. Recommended size: **CAX11** (Arm, 2 vCPU / 4 GB /
40 GB, ~€4/mo). Resize to CAX21 (4 vCPU / 8 GB) later if you outgrow it.

---

## Securing the app ↔ server connection

This is the important part. Layers, from most to least critical:

### 1. Encrypt everything in transit — TLS (HTTPS + WSS)
Today the app talks to a raw IP over **plain HTTP/WS** (`http://18.116.98.119:8000`).
That's readable and tamperable by anyone on the network path, and Apple's **App
Transport Security will block it in a TestFlight/App Store build**.

This kit fixes that: **Caddy** sits in front of the API, gets a free Let's
Encrypt certificate for your domain automatically, and terminates TLS. The app
then uses `https://api.yourdomain.com` and `wss://api.yourdomain.com/stream/...`.
WebSockets are proxied transparently. Certs auto-renew. → **You must use a
domain name, not a bare IP** (Let's Encrypt won't issue certs for IPs).

After deploy, update the iOS app's server URL (Settings → server URL, or the
`serverURL` UserDefaults key) to `https://api.yourdomain.com`. `SyncService`
already upgrades `https` → `wss` for the stream socket, so nothing else changes.

### 2. Don't expose anything you don't have to
- **uvicorn binds to `127.0.0.1:8000`** (see the systemd unit) — it is *not*
  reachable from the internet at all; only Caddy can reach it.
- **PostgreSQL listens on localhost only** and the **firewall blocks 5432**.
- The firewall opens **only 22 (SSH), 80, 443**.

### 3. Harden the box
- **SSH: keys only.** Disable password login: in `/etc/ssh/sshd_config` set
  `PasswordAuthentication no` and `PermitRootLogin prohibit-password`, then
  `systemctl restart ssh`. Add your public key to the `deploy` user.
- **Automatic security updates** are enabled (`unattended-upgrades`).
- Optional but recommended: `apt install fail2ban` to throttle SSH brute force.

### 4. Authenticate the app to the API (the current gap)
Right now the API has **no authentication** — anyone who learns the URL can POST
to `/sessions`, `/insights`, etc. TLS protects the *channel* but not *who may
call it*. The endpoints identify a device via an `X-User-ID` header, but that's
not a secret.

Minimal hardening included here: set **`API_KEY`** in `.env`. When set, the app
must send it as an `X-API-Key` header; requests without it get `401`. Generate
one with `openssl rand -hex 32`. (Enabling this also needs a one-line change in
the iOS `APIClient` to send the header — ask and I'll wire both sides.) For a
larger user base, graduate to per-user tokens / Sign in with Apple.

### 5. Protect the OpenAI proxy from abuse (cost)
`/insights` spends real money per call. Behind auth (step 4) it's much safer;
you can also add a Caddy `rate_limit` on that path if you expose it widely.

### 6. Optional: certificate pinning
For a high-assurance app you can pin the server's certificate/public key in the
iOS `URLSession` delegate, so a mis-issued CA cert can't MITM you. Overkill for
most; say the word if you want it.

---

## First-time setup

1. **Create the server** in Hetzner Cloud: CAX11, Ubuntu 24.04, your nearest
   location, add your SSH key, enable backups.
2. **DNS:** point an `A` record `api.yourdomain.com` → the server IP.
3. **SSH in** and clone the repo:
   ```bash
   sudo git clone https://github.com/avutkin/pulsar.git /opt/pulsar
   cp /opt/pulsar/server/deploy/env.example /opt/pulsar/server/deploy/.env
   sudo nano /opt/pulsar/server/deploy/.env      # set DB_PASSWORD, DATABASE_URL, OPENAI_API_KEY
   ```
4. **Provision:**
   ```bash
   sudo bash /opt/pulsar/server/deploy/hetzner-setup.sh api.yourdomain.com
   ```
5. **Verify:** `curl https://api.yourdomain.com/health` → `{"status":"ok"}`.
6. Point the iOS app's server URL at `https://api.yourdomain.com`.

## Continuous deploys (GitHub Actions)

The `Server Deploy` workflow SSHes to the box on every push to `main` that
touches `server/**`, pulls, updates deps, migrates, and restarts the service.
Set these repo secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | server IP or `api.yourdomain.com` |
| `DEPLOY_USER` | the deploy SSH user (e.g. `deploy`) |
| `DEPLOY_SSH_KEY` | private key whose public half is on the box |
| `API_DOMAIN` | `api.yourdomain.com` (used for the HTTPS health check) |

The deploy user needs passwordless restart rights — add a sudoers drop-in:
```
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart pulsar-api
```

## Files

| File | Purpose |
|---|---|
| `hetzner-setup.sh` | one-time provisioning (idempotent-ish) |
| `pulsar-api.service` | systemd unit (loopback-bound uvicorn) |
| `Caddyfile` | reverse proxy + automatic HTTPS + security headers |
| `migrate.py` | idempotent schema creation |
| `env.example` | template for the (gitignored) `.env` |
