# tests/conftest.py
# Shared fixtures and helpers for PMxAgent test suite

import json
import pytest
from fastmcp import Client
from fastmcp.client.transports import SSETransport

BASE_URL = "http://127.0.0.1:8000/messages"


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


@pytest.fixture
async def mcp_client():
    """Shared MCP client connection."""
    async with Client(SSETransport(BASE_URL)) as c:
        yield c


async def call_tool_ok(client, tool_name: str, args: dict) -> dict:
    """Call a tool and return the extracted result dict."""
    call_result = await client.call_tool(tool_name, args)
    return extract_result(call_result)
