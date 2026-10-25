"""Catalogue access — the PostfixAdmin tables, written the PostfixAdmin way.

Non-negotiable compatibility rules (technical-draft §3.1):
  * password: NEW hashes are Argon2id ('{ARGON2ID}$argon2id$…', produced by
    `app.passwords` per PASSWORD_SCHEME); legacy raw md5crypt ($1$…) stays
    verifiable until 2027-02-01 (weak-scheme removal) — both formats are
    legal and may mix in the same column (Dovecot verifies both);
  * mailbox.maildir = '<domain>/<local_part>/' (trailing slash);
  * mailbox.quota and domain.quota are BYTES, 0 = unlimited;
  * deletes cascade explicitly (domain -> mailboxes/aliases/domain_admins/...),
    one transaction per mutation, and a deleted/disabled account loses its
    sessions;
  * no DDL is ever issued against the catalogue.

Every list is tenant-scoped: a superadmin sees everything, a custom admin only
the domains of its active `domain_admins` rows.
"""

import psycopg

from . import settings
from .auth import Principal, ensure_domain_allowed, revoke_user_sessions
from .db import connect
from .errors import conflict, not_found
from .passwords import hash_password
from .pagination import clamp_limit, decode_cursor, page

# Advisory lock for admin mutations (the last-superadmin guard must not race).
_ADMIN_LOCK = 842019021

_DOMAIN_COLUMNS = (
    "domain, description, aliases, mailboxes, maxquota, quota, transport, "
    "backupmx, active, created, modified, "
    "(SELECT count(*) FROM alias_domain ad WHERE ad.target_domain = domain.domain) "
    "AS alias_domains, "
    "(SELECT ad.target_domain FROM alias_domain ad "
    "WHERE ad.alias_domain = domain.domain) AS aliasing_to"
)
_DOMAIN_ALIAS_COLUMNS = "alias_domain, target_domain, active, created, modified"


def _tenant_clause(principal: Principal, column: str = "domain") -> tuple[str, list]:
    if principal.superadmin:
        return "", []
    return f" AND {column} = ANY(%s)", [principal.domains]


def _domain_out(row: dict) -> dict:
    return {
        "domain": row["domain"],
        "description": row["description"],
        "aliases": row["aliases"],
        "mailboxes": row["mailboxes"],
        "maxquota": row["maxquota"],
        "quota": row["quota"],
        "transport": row["transport"],
        "backupmx": row["backupmx"],
        "active": row["active"],
        "created": row["created"],
        "modified": row["modified"],
        "alias_domains": row["alias_domains"],
        "aliasing_to": row["aliasing_to"],
    }


def _domain_alias_out(row: dict) -> dict:
    return {
        "alias_domain": row["alias_domain"],
        "target_domain": row["target_domain"],
        "active": row["active"],
        "created": row["created"],
        "modified": row["modified"],
    }


def _ensure_domain_alias_pair(
    principal: Principal, alias_domain: str, target_domain: str
) -> None:
    if alias_domain == target_domain:
        raise conflict("alias domain must differ from target domain")
    ensure_domain_allowed(principal, alias_domain)
    ensure_domain_allowed(principal, target_domain)
    get_domain(principal, alias_domain)
    get_domain(principal, target_domain)


def _mailbox_out(row: dict) -> dict:
    return {
        "username": row["username"],
        "name": row["name"],
        "quota_bytes": row["quota"],
        "active": row["active"],
        "domain": row["domain"],
        "local_part": row["local_part"],
        "maildir": row["maildir"],
        "created": row["created"],
        "modified": row["modified"],
    }


def _alias_out(row: dict) -> dict:
    return {
        "address": row["address"],
        "goto": row["goto"],
        "domain": row["domain"],
        "active": row["active"],
        "created": row["created"],
        "modified": row["modified"],
    }


def recount_domain(cur, domain: str) -> None:
    """Keep domain.mailboxes / domain.aliases in step (PostfixAdmin counters)."""
    cur.execute(
        """
        UPDATE domain
           SET mailboxes = (SELECT count(*) FROM mailbox WHERE domain = %s),
               aliases   = (SELECT count(*) FROM alias   WHERE domain = %s),
               modified  = now()
         WHERE domain = %s
        """,
        (domain, domain, domain),
    )


def _mirror_admin_password(cur, username: str, hashed: str) -> None:
    """MailD convention (the api seeder): admin.password == mailbox.password."""
    cur.execute(
        "UPDATE admin SET password = %s, modified = now() WHERE username = %s",
        (hashed, username),
    )


def _mirror_mailbox_password(cur, username: str, hashed: str) -> None:
    cur.execute(
        "UPDATE mailbox SET password = %s, modified = now() WHERE username = %s",
        (hashed, username),
    )

# PostfixAdmin's $CONF['default_aliases']: the aliases every new domain used to get
# from the "create domain" click. They point at the administrator who creates the
# domain — the equivalent of MailD's old fixed administrator address.
DEFAULT_ALIASES = ("postmaster", "abuse", "hostmaster", "webmaster")


# ----------------------------------------------------------------------- domains
def list_domains(
    principal: Principal, q: str | None, limit: int, cursor: str | None
) -> dict:
    conds, params = ["TRUE"], []
    tenant, tenant_params = _tenant_clause(principal)
    if tenant:
        conds.append(tenant.removeprefix(" AND "))
        params.extend(tenant_params)
    if q:
        conds.append("(domain ILIKE %s OR description ILIKE %s)")
        params.extend([f"%{q}%", f"%{q}%"])
    if cursor:
        conds.append("domain > %s")
        params.append(decode_cursor(cursor))

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        f"SELECT {_DOMAIN_COLUMNS} FROM domain "
        f"WHERE {' AND '.join(conds)} ORDER BY domain LIMIT %s"
    )
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = [_domain_out(row) for row in cur.fetchall()]
    return page(rows, "domain", limit)


def get_domain(principal: Principal, domain: str) -> dict:
    ensure_domain_allowed(principal, domain)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT {_DOMAIN_COLUMNS} FROM domain WHERE domain = %s", (domain,))
        row = cur.fetchone()
    if row is None:
        raise not_found("domain", domain)
    return _domain_out(row)


def create_domain(principal: Principal, payload: dict) -> dict:
    ensure_domain_allowed(principal, payload["domain"])
    domain = payload["domain"]
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        try:
            cur.execute(
                """
                INSERT INTO domain
                       (domain, description, aliases, mailboxes, maxquota, quota,
                        transport, backupmx, active)
                VALUES (%s, %s, 0, 0, %s, %s, %s, %s, %s)
                """,
                (
                    domain,
                    payload["description"],
                    payload["maxquota"],
                    payload["quota"],
                    payload["transport"],
                    payload["backupmx"],
                    payload["active"],
                ),
            )
        except psycopg.errors.UniqueViolation:
            raise conflict(f"domain '{domain}' already exists") from None

        # The domain was created: add the same default aliases the PostfixAdmin
        # "create domain" click always added (its $CONF['default_aliases']), in the
        # same transaction, then fix the counters AdminNG keeps in step everywhere.
        if payload.get("default_aliases", True):
            cur.executemany(
                "INSERT INTO alias (address, goto, domain, active) "
                "VALUES (%s, %s, %s, true) ON CONFLICT DO NOTHING",
                [
                    (f"{alias}@{domain}", principal.username, domain)
                    for alias in DEFAULT_ALIASES
                ],
            )
            recount_domain(cur, domain)

        conn.commit()
    return get_domain(principal, domain)


def update_domain(principal: Principal, domain: str, payload: dict) -> dict:
    ensure_domain_allowed(principal, domain)
    fields = {key: value for key, value in payload.items() if value is not None}
    if fields:
        assignments = ", ".join(f"{key} = %s" for key in fields)
        with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
            cur.execute(
                f"UPDATE domain SET {assignments}, modified = now() WHERE domain = %s",
                [*fields.values(), domain],
            )
            if cur.rowcount == 0:
                raise not_found("domain", domain)
            conn.commit()
    return get_domain(principal, domain)


def delete_domain(principal: Principal, domain: str) -> None:
    """Cascade exactly like PostfixAdmin: one transaction, mail data untouched."""
    ensure_domain_allowed(principal, domain)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT username FROM mailbox WHERE domain = %s", (domain,))
        usernames = [row["username"] for row in cur.fetchall()]
        if not usernames:
            cur.execute("SELECT 1 FROM domain WHERE domain = %s", (domain,))
            if cur.fetchone() is None:
                raise not_found("domain", domain)

        if usernames:
            cur.execute("DELETE FROM quota  WHERE username = ANY(%s)", (usernames,))
            cur.execute("DELETE FROM quota2 WHERE username = ANY(%s)", (usernames,))
        cur.execute("DELETE FROM vacation      WHERE domain = %s", (domain,))
        cur.execute("DELETE FROM alias         WHERE domain = %s", (domain,))
        cur.execute("DELETE FROM domain_admins WHERE domain = %s", (domain,))
        cur.execute("DELETE FROM mailbox       WHERE domain = %s", (domain,))
        cur.execute("DELETE FROM domain        WHERE domain = %s", (domain,))
        conn.commit()

    for username in usernames:
        revoke_user_sessions(username)

# --------------------------------------------------------------- domain aliases
def list_domain_aliases(
    principal: Principal,
    domain: str | None,
    limit: int,
    cursor: str | None,
) -> dict:
    conds, params = ["TRUE"], []
    if domain:
        ensure_domain_allowed(principal, domain)
        conds.append("(alias_domain = %s OR target_domain = %s)")
        params.extend([domain, domain])
    if not principal.superadmin:
        conds.append("alias_domain = ANY(%s) AND target_domain = ANY(%s)")
        params.extend([principal.domains, principal.domains])
    if cursor:
        conds.append("alias_domain > %s")
        params.append(decode_cursor(cursor))

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        f"SELECT {_DOMAIN_ALIAS_COLUMNS} FROM alias_domain "
        f"WHERE {' AND '.join(conds)} ORDER BY alias_domain LIMIT %s"
    )
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = [_domain_alias_out(row) for row in cur.fetchall()]
    return page(rows, "alias_domain", limit)


def get_domain_alias(principal: Principal, alias_domain: str) -> dict:
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT {_DOMAIN_ALIAS_COLUMNS} FROM alias_domain WHERE alias_domain = %s",
            (alias_domain,),
        )
        row = cur.fetchone()
    if row is None:
        raise not_found("domain alias", alias_domain)
    _ensure_domain_alias_pair(principal, row["alias_domain"], row["target_domain"])
    return _domain_alias_out(row)


def create_domain_alias(principal: Principal, payload: dict) -> dict:
    alias_domain = payload["alias_domain"]
    target_domain = payload["target_domain"]
    _ensure_domain_alias_pair(principal, alias_domain, target_domain)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        try:
            cur.execute(
                """
                INSERT INTO alias_domain (alias_domain, target_domain, active)
                VALUES (%s, %s, %s)
                """,
                (alias_domain, target_domain, payload["active"]),
            )
        except psycopg.errors.UniqueViolation:
            raise conflict(f"alias domain '{alias_domain}' already exists") from None
        conn.commit()
    return get_domain_alias(principal, alias_domain)


def update_domain_alias(
    principal: Principal, alias_domain: str, payload: dict
) -> dict:
    current = get_domain_alias(principal, alias_domain)
    fields = {key: value for key, value in payload.items() if value is not None}
    if "target_domain" in fields:
        _ensure_domain_alias_pair(principal, alias_domain, fields["target_domain"])
    if fields:
        assignments = ", ".join(f"{key} = %s" for key in fields)
        with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
            cur.execute(
                f"UPDATE alias_domain SET {assignments}, modified = now() "
                "WHERE alias_domain = %s",
                [*fields.values(), alias_domain],
            )
            if cur.rowcount == 0:
                raise not_found("domain alias", alias_domain)
            conn.commit()
    return get_domain_alias(principal, current["alias_domain"])


def delete_domain_alias(principal: Principal, alias_domain: str) -> None:
    get_domain_alias(principal, alias_domain)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM alias_domain WHERE alias_domain = %s", (alias_domain,))
        if cur.rowcount == 0:
            raise not_found("domain alias", alias_domain)
        conn.commit()

# --------------------------------------------------------------------- mailboxes
_MAILBOX_COLUMNS = (
    "username, password, name, maildir, quota, active, domain, local_part, "
    "created, modified"
)


def list_mailboxes(
    principal: Principal,
    domain: str | None,
    q: str | None,
    active: bool | None,
    limit: int,
    cursor: str | None,
) -> dict:
    conds, params = ["TRUE"], []
    tenant, tenant_params = _tenant_clause(principal)
    if tenant:
        conds.append(tenant.removeprefix(" AND "))
        params.extend(tenant_params)
    if domain:
        ensure_domain_allowed(principal, domain)
        conds.append("domain = %s")
        params.append(domain)
    if q:
        conds.append("(username ILIKE %s OR name ILIKE %s)")
        params.extend([f"%{q}%", f"%{q}%"])
    if active is not None:
        conds.append("active = %s")
        params.append(active)
    if cursor:
        conds.append("username > %s")
        params.append(decode_cursor(cursor))

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        f"SELECT {_MAILBOX_COLUMNS} FROM mailbox "
        f"WHERE {' AND '.join(conds)} ORDER BY username LIMIT %s"
    )
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = [_mailbox_out(row) for row in cur.fetchall()]
    return page(rows, "username", limit)


def get_mailbox(principal: Principal, username: str) -> dict:
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT {_MAILBOX_COLUMNS} FROM mailbox WHERE username = %s", (username,))
        row = cur.fetchone()
    if row is None:
        raise not_found("mailbox", username)
    ensure_domain_allowed(principal, row["domain"])
    return _mailbox_out(row)


def create_mailbox(principal: Principal, payload: dict) -> dict:
    username = payload["username"]
    local_part, _, domain = username.rpartition("@")
    ensure_domain_allowed(principal, domain)
    # `password_hash` lets callers (e.g. bootstrap CSV import) store a
    # pre-hashed password verbatim instead of hashing plaintext. When present
    # and non-empty it wins over `password`.
    password_hash = payload.get("password_hash") or ""
    hashed = password_hash or hash_password(payload["password"])
    # PostfixAdmin's maildir layout: '<domain>/<local_part>/' (trailing slash).
    maildir = f"{domain}/{local_part}/"

    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        try:
            cur.execute(
                """
                INSERT INTO mailbox
                       (username, password, name, maildir, quota, domain,
                        local_part, active)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    username,
                    hashed,
                    payload["name"],
                    maildir,
                    payload["quota_bytes"],
                    domain,
                    local_part,
                    payload["active"],
                ),
            )
        except psycopg.errors.UniqueViolation:
            raise conflict(f"mailbox '{username}' already exists") from None
        except psycopg.errors.ForeignKeyViolation:
            raise not_found("domain", domain) from None
        _mirror_admin_password(cur, username, hashed)
        recount_domain(cur, domain)
        conn.commit()
    return get_mailbox(principal, username)


def update_mailbox(principal: Principal, username: str, payload: dict) -> dict:
    current = get_mailbox(principal, username)
    fields: dict = {}
    if payload.get("name") is not None:
        fields["name"] = payload["name"]
    if payload.get("quota_bytes") is not None:
        fields["quota"] = payload["quota_bytes"]
    if payload.get("active") is not None:
        fields["active"] = payload["active"]

    hashed = None
    if payload.get("password") is not None:
        hashed = hash_password(payload["password"])
        fields["password"] = hashed

    if fields:
        assignments = ", ".join(f"{key} = %s" for key in fields)
        with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
            cur.execute(
                f"UPDATE mailbox SET {assignments}, modified = now() "
                "WHERE username = %s",
                [*fields.values(), username],
            )
            if hashed:
                # Keep the MailD convention: an admin with the same address
                # verifies the same password.
                _mirror_admin_password(cur, username, hashed)
            conn.commit()

    if payload.get("active") is False:
        revoke_user_sessions(username)
    return get_mailbox(principal, current["username"])


def delete_mailbox(principal: Principal, username: str) -> None:
    get_mailbox(principal, username)  # tenant + existence check
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "DELETE FROM mailbox WHERE username = %s RETURNING domain", (username,)
        )
        row = cur.fetchone()
        if row is None:
            raise not_found("mailbox", username)
        cur.execute("DELETE FROM quota  WHERE username = %s", (username,))
        cur.execute("DELETE FROM quota2 WHERE username = %s", (username,))
        recount_domain(cur, row["domain"])
        conn.commit()
    # Deleting an account must cut its access immediately; the maildir stays on
    # disk (PostfixAdmin default), so recreating the address keeps its mail.
    revoke_user_sessions(username)

# ----------------------------------------------------------------------- aliases
_ALIAS_COLUMNS = "address, goto, domain, active, created, modified"


def list_aliases(
    principal: Principal,
    domain: str | None,
    goto: str | None,
    q: str | None,
    limit: int,
    cursor: str | None,
) -> dict:
    conds, params = ["TRUE"], []
    tenant, tenant_params = _tenant_clause(principal)
    if tenant:
        conds.append(tenant.removeprefix(" AND "))
        params.extend(tenant_params)
    if domain:
        ensure_domain_allowed(principal, domain)
        conds.append("domain = %s")
        params.append(domain)
    if goto:
        # The user editor's alias tags: aliases forwarding to this mailbox.
        conds.append("(',' || replace(goto, ', ', ',') || ',') LIKE %s")
        params.append(f"%,{goto},%")
    if q:
        conds.append("(address ILIKE %s OR goto ILIKE %s)")
        params.extend([f"%{q}%", f"%{q}%"])
    if cursor:
        conds.append("address > %s")
        params.append(decode_cursor(cursor))

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        f"SELECT {_ALIAS_COLUMNS} FROM alias "
        f"WHERE {' AND '.join(conds)} ORDER BY address LIMIT %s"
    )
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = [_alias_out(row) for row in cur.fetchall()]
    return page(rows, "address", limit)


def get_alias(principal: Principal, address: str) -> dict:
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT {_ALIAS_COLUMNS} FROM alias WHERE address = %s", (address,))
        row = cur.fetchone()
    if row is None:
        raise not_found("alias", address)
    ensure_domain_allowed(principal, row["domain"])
    return _alias_out(row)


def create_alias(principal: Principal, payload: dict) -> dict:
    address = payload["address"]
    _, _, domain = address.rpartition("@")
    ensure_domain_allowed(principal, domain)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        try:
            cur.execute(
                "INSERT INTO alias (address, goto, domain, active) VALUES (%s, %s, %s, %s)",
                (address, payload["goto"], domain, payload["active"]),
            )
        except psycopg.errors.UniqueViolation:
            raise conflict(f"alias '{address}' already exists") from None
        except psycopg.errors.ForeignKeyViolation:
            raise not_found("domain", domain) from None
        recount_domain(cur, domain)
        conn.commit()
    return get_alias(principal, address)


def update_alias(principal: Principal, address: str, payload: dict) -> dict:
    get_alias(principal, address)  # tenant + existence check
    fields = {key: value for key, value in payload.items() if value is not None}
    if fields:
        assignments = ", ".join(f"{key} = %s" for key in fields)
        with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
            cur.execute(
                f"UPDATE alias SET {assignments}, modified = now() WHERE address = %s",
                [*fields.values(), address],
            )
            conn.commit()
    return get_alias(principal, address)


def delete_alias(principal: Principal, address: str) -> None:
    row = get_alias(principal, address)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM alias WHERE address = %s", (address,))
        recount_domain(cur, row["domain"])
        conn.commit()

# ------------------------------------------------------------------------ admins
_ADMIN_SELECT = """
    SELECT a.username, a.superadmin, a.active, a.created, a.modified,
           COALESCE(json_agg(da.domain ORDER BY da.domain)
                    FILTER (WHERE da.domain IS NOT NULL), '[]') AS domains
      FROM admin a
      LEFT JOIN domain_admins da ON da.username = a.username AND da.active
"""


def _admin_out(row: dict) -> dict:
    return {
        "username": row["username"],
        "superadmin": row["superadmin"],
        "active": row["active"],
        "domains": list(row["domains"] or []),
        "created": row["created"],
        "modified": row["modified"],
    }


def list_admins(limit: int, cursor: str | None) -> dict:
    limit = clamp_limit(limit)
    after = decode_cursor(cursor) if cursor else None
    sql = (
        _ADMIN_SELECT
        + " WHERE (%s::text IS NULL OR a.username > %s::text)"
        + " GROUP BY a.username, a.superadmin, a.active, a.created, a.modified"
        + " ORDER BY a.username LIMIT %s"
    )
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, (after, after, limit + 1))
        rows = [_admin_out(row) for row in cur.fetchall()]
    return page(rows, "username", limit)


def get_admin(username: str) -> dict:
    sql = (
        _ADMIN_SELECT
        + " WHERE a.username = %s"
        + " GROUP BY a.username, a.superadmin, a.active, a.created, a.modified"
    )
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, (username,))
        row = cur.fetchone()
    if row is None:
        raise not_found("admin", username)
    return _admin_out(row)


def _check_domains_exist(cur, domains: list[str]) -> None:
    if not domains:
        return
    cur.execute(
        "SELECT count(DISTINCT domain) AS n FROM domain WHERE domain = ANY(%s)", (domains,)
    )
    if cur.fetchone()["n"] != len(set(domains)):
        raise not_found("domain", ", ".join(sorted(set(domains))))


def _replace_admin_domains(cur, username: str, domains: list[str], superadmin: bool) -> None:
    cur.execute("DELETE FROM domain_admins WHERE username = %s", (username,))
    if superadmin:
        return
    _check_domains_exist(cur, domains)
    for domain in dict.fromkeys(domains):
        cur.execute(
            "INSERT INTO domain_admins (username, domain, active) VALUES (%s, %s, true)",
            (username, domain),
        )


def _active_superadmins(cur, excluding: str | None = None) -> int:
    cur.execute(
        "SELECT count(*) AS n FROM admin WHERE superadmin AND active "
        "AND (%s::text IS NULL OR username <> %s::text)",
        (excluding, excluding),
    )
    return cur.fetchone()["n"]

def create_admin(principal: Principal, payload: dict) -> dict:
    hashed = hash_password(payload["password"])
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_xact_lock(%s)", (_ADMIN_LOCK,))
        try:
            cur.execute(
                "INSERT INTO admin (username, password, superadmin, active) "
                "VALUES (%s, %s, %s, %s)",
                (
                    payload["username"],
                    hashed,
                    payload["superadmin"],
                    payload["active"],
                ),
            )
        except psycopg.errors.UniqueViolation:
            raise conflict(f"admin '{payload['username']}' already exists") from None
        _replace_admin_domains(
            cur, payload["username"], payload["domains"], payload["superadmin"]
        )
        _mirror_mailbox_password(cur, payload["username"], hashed)
        conn.commit()
    return get_admin(payload["username"])


def update_admin(principal: Principal, username: str, payload: dict) -> dict:
    current = get_admin(username)
    new_superadmin = (
        payload["superadmin"]
        if payload.get("superadmin") is not None
        else current["superadmin"]
    )
    new_active = payload["active"] if payload.get("active") is not None else current["active"]

    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_xact_lock(%s)", (_ADMIN_LOCK,))
        # Never lock the deployment out: demoting/deactivating the last active
        # superadmin is refused.
        if (
            current["superadmin"]
            and current["active"]
            and (not new_superadmin or not new_active)
            and _active_superadmins(cur, excluding=username) == 0
        ):
            raise conflict("cannot demote or disable the last active superadmin")

        fields = {}
        if payload.get("superadmin") is not None:
            fields["superadmin"] = payload["superadmin"]
        if payload.get("active") is not None:
            fields["active"] = payload["active"]
        hashed = None
        if payload.get("password") is not None:
            hashed = hash_password(payload["password"])
            fields["password"] = hashed
        if fields:
            assignments = ", ".join(f"{key} = %s" for key in fields)
            cur.execute(
                f"UPDATE admin SET {assignments}, modified = now() WHERE username = %s",
                [*fields.values(), username],
            )
            if hashed:
                _mirror_mailbox_password(cur, username, hashed)
        if payload.get("domains") is not None or payload.get("superadmin") is not None:
            domains = (
                current["domains"] if payload.get("domains") is None else payload["domains"]
            )
            _replace_admin_domains(cur, username, domains, new_superadmin)
        conn.commit()

    if new_active is False:
        revoke_user_sessions(username)
    return get_admin(username)


def delete_admin(principal: Principal, username: str) -> None:
    current = get_admin(username)
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_xact_lock(%s)", (_ADMIN_LOCK,))
        if (
            current["superadmin"]
            and current["active"]
            and _active_superadmins(cur, excluding=username) == 0
        ):
            raise conflict("cannot delete the last active superadmin")
        cur.execute("DELETE FROM domain_admins WHERE username = %s", (username,))
        cur.execute("DELETE FROM admin WHERE username = %s", (username,))
        conn.commit()
    revoke_user_sessions(username)

# ------------------------------------------------------------------------ search
def search(principal: Principal, query: str, limit: int) -> dict:
    """Mixed user/alias/domain results, tenant-scoped and capped per type."""
    like = f"%{query}%"
    tenant, tenant_params = _tenant_clause(principal)
    results: list[dict] = []

    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT username, name, domain, quota, active FROM mailbox "
            f"WHERE (username ILIKE %s OR name ILIKE %s){tenant} "
            "ORDER BY username LIMIT %s",
            [like, like, *tenant_params, limit],
        )
        for row in cur.fetchall():
            results.append(
                {
                    "type": "user",
                    "id": row["username"],
                    "display_name": row["name"] or row["username"],
                    "domain": row["domain"],
                    "details": {"quota_bytes": row["quota"], "active": row["active"]},
                }
            )

        cur.execute(
            "SELECT address, goto, domain, active FROM alias "
            f"WHERE (address ILIKE %s OR goto ILIKE %s){tenant} "
            "ORDER BY address LIMIT %s",
            [like, like, *tenant_params, limit],
        )
        for row in cur.fetchall():
            results.append(
                {
                    "type": "alias",
                    "id": row["address"],
                    "display_name": row["address"],
                    "domain": row["domain"],
                    "details": {"goto": row["goto"], "active": row["active"]},
                }
            )

        cur.execute(
            "SELECT domain, description, active FROM domain "
            f"WHERE (domain ILIKE %s OR description ILIKE %s){tenant} "
            "ORDER BY domain LIMIT %s",
            [like, like, *tenant_params, limit],
        )
        for row in cur.fetchall():
            results.append(
                {
                    "type": "domain",
                    "id": row["domain"],
                    "display_name": row["domain"],
                    "domain": row["domain"],
                    "details": {"active": row["active"], "description": row["description"]},
                }
            )

    return {"query": query, "results": results}





