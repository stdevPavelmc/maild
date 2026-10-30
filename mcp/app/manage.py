#!/usr/bin/env python3
"""Django's command-line utility for the MailD MCP."""

import os
import sys

if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "maild_mcp.settings")
    from django.core.management import execute_from_command_line

    execute_from_command_line(sys.argv)
