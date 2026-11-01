#!/usr/bin/env python3
"""H-02 regression — client-IP resolution (`app.audit.client_ip`).

    docker compose --env-file env.dev -f docker-compose-dev.yml \
        exec -T api python tests/test_client_ip.py

The left-most X-Forwarded-For value is always client-controlled (proxies append,
they do not replace), so the lockout/audit key must come from the right-most hop
that is not a trusted proxy — the MCP rule (mcp/app/asgi.py). These tests pin the
walk with fabricated requests; they need no database.
"""

import ipaddress
import os
import sys
import tempfile
import unittest

from starlette.requests import Request

from app import audit, settings


def _request(peer: str | None, xff: str | None = None) -> Request:
    headers = [(b"x-forwarded-for", xff.encode())] if xff is not None else []
    scope = {
        "type": "http",
        "method": "GET",
        "path": "/api/v1/auth/login-step1",
        "headers": headers,
        "scheme": "http",
        "query_string": b"",
    }
    if peer is not None:
        scope["client"] = (peer, 12345)
    return Request(scope)


class ClientIpTests(unittest.TestCase):
    def setUp(self):
        self._saved = audit._TRUSTED, audit._UNTRUSTED
        audit._TRUSTED = [
            ipaddress.ip_network("172.23.0.0/16", strict=False)
        ]
        audit._UNTRUSTED = set()

    def tearDown(self):
        audit._TRUSTED, audit._UNTRUSTED = self._saved

    def test_no_header_returns_the_peer(self):
        self.assertEqual(audit.client_ip(_request("172.23.0.5")), "172.23.0.5")

    def test_trust_nobody_ignores_the_header_entirely(self):
        audit._TRUSTED = []
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "198.51.100.7")), "172.23.0.5"
        )

    def test_forged_left_most_hop_is_discarded(self):
        """The H-02 kill shot: nginx appends the real client, the spoof is first."""
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "203.0.113.9, 198.51.100.7")),
            "198.51.100.7",
        )

    def test_untrusted_direct_peer_is_never_overridden_by_the_header(self):
        self.assertEqual(
            audit.client_ip(_request("203.0.113.50", "10.9.9.9, 198.51.100.7")),
            "203.0.113.50",
        )

    def test_all_hops_trusted_falls_back_to_the_left_most(self):
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "172.23.0.9, 172.23.0.7")),
            "172.23.0.9",
        )

    def test_a_malformed_hop_fails_closed_to_the_peer(self):
        # The malformed hop sits to the RIGHT of the real client, so the walk
        # reaches it first: the whole chain then falls back to the socket peer.
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "198.51.100.7, not-an-ip")),
            "172.23.0.5",
        )
        # A malformed value left of a valid untrusted hop is never examined: the
        # walk stops at the first untrusted hop it reaches.
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "not-an-ip, 198.51.100.7")),
            "198.51.100.7",
        )

    def test_ipv6_hops(self):
        audit._TRUSTED = [ipaddress.ip_network("fd00::/8", strict=False)]
        self.assertEqual(
            audit.client_ip(_request("fd00::5", "2001:db8::1, fd00::7")), "2001:db8::1"
        )

    def test_empty_header_returns_the_peer(self):
        self.assertEqual(audit.client_ip(_request("172.23.0.5", " , ")), "172.23.0.5")

    def test_missing_client_scope_returns_none(self):
        self.assertIsNone(audit.client_ip(_request(None)))

    def test_the_docker_gateway_is_never_a_proxy(self):
        """A published-port / host request reaches nginx from the gateway with a
        client-supplied header: the walk must stop at the gateway, not believe
        the forged hop to its left (H-02 follow-up)."""
        audit._UNTRUSTED = {ipaddress.ip_address("172.23.0.1")}
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "198.51.100.7, 172.23.0.1")),
            "172.23.0.1",
        )
        # a forged hop inside the trusted subnet cannot be smuggled past it
        self.assertEqual(
            audit.client_ip(_request("172.23.0.5", "172.23.0.99, 172.23.0.1")),
            "172.23.0.1",
        )


class RouteParsingTests(unittest.TestCase):
    """`settings.attached_subnets` / `attached_gateways` over fabricated
    /proc/net route tables (the docker bridge 172.23.0.0/16 via 172.23.0.1)."""

    ROUTE4 = (
        "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
        "eth0\t00000000\t010017AC\t0003\t0\t0\t0\t00000000\t0\t0\t0\n"
        "eth0\t000017AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n"
    )
    ROUTE6 = (
        "fd000000000000000000000000000000 40 00000000000000000000000000000000 00 "
        "00000000000000000000000000000000 00000100 00000001 00000000 00000001 eth0\n"
        "00000000000000000000000000000000 00 00000000000000000000000000000000 00 "
        "fd000000000000000000000000000001 00000400 00000001 00000000 00000003 eth0\n"
    )

    def _tables(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        r4, r6 = os.path.join(tmp.name, "route"), os.path.join(tmp.name, "ipv6_route")
        with open(r4, "w") as fh:
            fh.write(self.ROUTE4)
        with open(r6, "w") as fh:
            fh.write(self.ROUTE6)
        return r4, r6

    def test_subnets_and_gateways(self):
        r4, r6 = self._tables()
        self.assertEqual(
            settings.attached_subnets(r4, r6), ["172.23.0.0/16", "fd00::/64"]
        )
        self.assertEqual(settings.attached_gateways(r4, r6), ["172.23.0.1", "fd00::1"])

    def test_missing_tables_yield_nothing(self):
        self.assertEqual(settings.attached_gateways("/nonexistent", "/nonexistent"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
