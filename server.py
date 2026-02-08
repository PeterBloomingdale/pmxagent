# server.py
"""
PMxAgent MCP Server
Exposes R pharmacometric API via Model Context Protocol
"""
import os
import time
import logging
import traceback
from urllib.parse import urlparse

import httpx
from fastmcp import FastMCP

# Descriptive tool names for better AI agent understanding
# Maps R API paths to human-readable MCP tool names
ENDPOINT_TOOL_NAMES = {
    "/NCA": "Noncompartmental_analysis_NCA",
    "/ER": "Exposure_response_ER_analysis",
    "/PK": "Pharmacokinetic_simulation_IV_1_or_2_CM",
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

# ───────────────────────── 1. MCP server ───────────────────────────────
log.info("Initializing PMxAgent MCP Server...")
mcp = FastMCP(name="PMxAgent MCP Server")

# ──────────────────────── 2. Mount Plumber API ─────────────────────────
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
            # Note: FastMCP mount signature is mount(server, path) not mount(path, server)
            log.debug(f"  Calling mcp.mount with server={type(r_mcp)} and path='r'")
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

# ─────────────────────── 3. Health check endpoint ──────────────────────
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
        path = "/messages"

        log.info("=" * 60)
        log.info("PMxAgent MCP Server starting...")
        log.info(f"  Transport: SSE")
        log.info(f"  Listening: {host}:{port}")
        log.info(f"  Endpoint: {path}")
        log.info(f"  Log level: {LOG_LEVEL}")
        log.info("=" * 60)

        mcp.run(
            transport="sse",
            host=host,
            port=port,
            path=path
        )

    except KeyboardInterrupt:
        log.info("Received shutdown signal (Ctrl+C)")
        log.info("PMxAgent MCP Server shutting down...")
    except Exception as e:
        log.error(f"Fatal error: {e.__class__.__name__}: {e}")
        raise
