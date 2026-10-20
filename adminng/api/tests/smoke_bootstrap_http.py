#!/usr/bin/env python3
"""HTTP smoke test for POST /api/v1/bootstrap (run inside the api container).

It logs in as the alice fixture (a domain admin of example.net, no TOTP),
approves the device through the admin CLI, and then imports a CSV through the
real HTTP endpoint. It is a manual/one-off probe, not part of the unit suite
(the unit tests live in tests/test_bootstrap.py).
"""

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

BASE = "http://127.0.0.1:8080/api/v1"
USER = "alice@example.net"
DOMAIN = "example.net"
DEVICE = str(uuid.uuid4())
SECRET = base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("=")


def fixture_password(user: str) -> str:
    """The fixture password: from FIXTURE_PASSWORD env, else test.creds."""
    from_env = os.environ.get("FIXTURE_PASSWORD")
    if from_env:
        return from_env
    creds = os.environ.get("TEST_CREDS", "/repo/test.creds")
    with open(creds, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.lower() == user.lower():
                return value
    raise SystemExit(f"{user} is not in {creds} (set FIXTURE_PASSWORD)")


def call(path, payload=None, token=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=data,
        method=method or ("POST" if data else "GET"),
        headers={
            "Content-Type": "application/json",
            "X-Device-ID": DEVICE,
            "X-Device-Secret": SECRET,
            **({"Authorization": f"Bearer {token}"} if token else {}),
        },
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.status, json.loads(response.read() or b"null")


def main() -> int:
    password = fixture_password(USER)

    def login_once():
        return call(
            "/auth/login-step1",
            {"username": USER, "password": password, "remember": False, "client_type": "web"},
        )

    # First sign-in: the device is unknown, so step1 answers 403 pending approval.
    try:
        status, body = login_once()
    except urllib.error.HTTPError as exc:
        body = json.loads(exc.read().decode() or "{}")
        if exc.code != 403 or body.get("detail") != "DEVICE_NOT_AUTHORIZED":
            print("unexpected login-step1:", exc.code, body, file=sys.stderr)
            return 1
        print("device pending approval:", body.get("device_id"))
        # Approve it through the documented CLI (the UI cannot self-authorize).
        subprocess.run(
            ["adminng.py", "--approve-device", DEVICE, "--user", USER],
            check=True,
            capture_output=True,
        )
        status, body = login_once()

    if body.get("session_state") != "AUTHENTICATED":
        print("unexpected session state:", body, file=sys.stderr)
        return 1

    token = body.get("access_token")
    if not token:
        print("no access token:", body, file=sys.stderr)
        return 1
    print("logged in as", USER)

    csv_text = (
        "fullname,emailaddress,password,quota\n"
        f"Smoke User,smoke@{DOMAIN},Str0ng!Pass,512\n"
        f"Weak User,weak@{DOMAIN},weak,512\n"
    )
    payload = {"csv_base64": base64.b64encode(csv_text.encode()).decode()}
    status, report = call("/bootstrap", payload, token=token)
    print("bootstrap:", status, json.dumps(report, indent=2)[:900])

    if report.get("failed_csv_base64"):
        decoded = base64.b64decode(report["failed_csv_base64"]).decode()
        print("--- failed rows CSV ---")
        print(decoded)

    # A whole-file error must be a 422.
    try:
        call("/bootstrap", {"csv_base64": "not base64 !!"}, token=token)
        print("ERROR: a broken payload did not fail", file=sys.stderr)
        return 1
    except urllib.error.HTTPError as exc:
        print("broken payload ->", exc.code, exc.read().decode()[:120])
    return 0


if __name__ == "__main__":
    sys.exit(main())
