# tests/conftest.py
# Shared fixtures and helpers for PMxAgent test suite

import json
import os
import shutil
import pytest
import pytest_asyncio
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")

BASE_URL = "http://127.0.0.1:8000/mcp"

def _load_dotenv_token() -> None:
    """Pick MCP_TEST_TOKEN up from the repo's .env, the file `docker compose` reads too.

    One line in .env then configures both the server and the tests, with nothing to
    export. A value already in the environment wins.
    """
    if os.getenv("MCP_TEST_TOKEN"):
        return
    env_file = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    try:
        with open(env_file, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and key.strip() == "MCP_TEST_TOKEN":
                    os.environ["MCP_TEST_TOKEN"] = value.strip().strip("\"'")
    except OSError:
        pass


# Static test token pre-authorized on the server via the MCP_TEST_TOKEN env var, which
# docker-compose.yml passes through (off when unset). Lets automated tests skip browser OAuth.
_load_dotenv_token()
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


@pytest.fixture(scope="session", autouse=True)
def ensure_test_fixtures():
    """Copy test fixture files into ./data/ before the test session runs.

    This ensures files like example_pk_data.csv are always present in the
    Docker volume even if a developer accidentally deletes them from data/.
    The source of truth is tests/fixtures/.
    """
    os.makedirs(DATA_DIR, exist_ok=True)
    for filename in os.listdir(FIXTURES_DIR):
        src = os.path.join(FIXTURES_DIR, filename)
        dst = os.path.join(DATA_DIR, filename)
        if os.path.isfile(src) and not os.path.exists(dst):
            shutil.copy2(src, dst)


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
