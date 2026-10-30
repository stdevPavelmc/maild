"""CLI for the MCP domain allow-list (decision 2026-10-29, mcp/progress.md P1): the admin
panel's Domains group arrives in P3, this stays as the fallback.

    manage.py mcp_domains list
    manage.py mcp_domains allow example.net [other.org …]
    manage.py mcp_domains deny example.net
"""

from django.core.management.base import BaseCommand, CommandError

from mcpcore import domains


class Command(BaseCommand):
    help = "List, allow or deny catalogue domains for the MCP (new domains start denied)."

    def add_arguments(self, parser):
        parser.add_argument("action", choices=["list", "allow", "deny"])
        parser.add_argument("domain", nargs="*")

    def handle(self, *args, action, domain, **options):
        if action == "list":
            for row in domains.listing():
                state = "ALLOWED" if row["effective"] else "denied"
                note = "" if row["catalogue_active"] else "  (inactive in the catalogue)"
                self.stdout.write(f"{row['domain']:40} {state}{note}")
            return
        if not domain:
            raise CommandError(f"'{action}' needs at least one domain")
        for d in domain:
            try:
                domains.set_allowed(d, action == "allow", actor={"type": "cli"})
            except ValueError as exc:
                raise CommandError(str(exc)) from None
            self.stdout.write(f"{d.lower()}: {'allowed' if action == 'allow' else 'denied'}")
