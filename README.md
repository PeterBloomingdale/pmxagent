# PMxAgent: An Agentic Platform for Pharmacometrics

**Transform your existing R-based pharmacometrics workflow into AI agent-callable tools.**


[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)](https://www.docker.com/)
[![R](https://img.shields.io/badge/r-%23276DC3.svg?style=flat&logo=r&logoColor=white)](https://www.r-project.org/)
[![Python](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/)
[![Tests](https://img.shields.io/badge/tests-62%20passing-brightgreen)](tests/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

---

## ⚡ Architecture at a Glance

```
                                PMxAgent
┌─────────────────────────────── Docker ──────────────────────────────────┐
│                                                                         │
│  ┌────────────────────┐                 ┌────────────────────┐          │
│  │   R Plumber API    │    OpenAPI      │   MCP Server (Host)│          │
│  │                    │────────────────▶│                    │          │
│  │   /NCA  /ER  /PK   │◀───────────────▶│      FastMCP       │          │
│  │   PKNCA, mrgsolve  │      HTTP       └──────────┬─────────┘          │
│  └────────────────────┘                            │                    │
└────────────────────────────────────────────────────┼────────────────────┘
                                                     │
                                                MCP Protocol
                                                     │
┌─────────────────────────── AI Agents (Clients) ────┼────────────────────┐
│                                                    │                    │
│   • Cursor                              ┌──────────▼──────────┐         │
│   • Claude Code                         │   Tool Discovery    │         │
│   • ChatGPT                             │   & Execution       │         │
│                                         └─────────────────────┘         │
└─────────────────────────────────────────────────────────────────────────┘
```
PMxAgent is an agentic platform for building custom pharmacometric agents and automation pipelines. PMxAgent's architecture consists of R functions exposed as RESTful API endpoints that are converted to agent-callable tools and wrapped by a model context protocol (MCP) server, all orchestrated via Docker.

---


## ✨ Why Use PMxAgent?

- **Stop digging through old scripts.** You made a beautiful ggplot figure 8 months ago. You remember it was perfect. You cannot find it. It's in a folder called "final_final_v3_REAL". PMxAgent turns your plotting code into discoverable tools. Never dig again.

- **The Gantt chart says "PopPK analysis" takes one day.** The Gantt chart was made by someone who thinks NONMEM is a person. It takes weeks. But with the right automation? Maybe that one-day box finally makes sense.

- **4:47 PM. Friday.** Slack: "Quick NCA before Monday 9am?" You type a prompt. Reply "Done." Leave at 5. The old you would've canceled dinner. The old you didn't have PMxAgent.

- **Check the AI box at year-end.** "Are you leveraging AI?" Yes. Yes you are. You're welcome.

- **Excel files from clin ops.** An email lands. There's an attachment. You open it. Column headers in row 47. Dates formatted as text. Patient IDs that are somehow negative. PMxAgent can standardize your data cleaning workflows too.

- **"Can we try a different color?"** Then dashed lines. Then dotted. Then "actually, can we go back to the original?" Then the legend needs to move. Then Comic Sans (they're joking... you hope). Standardize your figures once. Let the AI regenerate them forever. Your sanity is worth it.

**The boring-but-important stuff:**

- 🔒 **Reproducible** — Same inputs, same outputs. Every time.
- 📐 **Standardized** — Same functions, same figures, same style guide. Across your entire team.
- ✅ **Trustworthy** — Built on PKNCA and mrgsolve. Not a black box. You can read the R code.
- 🎯 **Accurate** — Validated against analytical solutions and ground truth.
- ⚡ **Efficient** — Setup in 60 seconds. Run analyses in minutes, not days.

---

## 🚀 Choose Your Launch Experience

### Option A: Agent Startup (60 seconds) 🤖

**Let Claude Code set up everything automatically.**

**Prerequisites:**
- ✅ [Docker Desktop](https://www.docker.com/) 4.0+ (running)
- ✅ [Claude Code](https://claude.com/claude-code) (latest version)
- ✅ Git
- ✅ Python 3.11+ (optional, for tests)

**Steps:**

1. Open Claude Code in your terminal:
   ```bash
   claude
   ```

2. **Copy-paste this prompt:**

```
I want to set up PMxAgent, an AI-ready pharmacometrics platform. Please:

1. Verify prerequisites: Docker Desktop is running, Git is installed
2. Clone the repository: git clone https://github.com/peterbloomingdale/PMxAgent.git
3. Navigate to the PMxAgent directory
4. Build and start PMxAgent: docker compose up --build -d
5. Wait 30 seconds for services to initialize
6. Verify container health: docker compose ps
7. Run the test suite to confirm everything works: pytest tests/ -v
8. Test PMxAgent's MCP endpoint to discover tools
9. Verify one tool call (NCA endpoint) works end-to-end
10. Show me the access URLs (Swagger UI and MCP endpoint)

Please proceed step-by-step, showing me the output of each command, and stop if any errors occur.
```

**What happens:** Claude Code executes the entire setup, verifies health, runs tests, discovers PMxAgent's MCP tools, and confirms all endpoints work. Total time: **~60 seconds**.

---

### Option B: Manual Setup (5 minutes) 🛠️

**Traditional command-line setup.**

**Prerequisites:**
- ✅ [Docker Desktop](https://www.docker.com/) 4.0+ (running)
- ✅ Git

**Steps:**

```bash
# Clone and start
git clone https://github.com/peterbloomingdale/PMxAgent.git
cd PMxAgent
docker compose up --build -d
```

**Verify it worked:**
```bash
docker compose ps  # Should show 2 containers healthy/running
curl http://localhost:5762/openapi.json  # Should return JSON
```


---

## 🎯 What Can PMxAgent Do?

PMxAgent provides three core pharmacometric endpoints accessible via HTTP API:

| Endpoint | Purpose | Key Features |
|----------|---------|--------------|
| `POST /NCA` | Non-compartmental analysis | Cmax, Tmax, AUC, half-life; multi-subject mode; automatic unit derivation |
| `POST /ER` | Exposure-response modeling | Auto-select best model by AIC; gold-standard two-panel visualization |
| `POST /PK` | PK simulation | 1- or 2-compartment IV; population mode with between-subject variability |

**Access PMxAgent:**
- **API Documentation & Testing:** [http://localhost:5762/__docs__/](http://localhost:5762/__docs__/)
- **OpenAPI Specification:** [http://localhost:5762/openapi.json](http://localhost:5762/openapi.json)
- **MCP Endpoint (for AI agents):** [http://localhost:8000/messages](http://localhost:8000/messages)

### Unit Handling

Unit handling differs across endpoints. Each endpoint's approach is described below.

#### `/NCA` — Input Validation and Unit Label Derivation

**Supported input units** (validated by `validate_nca_units()`):

| Category | Supported Values | Default |
|----------|-----------------|---------|
| Dose | `mg`, `mg/kg` | `mg` |
| Concentration | `ug/mL`, `ng/mL`, `mg/L`, `g/L`, `umol/L`, `nmol/L` | `ug/mL` |
| Time | `h`, `min`, `d` | `h` |

**Time unit normalization:** Common variants are automatically normalized (e.g., `hr` → `h`, `hours` → `h`, `day` → `d`, `days` → `d`).

**How it works:** PKNCA performs all NCA calculations using the input data as-is (no internal unit conversion). The numeric values returned (Cmax, AUC, CL, etc.) are in the units implied by your input `time_unit` and `conc_unit`. Unit **labels** are then derived via pattern matching in `derive_param_unit()` and attached to each result:

| Parameter | Derived Label | Example (default inputs) |
|-----------|--------------|--------------------------|
| Cmax | `conc_unit` | ug/mL |
| Tmax | `time_unit` | h |
| AUC | `time_unit*conc_unit` | h*ug/mL |
| half_life | `time_unit` | h |
| lambda_z | `1/time_unit` | 1/h |
| Clearance | `mL/time_unit` | mL/h |
| Volume (Vz) | `mL` (fixed) | mL |
| pext | `%` | % |
| r.squared | dimensionless | null |

**Weight-based dosing:** When `dose_unit="mg/kg"`, the effective dose is calculated as `dose (mg/kg) × BW (kg)` before being passed to PKNCA. The `BW` parameter defaults to 70 kg.

#### `/PK` — Concentration Unit Conversion for Simulation Output

The PK simulation models (mrgsolve) compute concentrations in **mg/mL** (dose in mg ÷ volume in mL). A conversion factor is applied to convert the returned concentrations and plot y-axis to the user-specified `conc_unit`:

| `conc_unit` | Conversion Factor | Calculation |
|-------------|-------------------|-------------|
| `ug/mL` (default) | ×1000 | mg → ug |
| `ng/mL` | ×1,000,000 | mg → ng |
| `mg/mL` | ×1 | no conversion |
| `mg/L` | ×1000 | 1 mg/mL = 1000 mg/L |
| `g/L` | ×1 | 1 mg/mL = 0.001 g/mL = 1 g/L |
| `g/mL` | ×0.001 | mg → g |

Time is always input and returned in **hours**. For plot display, time is auto-converted based on range (>168 h → weeks, >24 h → days, otherwise hours) or set explicitly via `time_unit`.

PK parameters (CL, V1, V2, Q) are accepted as **per-kg values** and scaled by `BW` internally before simulation. Dose is always in **mg**.

#### `/ER` — Display Labels Only

The `auc_unit` parameter (default `"h*ug/mL"`) is used solely as an axis label on the exposure-response plot. No unit validation or numeric conversion is performed. Response values are treated as unitless.

---


## 🤖 Integration with AI Agents

PMxAgent exposes tools via the Model Context Protocol (MCP), allowing AI agents to discover and call pharmacometric functions automatically.

### Cursor IDE

Configure via Cursor's Settings UI:

1. Open **Cursor Settings** (Cursor → Settings → Cursor Settings)
2. Navigate to **Tools & MCP**
3. Under **Installed MCP Servers** Click to Activate Server
3. For **New MCP Server** Setup. Click and Add the Following:

```json
{
    "mcpServers": {
        "PMx MCP": {
            "url": "http://localhost:8000/messages",
            "transport": "sse"
        }
    }
}
```

### Claude Code

Claude Code auto-discovers running MCP servers:

1. Ensure PMxAgent is running:
2. Start Claude Code:
3. Tools are automatically available - verify by asking: *"What tools do you have?"*
4. Ask Claude to discover and connect to tools

### Claude Desktop

Configure via the Claude Desktop config file:

**Config file locations:**
- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Linux:** `~/.config/Claude/claude_desktop_config.json`

**Add this configuration:**
```json
{
  "mcpServers": {
    "pmxagent": {
      "url": "http://localhost:8000/messages",
      "description": "PMxAgent - Pharmacometric analysis tools"
    }
  }
}
```

### ChatGPT

ChatGPT does **not** currently support the MCP protocol. Will update when more information is available.

---

## 🛠️ Development

### Editing the Code

PMxAgent's R API is modularized for maintainability:

```bash
# Edit endpoint logic
vim apis/endpoints/nca.R    # NCA endpoint
vim apis/endpoints/er.R     # ER endpoint
vim apis/endpoints/pk.R     # PK endpoint

# Edit model calculations
vim apis/models/mrgsolve_pk.R   # PK compartment models (mrgsolve-based)
vim apis/models/er_models.R     # ER model fitting

# Edit utilities
vim apis/utils/validation.R    # Input validation
vim apis/utils/plotting.R      # Plotting utilities
vim apis/utils/constants.R     # Configuration constants

# Rebuild after changes
docker compose up --build
```

Output figures save to `figures/` directory. All changes persist across container restarts.

### Test Suite

PMxAgent includes **62 total tests**: 40 Python integration tests (via pytest) and 22 R unit tests.

| Test File | Tests | Description |
|-----------|-------|-------------|
| `tests/test_endpoints.py` | 27 | MCP endpoint integration tests |
| `tests/test_validation.py` | 13 | Input validation and error handling |
| `apis/tests/test_nca.R` | 16 | NCA ground truth, route validation, dosing scenarios, BLQ handling, business rules, PKNCA options |
| `apis/tests/test_pk_models.R` | 6 | mrgsolve vs analytical solutions |

#### Prerequisites

```bash
# Install test dependencies
pip install -r requirements-dev.txt

# Ensure PMxAgent is running
docker compose up -d

# Wait for services to be healthy (takes ~10 seconds)
docker compose ps
```

#### Python Integration Tests (40 tests)

Test all three pharmacometric endpoints via PMxAgent's MCP interface:

```bash
# Run all integration tests
pytest tests/test_endpoints.py -v

# Run specific test
pytest tests/test_endpoints.py::test_nca_endpoint -v

# Run with coverage report
pytest tests/ -v --cov=. --cov-report=html
# Open htmlcov/index.html in browser to view coverage

# Run validation/error handling tests
pytest tests/test_validation.py -v
```

**What's tested:**
- ✅ NCA calculations (Cmax, Tmax, AUC, half-life)
- ✅ Exposure-response model fitting (linear, Emax, Imax, logit)
- ✅ PK simulations (1-compartment and 2-compartment models)
- ✅ Input validation and error handling
- ✅ MCP tool discovery and invocation

**Expected output:**
```
tests/test_endpoints.py::test_nca_endpoint PASSED
tests/test_endpoints.py::test_er_endpoint PASSED
tests/test_endpoints.py::test_pk_endpoint_1cm PASSED
tests/test_endpoints.py::test_pk_endpoint_2cm PASSED
tests/test_endpoints.py::test_pk_endpoint_auto_selection PASSED
tests/test_endpoints.py::test_list_all_tools PASSED
tests/test_endpoints.py::test_pk_population_mode PASSED
tests/test_endpoints.py::test_pk_endpoint_multi_subject PASSED
tests/test_endpoints.py::test_nca_endpoint_multi_subject PASSED
tests/test_endpoints.py::test_er_endpoint_binary_response PASSED
...
tests/test_validation.py::test_nca_mismatched_lengths PASSED
tests/test_validation.py::test_nca_negative_dose PASSED
tests/test_validation.py::test_pk_negative_time PASSED
tests/test_validation.py::test_nca_non_numeric_data PASSED
tests/test_validation.py::test_er_non_numeric_response PASSED

======================== 40 passed in 13.15s ========================
```

#### R Unit Tests (22 tests)

Test core R functions in isolation:

```bash
# Run R unit tests inside PMxAgent
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_nca.R
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_pk_models.R
```

**What's tested:**

- **test_nca.R** (16 tests): Ground truth validation, input validation, time unit normalization, unit derivation, weight-based dose calculation, output formatting, route validation, dosing scenarios, BLQ handling, business rules, PKNCA options
- **test_pk_models.R** (6 tests): mrgsolve vs analytical solutions, monotonic concentration decrease, positive concentrations, eigenvalue validation for 2-compartment models

---

## 📁 Repository Structure

```
├── apis/
│   ├── rapi.R               # Main router (sources all modules)
│   ├── endpoints/           # Plumber endpoint handlers
│   │   ├── nca.R           # NCA endpoint
│   │   ├── er.R            # ER endpoint
│   │   └── pk.R            # PK endpoint
│   ├── models/             # Core model calculations
│   │   ├── mrgsolve_pk.R   # mrgsolve-based 1CM and 2CM models
│   │   ├── er_models.R     # ER model fitting functions
│   │   ├── 1CM.cpp         # mrgsolve 1-compartment model
│   │   └── 2CM.cpp         # mrgsolve 2-compartment model
│   ├── utils/              # Shared utilities
│   │   ├── constants.R     # Configuration constants
│   │   ├── validation.R    # Input validation functions
│   │   ├── units.R         # Unit derivation and formatting
│   │   ├── colors.R        # Color scheme utilities
│   │   └── plotting.R      # Plotting utilities
│   └── tests/              # R unit tests
│       ├── test_nca.R      # NCA ground truth validation
│       └── test_pk_models.R # PK model unit tests
├── tests/                   # Python integration tests
│   ├── test_endpoints.py   # MCP endpoint tests
│   └── test_validation.py  # Input validation tests
├── server.py               # MCP server entry point
├── docker-compose.yml      # Container orchestration
└── figures/                # Generated plot outputs
```

---

## 🔧 Troubleshooting

### R code changes not taking effect

**Problem:** You modified R code in `apis/` but changes aren't reflected

**Solution:** R code runs inside Docker. You **must** rebuild:

```bash
docker compose down
docker compose up --build
```

**Important:** `docker compose restart` is **not** sufficient - you must rebuild with `--build`.

---

### PMxAgent won't start

**Problem:** `docker compose up` fails

**Solutions:**
- Ensure Docker Desktop is running
- Check port conflicts: `lsof -i :8000` and `lsof -i :5762`
- Clear old containers: `docker compose down -v`
- Rebuild from scratch: `docker compose build --no-cache`

### Port already in use

**Problem:** `Error: port 8000 is already allocated`

**Solution:**
```bash
# Find process using the port
lsof -i :8000
# Kill the process or change the port in docker-compose.yml
```

### PMxAgent not generating OpenAPI spec

**Problem:** MCP endpoint can't find OpenAPI spec at `http://rapi:8000/openapi.json`

**Solution:**
- Check PMxAgent health: `docker compose ps`
- View R API logs: `docker compose logs rapi`
- Verify OpenAPI endpoint: `curl http://localhost:5762/openapi.json`

### Figures not appearing

**Problem:** Plots not saving to `figures/` directory

**Solutions:**
- Check directory permissions: `chmod 755 figures`
- View container logs: `docker compose logs rapi`
- Verify Docker volume mount is working: `docker compose down && docker compose up -d`

### Tests failing

**Problem:** `pytest` or R tests fail

**Solutions:**
- Ensure PMxAgent is running: `docker compose up -d`
- Wait for services to be healthy (~10s): `docker compose ps`
- Verify R API is accessible: `curl http://localhost:5762/openapi.json`
- Verify MCP endpoint: `curl http://localhost:8000/health` (may return 404, but should connect)
- Check service logs: `docker compose logs`
- Reinstall test dependencies: `pip install -r requirements-dev.txt`
- Run single test to isolate issue: `pytest tests/test_endpoints.py::test_nca_endpoint -v`

### AI agents can't connect

**Problem:** Cursor or Claude Desktop can't discover PMxAgent's tools

**Solutions:**
- Verify PMxAgent is running: `curl http://localhost:8000/health`
- Check MCP endpoint URL is correct: `http://localhost:8000/messages`
- Restart PMxAgent: `docker compose restart`
- Check client configuration files match examples

---

## 🤝 Contributing

Pull requests and issues welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Adding new endpoints to PMxAgent
- Code style and testing requirements
- Submitting pull requests

For questions, open an issue on GitHub.

---

## 📄 License

PMxAgent is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

---

**PMxAgent: Modern, reproducible, and automation-ready pharmacometrics.**
