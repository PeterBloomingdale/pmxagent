# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

PMxAgent transforms validated R pharmacometric workflows into AI-ready HTTP APIs. The architecture consists of:
- **R Plumber API** (modular structure in `apis/`): Pharmacometric endpoints (NCA, ER, PK, DATA, LIBRARY)
  - `apis/rapi.R` - Lightweight router using `copy_routes()` helper to compose endpoint modules
  - `apis/endpoints/` - Self-contained endpoint modules with Plumber annotations and dependencies
  - `apis/models/` - Core pharmacometric calculation functions
  - `apis/utils/` - Shared utilities (validation, plotting, constants, data_processing)
- **Python MCP Server** (`server.py`): MCP server that exposes R API via Model Context Protocol
- **Docker orchestration**: Two-container setup with health checks and inter-service communication

## Development Commands

### Build and Run
```bash
# Start both containers (R API + Python MCP Server)
docker compose up --build

# Rebuild after code changes
docker compose up --build

# Stop containers
docker compose down

# View logs
docker compose logs rapi
docker compose logs mcp

# Clean rebuild
docker compose down -v && docker compose up --build
```

### Running Tests
```bash
# Install test dependencies
pip install -r requirements-dev.txt

# Run Python integration tests
pytest tests/ -v

# Run specific test
pytest tests/test_endpoints.py::test_nca_endpoint -v

# Run R unit tests (in container)
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_nca.R
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_pk_models.R
```

### Access Points
- R API (Plumber): http://localhost:5762
- API Documentation (Swagger UI): http://localhost:5762/__docs__/
- Python MCP Server: http://localhost:8000
- MCP endpoint (streamable HTTP): http://localhost:8000/mcp

### Testing Endpoints
```bash
# Test NCA endpoint
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,1,2,4,8' \
  -d 'conc=10,8,5,2,1' \
  -d 'dose=100'

# Test ER endpoint
curl -X POST http://localhost:5762/ER \
  -d 'exposure=10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45' \
  -d 'resp=0,10,20,35,55,70,85,95,100'

# Test PK endpoint (single subject)
curl -X POST http://localhost:5762/PK \
  -d 'dose=100' \
  -d 'CL=1' \
  -d 'V1=10'

# Test PK endpoint (population mode with BSV)
curl -X POST http://localhost:5762/PK \
  -d 'n_subjects=30' \
  -d 'dose=10,30,100' \
  -d 'cv=0.25' \
  -d 'BW=70' \
  -d 't=0,1,2,4,8,12,24' \
  -d 'seed=42'
```

## Architecture

### Container Communication Flow
1. **rapi** container starts first, runs R Plumber on port 8000 (mapped to host 5762)
2. Health check monitors `/openapi.json` endpoint until available
3. **mcp** container starts after rapi is healthy
4. `server.py` fetches OpenAPI spec from `http://rapi:8000/openapi.json`
5. FastMCP dynamically mounts R API tools using the OpenAPI spec
6. MCP server exposes tools on port 8000 via streamable HTTP at `/mcp`

### Key Components

**R API (Modular Structure)**
- **Main Router** (`apis/rapi.R`): Uses `copy_routes()` helper to compose endpoint modules at root path
- **Endpoints** (`apis/endpoints/*.R`): Self-contained modules with Plumber annotations, library imports, and source dependencies
  - `nca.R` - Non-compartmental analysis endpoint (uses PKNCA)
  - `er.R` - Exposure-response modeling endpoint (uses ggplot2, er_models)
  - `pk.R` - PK simulation endpoint (uses ggplot2, pk_models)
  - `library.R` - Model library list/simulate endpoint (uses nlmixr2lib, rxode2)
- **Models** (`apis/models/*.R`): Pure R functions for calculations
  - `mrgsolve_pk.R` - mrgsolve-based 1CM and 2CM model simulations (simulate_1cm(), simulate_2cm())
  - `er_models.R` - Linear, Emax, Imax, logit model fitting
  - `nlmixr2lib_sim.R` - nlmixr2lib catalog access + faithful rxode2 population simulation (load_library_model(), probe_model(), simulate_library_population())
- **Utilities** (`apis/utils/*.R`): Shared functions and constants
  - `validation.R` - Input validation and error checking (includes route, dosing scenario, BLQ, business rules validators)
  - `plotting.R` - Standardized plot generation and saving
  - `constants.R` - Configuration constants (plot settings, bounds, limits, unit rules, NCA settings)
  - `units.R` - Unit label derivation and formatting for NCA parameters (`derive_nca_unit()` forwards to `derive_param_unit()`; `calculate_effective_dose()` for mg/kg; `format_value_unit()` and `format_nca_results_with_units()` for response formatting)
  - `pknca_units.R` - PKNCA route mapping (`map_route_to_pknca()`), interval creation (`create_nca_intervals()`), options management (`set_pknca_options()`/`reset_pknca_options()`), unit label derivation (`derive_param_unit()`), result extraction (`extract_results_with_units()`). Note: `create_pknca_units()` is defined but not called by the NCA endpoint
  - `colors.R` - Color scheme utilities for consistent plotting
  - `library_utils.R` - /LIBRARY sampling-design helpers (`assign_tier()`, `build_sampling_schedule()`, `fit_terminal_half_life()`) and catalog filtering (`filter_pk_models()`)
- **Tests** (`apis/tests/*.R`): R unit tests for model functions
  - `test_nca.R` - Ground truth validation for NCA
  - `test_pk_models.R` - Unit tests for compartment models
- Uses PKNCA library for non-compartmental analysis
- Generates publication-ready plots with ggplot2
- All endpoints return JSON (unboxedJSON serializer)
- Plots saved to `/figures/` with timestamp naming convention

**Python MCP Server (`server.py`)**
- Uses `FastMCP.from_openapi()` to auto-generate MCP tools from R API
- 30-second retry loop with 2-second intervals for R API availability
- Streamable HTTP transport at `/mcp`, stateless (SSE is deprecated as of MCP 2026-07-28)
- Base URL parsing from RAPI_OPENAPI_URL environment variable

**MCP protocol revision**

The server implements **MCP `2026-07-28`** (the stateless revision) and **only** that revision.
There is no `initialize` handshake and no `Mcp-Session-Id`: every request carries its protocol
version and client capabilities in `_meta`, and `server/discover` advertises server identity and
capabilities.

- **Modern-only enforcement**: `ModernProtocolOnlyMiddleware` (`server.py`) refuses requests to
  `/mcp` whose `MCP-Protocol-Version` header is absent or is a handshake-era version, replying
  with JSON-RPC `-32022`. OAuth routes (`/.well-known/*`, `/register`, `/authorize`, `/token`,
  `/revoke`) are deliberately **not** gated - they carry no such header, and gating them would
  break authentication for every client.
- **Escape hatch**: set `MCP_ALLOW_LEGACY=true` (declared in `docker-compose.yml`) to re-admit
  handshake clients. Restart only, no rebuild.
- **Cache hints**: `cache_ttl=300` / `cache_scope="private"` on the `FastMCP` constructor, so
  every cacheable result (`tools/list`, `server/discover`, ...) carries `ttlMs: 300000`. Without
  them the wire value is `ttlMs: 0`, which tells clients not to cache at all.
- **Stateless**: `mcp.run(..., stateless_http=True)` - nothing is pinned to a connection, so the
  server can sit behind a plain round-robin load balancer.
- **Version range (not an exact pin)**: `fastmcp>=4.0.3,<5` in **both** `requirements.txt` and
  `requirements-dev.txt` - patches and minors are picked up automatically, only a major bump
  requires an edit. The client major must match the server's or the tests negotiate a different
  protocol revision than production uses. FastMCP 4 requires `httpx2`, not `httpx`. The only
  exact pin in the repo is the R base image digest in `docker/Dockerfile.rapi`.
- **Health check**: the `mcp` container probes with a `server/discover` POST (possible only
  because the protocol is stateless - no handshake to complete). The probe is unauthenticated so
  it cannot expect a 200; it asserts `100 <= status < 500`, which separates "alive and handling
  requests" from both "failing everything with 5xx" and "not listening at all" (curl reports
  `000` when it cannot connect).

### Volume Mounts
- `./figures:/figures` - Persistent storage for generated plots across container restarts

### Platform
- Both containers use `platform: linux/amd64` for Apple Silicon compatibility

## Pharmacometric Endpoints

### POST /NCA (Non-Compartmental Analysis)
Comprehensive NCA endpoint leveraging PKNCA's native features including route of administration, dosing scenarios, BLQ handling, and business rules.

- **Required params**: `time`, `conc` (comma-separated numeric strings)
- **Basic params**:
  - `dose` (default "1") - Dose amount
  - `params` - Additional PK parameters to return
  - `dose_unit` - Unit of dose: `"mg"` (default) or `"mg/kg"`
  - `conc_unit` - Unit of concentration: `"ug/mL"` (default), `"ng/mL"`, `"mg/L"`, `"g/L"`, `"umol/L"`, `"nmol/L"`
  - `time_unit` - Unit of time: `"h"` (default), `"min"`, `"d"`
  - `BW` - Body weight in kg (default "70"); required when `dose_unit="mg/kg"`

**Route of Administration**:
- `route` - `"iv_bolus"`, `"iv_infusion"`, or `"extravascular"` (default). Also accepts the **numeric
  administration codes** `1`=iv_bolus, `2`=extravascular, `3`=iv_infusion (e.g. datasets prepared for
  PKanalix); `normalize_route()` maps them to the canonical strings. Applies to both the `route`
  parameter and the per-row `ROUTE` column in a `data_file`.
- `infusion_duration` - Duration in time_unit (required when `route="iv_infusion"`)

**Dosing Scenario**:
- `dosing_scenario` - `"single"` (default), `"repeat"`, or `"steady_state"`
- `tau` - Dosing interval in time_unit (required for repeat/steady_state)

**BLQ Handling**:
- `blq_first` - Pre-first-dose BLQ: `"keep"` (default), `"drop"`, `"zero"`
- `blq_middle` - Between-dose BLQ: `"keep"`, `"drop"` (default), `"zero"`
- `blq_last` - Terminal phase BLQ: `"keep"` (default), `"drop"`, `"zero"`

**Business Rules**:
- `auc_method` - `"lin up/log down"` (default), `"linear"`, `"lin-log"`
- `min_hl_points` - Minimum points for half-life (default "3")
- `min_hl_r_squared` - Minimum R² for half-life (default "0.9")
- `max_aucinf_pext` - Max % extrapolation for AUCinf (default "20")
- `first_tmax` - Use first Tmax if tied: `"true"` (default) or `"false"`

**Preferred Output Units** (label only — changes the unit string in the response but does NOT convert numeric values):
- `conc_unit_out` - Preferred output concentration unit label
- `time_unit_out` - Preferred output time unit label

**File-based input (from /DATA endpoint)**:
- `data_file` - ADPC CSV filename in /data (output from /DATA or /LIBRARY endpoints); when provided, reads time/conc/dose/subject_id from file, overrides time/conc/dose string params (string, optional, default "")
  - When `data_file` is set, the response includes `"source_file": "<filename>"` and runs in population mode automatically
  - The ADPC file must have columns: USUBJID, ATPTN, AVAL, DOSE (standard /DATA output)
  - **Multi-drug grouping**: an optional `DRUG` column lets one file hold many drugs. `ROUTE` and
    `AVALU` are then read **per subject**, so a single dataset can mix routes (IV + extravascular) and
    concentration units across drugs. `ROUTE` may be string or the numeric codes `1`/`2`/`3` (per row).
    The response gains `n_drugs` and a `summary_by_drug` block (mean±SD Cmax/Tmax/auclast/half-life per
    drug with that drug's route/units), and each `individual_results` entry is tagged with `drug` +
    `route`. This is the `/LIBRARY` `mode=benchmark` → `/NCA` workflow. Note `DRUG` and `USUBJID` are
    independent (USUBJID delimits each profile, DRUG is the grouping label) — they need not match.
    Without a `DRUG` column, behavior is unchanged (single route, `summary_by_dose` only).

- **Multi-subject mode**: Use pipe (`|`) separator between subjects for time, conc, dose
- **Returns**: All parameters include value/unit pairs with analysis settings:
  ```json
  {
    "mode": "single",
    "analysis_settings": {
      "route": "iv_bolus",
      "dosing_scenario": "single",
      "auc_method": "lin up/log down",
      "blq_handling": {"first": "keep", "middle": "drop", "last": "keep"},
      "min_hl_points": 3,
      "min_hl_r_squared": 0.9,
      "max_aucinf_pext": 20
    },
    "input_units": {"time": "h", "concentration": "ug/mL", "dose": "mg"},
    "dose_administered": {"value": 100, "unit": "mg"},
    "Cmax": {"value": 10.0, "unit": "ug/mL"},
    "Tmax": {"value": 0.25, "unit": "h"},
    "auclast": {"value": 85.5, "unit": "h*ug/mL"},
    "half_life": {"value": 6.93, "unit": "h"},
    "results": {
      "cmax": {"value": 10.0, "unit": "ug/mL"},
      "lambda.z": {"value": 0.1, "unit": "1/h"},
      "cl.obs": {"value": 1.0, "unit": "L/h"},
      "vz.obs": {"value": 10.0, "unit": "L"},
      "r.squared": {"value": 0.995, "unit": null},
      "pext.obs": {"value": 15.0, "unit": "%"}
    }
  }
  ```
- **Weight-based dosing**: When `dose_unit="mg/kg"`, the effective dose (mg) is calculated as `dose * BW` before passing to PKNCA
- **Uses**: PKNCA library with automatic interval calculation

**Unit handling**: PKNCA performs all calculations using input data as-is (no internal unit conversion). Numeric values returned are in the units implied by the input `time_unit` and `conc_unit`. Unit **labels** are derived via pattern matching in `derive_param_unit()` (`pknca_units.R`) and attached to each result. No numeric conversion is performed — these are labels only.

**Unit Label Derivation Rules**:
| Parameter | Derived Label | Example |
|-----------|--------------|---------|
| Cmax | `conc_unit` | ug/mL |
| Tmax | `time_unit` | h |
| AUC | `time_unit*conc_unit` | h*ug/mL |
| half_life | `time_unit` | h |
| lambda_z | `1/time_unit` | 1/h |
| CL | `L/time_unit` when the reduction is exact, else `dose_unit/(time_unit*conc_unit)` | L/h (ug/mL); mg/(h*ng/mL) (ng/mL) |
| Vz | `L` when the reduction is exact, else `dose_unit/conc_unit` | L (ug/mL); mg/ng/mL (ng/mL) |
| pext | `%` | % |
| r.squared | (dimensionless) | null |

**CL / Vz exact reduction**: `reduce_dose_conc_to_volume()` (`pknca_units.R`) simplifies the
composite label to litres **only when the reduction is exact** — a mg dose with `ug/mL` or `mg/L`
concentrations, since `ug/mL` is numerically identical to `mg/L` and mg/(mg/L) = L. `mg/kg` counts
as mg (the effective dose is converted before PKNCA). Every other concentration unit keeps the
composite: `ng/mL` would land on 10³ L, `g/L` on mL, and `umol/L`/`nmol/L` cannot reduce without a
molecular weight. **No numeric conversion is performed in either case** — a CL of 0.216 labelled
`L/h` is the same number that was previously mislabelled `mL/h`. `individual_results` and
`summary_by_dose`/`summary_by_drug` both derive from this one function, so their labels always agree.

**Note**: `create_pknca_units()` in `pknca_units.R` is defined but not called by the NCA endpoint — PKNCA's native unit conversion is not used.

**Example API calls**:
```bash
# Default units (extravascular, single dose)
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,1,2,4,8' \
  -d 'conc=10,8,5,2,1' \
  -d 'dose=100'

# IV bolus single dose
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,0.25,0.5,1,2,4,8,12,24' \
  -d 'conc=100,90,80,65,45,25,12,6,1.5' \
  -d 'dose=100' \
  -d 'route=iv_bolus'

# IV infusion
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,0.5,1,2,4,8,12,24' \
  -d 'conc=0,50,100,80,50,25,12,3' \
  -d 'dose=100' \
  -d 'route=iv_infusion' \
  -d 'infusion_duration=1'

# Extravascular with repeat dosing
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,1,2,4,8,12,24,25,26,28,32,36,48' \
  -d 'conc=0,5,10,15,12,8,4,9,14,18,14,10,5' \
  -d 'dose=50' \
  -d 'route=extravascular' \
  -d 'dosing_scenario=repeat' \
  -d 'tau=24'

# Custom business rules
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,1,2,4,8,12,24' \
  -d 'conc=10,8,6,4,2,1,0.25' \
  -d 'dose=100' \
  -d 'auc_method=linear' \
  -d 'min_hl_points=4' \
  -d 'min_hl_r_squared=0.95'

# Weight-based dosing (mg/kg)
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,1,2,4,8' \
  -d 'conc=10,8,5,2,1' \
  -d 'dose=1.5' \
  -d 'dose_unit=mg/kg' \
  -d 'BW=70'
```

### POST /ER (Exposure-Response)
- **Required params**: `exposure`, `resp` (comma-separated numeric strings, have defaults for Swagger UI)
- **Optional params**: `model` ("auto", "linear", "emax", "imax", "logit")
- **Response generation params** (alternative to providing `resp` directly):
  - `resp_rate` - Comma-separated target response rates per dose group (e.g., `"0.1,0.5,0.9"`). When provided with `dose`, generates binary (0/1) responses from these rates using `rbinom()`. Overrides `resp`.
  - `seed` - Random seed for reproducible response generation (default: `"42"`). Only used when `resp_rate` is provided.
- **Plot customization params**:
  - `auc_unit` - AUC unit label for x-axis (default: "h*ug/mL") — **display label only**, no validation or numeric conversion
  - `figure_dir` - Output directory for figures (default: "/figures")
- **Unit handling**: No unit validation or conversion. `auc_unit` is used solely as a plot axis label. Response values are treated as unitless.
- **Model selection**: Auto mode selects best model by AIC
- **Returns**: Best model parameters, fit statistics (AIC, R²), plot path, all fitted models. When `resp_rate` is used, also returns `resp_rate_generation` with the rates, seed, and generated binary responses.
- **Plot output**: `/figures/ER_YYYYMMDD_HHMMSS.png`

### POST /PK (Pharmacokinetic Simulation)
Supports three modes:
1. **Single-subject**: Single values for dose, CL, V1, etc.
2. **Multi-subject (explicit)**: Comma-separated CL, V1, etc. for each subject
3. **Population (TV + BSV)**: Use n_subjects with typical values and CV for between-subject variability

**All modes use per-kg values** (scaled by BW internally):
- `dose` - Dose amount(s) in mg, comma-separated
- `CL` - Clearance per kg in mL/h/kg (default "0.15" - Betts 2018)
- `V1` - Central volume per kg in mL/kg (default "46.31" - Betts 2018)
- `V2` - Peripheral volume per kg in mL/kg (default 31.47 - Betts 2018, optional for 2CM)
- `Q` - Intercompartmental clearance per kg in mL/h/kg (default 0.27 - Betts 2018, optional for 2CM)
- `BW` - Body weight in kg (default "70")
- `t` - Time points, comma-separated
- `model` - "auto", "1cm", or "2cm"

**Population mode additional params**:
- `n_subjects` - Number of subjects (triggers population mode)
- `cv` - Coefficient of variation for BSV (default "0.30" = 30%)
- `seed` - Random seed for reproducibility

**Plot customization params** (all modes):
- `time_unit` - Time unit for plot display: "auto", "hours", "days", or "weeks" (default: "auto")
  - Auto-selects based on time range: >168h → weeks, >24h → days, else hours
  - Time conversion is for **plot display only**; API response always reports time in hours
- `conc_unit` - Concentration unit for output and plot y-axis (default: "ug/mL")
- `figure_dir` - Output directory for figures (default: "/figures")

**CSV output params** (for DATA → NCA workflow):
- `save_csv` - If `"true"`, saves simulated concentration-time data as CSV to `output_dir` (default: `"false"`)
- `output_dir` - Output directory for CSV file (default: `"/data"`)
  - CSV columns: `USUBJID, TIME, CONC, DOSE, CONC_UNIT`
  - Response gains: `"output_file": "pk_simulation_TIMESTAMP.csv"` when `save_csv=true`
  - The CSV is compatible with `/DATA` (use `subject_col="USUBJID"`, `conc_col="CONC"`, `dose_col="DOSE"`)

**Unit handling**: mrgsolve models output concentrations in **mg/mL** (dose in mg ÷ volume in mL). A conversion factor from `get_conc_conversion_factor()` in `plotting.R` is applied to **both** the returned concentration values and the plot:
| `conc_unit` | Factor | Conversion |
|-------------|--------|------------|
| `ug/mL` | ×1000 | mg → ug |
| `ng/mL` | ×1,000,000 | mg → ng |
| `mg/mL` | ×1 | no conversion |
| `mg/L` | ×1000 | 1 mg/mL = 1000 mg/L |
| `g/L` | ×1 | 1 mg/mL = 0.001 g/mL = 1 g/L |
| `g/mL` | ×0.001 | mg → g |

PK parameters (CL, V1, V2, Q) are accepted as **per-kg values** and scaled by `BW` before simulation. Individual PK params in the response are returned as **absolute values** (mL/h, mL) without unit labels. Dose is always in **mg** (no mg/kg support in PK endpoint).

**Returns**: Simulated concentration-time profiles (converted to `conc_unit`), model type, individual PK params, summary by dose, plot path
- **Plot output**: `/figures/PK_YYYYMMDD_HHMMSS.png` (log-scale y-axis)

**Population mode example**:
```bash
curl -X POST http://localhost:5762/PK \
  -d 'n_subjects=30' \
  -d 'dose=10,30,100' \
  -d 'CL=0.15' \
  -d 'V1=46.31' \
  -d 'cv=0.25' \
  -d 'BW=70' \
  -d 't=0,1,2,4,8,12,24,48,168,336' \
  -d 'seed=42' \
  -d 'time_unit=weeks' \
  -d 'conc_unit=ug/mL'
```

### POST /DATA (Data Standardization)
Reads raw PK data files (CSV or Excel) from `/data` volume, standardizes to CDISC ADaM ADPC-aligned format, and saves output CSV for downstream use by `/NCA`.

- **Required params**: `file_path` - filename within `/data` directory (e.g. `"study.csv"`)
- **Dataset type**:
  - `dataset_type` - Processing type: `"adpc"` (default, v1). Future: `"nonmem_pk"` (v2)
- **Column mapping** (customize to match your input file):
  - `subject_col` - Column for subject ID (default `"ID"`)
  - `time_col` - Column for nominal time (default `"TIME"`)
  - `conc_col` - Column for concentration (default `"DV"`)
  - `dose_col` - Column for dose (default `"AMT"`); first non-zero per subject
  - `blq_col` - Column for BLQ flag (string, optional)
- **Dose fallback**: `dose` - Fallback dose if `dose_col` absent or all-zero (default `"1"`)
- **Output metadata**:
  - `conc_unit` - Concentration unit label for AVALU column (default `"ug/mL"`)
  - `dose_unit` - Dose unit label for DOSEU column (default `"mg"`)
  - `route` - Route for ROUTE column (default `"extravascular"`)
  - `output_prefix` - Output filename prefix; default uses input filename stem

**NONMEM AMT-style detection**: If the dose column contains a mix of zero and non-zero values, dosing event rows (AMT > 0) are filtered out and only observation rows (AMT = 0) are kept. If the dose column has non-zero values only (e.g., PK simulation output with DOSE column), all rows are kept.

**Returns**:
```json
{
  "status": "success",
  "dataset_type": "adpc",
  "source_file": "study.csv",
  "output_file": "study_adpc_20260228_123456.csv",
  "n_subjects": 3,
  "n_records": 24,
  "columns": ["USUBJID","ATPTN","AVAL","AVALU","DOSE","DOSEU","DOSNO","ROUTE","BLQ"],
  "input_column_mapping": {"subject_col":"ID","time_col":"TIME","conc_col":"DV","dose_col":"AMT","blq_col":"(none)"},
  "summary": {"subjects":[...],"time_range":[0,24],"conc_range":[0.1,10],"dose_per_subject":{"1":100}}
}
```

**PK → DATA → NCA workflow**:
```bash
# Step 1: PK simulation saves CSV to /data
curl -X POST http://localhost:5762/PK \
  -d 'dose=10,30,100' -d 'n_subjects=60' -d 'n_per_dose=20' \
  -d 'seed=42' -d 'save_csv=true'
# → output_file: "pk_simulation_20260228_123456.csv"

# Step 2: DATA standardizes PK CSV to ADPC (column names differ from NONMEM defaults)
curl -X POST http://localhost:5762/DATA \
  -d 'file_path=pk_simulation_20260228_123456.csv' \
  -d 'subject_col=USUBJID' -d 'conc_col=CONC' -d 'dose_col=DOSE' \
  -d 'route=iv_bolus'
# → output_file: "pk_simulation_20260228_123456_adpc_20260228_123500.csv"

# Step 3: NCA reads ADPC file directly (population mode automatic)
curl -X POST http://localhost:5762/NCA \
  -d 'data_file=pk_simulation_20260228_123456_adpc_20260228_123500.csv' \
  -d 'route=iv_bolus'
```

**Error messages** (actionable):
- File not found: `"File not found: 'study.csv'. Available in /data: example_pk_data.csv"`
- Wrong column: `"Column 'CONC' not found. Available: ID, TIME, DV, AMT. Use conc_col parameter to specify the correct column name."`
- Unsupported type: `"Unsupported dataset_type 'nonmem_pk'. Supported in v1: 'adpc'. PopPK support coming in v2."`

### POST /LIBRARY (Model Library — list, simulate & benchmark)
Wraps the **`nlmixr2lib`** literature model library to (a) list available human PK models, (b)
simulate concentration-time profiles from a named model, and (c) **benchmark** — simulate *many*
models into a single multi-drug ADPC CSV. All emit ADPC-compatible CSV(s) that feed the `/NCA`
`data_file` workflow directly. `nlmixr2lib` is installed from GitHub **pinned to a commit SHA** (see
`docker/Dockerfile.rapi`, `NLMIXR2LIB_SHA`) so simulated "ground truth" datasets stay reproducible
(CRAN lags far behind). Depends on `rxode2` + `nlmixr2est` (+ `qs2`); these compile native ODE code, so
`Dockerfile.rapi` adds `cmake`/`gmp`/`mpfr` system deps.

- **Required**: `mode` — `"list"` (default), `"simulate"`, or `"benchmark"`.
- **Simulate params**:
  - `model_name` — model name from the library (required for simulate; discover via `mode=list`)
  - `dose` — dose amount(s) in mg, comma-separated for multiple dose groups (default `"100"`)
  - `n_subjects` — population size (default `"20"`)
  - `seed` — random seed (default `"42"`)
  - `conc_unit` / `dose_unit` — unit **labels** for output/AVALU/DOSEU (default `"ug/mL"` / `"mg"`)
  - `time_unit` — plot display unit: auto/hours/days/weeks (default `"auto"`)
  - `covariates` — overrides for models that require covariates, e.g. `"WT=70,CRCL=90"` (default `""`)
  - `route_override` — force iv_bolus/iv_infusion/extravascular (default `""`, auto-detected)
  - `times_override` — custom comma-separated sampling times in hours (default `""`)
  - `save_csv` — write the ADPC CSV (default `"true"`); `output_dir` (default `/data`), `figure_dir` (default `/figures`)
- **List params**: `category_filter` — optional substring filter on model category.
- **Benchmark params** (`mode="benchmark"`): generate **one combined multi-drug ADPC CSV** (with a
  `DRUG` grouping column) for NCA benchmarking:
  - `models` — `"all"`/`"auto"` (clean deduplicated set via `select_benchmark_models()`) or an explicit
    comma-separated list (default `"all"`)
  - `output_profile` — `"mean"` (one representative profile/drug, default), `"individual"` (N patients),
    or `"both"`
  - `mean_type` — `"geometric"` (default; `exp(mean(log Cc))` per timepoint), `"arithmetic"`, or
    `"typical"` (deterministic eta=0 profile)
  - `scope` — `"standard"` (default, linear 1–2CM only; excludes TMDD, nonlinear, 3-compartment) or
    `"wide"` (casts a broader net: includes TMDD, Michaelis-Menten/nonlinear elimination, 3-compartment
    models, and PK-PD coupled models — any model where a PK concentration profile `Cc` can be simulated).
    Endogenous-baseline and non-eliminating models are excluded in both scopes (no clean NCA terminal phase).
  - `output_file` — fixed output CSV filename (default `""` → timestamped); `append` — `"true"` to
    merge/resume into an existing file (default `"false"`)
  - `route_format` — `ROUTE` column encoding in the CSV: `"string"` (default, `iv_bolus`/`extravascular`)
    or `"numeric"` (`1`=iv_bolus, `2`=extravascular, `3`=iv_infusion, e.g. for PKanalix). `/NCA` accepts
    either encoding.
  - reuses `dose`, `n_subjects`, `seed`, `dose_unit`, `output_dir`. Each model gets a deterministic seed
    (`base_seed + stable_index`) so output is identical regardless of how a run is chunked.
  - **Column identity**: `USUBJID` = full model reference (e.g. `Li_2006_meropenem`), `DRUG` = drug name
    (e.g. `meropenem`, via `library_drug_name()`; generic `PK_*` templates kept as-is). Stripping the
    `Author_Year_` prefix preserves all 151 drugs as unique; the full reference in `USUBJID` keeps each
    profile traceable to its source model.

**How simulate works** (`apis/models/nlmixr2lib_sim.R`, `apis/utils/library_utils.R`):
1. `modellib(name)` returns a model **function**; `rxode2::rxode2()` compiles it to an rxUi (exposing
   `$omega` = published BSV, `$allCovs` = required covariates).
2. Terminal half-life is estimated **numerically** from a typical-value (eta=0) probe simulation
   (`probe_model()` → `fit_terminal_half_life()`) — structure-agnostic, not by parsing theta names.
3. `assign_tier()` + `build_sampling_schedule()` derive a half-life-scaled sampling grid
   (early absolute points + log-spaced multiples out to ~5×t½).
4. `simulate_library_population()` runs `rxSolve(nSub=N, omega=<published>, params=<ref covariates>)`,
   reads the BSV-only concentration variable **`Cc`** (never the residual-bearing `sim`), and returns
   a long data frame. **BSV-only** ground truth (no residual error added). Reproducible: `rxSetSeed()` + `cores=1`.
5. The endpoint writes the standard ADPC columns (`USUBJID, ATPTN, AVAL, AVALU, DOSE, DOSEU, DOSNO,
   ROUTE, BLQ`) so `/NCA` ingests the CSV directly.

**How benchmark works** (`library_benchmark_mode()` + `.library_simulate_core()` in
`apis/endpoints/library.R`): resolves the model list, then per model (inside a `tryCatch` so one
failure never aborts the batch) reuses the simulate stack, normalizes **time to hours** via
`extract_model_units()` + `time_to_hours_factor()`, collapses the N-subject population to one
geometric-mean profile, tags rows with `DRUG`/`ROUTE`/native `AVALU`, and accumulates into one CSV.
The `ROUTE` is assigned **empirically from the simulated profile** (`empirical_route()`): the eta=0
profile's Tmax decides it — a peak at the dose → `iv_bolus`; a profile that starts ~0 and rises to a
later peak (absorption / lag) → `extravascular` — so the route always matches the data (and is robust to
the rxode2 dose-time pre-dose-0 artifact for fast IV drugs). The dose itself goes into the structural
compartment from `detect_route()` (depot when present, else central); `route_override` forces both.
Post-compile guards keep it clean: models compiling to `>2` disposition compartments, with an implausible
terminal half-life (`> LIBRARY_MAX_HALF_LIFE_H = 4380 h`, endogenous-baseline / non-eliminating), an
endogenous baseline, or nonlinear (dose-disproportionate) elimination are skipped and reported in the
manifest `failures[]`.

**Catalog filtering** (`filter_pk_models()`): primary include = catalog `DV == "Cc"` (concentration
output = PK); then drops, with a per-row `exclude_reason`: `algebraic` (MBMA/cellular-kinetic/disease
models flagged in the catalog `algebraic` column), `gt_2cmt` / `gt_2cmt_desc` (3-compartment by name
**or description**), `tmdd`, `multi_analyte` (ADC), `indirect_response` (indirect-response PD
templates), `non_human` (rat/mouse/sheep/… by name or filename), `combination` (multi-drug names), and
`null_route` (no dosing info). Route is read from the catalog `dosing` column (depot present →
extravascular). `select_benchmark_models()` then restricts to `iv_bolus`/`extravascular` and
deduplicates to one model per drug (latest publication `year`; literature models collapse on the first
drug token, generics keep their full stem).

**Covariates**: literature models often require covariates (e.g. WT, CRCL, AGE). Resolution order:
user `covariates=` → reference adult defaults in `LIBRARY_REF_COVARIATES` (reported as
`covariates_defaulted`) → categorical/indicator covariates matching `LIBRARY_CATEGORICAL_COV_PATTERN`
default to **0 = the reference category** (reported as `covariates_zeroed`). A required *continuous*
covariate with no default raises an actionable error (the model is skipped in benchmark mode).

**Units caveat**: concentration numeric values stay in the model's **native** units, carried per drug
in the `AVALU` column (label only, no numeric conversion). **Time IS normalized to hours** in
simulate/benchmark output using each model's native time unit (e.g. day→×24, minute→×1/60), so `ATPTN`
and reported half-lives are in hours and comparable across drugs.

**Returns** (simulate): `model_info` (route, n_compartments, conc_output_var, terminal_half_life,
tier), `simulation_settings` (doses, sampling_times_h, observation_window_h, bsv_source,
covariates_applied/defaulted, seed), `parameters` (typical CL/Vc/Q/Vp/Ka), `summary_stats` per dose
group (mean±SD profile, Cmax/Tmax), `output_files` (`csv` filename in /data, `plot` path in /figures).
**Returns** (list): `n_models`, `models[]` (name, category, route, n_compartments, description),
`excluded_count`, `excluded_reasons`, `pinned_commit`.
**Returns** (benchmark): `n_models_included`, `n_failed`, `n_drugs`, `n_rows`, `output_files.csv`,
`failures[]` (name + error), and a per-model `manifest[]` (route, n_compartments, native_time_unit,
terminal_half_life_h, tier, AVALU, n_cov_defaulted/zeroed, bsv_source).

**MCP tool name**: `r_Model_library_simulate_or_list` (mapped in `server.py` `ENDPOINT_TOOL_NAMES`).

**Example calls**:
```bash
# List available PK models
curl -X POST http://localhost:5762/LIBRARY -d 'mode=list'

# Simulate an IV 2-compartment literature model (published BSV + reference covariates)
curl -X POST http://localhost:5762/LIBRARY \
  -d 'mode=simulate' -d 'model_name=Li_2006_meropenem' \
  -d 'dose=500,1000' -d 'n_subjects=20' -d 'seed=42'

# Build the standard NCA benchmark dataset (linear 1-2CM only, ~130-150 models).
curl -X POST http://localhost:5762/LIBRARY \
  -d 'mode=benchmark' -d 'models=all' -d 'output_profile=mean' -d 'mean_type=geometric' \
  -d 'n_subjects=50' -d 'seed=42' -d 'output_file=nca_benchmark.csv'

# Build the wide NCA benchmark dataset (includes TMDD, nonlinear, 3CM; scope=wide).
# Run against the R API directly (not MCP) to avoid client timeout; may take longer than standard.
curl -X POST http://localhost:5762/LIBRARY \
  -d 'mode=benchmark' -d 'scope=wide' -d 'models=all' -d 'output_profile=mean' \
  -d 'mean_type=geometric' -d 'n_subjects=50' -d 'seed=42' \
  -d 'output_file=nca_benchmark_wide.csv'

# Analyze ALL drugs at once (groups by DRUG, per-drug route/units) -> summary_by_drug
curl -X POST http://localhost:5762/NCA -d 'data_file=nca_benchmark.csv'
```

## Code Conventions

### R API Structure
- **Separation of concerns**: Endpoints handle HTTP, models do calculations, utils provide shared functionality
- **Endpoint files** are self-contained modules with Plumber annotations (#*), library imports, and source dependencies
- **Model files** contain pure R functions with no Plumber dependencies
- **Main router** (`apis/rapi.R`) uses `copy_routes()` helper to compose endpoint modules:
  - Each endpoint file sources its own dependencies (utils, models)
  - Routes are copied to main router to preserve `/NCA`, `/ER`, `/PK`, `/DATA` paths and OpenAPI metadata

### R API Parameters
- All numeric inputs passed as strings and parsed with `as.numeric()`
- Comma-separated lists parsed with `strsplit(x, ",")[[1]]`
- Error handling with `tryCatch` wrapping endpoint functions
- Use validation functions from `utils/validation.R`:
  - `validate_numeric_vector()` - Check vector validity
  - `validate_pk_data()` - Validate time/concentration pairs
  - `validate_dose()` - Check dose is positive
  - `validate_pk_params()` - Validate PK parameters
  - `validate_nca_units()` - Validate NCA unit parameters (dose_unit, conc_unit, time_unit)
  - `normalize_time_unit()` - Normalize time unit variants (e.g., "hr" → "h")
- Plumber annotations use `#*` prefix in endpoint files only

### Plot Generation
- Use `save_pmx_plot()` from `utils/plotting.R`
- Plots automatically saved to `/figures/` with timestamp naming
- Standard size defined in `utils/constants.R` (6x4 inches, 300 DPI)
- Use `get_pmx_theme()` for consistent ggplot2 styling
- Return plot path in response JSON

### Python MCP Server
- Environment variable `RAPI_OPENAPI_URL` for R API location (defaults to http://localhost:5762/openapi.json)
- Detailed logging at DEBUG level for troubleshooting
- All endpoints automatically exposed as MCP tools via OpenAPI spec

### Testing
- **Python tests** (`tests/test_endpoints.py`): Integration tests via MCP client
- **R tests** (`apis/tests/*.R`): Unit tests for model functions with ground truth validation
- All new endpoints must include tests
- Tests run in CI via GitHub Actions

## Repository Structure

```
├── apis/
│   ├── rapi.R              # Main router - sources all modules
│   ├── endpoints/          # Plumber endpoint handlers
│   │   ├── nca.R          # NCA endpoint (#* annotations)
│   │   ├── er.R           # ER endpoint (#* annotations)
│   │   ├── pk.R           # PK endpoint (#* annotations)
│   │   ├── data.R         # DATA endpoint (#* annotations)
│   │   └── library.R      # LIBRARY endpoint (#* annotations)
│   ├── models/            # Pure R calculation functions
│   │   ├── mrgsolve_pk.R  # simulate_1cm(), simulate_2cm()
│   │   ├── er_models.R    # fit_*_model() functions
│   │   ├── nlmixr2lib_sim.R # nlmixr2lib load + rxode2 population simulation
│   │   ├── 1CM.cpp        # mrgsolve 1-compartment model
│   │   └── 2CM.cpp        # mrgsolve 2-compartment model
│   ├── utils/             # Shared utilities
│   │   ├── constants.R    # Configuration constants
│   │   ├── validation.R   # Input validation functions
│   │   ├── units.R        # NCA unit derivation and formatting
│   │   ├── colors.R       # Color scheme utilities
│   │   ├── plotting.R     # Plot utilities
│   │   ├── data_processing.R # Data reading, cleaning, ADPC standardization
│   │   └── library_utils.R # Tier/schedule + catalog filtering for /LIBRARY
│   └── tests/             # R unit tests
│       ├── test_nca.R     # NCA ground truth validation
│       ├── test_pk_models.R # PK model unit tests
│       └── test_library_models.R # /LIBRARY pure-helper unit tests
├── tests/                  # Python integration tests
│   ├── conftest.py        # Shared fixtures and helpers
│   ├── test_endpoints.py  # MCP endpoint tests
│   ├── test_library_endpoint.py # /LIBRARY integration tests
│   ├── test_validation.py # Input validation tests
│   └── fixtures/          # Test fixture files (auto-copied to data/ before test runs)
│       └── example_pk_data.csv # Example 3-subject NONMEM-style PK data
├── data/                   # Bind-mounted into rapi at /data/ — runtime-populated, contents gitignored
│   └── .gitkeep           # Keeps folder tracked; contents ignored
├── figures/                # Bind-mounted into rapi at /figures/ — generated plots, contents gitignored
│   └── .gitkeep           # Keeps folder tracked; contents ignored
├── docker/                 # Container build files
│   ├── Dockerfile.rapi    # R API container
│   ├── Dockerfile.mcp     # Python MCP server container
│   └── r-packages.txt     # R package install list
├── CLA.md                  # Contributor License Agreement
├── server.py              # FastMCP MCP server entry point
├── docker-compose.yml     # Container orchestration
├── .dockerignore          # Build context exclusions
├── pytest.ini             # Pytest configuration
├── requirements-dev.txt   # Test dependencies
├── .github/workflows/     # CI/CD
│   └── test.yml          # GitHub Actions tests
├── CONTRIBUTING.md        # Contribution guidelines
└── CITATION.cff          # Citation metadata
```

## Adding New Endpoints

To add a new pharmacometric endpoint:

1. **Create model function** in `apis/models/your_model.R`:
   ```r
   calculate_something <- function(param1, param2) {
     # Pure calculation logic
     return(result)
   }
   ```

2. **Create self-contained endpoint** in `apis/endpoints/your_endpoint.R`:
   ```r
   # endpoints/your_endpoint.R
   # Description of endpoint

   # Dependencies - each endpoint sources its own requirements
   library(ggplot2)  # if needed
   source("utils/constants.R")
   source("utils/validation.R")
   source("utils/plotting.R")  # if generating plots
   source("models/your_model.R")

   #* Your Endpoint Description
   #* @param param1 Description
   #* @post /YourEndpoint
   #* @serializer unboxedJSON
   function(param1, param2) {
     tryCatch({
       validate_string_input(param1, "param1")
       result <- calculate_something(param1, param2)
       return(list(result = result))
     }, error = function(e) {
       stop(sprintf("Failed: %s", e$message))
     })
   }
   ```

3. **Add to router** (`apis/rapi.R`):
   ```r
   #* @plumber
   function(pr) {
     # ... existing endpoint routers ...
     your_router <- plumb("endpoints/your_endpoint.R")

     # ... existing copy_routes calls ...
     pr <- copy_routes(pr, your_router)

     pr
   }
   ```

4. **Add tests** in `tests/test_endpoints.py` and `apis/tests/test_your_model.R`

5. **Rebuild and test**:
   ```bash
   docker compose up --build
   pytest tests/test_endpoints.py -v
   ```
