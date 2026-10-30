"""CLI fallback for the admin password (proposal §7.2): sets a new password (given, or generated
and printed once) and revokes every admin session.

    manage.py mcp_admin_reset                 # generate, print once
    manage.py mcp_admin_reset --password …    # set this one (min 12 chars)
"""

from django.core.management.base import BaseCommand, CommandError

from mcpcore import adminauth
from mcpcore.accounts import AccountError
from mcpcore.models import AdminUser
from mcpcore.passwords import generate_password


class Command(BaseCommand):
    help = "Reset the MCP admin password and revoke the admin sessions."

    def add_arguments(self, parser):
        parser.add_argument("--username", default=None)
        parser.add_argument("--password", default=None)

    def handle(self, *args, username, password, **options):
        qs = AdminUser.objects.all()
        admin = qs.filter(username=username).first() if username else qs.order_by("id").first()
        if admin is None:
            raise CommandError("no such admin user")
        generated = password is None
        password = password or generate_password()
        try:
            adminauth.check_password_rules(password)
        except AccountError as exc:
            raise CommandError(exc.message) from None
        adminauth.cli_reset(admin, password)
        self.stdout.write(f"admin '{admin.username}' password reset; every admin session revoked")
        if generated:
            self.stdout.write(f"NEW PASSWORD: {password}")
