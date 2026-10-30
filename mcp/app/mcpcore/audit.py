"""Audit / access / error logs (proposal §11).

Date-named JSON Lines files in MCP_LOG_DIR, opened O_APPEND per write: several uvicorn workers
can write the same file without coordination and nothing is ever renamed. Rotation period and
retention are admin settings in P3; until then: daily files, 90 kept, every category on.

Never logged: passwords, tokens, codes, message bodies, subjects.
"""

import datetime as dt
import json
import logging
import os
from pathlib import Path

from django.conf import settings

log = logging.getLogger("mcp.audit")

ROTATION = "day"     # day | week | month (P3 setting)
RETENTION = 90       # files per kind (P3 setting)
KINDS = ("access", "audit", "errors")


def _period(now: dt.datetime) -> str:
    if ROTATION == "week":
        y, w, _ = now.isocalendar()
        return f"{y}-W{w:02d}"
    if ROTATION == "month":
        return now.strftime("%Y-%m")
    return now.strftime("%Y-%m-%d")


def _write(kind: str, record: dict) -> None:
    now = dt.datetime.now(dt.UTC)
    record = {"ts": now.isoformat(timespec="milliseconds"), **record}
    path = Path(settings.MCP_LOG_DIR) / f"{kind}-{_period(now)}.log"
    line = (json.dumps(record, separators=(",", ":"), default=str) + "\n").encode()
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
        try:
            os.write(fd, line)
        finally:
            os.close(fd)
    except OSError as exc:  # a full/readonly log volume must never break a request
        log.error("cannot write %s: %s", path, exc)


def event(category: str, event_name: str, *, result: str = "ok", actor: dict | None = None,
          token: dict | None = None, target: dict | None = None, ip: str = "", ua: str = "",
          detail: dict | None = None, request_id: str = "", level: str = "info") -> None:
    rec = {"level": level, "category": category, "event": event_name, "result": result}
    for key, value in (("actor", actor), ("token", token), ("target", target), ("ip", ip),
                       ("ua", ua), ("detail", detail), ("request_id", request_id)):
        if value:
            rec[key] = value
    _write("audit", rec)
    if level == "error":
        _write("errors", rec)


def access(record: dict) -> None:
    _write("access", record)


def error(where: str, message: str, **extra) -> None:
    rec = {"level": "error", "category": "error", "event": where, "detail": {"message": message, **extra}}
    _write("errors", rec)
    log.error("%s: %s", where, message)


def prune() -> int:
    """Retention: keep the newest RETENTION files per kind. Returns how many were deleted."""
    removed = 0
    base = Path(settings.MCP_LOG_DIR)
    for kind in KINDS:
        files = sorted(base.glob(f"{kind}-*.log"))
        for old in files[:-RETENTION] if len(files) > RETENTION else []:
            try:
                old.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def recent(category_prefix: str, *, account_id: int | None = None, limit: int = 50) -> list[dict]:
    """Newest audit records (newest file first), optionally for one account."""
    out: list[dict] = []
    for path in sorted(Path(settings.MCP_LOG_DIR).glob("audit-*.log"), reverse=True):
        try:
            lines = path.read_text().splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not rec.get("category", "").startswith(category_prefix):
                continue
            if account_id is not None and (rec.get("actor") or {}).get("account") != account_id:
                continue
            out.append(rec)
            if len(out) >= limit:
                return out
    return out
