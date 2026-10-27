# tests/test_oauth.py
# OAuth discovery, authorization redirect, and client-registration persistence.
#
# Like test_mcp_protocol.py these talk to the server over plain HTTP: the OAuth routes
# are not MCP traffic, and the behaviour under test is what a client sees on the wire.

import base64
import hashlib
import os
import subprocess
import time
from urllib.parse import parse_qs, urlparse

import httpx2
import pytest

SERVER = "http://127.0.0.1:8000"
REDIRECT_URI = "http://localhost:53682/callback"


def _register_client(http: httpx2.Client) -> str:
    response = http.post(
        f"{SERVER}/register",
        json={
            "client_name": "pmxagent-oauth-test",
            "redirect_uris": [REDIRECT_URI],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        },
    )
    assert response.status_code in (200, 201), response.text
    return response.json()["client_id"]


def _authorize(http: httpx2.Client, client_id: str) -> httpx2.Response:
    verifier = base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return http.get(
        f"{SERVER}/authorize",
        params={
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": REDIRECT_URI,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "test-state",
            "scope": "mcp",
        },
        follow_redirects=False,
    )


def test_authorize_iss_matches_advertised_issuer():
    """The `iss` on the authorization redirect must equal the discovery `issuer` exactly.

    A client that validates RFC 9207 compares the two strings byte for byte, so a
    missing trailing slash on either side makes sign-in fail.
    """
    with httpx2.Client(timeout=30.0) as http:
        issuer = http.get(f"{SERVER}/.well-known/oauth-authorization-server").json()["issuer"]
        client_id = _register_client(http)
        response = _authorize(http, client_id)

    assert response.status_code in (302, 303, 307), response.text
    query = parse_qs(urlparse(response.headers["location"]).query)
    assert query["iss"] == [issuer]
    assert query["state"] == ["test-state"]
    assert "code" in query


@pytest.mark.skipif(
    os.getenv("PMXAGENT_TEST_RESTART") != "1",
    reason="Restarts the mcp container; set PMXAGENT_TEST_RESTART=1 to run.",
)
def test_registered_client_survives_mcp_restart():
    """A client registered before a restart can still authorize afterwards."""
    with httpx2.Client(timeout=30.0) as http:
        client_id = _register_client(http)

        subprocess.run(["docker", "compose", "restart", "mcp"], check=True)
        # The stateless server comes back as soon as the OAuth routes answer again.
        for _ in range(60):
            try:
                if http.get(f"{SERVER}/.well-known/oauth-authorization-server").status_code == 200:
                    break
            except httpx2.HTTPError:
                pass
            time.sleep(1)

        response = _authorize(http, client_id)

    assert response.status_code in (302, 303, 307), response.text
