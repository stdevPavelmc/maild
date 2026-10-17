"""Request/response models for the catalogue API (technical-draft §5).

Writes follow the legacy catalogue contract: `quota_bytes` (0 = unlimited) is
the DB's `quota` column, mailbox identity is the full address, and an admin is a
catalogue `admin` row plus its `domain_admins` scope.
"""

import re
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

_DOMAIN_RE = re.compile(
    r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$"
)
_LOCAL_RE = re.compile(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$")


def _norm_domain(value: str) -> str:
    value = str(value).strip().lower()
    if not _DOMAIN_RE.match(value):
        raise ValueError("invalid domain name")
    return value


def _norm_address(value: str) -> str:
    value = str(value).strip()
    if "@" not in value:
        raise ValueError("invalid email address")
    local, _, domain = value.rpartition("@")
    if not local or not _LOCAL_RE.match(local):
        raise ValueError("invalid email address")
    return f"{local}@{_norm_domain(domain)}"


def _norm_goto(value: str) -> str:
    recipients = [part.strip() for part in value.split(",") if part.strip()]
    if not recipients:
        raise ValueError("goto needs at least one recipient")
    return ",".join(_norm_address(part) for part in recipients)


# --------------------------------------------------------------------- domains
class DomainCreate(BaseModel):
    domain: str
    description: str = ""
    maxquota: int = Field(default=0, ge=0)
    quota: int = Field(default=0, ge=0)
    transport: str = "virtual"
    backupmx: bool = False
    active: bool = True

    @field_validator("domain")
    @classmethod
    def _validate_domain(cls, value: str) -> str:
        return _norm_domain(value)


class DomainUpdate(BaseModel):
    description: str | None = None
    maxquota: int | None = Field(default=None, ge=0)
    quota: int | None = Field(default=None, ge=0)
    transport: str | None = None
    backupmx: bool | None = None
    active: bool | None = None


class DomainOut(BaseModel):
    domain: str
    description: str
    aliases: int
    mailboxes: int
    maxquota: int
    quota: int
    transport: str | None
    backupmx: bool
    active: bool
    created: datetime | None
    modified: datetime | None


class Advisory(BaseModel):
    code: str
    services: list[str] = []
    message: str


class DomainCreated(DomainOut):
    advisories: list[Advisory] = []


# -------------------------------------------------------------------- mailboxes
class MailboxCreate(BaseModel):
    username: str
    password: str = Field(min_length=1)
    name: str = ""
    quota_bytes: int = Field(default=0, ge=0)
    active: bool = True

    @field_validator("username")
    @classmethod
    def _validate_username(cls, value: str) -> str:
        return _norm_address(value)


class MailboxUpdate(BaseModel):
    name: str | None = None
    password: str | None = Field(default=None, min_length=1)
    quota_bytes: int | None = Field(default=None, ge=0)
    active: bool | None = None


class MailboxOut(BaseModel):
    username: str
    name: str
    quota_bytes: int
    active: bool
    domain: str
    local_part: str
    maildir: str
    created: datetime | None
    modified: datetime | None


class QuotaStatus(BaseModel):
    username: str
    quota_bytes: int
    used_bytes: int
    percentage: float | None
    unlimited: bool
    source: Literal["maildirsize", "du", "unavailable"]


# ----------------------------------------------------------------------- aliases
class AliasCreate(BaseModel):
    address: str
    goto: str
    active: bool = True

    @field_validator("address")
    @classmethod
    def _validate_address(cls, value: str) -> str:
        return _norm_address(value)

    @field_validator("goto")
    @classmethod
    def _validate_goto(cls, value: str) -> str:
        return _norm_goto(value)


class AliasUpdate(BaseModel):
    goto: str | None = None
    active: bool | None = None

    @field_validator("goto")
    @classmethod
    def _validate_goto(cls, value: str | None) -> str | None:
        return None if value is None else _norm_goto(value)


class AliasOut(BaseModel):
    address: str
    goto: str
    domain: str
    active: bool
    created: datetime | None
    modified: datetime | None


# ------------------------------------------------------------------------ admins
class AdminCreate(BaseModel):
    username: str
    password: str = Field(min_length=1)
    superadmin: bool = False
    active: bool = True
    domains: list[str] = []

    @field_validator("username")
    @classmethod
    def _validate_username(cls, value: str) -> str:
        return _norm_address(value)

    @field_validator("domains")
    @classmethod
    def _validate_domains(cls, values: list[str]) -> list[str]:
        return [_norm_domain(value) for value in values]


class AdminUpdate(BaseModel):
    password: str | None = Field(default=None, min_length=1)
    superadmin: bool | None = None
    active: bool | None = None
    domains: list[str] | None = None

    @field_validator("domains")
    @classmethod
    def _validate_domains(cls, values: list[str] | None) -> list[str] | None:
        return None if values is None else [_norm_domain(value) for value in values]


class AdminOut(BaseModel):
    username: str
    superadmin: bool
    active: bool
    domains: list[str]
    created: datetime | None
    modified: datetime | None


# ------------------------------------------------------------------------ search
class SearchHit(BaseModel):
    type: Literal["user", "alias", "domain"]
    id: str
    display_name: str
    domain: str | None
    details: dict


class SearchOut(BaseModel):
    query: str
    results: list[SearchHit]


# ----------------------------------------------------------------------- generic
class Page(BaseModel):
    items: list
    next_cursor: str | None = None
