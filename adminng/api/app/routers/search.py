"""Rapid search: one query, mixed user/alias/domain hits, tenant-scoped."""

from fastapi import APIRouter, Depends, Query

from .. import catalogue, settings
from ..auth import Principal, get_principal
from ..models import SearchOut

router = APIRouter(tags=["search"])


@router.get("/search", response_model=SearchOut, summary="Rapid search (CTRL/CMD+K)")
def search(
    q: str = Query(min_length=1, max_length=100),
    principal: Principal = Depends(get_principal),
) -> dict:
    return catalogue.search(principal, q, settings.ADMINNG_SEARCH_LIMIT)
