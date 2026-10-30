"""Read-only access to the PostfixAdmin catalogue (proposal §9.2, D8).

The MCP role can SELECT domain(domain, active), mailbox(username, domain, local_part, name,
active) and maild_provision, and EXECUTE maild_mcp_ensure_service_mailbox(). Nothing else —
never select `*` or `password` here, the grants refuse it.
"""

from django.db import connections


def _cursor():
    return connections["catalogue"].cursor()


def provisioned() -> bool:
    with _cursor() as cur:
        cur.execute("SELECT 1 FROM maild_provision WHERE id = 1")
        return cur.fetchone() is not None


def domain_state(domain: str) -> bool | None:
    """True/False for an active/inactive catalogue domain, None when it does not exist."""
    with _cursor() as cur:
        cur.execute("SELECT active FROM domain WHERE domain = %s", [domain])
        row = cur.fetchone()
    return None if row is None else bool(row[0])


def mailbox_state(username: str) -> bool | None:
    """True/False for an active/inactive mailbox, None when it does not exist."""
    with _cursor() as cur:
        cur.execute("SELECT active FROM mailbox WHERE username = %s", [username])
        row = cur.fetchone()
    return None if row is None else bool(row[0])


def ensure_service_mailbox(address: str, dovecot_hash: str, name: str) -> bool:
    """Create the service mailbox if missing (SECURITY DEFINER, migration 003).

    Returns True when it was created. Never modifies an existing mailbox.
    """
    conn = connections["catalogue"]
    with conn.cursor() as cur:
        cur.execute("SELECT maild_mcp_ensure_service_mailbox(%s, %s, %s)", [address, dovecot_hash, name])
        created = bool(cur.fetchone()[0])
    if not conn.get_autocommit():
        conn.commit()
    return created


def domains() -> list[tuple[str, bool]]:
    """Every catalogue domain with its active flag (alias domains are a separate table)."""
    with _cursor() as cur:
        cur.execute("SELECT domain, active FROM domain ORDER BY domain")
        return [(row[0], bool(row[1])) for row in cur.fetchall()]
