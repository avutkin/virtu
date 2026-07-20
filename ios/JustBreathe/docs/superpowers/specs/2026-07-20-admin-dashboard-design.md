# JustBreathe Admin Dashboard — Design

**Date:** 2026-07-20
**Status:** Approved (design), pending implementation plan
**Sequencing:** Follow-up to the Hetzner backend deployment (`2026-07-20-hetzner-backend-deployment-design.md`). Build/deploy the backend first; add this dashboard as a second plan.

## Goal

A web dashboard for the app owner (single admin) to see the numbers across all beta users: aggregate stats, browsable/exportable raw data, and per-user drill-down. Server-rendered pages inside the existing FastAPI app — no separate service, no SPA build step, runs on the same CAX11 box.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| Content | Aggregate stats, raw data browsing/export, per-user drill-down. **No** live real-time monitoring. |
| Approach | **Custom** dashboard in the FastAPI app (Jinja + HTMX + Chart.js). Not Metabase/Grafana — keeps the box small, reuses admin auth, tailored to HRV, looks like the product. |
| Analytics data layer | **Postgres only** (same DB as the app). No ClickHouse, no TimescaleDB for the beta. Revisit at real scale. |
| Auth | Reuse `ADMIN_TOKEN` from the deployment design. Browser login sets a signed HttpOnly cookie; JSON API keeps `Bearer`. |
| Schema | Read-only. No new tables, no writes. |

## Views

1. **Overview** (`/dashboard`)
   - Stat tiles: total users, total sessions, active users (last 7d), avg coherence, avg RSA (ms).
   - Chart: sessions-per-day (bar) over a selectable window.
   - Chart: average coherence over time (line) across all users.

2. **Users** (`/dashboard/users`)
   - Filterable / sortable / paginated table: device id, last seen, session count.
   - This is the "raw browsing" surface. Row click → user detail.
   - HTMX swaps table fragments for filter/sort/paginate (no full reload, no SPA).

3. **User detail** (`/dashboard/users/{id}`)
   - That user's session list (started/ended, avg RSA, avg coherence, notes).
   - Charts: the user's coherence and RSA trends across their sessions.
   - Per-session detail view.
   - CSV export button — reuses/extends the existing `/admin/sessions/{id}/export`.

## Architecture

Server-rendered pages served by the existing FastAPI app, behind cookie auth.

```
Browser (admin) ──HTTPS──> Caddy ──> FastAPI app
                                        ├── routers/dashboard.py   (HTML page routes)
                                        ├── dashboard_queries.py   (read-only aggregate SQL)
                                        ├── templates/             (Jinja2)
                                        │     base.html, overview.html,
                                        │     users.html, user_detail.html,
                                        │     _users_table.html (HTMX fragment), login.html
                                        └── static/                (chart.js, dashboard.css, htmx.min.js)
```

### Components & boundaries

- **`routers/dashboard.py`** — page routes only; render templates, call query functions. No SQL inline.
- **`dashboard_queries.py`** — all aggregate/read SQL as small named async functions (e.g. `overview_stats()`, `sessions_per_day(window)`, `list_users(filter, sort, page)`, `user_sessions(user_id)`, `user_trends(user_id)`). Testable independently of the web layer.
- **`templates/`** — Jinja2; `base.html` holds layout/nav; page templates extend it; `_users_table.html` is the HTMX-swappable fragment.
- **`static/`** — vendored Chart.js + htmx (no CDN dependency), one small CSS file.
- **Auth dependency** — `require_admin_cookie` for `/dashboard/*`; the existing `Bearer ADMIN_TOKEN` check stays for `/admin/*` JSON.

## Auth flow

- `GET /dashboard/login` → login form (admin secret field).
- `POST /dashboard/login` → compare to `ADMIN_TOKEN`; on success set a signed, HttpOnly, Secure, SameSite=Lax cookie (short-ish expiry, e.g. 7 days); redirect to `/dashboard`.
- All `/dashboard/*` routes depend on a valid signed cookie; missing/invalid → redirect to login.
- Cookie signed with a server secret (`DASHBOARD_SECRET` in `.env`, or derived from `ADMIN_TOKEN`).
- `GET /dashboard/logout` clears the cookie.

## Data

- Reads existing tables (`users`, `sessions`, and HRV sample/tick tables) only.
- Aggregates computed in SQL (counts, `GROUP BY date` rollups, `AVG`). At beta volume these are cheap; add indexes only if a query shows up slow.
- No caching layer for the beta (numbers are small; recompute per request).

## Implementation-time skills (not part of this spec)

- **frontend-design** — so the dashboard is intentional, not a bootstrap template; consistent typography/layout, light + dark.
- **dataviz** — for the charts: consistent, accessible color, readable axes/legends/tooltips, light + dark.

## Testing

- Unit-test each `dashboard_queries.py` function against a seeded test DB (the repo already has a `tests/` dir).
- Auth tests: `/dashboard/*` redirects to login without a cookie; valid login sets cookie and grants access; wrong secret rejected.
- A smoke test that each page renders 200 with seeded data.

## Success criteria

- Visiting `/dashboard` without a cookie redirects to login; correct secret logs in.
- Overview shows correct totals/averages against seeded data.
- Users table filters, sorts, and paginates via HTMX without full page reload.
- User detail shows that user's sessions + trend charts; CSV export downloads.
- Charts render legibly in light and dark.
- No new writes or schema changes; app endpoints unaffected.

## Out of scope

- Live real-time monitoring (the WebSocket stream view) — not requested.
- Multi-admin accounts / roles (single shared admin secret).
- ClickHouse / TimescaleDB / any second datastore.
- Editing user data from the dashboard (read-only).
