"""MailD MCP data model (proposal §10). Tables arrive with the phase that uses them, each with
its own migration: P0 admin_user; P1 domain_policy, account, account_address, token,
web_session, login_failure, altcha_used, notice_throttle."""

from django.db import models


class AdminUser(models.Model):
    username = models.CharField(max_length=150, unique=True)
    email = models.CharField(max_length=255)
    # Argon2id (argon2-cffi), same parameters as the AdminNG API
    password_hash = models.CharField(max_length=255)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    last_login_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "admin_user"

    def __str__(self) -> str:
        return self.username


class DomainPolicy(models.Model):
    """MCP allow-list (D6). Domains themselves are read live from the catalogue; a domain with
    no row here is denied."""

    domain = models.CharField(max_length=255, primary_key=True)
    allowed = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "domain_policy"


class Account(models.Model):
    main_email = models.CharField(max_length=255, unique=True)
    mcp_enabled = models.BooleanField(default=True)
    prefs = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    last_login_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "account"


class AccountAddress(models.Model):
    """Every address of an account, the main one included (`is_main`), so one unique column
    enforces D11: an address belongs to at most one account, pending rows included."""

    PENDING, ACTIVE, DISABLED = "pending", "active", "disabled"
    STATUS = [(PENDING, PENDING), (ACTIVE, ACTIVE), (DISABLED, DISABLED)]

    account = models.ForeignKey(Account, on_delete=models.CASCADE, related_name="addresses")
    email = models.CharField(max_length=255, unique=True)
    is_main = models.BooleanField(default=False)
    status = models.CharField(max_length=16, choices=STATUS)
    magic_hash = models.CharField(max_length=64, blank=True, default="")
    magic_expires_at = models.DateTimeField(null=True, blank=True)
    resend_count = models.IntegerField(default=0)
    next_resend_at = models.DateTimeField(null=True, blank=True)
    confirmed_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "account_address"


class Token(models.Model):
    PAT, OAUTH_ACCESS, OAUTH_REFRESH, MASTER = "pat", "oauth_access", "oauth_refresh", "master"
    KINDS = [(k, k) for k in (PAT, OAUTH_ACCESS, OAUTH_REFRESH, MASTER)]
    ACTIVE, DISABLED, REVOKED = "active", "disabled", "revoked"
    STATUS = [(k, k) for k in (ACTIVE, DISABLED, REVOKED)]

    public_id = models.CharField(max_length=32, unique=True)
    kind = models.CharField(max_length=16, choices=KINDS)
    account = models.ForeignKey(Account, null=True, blank=True, on_delete=models.CASCADE, related_name="tokens")
    admin = models.ForeignKey(AdminUser, null=True, blank=True, on_delete=models.CASCADE)
    name = models.CharField(max_length=100)
    # HMAC-SHA256(MCP_SECRET_KEY, token): the token itself is never stored
    hash = models.CharField(max_length=64, unique=True)
    display = models.CharField(max_length=40)          # prefix + "…" + last 4
    scopes = models.JSONField(default=list)
    addresses = models.JSONField(null=True, blank=True)  # None = every active address
    status = models.CharField(max_length=16, choices=STATUS, default=ACTIVE)
    disabled_reason = models.CharField(max_length=16, blank=True, default="")  # user|admin|idle
    expires_at = models.DateTimeField(null=True, blank=True)  # None = forever
    family_id = models.CharField(max_length=32, blank=True, default="")
    client_id = models.CharField(max_length=255, blank=True, default="")
    allowed_cidrs = models.JSONField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    last_used_at = models.DateTimeField(null=True, blank=True)
    last_used_ip = models.CharField(max_length=64, blank=True, default="")
    last_used_client = models.CharField(max_length=255, blank=True, default="")
    # D12: re-enabling (from the web page only) restarts the idle clock
    reenabled_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "token"


class WebSession(models.Model):
    """Server side of a web login: the refresh cookie rotates on every use; presenting a
    superseded one revokes the session (reuse detection)."""

    jti = models.CharField(max_length=32, primary_key=True)
    kind = models.CharField(max_length=8)              # user | admin
    subject_id = models.BigIntegerField()
    refresh_hash = models.CharField(max_length=64, unique=True)
    prev_refresh_hash = models.CharField(max_length=64, blank=True, default="", db_index=True)
    expires_at = models.DateTimeField()                # absolute lifetime (24 h user / 72 h admin)
    revoked_at = models.DateTimeField(null=True, blank=True)
    login_email = models.CharField(max_length=255, blank=True, default="")
    ip = models.CharField(max_length=64, blank=True, default="")
    user_agent = models.CharField(max_length=255, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "web_session"


class LoginFailure(models.Model):
    key = models.CharField(max_length=320)
    ip = models.CharField(max_length=64)
    count = models.IntegerField(default=0)
    locked_until = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "login_failure"
        constraints = [models.UniqueConstraint(fields=["key", "ip"], name="login_failure_key_ip")]


class AltchaUsed(models.Model):
    """Spent ALTCHA challenges (single use until they expire)."""

    signature = models.CharField(max_length=128, primary_key=True)
    expires_at = models.DateTimeField()

    class Meta:
        db_table = "altcha_used"


class NoticeThrottle(models.Model):
    kind = models.CharField(max_length=64)
    key = models.CharField(max_length=512)
    last_sent_at = models.DateTimeField()

    class Meta:
        db_table = "notice_throttle"
        constraints = [models.UniqueConstraint(fields=["kind", "key"], name="notice_throttle_kind_key")]
