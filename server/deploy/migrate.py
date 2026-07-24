"""
Idempotent schema migration — creates tables if they don't exist.
Run from the repo root with the venv python and .env loaded:

    set -a && . server/deploy/.env && set +a
    .venv/bin/python server/deploy/migrate.py
"""
import asyncio
import os
import sys

# Ensure the repo root (…/wythin) is importable no matter how this is invoked
# (running `python server/deploy/migrate.py` puts server/deploy on sys.path,
# not the repo root, so `import server` would fail without this).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from server.db import init_pool, create_schema, close_pool


async def main() -> None:
    await init_pool()
    await create_schema()
    await close_pool()


if __name__ == "__main__":
    asyncio.run(main())
