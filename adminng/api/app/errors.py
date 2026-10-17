"""Uniform API errors (technical-draft §5).

Every failure answers `{"detail": "<CODE>", "message": "...", ...extra}` with the
fitting HTTP status, so the PWA can branch on stable codes instead of parsing
prose. FastAPI's own validation errors are normalised to the same shape.
"""

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class ApiError(Exception):
    """Application error carrying the contract's status + code."""

    def __init__(self, status_code: int, code: str, message: str | None = None, **extra):
        super().__init__(message or code)
        self.status_code = status_code
        self.code = code
        self.message = message or code
        self.extra = extra

    def payload(self) -> dict:
        body = {"detail": self.code, "message": self.message}
        body.update(self.extra)
        return body


def not_found(entity: str, value: str) -> ApiError:
    return ApiError(404, "NOT_FOUND", f"{entity} '{value}' does not exist")


def conflict(message: str) -> ApiError:
    return ApiError(409, "CONFLICT", message)


def forbidden_tenant() -> ApiError:
    return ApiError(
        403,
        "FORBIDDEN_TENANT",
        "the entity belongs to a domain outside the caller's scope",
    )


def validation(message: str, **extra) -> ApiError:
    return ApiError(422, "VALIDATION", message, **extra)


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(exc.payload(), status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        # Keep the offending fields, drop pydantic internals (ctx objects are not JSON).
        fields = [
            {"loc": [str(part) for part in err.get("loc", [])], "msg": err.get("msg", "")}
            for err in exc.errors()
        ]
        return JSONResponse(
            {"detail": "VALIDATION", "message": "request validation failed", "fields": fields},
            status_code=422,
        )
