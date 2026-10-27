# Changelog

All notable user-visible changes to PMxAgent are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-10-26

### Added
- README now states at the top that the tools are examples that have not been verified or validated, and that users are responsible for their own verification and validation.
- Tests: `tests/test_oauth.py` (issuer match; opt-in restart persistence via `PMXAGENT_TEST_RESTART=1`) and extended `/ER` tests. The Python suite now collects 74 tests (73 run by default, 1 opt-in).
- `/ER` responses include `model_selection` (the rule that chose the model) and `aic_comparable`. **Tool change:** two additive response fields alter the schema agents see; existing fields are unchanged.

### Changed
- `/ER` documentation (Swagger and MCP tool description, README) now states that `auto` picks the logit model by rule for binary responses and the lowest AIC otherwise, that AIC is not comparable between the logit and least-squares fits, that no significance test is reported, and that `resp_rate` is a data-generation convenience that draws responses by dose group before all models are fitted to the individual exposure/response values. **Tool change:** the `model` parameter description changed. **Numerical:** none; model fitting and selection are unchanged.
- `docker-compose.yml` adds a named volume `mcp-state` mounted at `/state` in the `mcp` container, used only to persist OAuth client registrations (MCP itself stays stateless). **Dependencies:** no change to the base image, FastMCP, the MCP spec version, or R packages.
- Version metadata is now 1.1.0 in the health check, `CITATION.cff`, both Dockerfiles, and the `docker-compose.ghcr.yml` image tags. **Dependencies:** no change to the base image, FastMCP, the MCP spec version, or R packages.
- README cleanup: shorter introduction, corrected clone URL, CI status badge, changelog pointer.

### Fixed
- **Resolved: OAuth sign-in failed on a trailing-slash mismatch.** The `iss` on the authorization redirect now matches the issuer in the discovery document exactly (`http://localhost:8000/`), so clients that validate RFC 9207 sign in normally and no longer need the test token as a workaround.
- **Resolved: "Client ID not found" after a container restart.** Registered OAuth clients now persist in the `mcp-state` volume, so a client that cached its `client_id` keeps working. The store is written with mode `0600`, and a storage failure is logged instead of blocking registration. Rebuild the images so `/state` exists with the right ownership.
- **Resolved: `/ER` auto model selection was easy to misreport as "lowest AIC".** For binary responses the logit model is chosen by rule, not AIC, and its AIC is not comparable with the least-squares fits. The response now says so (`model_selection`, `aic_comparable`) and the documentation matches. **Numerical:** none; fitting and selection are unchanged.

### Security
- The default `docker-compose.yml` no longer enables the static test token (`MCP_TEST_TOKEN`); clients now sign in through the standard OAuth approval, and the tests opt in to a token of their own. To run the tests, set `MCP_TEST_TOKEN` in the environment or a gitignored `.env` (see `.env.example`); the tests read `.env` automatically and CI sets the variable itself. Upgrade to pick this up. **Tool change:** none.

## [1.0.0] - 2026-09-10

### Added
- First tagged release: `/NCA`, `/ER`, `/PK`, `/DATA`, and `/LIBRARY` endpoints exposed as MCP tools, MCP `2026-07-28` (stateless) server, and container images published to GitHub Container Registry.
