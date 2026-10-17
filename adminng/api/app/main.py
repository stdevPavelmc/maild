"""AdminNG API application.

Phase 1 serves the catalogue CRUD + search + quota usage behind plain bearer
auth (device trust/TOTP land in Phase 2). Everything is mounted under /api/v1/
through the `adminng` nginx frontend, which also owns the exterior access log;
the bare /health path exists for the container healthcheck.
"""

import psycopg
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from . import settings
from .errors import install_error_handlers
from .routers import admins, aliases, auth, devices, domains, logs, mailboxes, search

app = FastAPI(
    title="MailD AdminNG API",
    version=settings.APP_VERSION,
    description=(
        "PWA-first administration API for the MailD PostfixAdmin catalogue: "
        "domains, mailboxes, aliases, administrators, rapid search and quota "
        "usage. Catalogue writes follow PostfixAdmin exactly (md5crypt, "
        "maildir layout, quota in bytes); AdminNG's own state lives in its own "
        "database."
    ),
    docs_url="/api/v1/docs",
    openapi_url="/api/v1/openapi.json",
)

install_error_handlers(app)

for _router in (
    auth.router,
    devices.router,
    domains.router,
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

