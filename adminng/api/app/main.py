"""AdminNG API application.

Phase 1 serves the catalogue CRUD + search + quota usage behind plain bearer
auth (device trust/TOTP land in Phase 2). Everything is mounted under /api/v1/
through the `adminng` nginx frontend, which also owns the exterior access log;
the bare /health path exists for the container healthcheck.
"""

import asyncio
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from . import settings
from .errors import install_error_handlers
from .routers import (
    admins,
    aliases,
    auth,
    devices,
    domain_aliases,
    domains,
    logs,
    mailboxes,
    search,
    webauthn,
)

# The OpenAPI contract + Swagger UI are a dev affordance: with ADMINNG_API_DOCS=no
# (the image default = production posture) FastAPI serves 404s on /api/v1/docs and
# /api/v1/openapi.json instead of the full API map (2026-10 audit F-04). ReDoc
# stays off in both modes: its default /redoc path is not proxied by nginx anyway.
_docs_kwargs = (
    {
        "docs_url": "/api/v1/docs",
        "redoc_url": None,
        "openapi_url": "/api/v1/openapi.json",
    }
    if settings.ADMINNG_API_DOCS
    else {"docs_url": None, "redoc_url": None, "openapi_url": None}
)

# Housekeeping: purge stale PENDING device grants every hour so a browser that
# asked for access but was never approved does not linger forever (F-11).
_PURGE_INTERVAL = 3600


async def _purge_loop() -> None:
    from . import devices

    while True:
        await asyncio.sleep(_PURGE_INTERVAL)
        try:
            await asyncio.to_thread(
                devices.purge_stale_pending, settings.ADMINNG_PENDING_TTL_DAYS
            )
        except Exception:  # pragma: no cover - housekeeping must never crash the app
            pass


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_purge_loop())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(
    title="MailD AdminNG API",
    version=settings.APP_VERSION,
    lifespan=lifespan,
    description=(
        "PWA-first administration API for the MailD PostfixAdmin catalogue: "
        "domains, domain aliases, mailboxes, address aliases, "
        "administrators, rapid search and quota "
        "usage. Catalogue writes follow PostfixAdmin exactly (Argon2id "
        "passwords with md5crypt accepted as legacy until 2027-02-01, "
        "maildir layout, quota in bytes); AdminNG's own state lives in its own "
        "database."
    ),
    **_docs_kwargs,
)

install_error_handlers(app)

for _router in (
    auth.router,
    webauthn.router,
    devices.router,
    domains.router,
    domain_aliases.router,
    mailboxes.router,
    aliases.router,
    admins.router,
    search.router,
    logs.router,
):
    app.include_router(_router, prefix="/api/v1")


def _database_ok() -> bool:
    """True when AdminNG's own database answers (it is required for any work)."""
    try:
        with (
            psycopg.connect(
                f"host={settings.POSTGRES_HOST} port={settings.POSTGRES_PORT} "
                f"user={settings.POSTGRES_USER} password={settings.POSTGRES_PASSWORD} "
                f"dbname={settings.ADMINNG_DB}",
                connect_timeout=3,
            ) as conn,
            conn.cursor() as cur,
        ):
            cur.execute("SELECT 1")
            return True
    except psycopg.Error:
        return False


@app.get("/health", tags=["meta"], summary="Container liveness/readiness")
@app.get("/api/v1/health", tags=["meta"], summary="Liveness/readiness via the proxy")
def health() -> JSONResponse:
    """Liveness for the Docker healthcheck and the onboarding "test connection"."""
    ok = _database_ok()
    return JSONResponse(
        {
            "status": "ok" if ok else "degraded",
            "service": settings.SERVICE_NAME,
            "version": settings.APP_VERSION,
            "database": "up" if ok else "down",
        },
        status_code=200 if ok else 503,
    )
