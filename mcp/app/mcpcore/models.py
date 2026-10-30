"""MailD MCP data model (proposal §10). P0 ships the admin seed only; the other tables
arrive with the phases that use them, each with its own migration."""

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
