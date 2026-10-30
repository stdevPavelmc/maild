"""pytest bootstrap for the MailD MCP unit tests (no database, no mail server needed).

Run them in a throwaway container from the mcp image (dev rule: everything in containers):
  docker run --rm -e DEFAULT_DOMAIN=maild.cu -e MCP_SECRET_KEY=test -e MCP_DB_PASSWORD=x \
    -e MCP_DOVECOT_MASTER_PASSWORD=x -v /tmp/maild-mcp-p1:/scratch --entrypoint sh \
    pavelmc/maild-mcp:develop -c 'pip install -q --target /scratch/py -r tests/requirements-test.txt \
    && PYTHONPATH=/scratch/py:/app python -m pytest -q -p no:cacheprovider tests'
"""

import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "maild_mcp.settings")

import django  # noqa: E402

django.setup()

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def _settings_defaults(monkeypatch):
    """Units run without a database: the admin settings resolve to their defaults."""
    from mcpcore import settings_store

    monkeypatch.setattr(settings_store, "get", lambda group: settings_store.defaults(group))
