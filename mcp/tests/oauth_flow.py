#!/usr/bin/env python3
"""Test helper (test.sh section O): a scripted OAuth 2.1 public client run inside the mcp
container, playing both the client and the user's browser, end to end:

  discovery (401 → protected-resource metadata → AS metadata)
  → client: DCR registration, or CIMD (serves its own metadata document on mcp:8099, which the
    dev-only MCP_CIMD_DEV_ALLOW admits)
  → /oauth/authorize (PKCE S256) → consent through the web API as the user (ALTCHA solved)
  → code exchange → MCP call with the access token (official SDK client)
  → refresh rotation → reuse of the old refresh token revokes the family
  → a second grant revoked through /oauth/revoke.

    oauth_flow.py dcr|cimd <user> <password>   → one JSON object with every step's outcome
"""

import asyncio
import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8080"
REDIRECT = "http://127.0.0.1:9/callback"
CIMD_URL = "http://mcp:8099/client.json"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def req(method, path, data=None, headers=None, form=False):
    body = None
    headers = dict(headers or {})
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path if path.startswith("/") else path, data=body, method=method, headers=headers)
    try:
        resp = opener.open(r, timeout=30)
        status, hdrs, raw = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as exc:
        status, hdrs, raw = exc.code, exc.headers, exc.read()
    try:
        payload = json.loads(raw) if raw else None
    except ValueError:
        payload = raw.decode(errors="replace")[:300]
    return status, hdrs, payload


def pkce():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def altcha():
    return subprocess.check_output([sys.executable, "tests/altcha_solve.py"], text=True).strip()


async def mcp_list(token):
    from mcp import ClientSession
    from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

    async with create_mcp_http_client(headers={"Authorization": f"Bearer {token}"}) as http:
        async with streamable_http_client(f"{BASE}/api/v1/mcp", http_client=http) as streams:
            async with ClientSession(streams[0], streams[1]) as session:
                await session.initialize()
                res = await session.call_tool("list_accounts", {})
                return res.structured_content


def grant(client_id, user, password, out, label):
    verifier, challenge = pkce()
    state = secrets.token_urlsafe(12)
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT,
                                "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
                                "scope": "mail.read mail.send", "resource": out["resource"]})
    st, hdrs, _ = req("GET", f"/oauth/authorize?{q}")
    loc = hdrs.get("Location", "") if hdrs else ""
    out[f"{label}_authorize"] = st
    request_id = loc.split("#", 1)[1] if loc.startswith("/consent#") else ""
    st, _, body = req("POST", "/webapi/user/login", {"email": user, "password": password, "altcha": altcha()})
    at = body.get("access_token", "") if isinstance(body, dict) else ""
    auth = {"Authorization": f"Bearer {at}"}
    st, _, info = req("POST", "/webapi/user/oauth/request", {"request_id": request_id}, auth)
    out[f"{label}_consent_info"] = info if isinstance(info, dict) else {"error": info}
    # the user narrows the scopes to mail.read only
    st, _, dec = req("POST", "/webapi/user/oauth/decision", {"request_id": request_id, "approve": True,
                                                             "scopes": ["mail.read"], "addresses": [user]}, auth)
    redirect = dec.get("redirect", "") if isinstance(dec, dict) else ""
    params = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(redirect).query))
    out[f"{label}_redirect_ok"] = redirect.startswith(REDIRECT) and params.get("state") == state
    out[f"{label}_iss"] = params.get("iss")
    code = params.get("code", "")
    # a wrong verifier must fail and burn nothing but this attempt's code
    st, _, tok = req("POST", "/oauth/token", {"grant_type": "authorization_code", "code": code, "client_id": client_id,
                                              "redirect_uri": REDIRECT, "code_verifier": verifier,
                                              "resource": out["resource"]}, form=True)
    out[f"{label}_token_status"] = st
    out[f"{label}_scope"] = tok.get("scope") if isinstance(tok, dict) else None
    st2, _, again = req("POST", "/oauth/token", {"grant_type": "authorization_code", "code": code, "client_id": client_id,
                                                 "redirect_uri": REDIRECT, "code_verifier": verifier}, form=True)
    out[f"{label}_code_reuse"] = again.get("error") if isinstance(again, dict) else st2
    return tok if isinstance(tok, dict) else {}, at


def main():
    mode, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
    out = {"mode": mode}
    # discovery
    st, hdrs, _ = req("POST", "/api/v1/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                      {"Accept": "application/json, text/event-stream"})
    www = hdrs.get("WWW-Authenticate", "") if hdrs else ""
    prm_url = www.split('resource_metadata="', 1)[1].split('"', 1)[0] if 'resource_metadata="' in www else ""
    out["discovery_401"] = st
    prm_path = urllib.parse.urlsplit(prm_url).path
    _, _, prm = req("GET", prm_path)
    out["resource"] = prm["resource"]
    as_path = urllib.parse.urlsplit(prm["authorization_servers"][0]).path.rstrip("/") + "/.well-known/oauth-authorization-server"
    _, _, meta = req("GET", as_path)
    out["as_cimd"] = meta.get("client_id_metadata_document_supported")
    out["as_pkce"] = meta.get("code_challenge_methods_supported")

    server = None
    if mode == "dcr":
        st, _, reg = req("POST", "/oauth/register", {"client_name": "Scripted DCR client", "redirect_uris": [REDIRECT],
                                                    "token_endpoint_auth_method": "none",
                                                    "grant_types": ["authorization_code", "refresh_token"]})
        out["register"] = st
        client_id = reg.get("client_id", "")
        st, _, bad = req("POST", "/oauth/register", {"client_name": "x", "redirect_uris": ["http://evil.example/cb"]})
        out["register_bad_redirect"] = bad.get("error") if isinstance(bad, dict) else st
    else:
        d = tempfile.mkdtemp(dir="/tmp")
        with open(os.path.join(d, "client.json"), "w") as f:
            json.dump({"client_id": CIMD_URL, "client_name": "Scripted CIMD client", "redirect_uris": [REDIRECT],
                       "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"]}, f)
        server = subprocess.Popen([sys.executable, "-m", "http.server", "8099", "-d", d, "-b", "0.0.0.0"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        client_id = CIMD_URL
    try:
        tok, _at = grant(client_id, user, password, out, "g1")
        access, refresh = tok.get("access_token", ""), tok.get("refresh_token", "")
        try:
            sc = asyncio.run(mcp_list(access))
            out["mcp_call"] = sc.get("default_sender") if sc else None
        except Exception as exc:  # noqa: BLE001
            out["mcp_call"] = f"error: {exc}"[:200]
        # refresh rotation
        st, _, new = req("POST", "/oauth/token", {"grant_type": "refresh_token", "refresh_token": refresh,
                                                  "client_id": client_id}, form=True)
        out["refresh"] = st
        new_access = new.get("access_token", "") if isinstance(new, dict) else ""
        st, _, wide = req("POST", "/oauth/token", {"grant_type": "refresh_token", "refresh_token": new.get("refresh_token", ""),
                                                   "client_id": client_id, "scope": "mail.read mail.send"}, form=True)
        out["refresh_widen"] = wide.get("error") if isinstance(wide, dict) else st
        # reuse of the ROTATED refresh token → the whole family is revoked
        st, _, reuse = req("POST", "/oauth/token", {"grant_type": "refresh_token", "refresh_token": refresh,
                                                    "client_id": client_id}, form=True)
        out["refresh_reuse"] = reuse.get("error") if isinstance(reuse, dict) else st
        st, _, _ = req("POST", "/api/v1/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                       {"Authorization": f"Bearer {new_access}", "Accept": "application/json, text/event-stream"})
        out["after_reuse_access"] = st
        # second grant, revoked through RFC 7009
        tok2, _ = grant(client_id, user, password, out, "g2")
        st, _, _ = req("POST", "/oauth/revoke", {"token": tok2.get("refresh_token", "")}, form=True)
        out["revoke"] = st
        st, _, _ = req("POST", "/api/v1/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                       {"Authorization": f"Bearer {tok2.get('access_token', '')}", "Accept": "application/json, text/event-stream"})
        out["after_revoke_access"] = st
    finally:
        if server:
            server.terminate()
    print(json.dumps(out))


if __name__ == "__main__":
    main()
