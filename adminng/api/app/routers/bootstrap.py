"""Bulk account bootstrap ("Carga inicial") from a base64-encoded CSV file.

The import is row-by-row: a failing row is reported and skipped, never
aborting the whole file. When there are failures the API also returns a CSV
with only the failed rows (+ a `problem` column), so the admin can fix them
and upload the file again.
"""

from fastapi import APIRouter, Depends, Request

from .. import audit, bulk, settings
from ..auth import Principal, get_principal
from ..models import BootstrapReport, BootstrapRequest

router = APIRouter(prefix="/bootstrap", tags=["bootstrap"])


@router.post(
    "",
    response_model=BootstrapReport,
    summary="Import accounts from a CSV file (row by row, failures are reported)",
)
def bootstrap_users(
    payload: BootstrapRequest,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    report = bulk.import_users(principal, payload.csv_base64)
    audit.record(
        actor=principal.username,
        action="BOOTSTRAP_IMPORT",
        device_id=principal.device_id,
        entity_type="bootstrap",
        entity_id=None,
        domain=None,
        ip=audit.client_ip(request),
        endpoint=f"{request.method} {request.url.path}",
        total=report["total"],
        created=report["created"],
        failed=report["failed"],
        hash_scheme=settings.PASSWORD_SCHEME,
    )
    return report
