# server.py
"""
PMxAgent MCP Server
Exposes R pharmacometric API via Model Context Protocol with OAuth authentication.
"""
import os
import time
import logging
import secrets
import traceback
from urllib.parse import urlparse

import httpx
from fastmcp import FastMCP
from fastmcp.server.auth import OAuthProvider, AccessToken
from mcp.server.auth.provider import (
    AuthorizationCode,
    AuthorizationParams,
    RefreshToken,
    construct_redirect_uri,
)
from mcp.server.auth.settings import ClientRegistrationOptions, RevocationOptions
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from pydantic import AnyHttpUrl

# Descriptive tool names for better AI agent understanding
# Maps R API paths to human-readable MCP tool names
ENDPOINT_TOOL_NAMES = {
    "/NCA":  "Noncompartmental_analysis_NCA",
    "/ER":   "Exposure_response_ER_analysis",
    "/PK":   "Pharmacokinetic_simulation_IV_1_or_2_CM",
    "/DATA": "Format_data_for_pharmacometric_analyses",
}

# Configure structured logging
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format='%(asctime)s - %(name)s - %(levelname)s - [%(funcName)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
log = logging.getLogger("pmxagent.server")

# Quiet noisy third-party loggers
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("uvicorn").setLevel(logging.WARNING)
logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
logging.getLogger("uvicorn.error").setLevel(logging.INFO)
logging.getLogger("starlette").setLevel(logging.WARNING)
logging.getLogger("fastmcp").setLevel(logging.INFO)
logging.getLogger("sse_starlette").setLevel(logging.WARNING)
logging.getLogger("docket").setLevel(logging.WARNING)
logging.getLogger("docket.worker").setLevel(logging.WARNING)
logging.getLogger("fakeredis").setLevel(logging.WARNING)


# ─────────────────────── OAuth Provider ─────────────────────────────────────

# Optional static token for CI/automated testing (avoids full browser OAuth flow)
_MCP_TEST_TOKEN = os.getenv("MCP_TEST_TOKEN", "")
_MCP_BASE_URL = os.getenv("MCP_BASE_URL", "http://localhost:8000")


class LocalOAuthProvider(OAuthProvider):
    """
    In-memory OAuth Authorization Server for local development.

    Automatically approves all authorization requests without user confirmation,
    making it seamless for local MCP clients like Claude Code. Serves the full
    OAuth 2.0/2.1 discovery endpoints required by the MCP 2025-11-05 HTTP spec:
      - /.well-known/oauth-authorization-server
      - /.well-known/oauth-protected-resource
      - POST /register  (dynamic client registration)
      - GET  /authorize (auto-approves, redirects with code)
      - POST /token     (code ↔ access+refresh token exchange)
      - POST /revoke    (token revocation)

    Tokens are stored in-memory and lost on container restart. MCP clients
    (e.g., Claude Code) will automatically re-authenticate via the OAuth flow.

    If MCP_TEST_TOKEN env var is set, that token is pre-authorized and can be
    used by automated tests without going through the browser OAuth flow.
    """

    def __init__(self, base_url: str) -> None:
        super().__init__(
            base_url=base_url,
            client_registration_options=ClientRegistrationOptions(
                enabled=True,
                valid_scopes=["mcp"],
                default_scopes=["mcp"],
            ),
            revocation_options=RevocationOptions(enabled=True),
        )
        self._clients: dict[str, OAuthClientInformationFull] = {}
        self._codes: dict[str, AuthorizationCode] = {}
        self._access: dict[str, AccessToken] = {}
        self._refresh: dict[str, RefreshToken] = {}

        # Pre-authorize a static test token for CI/automated tests
        if _MCP_TEST_TOKEN:
            _test_client_id = "test-ci-client"
            self._clients[_test_client_id] = OAuthClientInformationFull(
                client_id=_test_client_id,
                redirect_uris=[AnyHttpUrl("http://localhost")],
                client_name="PMxAgent CI Test Client",
            )
            self._access[_MCP_TEST_TOKEN] = AccessToken(
                token=_MCP_TEST_TOKEN,
                client_id=_test_client_id,
                scopes=["mcp"],
                expires_at=None,  # Never expires
            )
            log.info("✓ Pre-authorized static test token for CI/testing")

    # ── Client registration ──────────────────────────────────────────────────

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        return self._clients.get(client_id)

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        self._clients[client_info.client_id] = client_info
        log.debug("Registered OAuth client: %s (%s)", client_info.client_id, client_info.client_name)

    # ── Authorization code flow ──────────────────────────────────────────────

    async def authorize(
        self, client: OAuthClientInformationFull, params: AuthorizationParams
    ) -> str:
        """Auto-approve: generate code immediately and redirect back to client."""
        code = secrets.token_urlsafe(32)
        self._codes[code] = AuthorizationCode(
            code=code,
            scopes=params.scopes or ["mcp"],
            expires_at=time.time() + 600,  # 10 minutes
            client_id=client.client_id,
            code_challenge=params.code_challenge,
            redirect_uri=params.redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            resource=params.resource,
        )
        log.debug("Auto-approved authorization for client: %s", client.client_id)
        return construct_redirect_uri(str(params.redirect_uri), code=code, state=params.state)

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> AuthorizationCode | None:
        entry = self._codes.get(authorization_code)
        if entry and time.time() > entry.expires_at:
            del self._codes[authorization_code]
            return None
        return entry

    async def exchange_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode
    ) -> OAuthToken:
        access = secrets.token_urlsafe(32)
        refresh = secrets.token_urlsafe(32)
        scopes = authorization_code.scopes

        self._access[access] = AccessToken(
            token=access,
            client_id=client.client_id,
            scopes=scopes,
            expires_at=int(time.time()) + 3600,  # 1 hour
        )
        self._refresh[refresh] = RefreshToken(
            token=refresh,
            client_id=client.client_id,
            scopes=scopes,
            expires_at=int(time.time()) + 86400 * 30,  # 30 days
        )
        del self._codes[authorization_code.code]

        log.debug("Issued access token for client: %s", client.client_id)
        return OAuthToken(
            access_token=access,
            token_type="bearer",
            expires_in=3600,
            refresh_token=refresh,
            scope=" ".join(scopes),
        )

    # ── Refresh token flow ───────────────────────────────────────────────────

    async def load_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: str
    ) -> RefreshToken | None:
        entry = self._refresh.get(refresh_token)
        if entry and entry.expires_at and time.time() > entry.expires_at:
            del self._refresh[refresh_token]
            return None
        return entry

    async def exchange_refresh_token(
        self,
        client: OAuthClientInformationFull,
        refresh_token: RefreshToken,
        scopes: list[str],
    ) -> OAuthToken:
        """Rotate access token; keep existing refresh token."""
        access = secrets.token_urlsafe(32)
        effective_scopes = scopes or refresh_token.scopes

        self._access[access] = AccessToken(
            token=access,
            client_id=client.client_id,
            scopes=effective_scopes,
            expires_at=int(time.time()) + 3600,
        )
        log.debug("Rotated access token for client: %s", client.client_id)
        return OAuthToken(
            access_token=access,
            token_type="bearer",
            expires_in=3600,
            refresh_token=refresh_token.token,
            scope=" ".join(effective_scopes),
        )

    # ── Token validation ─────────────────────────────────────────────────────

    async def load_access_token(self, token: str) -> AccessToken | None:
        entry = self._access.get(token)
        if entry is None:
            return None
        if entry.expires_at is not None and time.time() > entry.expires_at:
            del self._access[token]
            return None
        return entry

    # ── Token revocation ─────────────────────────────────────────────────────

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        if isinstance(token, AccessToken):
            self._access.pop(token.token, None)
        else:
            self._refresh.pop(token.token, None)


# ───────────────────────── 1. OAuth + MCP server ────────────────────────────
log.info("Initializing PMxAgent MCP Server...")
oauth_provider = LocalOAuthProvider(base_url=_MCP_BASE_URL)
mcp = FastMCP(name="PMxAgent MCP Server", auth=oauth_provider)


# ──────────────────────── 2. Mount Plumber API ─────────────────────────────
def mount_plumber_api(timeout: float = 30.0) -> None:
    """
    Attempt to fetch the Plumber OpenAPI spec and mount it as MCP tools.
    Retries until timeout seconds have elapsed.

    Args:
        timeout: Maximum time to wait for R API availability (seconds)

    Raises:
        RuntimeError: If unable to mount API within timeout period
    """
    spec_url = os.getenv(
        "RAPI_OPENAPI_URL",
        "http://localhost:5762/openapi.json",
    )
    log.info(f"Attempting to mount R API from: {spec_url}")
    log.info(f"Timeout: {timeout}s, retry interval: 2s")

    deadline = time.time() + timeout
    last_err = None
    attempt = 0

    while time.time() < deadline:
        attempt += 1
        try:
            log.debug(f"Attempt {attempt}: Fetching OpenAPI spec from {spec_url}")
            spec = httpx.get(spec_url, timeout=2).json()

            # Extract API metadata
            api_title = spec.get('info', {}).get('title', 'Unknown API')
            api_version = spec.get('info', {}).get('version', 'Unknown')
            endpoints = list(spec.get('paths', {}).keys())

            log.info(f"✓ OpenAPI spec retrieved: {api_title} v{api_version}")
            log.info(f"  Discovered {len(endpoints)} endpoints: {', '.join(endpoints)}")

            # Parse base URL
            u = urlparse(spec_url)
            base_url = f"{u.scheme}://{u.hostname}:{u.port or 80}"
            log.debug(f"  Base URL: {base_url}")

            # Create async HTTP client for R API
            r_client = httpx.AsyncClient(base_url=base_url, timeout=30.0)

            # Build mcp_names mapping from operationIds in spec
            mcp_names = {}
            for path, methods in spec.get("paths", {}).items():
                for method, details in methods.items():
                    op_id = details.get("operationId")
                    if op_id and path in ENDPOINT_TOOL_NAMES:
                        mcp_names[op_id] = ENDPOINT_TOOL_NAMES[path]
                        log.debug(f"  Tool name mapping: {op_id} -> {ENDPOINT_TOOL_NAMES[path]}")

            # Generate MCP tools from OpenAPI spec
            log.debug("  Generating MCP tools from OpenAPI spec...")
            r_mcp = FastMCP.from_openapi(
                openapi_spec=spec,
                client=r_client,
                name="R API",
                mcp_names=mcp_names,
            )
            log.debug(f"  Type of r_mcp: {type(r_mcp)}")
            log.debug(f"  r_mcp value: {r_mcp}")

            # Mount to MCP server
            # Note: FastMCP mount signature is mount(server, namespace) not mount(namespace, server)
            log.debug(f"  Calling mcp.mount with server={type(r_mcp)} and namespace='r'")
            mcp.mount(r_mcp, "r")
            log.info(f"✓ R API successfully mounted to MCP server")
            # Format endpoint names for display
            tool_names = [f'r_{ENDPOINT_TOOL_NAMES.get(ep, ep.strip("/"))}' for ep in endpoints]
            log.info(f"  Available tools: {', '.join(tool_names)}")

            return  # Success!

        except httpx.HTTPError as exc:
            last_err = exc
            log.warning(f"Attempt {attempt}: HTTP error connecting to R API: {exc.__class__.__name__}: {exc}")
        except ValueError as exc:
            last_err = exc
            log.warning(f"Attempt {attempt}: Invalid JSON response from R API: {exc}")
        except Exception as exc:
            last_err = exc
            log.warning(f"Attempt {attempt}: Failed to mount R API: {exc.__class__.__name__}: {exc}")
            log.debug(f"Full traceback:\n{traceback.format_exc()}")

        time.sleep(2)

    # Timeout reached without success
    log.error(f"✗ Failed to mount R API after {timeout}s ({attempt} attempts)")
    log.error(f"  Last error: {last_err.__class__.__name__}: {last_err}")
    raise RuntimeError(f"Unable to connect to R API at {spec_url} after {timeout}s")

# ─────────────────────── 3. Health check endpoint ──────────────────────────
@mcp.tool()
def health() -> dict:
    """Health check endpoint for monitoring"""
    return {
        "status": "healthy",
        "service": "PMxAgent MCP Server",
        "version": "1.0.0"
    }


# ───────────────────────── 4. Run MCP server ───────────────────────────
if __name__ == "__main__":
    try:
        # Mount R API with retries
        mount_plumber_api(timeout=30.0)

        # Start MCP server
        host = "0.0.0.0"
        port = int(os.getenv("PORT", 8000))
        path = "/mcp"

        log.info("=" * 60)
        log.info("PMxAgent MCP Server starting...")
        log.info(f"  Transport: streamable-http with OAuth")
        log.info(f"  Listening: {host}:{port}")
        log.info(f"  MCP endpoint: {path}")
        log.info(f"  OAuth discovery: /.well-known/oauth-authorization-server")
        log.info(f"  Log level: {LOG_LEVEL}")
        log.info("=" * 60)

        mcp.run(
            transport="http",
            host=host,
            port=port,
            path=path,
        )

    except KeyboardInterrupt:
        log.info("Received shutdown signal (Ctrl+C)")
        log.info("PMxAgent MCP Server shutting down...")
    except Exception as e:
        log.error(f"Fatal error: {e.__class__.__name__}: {e}")
        raise
