# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

PMxAgent transforms validated R pharmacometric workflows into AI-ready HTTP APIs. The architecture consists of:
- **R Plumber API** (modular structure in `apis/`): Pharmacometric endpoints (NCA, ER, PK)
  - `apis/rapi.R` - Lightweight router using `copy_routes()` helper to compose endpoint modules
  - `apis/endpoints/` - Self-contained endpoint modules with Plumber annotations and dependencies
  - `apis/models/` - Core pharmacometric calculation functions
  - `apis/utils/` - Shared utilities (validation, plotting, constants)
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
- MCP SSE endpoint: http://localhost:8000/messages

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
6. MCP server exposes tools on port 8000 via SSE transport at `/messages`

### Key Components

**R API (Modular Structure)**
- **Main Router** (`apis/rapi.R`): Uses `copy_routes()` helper to compose endpoint modules at root path
- **Endpoints** (`apis/endpoints/*.R`): Self-contained modules with Plumber annotations, library imports, and source dependencies
  - `nca.R` - Non-compartmental analysis endpoint (uses PKNCA)
  - `er.R` - Exposure-response modeling endpoint (uses ggplot2, er_models)
  - `pk.R` - PK simulation endpoint (uses ggplot2, pk_models)
- **Models** (`apis/models/*.R`): Pure R functions for calculations
  - `mrgsolve_pk.R` - mrgsolve-based 1CM and 2CM model simulations (simulate_1cm(), simulate_2cm())
  - `er_models.R` - Linear, Emax, Imax, logit model fitting
- **Utilities** (`apis/utils/*.R`): Shared functions and constants
  - `validation.R` - Input validation and error checking (includes route, dosing scenario, BLQ, business rules validators)
  - `plotting.R` - Standardized plot generation and saving
  - `constants.R` - Configuration constants (plot settings, bounds, limits, unit rules, NCA settings)
  - `units.R` - Unit label derivation and formatting for NCA parameters (`derive_nca_unit()` forwards to `derive_param_unit()`; `calculate_effective_dose()` for mg/kg; `format_value_unit()` and `format_nca_results_with_units()` for response formatting)
  - `pknca_units.R` - PKNCA route mapping (`map_route_to_pknca()`), interval creation (`create_nca_intervals()`), options management (`set_pknca_options()`/`reset_pknca_options()`), unit label derivation (`derive_param_unit()`), result extraction (`extract_results_with_units()`). Note: `create_pknca_units()` is defined but not called by the NCA endpoint
  - `colors.R` - Color scheme utilities for consistent plotting
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
- SSE transport for MCP communication
- Base URL parsing from RAPI_OPENAPI_URL environment variable

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
- `route` - `"iv_bolus"`, `"iv_infusion"`, or `"extravascular"` (default)
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
      "cl.obs": {"value": 1000, "unit": "mL/h"},
      "vz.obs": {"value": 10000, "unit": "mL"},
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
| CL | `mL/time_unit` | mL/h |
| Vz | `mL` | mL |
| pext | `%` | % |
| r.squared | (dimensionless) | null |

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

## Code Conventions

### R API Structure
- **Separation of concerns**: Endpoints handle HTTP, models do calculations, utils provide shared functionality
- **Endpoint files** are self-contained modules with Plumber annotations (#*), library imports, and source dependencies
- **Model files** contain pure R functions with no Plumber dependencies
- **Main router** (`apis/rapi.R`) uses `copy_routes()` helper to compose endpoint modules:
  - Each endpoint file sources its own dependencies (utils, models)
  - Routes are copied to main router to preserve `/NCA`, `/ER`, `/PK` paths and OpenAPI metadata

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
│   ├── rapi.R.backup       # Original monolithic file (backup)
│   ├── endpoints/          # Plumber endpoint handlers
│   │   ├── nca.R          # NCA endpoint (#* annotations)
│   │   ├── er.R           # ER endpoint (#* annotations)
│   │   └── pk.R           # PK endpoint (#* annotations)
│   ├── models/            # Pure R calculation functions
│   │   ├── mrgsolve_pk.R  # simulate_1cm(), simulate_2cm()
│   │   └── er_models.R    # fit_*_model() functions
│   ├── utils/             # Shared utilities
│   │   ├── constants.R    # Configuration constants
│   │   ├── validation.R   # Input validation functions
│   │   ├── units.R        # NCA unit derivation and formatting
│   │   ├── colors.R       # Color scheme utilities
│   │   └── plotting.R     # Plot utilities
│   └── tests/             # R unit tests
│       ├── test_nca.R     # NCA ground truth validation
│       └── test_pk_models.R # PK model unit tests
├── tests/                  # Python integration tests
│   └── test_endpoints.py  # MCP client tests
├── examples/               # Usage examples and guides
│   ├── basic_usage.py     # Python client examples
│   ├── basic_usage.sh     # Curl examples
│   ├── cursor_setup.md    # Cursor MCP configuration
│   └── claude_desktop_setup.md # Claude Desktop configuration
├── figures/                # Generated plot outputs
├── server.py              # FastMCP MCP server entry point
├── docker-compose.yml     # Container orchestration
├── Dockerfile.rapi        # R API container
├── Dockerfile.mcp         # Python MCP server container
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
