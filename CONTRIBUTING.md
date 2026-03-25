# Contributing to PMxAgent

Thank you for your interest in contributing to PMxAgent! This document provides guidelines for contributing to the project.

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help maintain a welcoming environment for all contributors

## Getting Started

### Prerequisites

- Docker Desktop installed and running
- Git for version control
- Basic familiarity with R (for endpoint development) or Python (for MCP server development)

### Development Setup

1. **Fork and clone the repository:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/PMxAgent.git
   cd PMxAgent
   ```

2. **Create a development branch:**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Start the development environment:**
   ```bash
   mkdir -p figures
   docker compose up --build
   ```

4. **Verify services are running:**
   - API docs: http://localhost:5762/__docs__/
   - MCP server: http://localhost:8000/messages

## Project Structure

```
├── apis/
│   ├── rapi.R               # Main router - sources all modules
│   ├── endpoints/           # Plumber endpoint handlers (#* annotations)
│   ├── models/             # Core pharmacometric calculations
│   └── utils/              # Shared utilities (validation, plotting, constants)
├── tests/                   # Python integration tests
├── server.py               # MCP server entry point
└── docker-compose.yml      # Container orchestration
```

## How to Contribute

### Adding a New R Endpoint

1. **Create model functions** in `apis/models/your_model.R`:
   ```r
   # apis/models/your_model.R
   calculate_something <- function(param1, param2) {
     # Your calculation logic here
     return(result)
   }
   ```

2. **Create endpoint handler** in `apis/endpoints/your_endpoint.R`:
   ```r
   # apis/endpoints/your_endpoint.R

   #* Your Endpoint Description
   #* @param param1 Description of param1
   #* @param param2 Description of param2
   #* @post /YourEndpoint
   #* @serializer unboxedJSON
   function(param1 = "default", param2 = "default") {
     tryCatch({
       # Parse and validate inputs
       validate_your_inputs(param1, param2)

       # Call model function
       result <- calculate_something(param1, param2)

       # Return results
       return(list(result = result))
     }, error = function(e) {
       stop(sprintf("Your endpoint failed: %s", e$message))
     })
   }
   ```

3. **Source the new modules** in `apis/rapi.R`:
   ```r
   # Add to apis/rapi.R
   source("models/your_model.R")
   source("endpoints/your_endpoint.R")
   ```

4. **Add tests** in `tests/test_endpoints.py`:
   ```python
   @pytest.mark.asyncio
   async def test_your_endpoint():
       async with Client(SSETransport(BASE_URL)) as c:
           raw = (await c.call_tool("r_post_YourEndpoint", {
               "param1": "value1",
               "param2": "value2"
           }))[0].model_dump_json()
           result = extract_result(raw)
           assert "result" in result
   ```

5. **Test your changes:**
   ```bash
   docker compose up --build
   pytest tests/test_endpoints.py::test_your_endpoint -v
   ```

### Code Style Guidelines

#### R Code Style

- **Naming conventions:**
  - Functions: `snake_case` (e.g., `calculate_pk_profile`)
  - Constants: `UPPER_SNAKE_CASE` (e.g., `MAX_DATA_POINTS`)
  - Variables: `snake_case`

- **Documentation:**
  - Use Plumber annotations (`#*`) for all endpoints
  - Include `@param` descriptions for all parameters
  - Specify `@post` or `@get` with endpoint path
  - Always use `@serializer unboxedJSON` for consistent output

- **Error handling:**
  - Wrap endpoint functions in `tryCatch`
  - Use `validate_*` functions from `utils/validation.R`
  - Provide informative error messages with `sprintf()`

- **Code organization:**
  - Keep endpoint handlers thin (delegate to model functions)
  - Put calculation logic in `models/`
  - Put reusable utilities in `utils/`

#### Python Code Style

- Follow PEP 8
- Use type hints where appropriate
- Document functions with docstrings

### Testing Requirements

All contributions must include tests:

1. **R unit tests** (`apis/tests/`) for model functions:
   - Test against known ground truth values
   - Test edge cases (zero, negative, NaN)
   - Use `stopifnot()` for assertions

2. **Python integration tests** (`tests/`) for endpoints:
   - Test via MCP client (FastMCP)
   - Verify response structure
   - Test error handling

3. **Run tests before submitting:**
   ```bash
   # Python tests
   pytest tests/ -v

   # R tests
   docker compose exec rapi Rscript /home/rstudio/apis/tests/test_nca.R
   docker compose exec rapi Rscript /home/rstudio/apis/tests/test_pk_models.R
   ```

### Submitting a Pull Request

1. **Ensure all tests pass:**
   ```bash
   pytest tests/ -v
   docker compose exec rapi Rscript /home/rstudio/apis/tests/test_your_test.R
   ```

2. **Update documentation:**
   - Update README.md if adding new features
   - Update CLAUDE.md with development notes
   - Add examples to `examples/` if appropriate

3. **Commit with clear messages:**
   ```bash
   git add .
   git commit -m "Add new PK/PD endpoint with validation"
   ```

4. **Push to your fork:**
   ```bash
   git push origin feature/your-feature-name
   ```

5. **Create pull request:**
   - Provide clear description of changes
   - Reference any related issues
   - Include screenshots if UI/output changes
   - Ensure CI tests pass

### Pull Request Checklist

- [ ] Code follows project style guidelines
- [ ] All tests pass locally
- [ ] New tests added for new functionality
- [ ] Documentation updated (README, CLAUDE.md, etc.)
- [ ] No merge conflicts with main branch
- [ ] Descriptive commit messages
- [ ] PR description explains the changes

## Common Development Tasks

### Debugging Container Issues

```bash
# View logs
docker compose logs rapi
docker compose logs mcp

# Restart services
docker compose restart

# Rebuild from scratch
docker compose down -v
docker compose up --build

# Access container shell
docker compose exec rapi /bin/bash
docker compose exec mcp /bin/bash
```

### Testing Endpoints Manually

```bash
# Via curl
curl -X POST http://localhost:5762/NCA \
  -d 'time=0,1,2,4,8' \
  -d 'conc=10,8,5,2,1' \
  -d 'dose=100'

# Via Swagger UI
open http://localhost:5762/__docs__/
```

### Adding R Package Dependencies

1. Add package name to `r-packages.txt`
2. Rebuild container: `docker compose up --build`

## Questions or Issues?

- **Questions:** Open a GitHub issue with the `question` label
- **Bugs:** Open a GitHub issue with the `bug` label and include:
  - Steps to reproduce
  - Expected vs actual behavior
  - System information (OS, Docker version)
  - Relevant logs

## License

PMxAgent is licensed under `AGPL-3.0-only` (see `LICENSE`).

For non-trivial pull requests, contributors must sign the Contributor License Agreement (CLA) before a PR is merged.
- CLA document: `CONTRIBUTOR_LICENSE_AGREEMENT.md`
- Signing method: Add the following exact statement as a comment on your PR:
  - `I have read the CLA and agree to its terms.`

Trivial fixes (for example, typo corrections and minor documentation edits) are exempt from the CLA requirement.

---

Thank you for contributing to PMxAgent!
