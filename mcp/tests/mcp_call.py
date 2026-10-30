#!/usr/bin/env python3
"""Test helper: drive the MCP endpoint with the official SDK client (the P1 exit criterion's
scripted half). Runs inside the mcp container.

    mcp_call.py <token> list                      → tool names, one per line
    mcp_call.py <token> call <tool> '<json args>' → {"is_error":…, "structured":…, "text":…}
"""

import asyncio
import json
import sys

from mcp import ClientSession
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

URL = "http://127.0.0.1:8080/api/v1/mcp"


async def main(token: str, action: str, rest: list[str]) -> int:
    async with create_mcp_http_client(headers={"Authorization": f"Bearer {token}"}) as http:
        async with streamable_http_client(URL, http_client=http) as streams:
            read, write = streams[0], streams[1]
            async with ClientSession(read, write) as session:
                await session.initialize()
                if action == "list":
                    tools = await session.list_tools()
                    for t in tools.tools:
                        print(t.name)
                    return 0
                tool, args = rest[0], json.loads(rest[1]) if len(rest) > 1 else {}
                res = await session.call_tool(tool, args)
                text = "\n".join(getattr(c, "text", "") or "" for c in (res.content or []))
                blobs = [c.resource.blob for c in (res.content or []) if getattr(c, "type", "") == "resource"]
                print(json.dumps({"is_error": bool(res.is_error), "structured": res.structured_content,
                                  "text": text, "blobs": blobs}, default=str))
                return 1 if res.is_error else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3:])))
