#!/usr/bin/env python3
"""Print the current TOTP code for an admin (TESTS ONLY).

    docker compose ... exec -T api python tests/totp_code.py <username> [--next]

Container access is root authority already (the CLI can approve devices and read
the adminng database), so a test helper that decrypts the seed adds no privilege.
It is used by test.sh to drive the real login-step2 flow.

`--next` prints the code for the NEXT 30-second step: right after enrollment the
current step is already consumed (replay protection), so the first login must use
the next one.
"""

import sys
import time

from app import auth, crypto, settings, totp

args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
next_step = "--next" in sys.argv

if len(args) != 1:
    print("usage: totp_code.py <username> [--next]", file=sys.stderr)
    sys.exit(2)

credential = auth._credential(args[0])
if not credential or not credential["confirmed"]:
    print(f"no confirmed TOTP credential for {args[0]}", file=sys.stderr)
    sys.exit(3)

moment = time.time() + (settings.ADMINNG_TOTP_STEP if next_step else 0)
print(totp.code_at(crypto.decrypt(credential["secret"]), moment))

