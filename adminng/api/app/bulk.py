"""Bulk account bootstrap from a CSV file ("Carga inicial").

The admin uploads a comma-separated file with one account per row; the API
decodes it, validates every row on its own and creates the mailboxes that
pass. The report is per row (success/fail + reason), because a bulk import
must never fail as a whole: one bad row must not block the good ones.

CSV contract (the headers are mandatory, in this exact order):

    fullname,emailaddress,password,quota
    Pavel Milanes Costa,pavel@maild.cu,Str0ng!Pass,512MB

  * fullname      - the display name of the account (free text);
  * emailaddress  - the FULL address, domain included (pavel@maild.cu);
  * password      - at least 8 chars with an upper case letter, a lower case
                    letter, a digit and a symbol;
  * quota         - a bare number means MB; "512MB"/"512 MB", "1G"/"1 G" and
                    "1T" are accepted too. Empty (or 0) means unlimited.

The target domain must exist on the server *before* the import, and the
uploading admin must be allowed to manage it (a custom admin only manages the
domains of its own `domain_admins` rows).

The file travels base64-encoded (the PWA reads it with FileReader and sends
the base64 payload) so that passwords with commas, quotes or any other
special character survive the transport untouched.

When some rows fail, the API also returns a CSV with ONLY the failed rows
(original values + an extra `problem` column with the reason), so the admin
can fix them and upload the file again.
"""

import base64
import binascii
import csv
import io
import re

from . import catalogue, settings
from .auth import Principal
from .db import connect
from .errors import ApiError, validation
from .passwords import MD5CRYPT_SUPPORT_ENDS, _today

# The header row, in order. Anything else is rejected as a whole file.
CSV_HEADERS = ("fullname", "emailaddress", "password", "quota")
# Optional trailing columns (any order among them, after the required four).
PROBLEM_COLUMN = "problem"
PASSWORDHASH_COLUMN = "passwordhash"
# Dovecot requires the {SCHEME} prefix for anything that is not the default
# scheme; argon2id bodies we receive may or may not carry it.
ARGON_PREFIX = "{ARGON2ID}"

# Quota suffixes -> bytes. A bare number is megabytes.
_QUOTA_UNITS = {
    "MB": 1024**2,
    "M": 1024**2,
    "GB": 1024**3,
    "G": 1024**3,
    "TB": 1024**4,
    "T": 1024**4,
}
_QUOTA_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*([A-Za-z]*)\s*$")

# Mailbox rows are bounded: a bootstrap file is a hand-made document, not a
# data feed. The limit protects the API from a runaway upload.
MAX_ROWS = 5000

# Per-row failure codes (the PWA maps them to a human message).
ERR_BAD_CSV = "BAD_CSV"
ERR_BAD_HEADERS = "BAD_HEADERS"
ERR_EMPTY = "EMPTY"
ERR_MISSING_FIELD = "MISSING_FIELD"
ERR_INVALID_EMAIL = "INVALID_EMAIL"
ERR_WRONG_DOMAIN = "WRONG_DOMAIN"
ERR_WEAK_PASSWORD = "WEAK_PASSWORD"
ERR_INVALID_QUOTA = "INVALID_QUOTA"
ERR_EXISTS = "USER_EXIST_ALREADY"
ERR_FAILED = "FAILED"
ERR_INVALID_PASSWORD_HASH = "INVALID_PASSWORD_HASH"
ERR_MALFORMED_PASSWORD_HASH = "MALFORMED_PASSWORD_HASH"
ERR_WEAK_PASSWORD_ALGORITHM = "WEAK_PASSWORD_ALGORITHM"



def decode_payload(csv_base64: str) -> bytes:
    """Decode the base64 CSV payload; raises a 422 on a broken encoding."""
    try:
        raw = base64.b64decode(csv_base64, validate=True)
    except (binascii.Error, ValueError):
        raise validation("the uploaded file is not valid base64") from None
    if not raw.strip():
        raise validation("the uploaded file is empty")
    return raw


def parse_quota(value: str) -> int:
    """Parse a quota cell into bytes (0 = unlimited).

    A bare number is megabytes ("512" -> 512 MB); "512MB", "512 MB", "1G",
    "1 G" and "1T" are accepted as well. An empty cell (or 0) means
    unlimited.
    """
    text = (value or "").strip()
    if not text:
        return 0
    match = _QUOTA_RE.match(text)
    if not match:
        raise ValueError(f"invalid quota '{value}'")
    number, suffix = match.groups()
    factor = _QUOTA_UNITS.get(suffix.upper()) if suffix else _QUOTA_UNITS["MB"]
    if factor is None:
        raise ValueError(f"invalid quota unit in '{value}'")
    amount = float(number)
    if amount < 0:
        raise ValueError(f"invalid quota '{value}'")
    return int(round(amount * factor))


def password_problem(password: str) -> str | None:
    """Return the reason the password is rejected, or None when it is fine.

    The rule (stated in the UI): at least 8 characters, an upper case letter,
    a lower case letter, a digit and a symbol.
    """
    if not password:
        return "the password is empty"
    if len(password) < 8:
        return "the password needs at least 8 characters"
    if not re.search(r"[A-Z]", password):
        return "the password needs an upper case letter"
    if not re.search(r"[a-z]", password):
        return "the password needs a lower case letter"
    if not re.search(r"[0-9]", password):
        return "the password needs a digit"
    if not re.search(r"[^A-Za-z0-9]", password):
        return "the password needs a symbol"
    return None


def _normalize_password_hash(raw: str) -> str:
    """Validate and normalize a pre-hashed password for Dovecot storage.

    Accepted forms (fail fast otherwise -> MALFORMED_PASSWORD_HASH):

      * ``{ARGON2ID}$argon2id$v=19$...``  — already Dovecot-ready, stored verbatim.
      * ``$argon2id$v=19$...``            — bare body, the prefix is added.
      * ``$1$<8-salt>$<22-checksum>``     — legacy md5crypt; accepted only while
        weak-scheme support lives (before 2027-02-01).

    Raises ``ValueError`` carrying one of MALFORMED_PASSWORD_HASH /
    WEAK_PASSWORD_ALGORITHM on rejection.
    """
    value = (raw or "").strip()
    if not value:
        raise ValueError("the passwordhash cell is empty")

    if value.startswith(ARGON_PREFIX):
        body = value[len(ARGON_PREFIX):]
        if not body.startswith("$argon2id$"):
            raise ValueError("invalid argon2id hash body")
        return value

    if value.startswith("$argon2id$"):
        # Normalize a bare body into Dovecot's required prefixed form.
        return ARGON_PREFIX + value

    # Legacy md5crypt: $1$<8-char salt>$<22-char checksum>
    parts = value.split("$")
    if len(parts) == 4 and parts[1] == "1" and len(parts[2]) == 8:
        if _today() >= MD5CRYPT_SUPPORT_ENDS:
            raise ValueError(
                "md5crypt hashes are no longer accepted "
                f"(weak-scheme support ended on {MD5CRYPT_SUPPORT_ENDS.isoformat()})"
            )
        return value

    raise ValueError("unsupported hash format")


def _rows_from_csv(raw: bytes) -> list[list[str]]:
    """Parse the CSV body into rows; the header row is checked separately."""
    text = raw.decode("utf-8-sig", errors="replace")
    if not text.strip():
        raise validation("the uploaded file is empty")
    try:
        rows = list(csv.reader(io.StringIO(text)))
    except csv.Error as exc:
        raise validation(f"the uploaded file is not a valid CSV: {exc}") from None
    return rows


def _check_headers(rows: list[list[str]]) -> dict[str, int]:
    """Validate the header row and return column-name -> index mapping.

    The first four columns must be exactly ``fullname,emailaddress,password,quota``
    in that order. Trailing columns may only be ``passwordhash`` and/or
    ``problem`` (in any order); any other trailing column rejects the whole file
    as a whole-file error (HTTP 422).
    """
    header = [cell.strip().lower() for cell in rows[0]]
    expected = list(CSV_HEADERS)
    if header[: len(expected)] != expected:
        raise validation(
            "the CSV header must be exactly: " + ",".join(CSV_HEADERS),
            expected=expected,
            received=header,
        )
    trailing = header[len(expected):]
    for col in trailing:
        if col not in (PROBLEM_COLUMN, PASSWORDHASH_COLUMN):
            raise validation(
                "unexpected CSV column: " + col,
                expected=list(CSV_HEADERS) + [PROBLEM_COLUMN, PASSWORDHASH_COLUMN],
                received=header,
            )
    return {col: idx for idx, col in enumerate(header)}


def _existing_domains() -> set[str]:
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT domain FROM domain")
        return {row["domain"].lower() for row in cur.fetchall()}


def _existing_mailboxes() -> set[str]:
    """The usernames already in the catalogue (lowercased)."""
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT username FROM mailbox")
        return {row["username"].lower() for row in cur.fetchall()}


def import_users(principal: Principal, csv_base64: str) -> dict:
    """Create the accounts of a CSV bootstrap file and report each row.

    Returns ``{"total", "created", "failed", "results": [...]}`` where every
    result carries the row number, the address and the outcome. A failed row
    never fails the import: it is reported and the import goes on.
    """
    raw = decode_payload(csv_base64)
    rows = _rows_from_csv(raw)
    col_index = _check_headers(rows)

    body = rows[1:]
    if len(body) > MAX_ROWS:
        raise validation(f"the file has too many rows (the limit is {MAX_ROWS})")

    known_domains = _existing_domains()
    known_mailboxes = _existing_mailboxes()
    results: list[dict] = []

    for index, row in enumerate(body, start=2):  # row 1 is the header
        # A completely empty row is ignored (a trailing newline must not
        # produce a phantom failure).
        if not any((cell or "").strip() for cell in row):
            continue
        results.append(
            _import_row(principal, index, row, col_index, known_domains, known_mailboxes)
        )

    created = sum(1 for item in results if item["ok"])
    failed = [item for item in results if not item["ok"]]
    report = {
        "total": len(results),
        "created": created,
        "failed": len(failed),
        "results": results,
    }
    if failed:
        # A CSV with only the failed rows (+ the `problem` column), so the
        # admin can fix them and upload the file again.
        header_cols = [name for name, _ in sorted(col_index.items(), key=lambda kv: kv[1])]
        report["failed_csv_base64"] = _failed_rows_csv(failed, header_cols)
    return report


def _import_row(
    principal: Principal,
    index: int,
    row: list[str],
    col_index: dict[str, int],
    known_domains: set[str],
    known_mailboxes: set[str],
) -> dict:
    """Process one CSV row: validate it and create the mailbox.

    When ``passwordhash`` is present (and ``password`` is absent) the hash is
    validated and stored verbatim — useful for migrating users from another
    system's dumped database without knowing their plaintext passwords.
    """
    cells = [(cell or "").strip() for cell in row]
    pad = max(col_index.values()) + 1
    cells += [""] * (pad - len(cells))

    fullname = cells[col_index["fullname"]]
    address = cells[col_index["emailaddress"]]
    password = cells[col_index["password"]]
    quota = cells[col_index["quota"]]
    passwordhash = cells[col_index[PASSWORDHASH_COLUMN]] if PASSWORDHASH_COLUMN in col_index else ""

    def fail(code: str, reason: str) -> dict:
        return {
            "row": index,
            "fullname": fullname,
            "email": address,
            "ok": False,
            "code": code,
            "reason": reason,
            "cells": cells,
        }

    if not address:
        return fail(ERR_MISSING_FIELD, "the email address is missing")

    # Password policy: either a plaintext password (hashed server-side) or a
    # pre-hashed passwordhash. When both are present, `password` wins.
    if not password and not passwordhash:
        return fail(ERR_MISSING_FIELD, "password or passwordhash is required")

    local, domain = _split_address(address)
    if not local or not domain or "@" not in address:
        return fail(
            ERR_INVALID_EMAIL,
            "the email address must be a full address, domain included",
        )

    # The domain must exist on the server AND be manageable by this admin.
    if domain not in known_domains or not principal.allows(domain):
        return fail(
            ERR_WRONG_DOMAIN,
            f"the domain '{domain}' does not exist on this server",
        )

    # An existing account is never touched: the row is skipped and reported.
    if f"{local}@{domain}".lower() in known_mailboxes:
        return fail(
            ERR_EXISTS,
            f"the account '{local}@{domain}' already exists",
        )

    # A pre-hashed password bypasses the plaintext password policy but must be
    # a valid hash in a format Dovecot understands.
    password_hash: str | None = None
    if passwordhash and not password:
        try:
            password_hash = _normalize_password_hash(passwordhash)
        except ValueError as exc:
            code = (
                ERR_WEAK_PASSWORD_ALGORITHM
                if "md5crypt" in str(exc)
                else ERR_MALFORMED_PASSWORD_HASH
            )
            return fail(code, str(exc))
    elif password:
        problem = password_problem(password)
        if problem:
            return fail(ERR_WEAK_PASSWORD, problem)

    try:
        quota_bytes = parse_quota(quota)
    except ValueError as exc:
        return fail(ERR_INVALID_QUOTA, str(exc))

    payload = {
        "username": f"{local}@{domain}",
        "password": password,
        "password_hash": password_hash,
        "name": fullname or local,
        "quota_bytes": quota_bytes,
        "active": True,
    }
    try:
        created = catalogue.create_mailbox(principal, payload)
    except ApiError as exc:
        if exc.code == "CONFLICT":
            return fail(ERR_EXISTS, f"the account '{address}' already exists")
        if exc.code == "FORBIDDEN_TENANT":
            return fail(
                ERR_WRONG_DOMAIN,
                f"the domain '{domain}' does not exist on this server",
            )
        return fail(ERR_FAILED, exc.message)
    except Exception as exc:  # pragma: no cover - defensive: one row must not kill the import
        return fail(ERR_FAILED, str(exc))

    return {
        "row": index,
        "fullname": created["name"],
        "email": created["username"],
        "ok": True,
        "code": "OK",
        "reason": "",
        "quota_bytes": created["quota_bytes"],
        "cells": cells,
    }


def _failed_rows_csv(failed: list[dict], header_cols: list[str]) -> str:
    """Build the CSV with only the failed rows (+ the `problem` column).

    The original values are kept verbatim so the admin can fix the row and
    upload the file again; the `problem` column carries the reason. The
    result is base64-encoded (the PWA turns it into a download).

    ``header_cols`` are the original CSV column names (in order); the output
    header repeats them and appends ``problem`` when it is not already
    present.
    """
    out_cols = list(header_cols)
    if PROBLEM_COLUMN not in out_cols:
        out_cols.append(PROBLEM_COLUMN)
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(out_cols)
    for item in failed:
        cells = list(item.get("cells") or [])
        cells += [""] * (len(out_cols) - 1 - len(cells))
        writer.writerow([*cells[: len(out_cols) - 1], item.get("reason") or item.get("code") or ""])
    return base64.b64encode(buffer.getvalue().encode("utf-8")).decode("ascii")


def _split_address(address: str) -> tuple[str, str]:
    local, _, domain = address.strip().rpartition("@")
    return local, domain.lower()
