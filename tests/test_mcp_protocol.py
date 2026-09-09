# tests/test_mcp_protocol.py
# Transport-level tests for the MCP 2026-07-28 protocol.
#
# These exercise the wire protocol directly with httpx rather than through the
# fastmcp Client, because the client abstracts away exactly what is under test:
# which protocol version is negotiated, and what a legacy client receives.

import os

import httpx2
import pytest

BASE_URL = "http://127.0.0.1:8000/mcp"
PROTOCOL_VERSION = "2026-07-28"
LEGACY_VERSION = "2025-11-25"
UNSUPPORTED_PROTOCOL_VERSION = -32022

_TEST_TOKEN = os.getenv("MCP_TEST_TOKEN", "")

# Set when the server is deliberately run with the legacy escape hatch enabled,
# so the modern-only assertions invert instead of failing.
_ALLOW_LEGACY = os.getenv("MCP_ALLOW_LEGACY", "").strip().lower() in ("1", "true", "yes")

_META = {
    "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {"name": "pmxagent-tests", "version": "1.0"},
}


def _headers(method: str, version: str = PROTOCOL_VERSION) -> dict:
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": version,
        # Required on Streamable HTTP POSTs as of 2026-07-28 (SEP-2243).
        "Mcp-Method": method,
        "Mcp-Name": method,
    }
    if _TEST_TOKEN:
        h["Authorization"] = f"Bearer {_TEST_TOKEN}"
    return h


def _post(method: str, version: str = PROTOCOL_VERSION, params: dict | None = None):
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params
    return httpx2.post(BASE_URL, headers=_headers(method, version), json=body, timeout=30.0)


def _json(response):
    """Parse a response body that may be JSON or a single SSE `data:` frame."""
    text = response.text
    if text.startswith("data:"):
        for line in text.splitlines():
            if line.startswith("data:"):
                import json

                return json.loads(line[len("data:"):].strip())
    return response.json()


# ==================== server/discover ====================


def test_discover_advertises_only_the_modern_protocol():
    """server/discover is new in 2026-07-28 and MUST be implemented."""
    result = _json(_post("server/discover", params={"_meta": _META}))["result"]
    assert result["supportedVersions"] == [PROTOCOL_VERSION]
    assert "tools" in result["capabilities"]


def test_discover_identifies_the_server():
    """Servers SHOULD identify themselves in each result's _meta."""
    result = _json(_post("server/discover", params={"_meta": _META}))["result"]
    server_info = result["_meta"]["io.modelcontextprotocol/serverInfo"]
    assert server_info["name"] == "PMxAgent MCP Server"


# ==================== result envelope ====================


def test_results_carry_result_type():
    """Every result carries a required resultType as of 2026-07-28 (SEP-2322)."""
    result = _json(_post("tools/list", params={"_meta": _META}))["result"]
    assert result["resultType"] == "complete"


def test_list_results_carry_a_usable_cache_hint():
    """tools/list must advertise a non-zero ttlMs (SEP-2549).

    Regression guard for the cache_ttl/cache_scope settings on the FastMCP
    constructor: without them the server emits ttlMs 0, which tells clients not
    to cache at all and makes the hint inert.
    """
    result = _json(_post("tools/list", params={"_meta": _META}))["result"]
    assert result["ttlMs"] > 0, "ttlMs is 0 - cache_ttl is not set on the FastMCP server"
    assert result["cacheScope"] == "private"


def test_tools_are_all_present_over_the_modern_protocol():
    result = _json(_post("tools/list", params={"_meta": _META}))["result"]
    names = {t["name"] for t in result["tools"]}
    assert {
        "health",
        "r_Noncompartmental_analysis_NCA",
        "r_Exposure_response_ER_analysis",
        "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
        "r_Format_data_for_pharmacometric_analyses",
        "r_Model_library_simulate_or_list",
    } <= names


def test_meta_envelope_is_enforced():
    """The modern entry point rejects a request with no _meta envelope."""
    payload = _json(_post("tools/list", params={}))
    assert payload["error"]["code"] == -32602


# ==================== modern-only enforcement ====================


@pytest.mark.skipif(_ALLOW_LEGACY, reason="server running with MCP_ALLOW_LEGACY=true")
def test_legacy_handshake_is_rejected():
    """A 2025-11-25 initialize must be refused, and must not mint a session."""
    response = _post(
        "initialize",
        version=LEGACY_VERSION,
        params={
            "protocolVersion": LEGACY_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "legacy-probe", "version": "1.0"},
        },
    )
    assert _json(response)["error"]["code"] == UNSUPPORTED_PROTOCOL_VERSION
    assert "mcp-session-id" not in response.headers


@pytest.mark.skipif(_ALLOW_LEGACY, reason="server running with MCP_ALLOW_LEGACY=true")
def test_missing_protocol_version_header_is_rejected():
    """A missing header falls to the legacy path in the SDK, so it must be refused too."""
    headers = {k: v for k, v in _headers("tools/list").items() if k != "MCP-Protocol-Version"}
    response = httpx2.post(
        BASE_URL, headers=headers,
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, timeout=30.0,
    )
    assert _json(response)["error"]["code"] == UNSUPPORTED_PROTOCOL_VERSION


@pytest.mark.skipif(_ALLOW_LEGACY, reason="server running with MCP_ALLOW_LEGACY=true")
def test_oauth_discovery_is_not_gated_by_the_protocol_middleware():
    """OAuth endpoints carry no MCP-Protocol-Version and must stay reachable.

    Gating them would break authentication for every client, so this guards the
    path check in ModernProtocolOnlyMiddleware.
    """
    response = httpx2.get(
        "http://127.0.0.1:8000/.well-known/oauth-authorization-server", timeout=30.0
    )
    assert response.status_code == 200
    assert "issuer" in response.json()
