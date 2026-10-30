#!/usr/bin/env python3
"""Test helper (test.sh, pwa-test): fetch an ALTCHA challenge from the local mcp and print the
solved payload the login form would submit. Runs inside the mcp container."""

import base64
import json
import sys
import urllib.request

import altcha

base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
with urllib.request.urlopen(f"{base}/webapi/altcha/challenge", timeout=10) as resp:
    ch = json.load(resp)
sol = altcha.solve_challenge_v1(ch["challenge"], ch["salt"], ch["algorithm"], ch["maxnumber"], 0)
if sol is None:
    sys.exit("could not solve the challenge")
print(base64.b64encode(json.dumps({"algorithm": ch["algorithm"], "challenge": ch["challenge"],
                                   "number": sol.number, "salt": ch["salt"],
                                   "signature": ch["signature"]}).encode()).decode())
