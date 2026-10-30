"""Audit / access / error logs (proposal §11).

Date-named JSON Lines files in MCP_LOG_DIR, opened O_APPEND per write: several uvicorn workers
can write the same file without coordination and nothing is ever renamed. Rotation period,
retention and the per-category switches come from the admin's `logging` settings group (P3);
master-token use is written whatever the switches say (D7: always audited).

Never logged: passwords, tokens, codes, message bodies, subjects.
"""

import datetime as dt
import json
import logging
import os
from pathlib import Path

from django.conf import settings

log = logging.getLogger("mcp.audit")

KINDS = ("access", "audit", "errors")

# audit category → the admin's logging switch that governs it
_SWITCH = {"web.login": "web_login", "web.logout": "web_login", "bearer.access": "bearer_access",
           "mail.read": "mail_actions", "mail.modify": "mail_actions", "mail.trash": "mail_actions",
           "mail.send": "mail_actions", "token.lifecycle": "token_lifecycle", "admin.settings": "admin_changes",
           "admin.login": "web_login", "oauth": "token_lifecycle", "error": "errors", "security": "security"}


def _config() -> dict:
    try:
        from mcpcore import settings_store

        return settings_store.get("logging")
    except Exception:   # no DB yet (boot) or a broken row: log everything, daily
        return {"enabled": True, "categories": {}, "rotation": "day", "retention": 90}


def _allowed(category: str) -> bool:
    cfg = _config()
    if not cfg.get("enabled", True):
        return False
    return bool(cfg.get("categories", {}).get(_SWITCH.get(category, "security"), True))


def _period(now: dt.datetime) -> str:
    rotation = _config().get("rotation", "day")
    if rotation == "week":
        y, w, _ = now.isocalendar()
        return f"{y}-W{w:02d}"
    if rotation == "month":
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
          detail: dict | None = None, request_id: str = "", level: str = "info", force: bool = False) -> None:
    """`force` bypasses the admin's switches (D7: master-token use is always audited)."""
    if token and token.get("kind") == "master":
        force = True
    if not force and not _allowed(category):
        return
    rec = {"level": level, "category": category, "event": event_name, "result": result}
    for key, value in (("actor", actor), ("token", token), ("target", target), ("ip", ip),
                       ("ua", ua), ("detail", detail), ("request_id", request_id)):
        if value:
            rec[key] = value
    _write("audit", rec)
    if level == "error":
        _write("errors", rec)


def access(record: dict) -> None:
    if _allowed("bearer.access"):
        _write("access", record)


def error(where: str, message: str, **extra) -> None:
    rec = {"level": "error", "category": "error", "event": where, "detail": {"message": message, **extra}}
    if _allowed("error"):
        _write("errors", rec)
    log.error("%s: %s", where, message)


def prune() -> int:
    """Retention: keep the newest `retention` files per kind. Returns how many were deleted."""
    retention = int(_config().get("retention", 90))
    removed = 0
    base = Path(settings.MCP_LOG_DIR)
    for kind in KINDS:
        files = sorted(base.glob(f"{kind}-*.log"))
        for old in files[:-retention] if len(files) > retention else []:
            try:
                old.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def recent(category_prefix: str, *, account_id: int | None = None, limit: int = 50,
           exclude: tuple[str, ...] = ()) -> list[dict]:
    """Newest audit records (newest file first), optionally for one account, skipping the
    categories in `exclude`."""
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
            if not rec.get("category", "").startswith(category_prefix) or rec.get("category") in exclude:
                continue
            if account_id is not None and (rec.get("actor") or {}).get("account") != account_id:
                continue
            out.append(rec)
            if len(out) >= limit:
                return out
    return out


def tail(kind: str, query: str = "", limit: int = 200) -> list[dict]:
    """Newest lines of one log kind (admin logs viewer), optionally filtered by a substring."""
    if kind not in KINDS:
        raise ValueError(kind)
    out: list[dict] = []
    q = query.lower()
    for path in sorted(Path(settings.MCP_LOG_DIR).glob(f"{kind}-*.log"), reverse=True):
        try:
            lines = path.read_text().splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if q and q not in line.lower():
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
            if len(out) >= limit:
                return out
    return out
