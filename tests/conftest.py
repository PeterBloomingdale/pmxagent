# tests/conftest.py
# Shared fixtures and helpers for PMxAgent test suite

import json
import os
import pytest
import pytest_asyncio
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

BASE_URL = "http://127.0.0.1:8000/mcp"

# Static test token pre-authorized on the server via MCP_TEST_TOKEN env var.
# Set MCP_TEST_TOKEN in the environment (and in docker-compose.yml) to enable
# token-based auth for automated tests without browser OAuth.
_TEST_TOKEN = os.getenv("MCP_TEST_TOKEN", "")


def extract_result(call_result) -> dict:
    """Extract result dict from MCP call_tool response (FastMCP >=2.8)."""
    text = call_result.content[0].text
    outer = json.loads(text)
    if isinstance(outer, dict) and "text" in outer:  # pragma: no cover
        return json.loads(outer["text"])
    return outer


def is_error_response(result: dict) -> bool:
    """Check if result is an error response."""
    return "error" in result


@pytest_asyncio.fixture(loop_scope="function")
async def mcp_client():
    """Shared MCP client connection with Bearer token auth for CI tests."""
    headers = {"Authorization": f"Bearer {_TEST_TOKEN}"} if _TEST_TOKEN else None
    transport = StreamableHttpTransport(BASE_URL, headers=headers)
    async with Client(transport) as c:
        yield c


async def call_tool_ok(client, tool_name: str, args: dict) -> dict:
    """Call a tool and return the extracted result dict."""
    call_result = await client.call_tool(tool_name, args)
    return extract_result(call_result)
