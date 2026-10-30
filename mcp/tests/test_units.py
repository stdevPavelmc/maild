"""Unit tests for the pure parts of the MCP core: handles, policy, IMAP criteria, the idle rule,
duration parsing. The end-to-end behaviour is covered by test.sh (sections J, K) and the
pwa-test `mcp` flows."""

import datetime as dt
import time

import pytest
from django.utils import timezone

from maild_mcp.settings import env_duration
from mcpcore import crypto, mail, policy, tokens
from mcpcore.models import Token


# ------------------------------------------------------------------ handles ---
def test_handle_round_trip_and_binding():
    h = crypto.mint_handle("cursor", "tok1", {"i": 2, "o": 25})
    assert crypto.open_handle(h, "cursor", "tok1") == {"i": 2, "o": 25}
    with pytest.raises(ValueError):
        crypto.open_handle(h, "cursor", "tok2")      # another token
    with pytest.raises(ValueError):
        crypto.open_handle(h, "watermark", "tok1")   # another kind


def test_handle_tamper_and_expiry():
    h = crypto.mint_handle("cursor", "tok1", {"i": 0}, ttl=1)
    raw, sig = h.split(".")
    forged = crypto._b64(b'{"b":"tok1","k":"cursor","p":{"i":99}}') + "." + sig
    with pytest.raises(ValueError):
        crypto.open_handle(forged, "cursor", "tok1")
    with pytest.raises(ValueError):
        crypto.open_handle("garbage", "cursor", "tok1")
    time.sleep(1.1)
    with pytest.raises(ValueError, match="expired"):
        crypto.open_handle(h, "cursor", "tok1")


def test_token_hash_is_keyed_and_tokens_are_long():
    t = crypto.new_token("mdmcp_pat_")
    assert t.startswith("mdmcp_pat_") and len(t) == len("mdmcp_pat_") + 43
    assert crypto.token_hash(t) == crypto.token_hash(t)
    assert crypto.token_hash(t) != crypto.token_hash(t + "x")
    assert t not in crypto.token_hash(t)


# ------------------------------------------------------------------- policy ---
def test_resend_backoff_is_2n_minutes_capped_at_a_day():
    assert [policy.resend_delay(n) for n in range(4)] == [60, 120, 240, 480]
    assert policy.resend_delay(30) == policy.DAY


# --------------------------------------------------------------- criteria ---
def test_search_criteria():
    assert mail.build_criteria({}) == ["ALL"]
    crit = mail.build_criteria({"from": "bob", "since": "2026-10-01", "unread": True, "larger_than": 1000})
    assert crit == ["FROM", "bob", "SINCE", dt.date(2026, 10, 1), "UNSEEN", "LARGER", 1000]
    assert mail.build_criteria({"unread": False, "flagged": False}) == ["SEEN", "UNFLAGGED"]
    with pytest.raises(mail.MailError):
        mail.build_criteria({"before": "yesterday"})


def test_or_tree_is_binary():
    terms = [["A"], ["B"], ["C"]]
    assert mail._any_of(terms) == ["OR", ["A"], ["OR", ["B"], ["C"]]]
    assert mail._any_of([["A"]]) == ["A"]


def test_message_ids():
    assert mail.parse_id(mail.make_id(17, 42)) == (17, 42)
    with pytest.raises(mail.MailError):
        mail.parse_id("42")
    with pytest.raises(mail.MailError):
        mail._check_uidvalidity(18, "17.42")       # UIDVALIDITY changed → stale


# ---------------------------------------------------------------- idle rule ---
def _pat(**times):
    now = timezone.now()
    tok = Token(kind=Token.PAT, created_at=now, last_used_at=None, reenabled_at=None)
    for k, days in times.items():
        setattr(tok, k, now - dt.timedelta(days=days))
    return tok


def test_idle_anchor_is_the_newest_of_created_used_reenabled():
    assert not tokens.is_idle(_pat(created_at=10))
    assert tokens.is_idle(_pat(created_at=31))
    assert not tokens.is_idle(_pat(created_at=60, last_used_at=5))
    assert not tokens.is_idle(_pat(created_at=60, last_used_at=45, reenabled_at=1))
    assert tokens.is_idle(_pat(created_at=90, last_used_at=40, reenabled_at=31))


def test_idle_rule_only_for_pats():
    tok = _pat(created_at=90)
    tok.kind = Token.MASTER
    assert not tokens.is_idle(tok)


# ---------------------------------------------------------------- durations ---
@pytest.mark.parametrize("raw,seconds", [("900", 900), ("15m", 900), ("24h", 86400), ("7d", 604800)])
def test_env_duration(monkeypatch, raw, seconds):
    monkeypatch.setenv("X_TTL", raw)
    assert env_duration("X_TTL", "1") == seconds


def test_env_duration_rejects_garbage(monkeypatch):
    from django.core.exceptions import ImproperlyConfigured

    monkeypatch.setenv("X_TTL", "soon")
    with pytest.raises(ImproperlyConfigured):
        env_duration("X_TTL", "1")
