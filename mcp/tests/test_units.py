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


# ------------------------------------------------------------------- P2 ---
from mcpcore import confirm, sending  # noqa: E402


def test_confirm_digest_ignores_the_handle_and_key_order_but_not_values():
    a = confirm.digest("trash_emails", {"account": "a@x.cu", "ids": ["1.2"], "confirm": "mdmcp_cf_x"})
    b = confirm.digest("trash_emails", {"ids": ["1.2"], "account": "a@x.cu"})
    assert a == b
    assert a != confirm.digest("trash_emails", {"account": "a@x.cu", "ids": ["1.3"]})
    assert a != confirm.digest("report_spam", {"account": "a@x.cu", "ids": ["1.2"]})


def test_parse_addresses():
    assert sending.parse_addresses(["Bob <BOB@x.cu>", "c@x.cu, d@x.cu"], "to") == ["bob@x.cu", "c@x.cu", "d@x.cu"]
    assert sending.parse_addresses("a@x.cu, a@x.cu", "to") == ["a@x.cu"]
    assert sending.parse_addresses(None, "cc") == []
    with pytest.raises(sending.SendError):
        sending.parse_addresses(["a@x.cu\r\nBcc: evil@y.org"], "to")   # header injection
    with pytest.raises(sending.SendError):
        sending.parse_addresses(["not-an-address"], "to")


def test_subjects_and_quote():
    assert sending.reply_subject("Hello") == "Re: Hello"
    assert sending.reply_subject("RE: Hello") == "RE: Hello"
    assert sending.forward_subject("Hello") == "Fwd: Hello"
    assert sending.forward_subject("Fw: Hello") == "Fw: Hello"
    q = sending.quote({"date": "Mon", "from": "bob@x.cu"}, "line 1\nline 2")
    assert q.startswith("On Mon, bob@x.cu wrote:\n") and "> line 1\n> line 2" in q


def test_outgoing_recipients_are_unique_and_include_bcc():
    out = sending.Outgoing(sender="a@x.cu", to=["b@x.cu"], cc=["b@x.cu", "c@x.cu"], bcc=["d@x.cu"])
    assert out.recipients == ["b@x.cu", "c@x.cu", "d@x.cu"]


# ------------------------------------------------------------------- P3 ---
from mcpcore import adminauth, settings_store, tokens as tok_mod  # noqa: E402


def test_policy_bounds():
    cur = settings_store.defaults("user_policy")
    with pytest.raises(settings_store.SettingsError):
        settings_store._validate("user_policy", {"pat_idle_days": 31}, cur)      # D12: never above 30
    with pytest.raises(settings_store.SettingsError):
        settings_store._validate("user_policy", {"max_message_size": settings_store.env_max_messagesize() + 1}, cur)
    ok = settings_store._validate("user_policy", {"pat_idle_days": 7, "force_confirm": True}, cur)
    assert ok["pat_idle_days"] == 7 and ok["force_confirm"] is True and ok["max_tokens"] == cur["max_tokens"]


def test_logging_and_service_email_validation():
    lg = settings_store._validate("logging", {"rotation": "week", "retention": 26,
                                              "categories": {"mail_actions": False}}, settings_store.defaults("logging"))
    assert lg["rotation"] == "week" and lg["categories"]["mail_actions"] is False and lg["categories"]["security"] is True
    with pytest.raises(settings_store.SettingsError):
        settings_store._validate("logging", {"rotation": "hour"}, settings_store.defaults("logging"))
    se = settings_store.defaults("service_email")
    with pytest.raises(settings_store.SettingsError):
        settings_store._validate("service_email", {"transport": "external", "host": ""}, se)
    out = settings_store._validate("service_email", {"transport": "external", "host": "smtp.x", "password": "s3cret"}, se)
    assert out["password"] and out["password"] != "s3cret"          # stored encrypted
    from mcpcore import crypto
    assert crypto.decrypt(out["password"]) == "s3cret"
    kept = settings_store._validate("service_email", {"host": "smtp.y"}, out)
    assert kept["password"] == out["password"]                       # "" / absent keeps it
    assert out["verify_tls"] is True                                 # default on


def test_master_token_cidr_allowlist():
    t = Token(kind=Token.MASTER, allowed_cidrs=["192.0.2.0/24", "2001:db8::/32"])
    assert tok_mod.ip_allowed(t, "192.0.2.7") and tok_mod.ip_allowed(t, "2001:db8::1")
    assert not tok_mod.ip_allowed(t, "198.51.100.1") and not tok_mod.ip_allowed(t, "not-an-ip")
    assert tok_mod.ip_allowed(Token(kind=Token.MASTER, allowed_cidrs=None), "198.51.100.1")


def test_admin_codes_and_password_rules():
    codes = {adminauth._code() for _ in range(200)}
    assert all(len(c) == 6 and c.isdigit() for c in codes) and len(codes) > 150
    with pytest.raises(Exception):
        adminauth.check_password_rules("short")
    adminauth.check_password_rules("a" * 12)
