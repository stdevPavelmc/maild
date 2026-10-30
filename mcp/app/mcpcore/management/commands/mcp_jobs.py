"""Run the hourly jobs now (idle-token disable, expired pending addresses, cleanup, log
retention). The app runs them by itself every hour; this is for operators and tests."""

import json

from django.core.management.base import BaseCommand, CommandError

from mcpcore import jobs


class Command(BaseCommand):
    help = "Run the MCP hourly jobs once."

    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true", help="(default) run once and exit")

    def handle(self, *args, **options):
        done = jobs.run_once()
        if done is None:
            raise CommandError("another process is running the jobs right now, retry in a moment")
        self.stdout.write(json.dumps(done))
