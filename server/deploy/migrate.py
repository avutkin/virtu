"""
Idempotent schema migration — creates tables if they don't exist.
Run from the repo root with the venv python and .env loaded:

    set -a && . server/deploy/.env && set +a
    .venv/bin/python server/deploy/migrate.py
"""
import asyncio

from server.db import init_pool, create_schema, close_pool


async def main() -> None:
    await init_pool()
    await create_schema()
    await close_pool()


if __name__ == "__main__":
    asyncio.run(main())
