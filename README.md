# PMxAgent: An Agentic Platform for Pharmacometrics

**Transform your existing R-based pharmacometrics workflow into AI agent-callable tools.**


[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)](https://www.docker.com/)
[![R](https://img.shields.io/badge/r-%23276DC3.svg?style=flat&logo=r&logoColor=white)](https://www.r-project.org/)
[![Python](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen)](tests/)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

---

## ⚡ Architecture at a Glance

```
                                  PMxAgent
┌─────────────────────────────── Docker ──────────────────────────────────┐
│                                                                         │
│  ┌────────────────────────┐             ┌────────────────────┐          │
│  │      R Plumber API     │   OpenAPI   │   MCP Server (Host)│          │
│  │                        │────────────▶│                    │          │
│  │ /NCA /ER /PK /DATA     │◀───────────▶│      FastMCP       │          │
│  │      /LIBRARY          │    HTTP     └──────────┬─────────┘          │
│  │    PKNCA, mrgsolve     │                        │                    │
│  └────────────────────────┘                        │                    │
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

PMxAgent is an agentic platform for building custom pharmacometric agents and automation pipelines. Validated R functions are exposed as RESTful API endpoints, converted to agent-callable tools, and wrapped by a Model Context Protocol (MCP) server — all orchestrated with Docker.

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

## 🚀 Quick Start

**Prerequisites:** [Docker Desktop](https://www.docker.com/) 4.0+ (running) and Git.

```bash
git clone https://github.com/peterbloomingdale/PMxAgent.git
cd PMxAgent
docker compose up --build -d
```

**Verify it's up:**
```bash
docker compose ps                         # two containers, both healthy
curl http://localhost:5762/openapi.json   # returns JSON
```

**Access points:**
- **API docs & testing (Swagger UI):** http://localhost:5762/__docs__/
- **MCP endpoint (for AI agents):** http://localhost:8000/mcp

> Prefer to let an agent drive? Open [Claude Code](https://claude.com/claude-code) (`claude`) in the cloned repo and ask it to build, start, and health-check PMxAgent — it'll run the steps above and confirm the tools work end-to-end.

---

## 🎯 What PMxAgent Does

PMxAgent provides five pharmacometric endpoints, each exposed as an HTTP API and an MCP tool:

| Endpoint | Purpose | Highlights |
|----------|---------|------------|
| `POST /NCA` | Non-compartmental analysis | Cmax, Tmax, AUC, half-life; multi-subject mode; automatic unit derivation; reads ADPC files via `data_file` |
| `POST /ER` | Exposure-response modeling | Auto-selects best model by AIC; two-panel visualization |
| `POST /PK` | PK simulation | 1- or 2-compartment IV; population mode with between-subject variability; optional CSV output |
| `POST /DATA` | Data formatting | Reads raw CSV/Excel; standardizes to CDISC ADPC format; feeds `/NCA` directly |
| `POST /LIBRARY` | Model library | List, simulate, or benchmark literature PK models from `nlmixr2lib`; faithful rxode2 population PK; outputs ADPC CSV |

Full parameters, unit handling, and end-to-end workflows are documented in the **Swagger UI** (http://localhost:5762/__docs__/) and the accompanying manuscript.

---

## 🤖 Connect an AI Agent

PMxAgent exposes its tools over MCP at `http://localhost:8000/mcp`. On first connection, clients complete a one-time OAuth approval in the browser.

> **Protocol:** PMxAgent serves MCP `2026-07-28` (the stateless revision) and only that revision.
> Current clients negotiate it automatically. A client still on the older handshake protocol is
> refused with JSON-RPC `-32022`; set `MCP_ALLOW_LEGACY=true` in `docker-compose.yml` and restart
> to re-admit it.

**Claude Code** — a `.mcp.json` is included in the repo root and is picked up automatically when you run `claude` from the project directory. Approve the OAuth prompt on first connect.

**Cursor / Claude Desktop** — add an MCP server pointing at the same URL:
```json
{
  "mcpServers": {
    "pmxagent": {
      "type": "http",
      "url": "http://localhost:8000/mcp"
    }
  }
}
```
Claude Desktop config lives at `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS), `%APPDATA%\Claude\claude_desktop_config.json` (Windows), or `~/.config/Claude/claude_desktop_config.json` (Linux).

**ChatGPT** — supported via MCP custom connectors; follow the latest OpenAI connector docs and use the same URL.

---

## 🛠️ Development & Tests

The R API is modularized under `apis/` (`endpoints/`, `models/`, `utils/`, `tests/`). R code runs inside Docker, so after editing you **must rebuild** — `docker compose restart` is not enough:

```bash
docker compose up --build
```

Generated plots land in `figures/`; drop input files (CSV/Excel) into `data/`. Both are bind-mounted into the container and gitignored.

**Run the tests:**
```bash
# Python integration tests (via MCP)
pip install -r requirements-dev.txt
docker compose up -d
MCP_TEST_TOKEN=pmxagent-ci-token pytest tests/ -v

# R unit tests (inside the container)
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_nca.R
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_pk_models.R
docker compose exec rapi Rscript /home/rstudio/apis/tests/test_library_models.R
```

---

## 🔧 Troubleshooting

- **R changes not showing up?** Rebuild — `docker compose down && docker compose up --build`. A plain `restart` won't pick up code changes.
- **Port already in use?** Check with `lsof -i :8000` and `lsof -i :5762`, then free the port or change it in `docker-compose.yml`.
- **Agent can't connect?** Confirm the MCP URL is `http://localhost:8000/mcp` (not `/messages`), and approve the OAuth prompt on first connection. Tokens refresh automatically on reconnect.
- **Agent rejected with `-32022`?** Its MCP client is on the older handshake protocol; PMxAgent serves `2026-07-28` only. Either update the client, or set `MCP_ALLOW_LEGACY=true` in `docker-compose.yml` and `docker compose up -d mcp`.

---

## 📖 Cite This Work

A manuscript describing PMxAgent is in preparation. In the meantime, please cite the software:

```bibtex
@software{pmxagent,
  author       = {Bloomingdale, Peter},
  title        = {PMxAgent: An Agentic Platform for Pharmacometrics},
  year         = {2026},
  publisher    = {Generate Biomedicines},
  url          = {https://github.com/peterbloomingdale/PMxAgent},
  note         = {Publication pending}
}
```

---

## 🤝 Contributing

Pull requests and issues welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on adding endpoints, code style, and testing. For questions, open an issue on GitHub.

---

## 📄 License

PMxAgent is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0-only). See [LICENSE](LICENSE) for details.

---

**PMxAgent: Modern, reproducible, and automation-ready pharmacometrics.**
