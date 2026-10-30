"""MailD MCP — root ASGI application (served by uvicorn).

The proposal's root router (§3.1) sends `/api/v1/mcp` to the MCP SDK app and everything else
to Django. P0 has no MCP endpoint yet, so every path goes to Django; the MCP mount is added
in P1.
"""

import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "maild_mcp.settings")

from django.core.asgi import get_asgi_application  # noqa: E402

django_app = get_asgi_application()


async def application(scope, receive, send):
    await django_app(scope, receive, send)
