#!/usr/bin/env python3
# ratelimitd — MailD per-user outbound submission throttle (2026-10 audit F-12).
#
# A Postfix SMTP policy daemon (postfix-policy(5)) consulted per RCPT by the
# submission (587) and smtps (465) services. It counts envelope recipients per
# authenticated user (sasl_username) over a fixed window and defers (450) past
# OUTBOUND_RATE_RECIPIENTS. Accounts listed in OUTBOUND_RATE_EXEMPT_USERS are
# never throttled: a hard, from-any-IP bypass for notification senders such as
# no-reply@ or the admin account (the envelope-spoofing angle is already closed
# by smtpd_sender_login_maps: the sender must be owned by the authenticating
# account, so exempting an account cannot send as anybody else).
#
# Deliberate properties:
#   - Fail-open BY CONTRACT: the submission services set
#     smtpd_policy_service_default_action=DUNNO, so a dead/behind daemon stops
#     no mail; the cron outbound_watch job alerts on the gap and on throttle
#     events (it greps the "maild-ratelimit:" lines this writes to stdout, which
#     production's syslog driver carries to the cron container's /var/log).
#   - In-memory counters: an mta restart resets them (the same tradeoff
#     Postfix's own anvil makes).
#   - Loopback-only (127.0.0.1:12341), runs unprivileged as the postfix user,
#     stdlib only (python3 is already in the image via postfix-policyd-spf).
#
# Protocol: one request is "attr=value" lines ended by an empty line; the
# answer is one "action=..." line plus an empty line.

import asyncio
import os
import sys
import time

HOST = "127.0.0.1"
PORT = int(os.environ.get("OUTBOUND_RATE_PORT", "12341"))


def _int(name, default, minimum=0):
    raw = os.environ.get(name, "").strip()
    try:
        val = int(raw) if raw else default
    except ValueError:
        print(f"maild-ratelimit: WARNING {name}='{raw}' is not an integer, using {default}",
              flush=True)
        val = default
    return max(minimum, val)


LIMIT = _int("OUTBOUND_RATE_RECIPIENTS", 200)        # 0 = pass everything through
WINDOW = _int("OUTBOUND_RATE_WINDOW", 3600, 60)      # seconds, floor 60
EXEMPT = {u.strip().lower() for u in
          os.environ.get("OUTBOUND_RATE_EXEMPT_USERS", "").split(",") if u.strip()}

# sasl_username -> [window bucket, recipients counted in that bucket]
COUNTERS = {}
CALLS = 0
LOG_EVERY = 5        # log the first throttle per user per window, then every Nth


def _prune(bucket):
    for user in [u for u, e in COUNTERS.items() if e[0] < bucket]:
        del COUNTERS[user]


def decide(attrs):
    """-> (action, logline-or-None) for one smtpd_rcpt request."""
    global CALLS
    CALLS += 1
    user = (attrs.get("sasl_username") or "").strip().lower()
    recip = attrs.get("recipient", "?")
    # submission/smtps reject unauthenticated clients before consulting us, but
    # never guess a bucket for an anonymous request either.
    if not user or user in EXEMPT or LIMIT <= 0:
        return "DUNNO", None
    bucket = int(time.time()) // WINDOW
    if CALLS % 4096 == 0:
        _prune(bucket)
    entry = COUNTERS.get(user)
    if entry is None or entry[0] != bucket:
        entry = [bucket, 0]
        COUNTERS[user] = entry
    entry[1] += 1
    if entry[1] <= LIMIT:
        return "DUNNO", None
    log = None
    if (entry[1] - LIMIT - 1) % LOG_EVERY == 0:
        log = (f"maild-ratelimit: throttled user={user} count={entry[1]} "
               f"limit={LIMIT} window={WINDOW}s recipient={recip}")
    return "450 4.7.1 Outbound rate limit exceeded for this account, try again later", log


async def handle(reader, writer):
    try:
        while True:
            attrs = {}
            while True:
                line = await reader.readline()
                if not line:
                    return                      # client closed the connection
                line = line.decode("utf-8", "replace").rstrip("\r\n")
                if not line:
                    break                       # end of this request
                if "=" in line:
                    key, val = line.split("=", 1)
                    attrs[key] = val
            action, log = decide(attrs)
            if log:
                print(log, flush=True)
            writer.write(f"action={action}\n\n".encode())
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    except Exception as exc:                    # never die on protocol garbage
        print(f"maild-ratelimit: ERROR {type(exc).__name__}: {exc}", flush=True)
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, HOST, PORT)
    print(f"maild-ratelimit: listening on {HOST}:{PORT} limit={LIMIT}/user "
          f"window={WINDOW}s exempt={len(EXEMPT)} account(s)", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
