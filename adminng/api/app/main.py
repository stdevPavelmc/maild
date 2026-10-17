"""AdminNG API application (Phase 0: health only).

The full catalogue/device API lands in Phases 1-2 (see adminng/doc/plan.md).
Everything is served under /api/v1/ through the adminng-nginx frontend, which
also owns the exterior access log; the bare /health path exists for the
container healthcheck.
"""

import psycopg
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from . import settings

app = FastAPI(
    title="MailD AdminNG API",
    version=settings.APP_VERSION,
    description=(
        "PWA-first administration API for the MailD PostfixAdmin catalogue. "
        "Every route except /health requires an approved device (X-Device-ID)."
    ),
    docs_url="/api/v1/docs",
    openapi_url="/api/v1/openapi.json",
)


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
