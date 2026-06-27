# tests/test_library_endpoint.py
# Integration tests for the /LIBRARY endpoint (nlmixr2lib wrapper) via the MCP server.

import pytest
from conftest import call_tool_ok

LIBRARY_TOOL = "r_Model_library_simulate_or_list"
NCA_TOOL     = "r_Noncompartmental_analysis_NCA"


@pytest.mark.asyncio
async def test_library_tool_in_list(mcp_client):
    """The /LIBRARY tool is exposed via MCP."""
    tools = [t.name for t in await mcp_client.list_tools()]
    assert LIBRARY_TOOL in tools, f"{LIBRARY_TOOL} not in {tools}"


# ==================== list mode ====================

@pytest.mark.asyncio
async def test_library_list_returns_models(mcp_client):
    """list mode returns a non-trivial catalog of PK models with required fields."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {"mode": "list"})

    assert result["mode"] == "list"
    assert result["source"] == "nlmixr2lib"
    assert result["n_models"] > 50
    assert len(result["models"]) == result["n_models"]

    names = [m["name"] for m in result["models"]]
    assert "PK_1cmt" in names and "PK_2cmt" in names

    for m in result["models"][:5]:
        assert "name" in m and "category" in m and "description" in m


@pytest.mark.asyncio
async def test_library_list_filters_non_pk(mcp_client):
    """PD / disease / TMDD / >2-cmt models are excluded with reasons."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {"mode": "list"})
    assert result["excluded_count"] > 0
    reasons = result["excluded_reasons"]
    # Non-PK-output (PD/disease/TTE) models dominate the exclusions.
    assert reasons.get("non_pk_output", 0) > 0
    # No excluded TMDD/3cmt names slipped into the included list.
    names = [m["name"].lower() for m in result["models"]]
    assert not any("tmdd" in n for n in names)
    assert not any("3cmt" in n for n in names)


# ==================== simulate mode ====================

@pytest.mark.asyncio
async def test_library_simulate_1cmt_oral(mcp_client):
    """Generic 1-compartment model: route detection, schedule, ADPC CSV."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "simulate", "model_name": "PK_1cmt",
        "dose": "100", "n_subjects": "6", "seed": "42",
    })
    mi = result["model_info"]
    assert result["mode"] == "simulate"
    assert mi["model_name"] == "PK_1cmt"
    assert mi["route"] == "extravascular"          # PK_1cmt has a depot
    assert mi["conc_output_var"] == "Cc"
    assert mi["n_compartments"] == 1
    assert mi["terminal_half_life"]["value"] > 0
    assert mi["tier"].startswith("tier")
    assert result["output_files"]["csv"].endswith(".csv")
    assert result["output_files"]["csv"].startswith("LIBRARY_PK_1cmt_")


@pytest.mark.asyncio
async def test_library_simulate_2cmt_iv_with_bsv(mcp_client):
    """IV 2-compartment literature model uses its published omega + covariate defaults."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "simulate", "model_name": "Li_2006_meropenem",
        "dose": "1000", "n_subjects": "8", "seed": "42",
    })
    mi, ss = result["model_info"], result["simulation_settings"]
    assert mi["route"] == "iv_bolus"
    assert mi["n_compartments"] == 2
    assert "model omega" in ss["bsv_source"]
    # Li_2006 requires AGE/CRCL/WT covariates, satisfied by reference defaults.
    assert "WT" in ss["covariates_defaulted"]
    assert result["parameters"]["CL"] > 0
    grp = result["summary_stats"]["1000 mg"]
    assert grp["n"] == 8 and grp["cmax_mean"] > 0


@pytest.mark.asyncio
async def test_library_simulate_multidose(mcp_client):
    """Multiple dose levels produce one summary group per dose."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "simulate", "model_name": "PK_2cmt",
        "dose": "100,300", "n_subjects": "8", "seed": "42",
    })
    assert set(result["summary_stats"].keys()) == {"100 mg", "300 mg"}


@pytest.mark.asyncio
async def test_library_simulate_reproducible(mcp_client):
    """Same seed -> identical simulated summary statistics."""
    args = {"mode": "simulate", "model_name": "PK_2cmt_mAb_Davda_2014",
            "dose": "100", "n_subjects": "6", "seed": "7"}
    r1 = await call_tool_ok(mcp_client, LIBRARY_TOOL, args)
    r2 = await call_tool_ok(mcp_client, LIBRARY_TOOL, args)
    s1 = r1["summary_stats"]["100 mg"]
    s2 = r2["summary_stats"]["100 mg"]
    assert s1["cmax_mean"] == s2["cmax_mean"]
    assert s1["cmax_sd"] == s2["cmax_sd"]
    assert r1["model_info"]["terminal_half_life"]["value"] == \
           r2["model_info"]["terminal_half_life"]["value"]


@pytest.mark.asyncio
async def test_library_invalid_model_name(mcp_client):
    """Unknown model name raises an actionable error."""
    with pytest.raises(Exception) as exc_info:
        await mcp_client.call_tool(LIBRARY_TOOL, {
            "mode": "simulate", "model_name": "NoSuchModel_xyz",
        })
    assert "NoSuchModel_xyz" in str(exc_info.value)


# ==================== end-to-end chain ====================

@pytest.mark.asyncio
async def test_library_end_to_end_nca_chain(mcp_client):
    """/LIBRARY simulate -> /NCA via data_file returns population NCA results."""
    sim = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "simulate", "model_name": "Li_2006_meropenem",
        "dose": "1000", "n_subjects": "6", "seed": "42",
    })
    csv = sim["output_files"]["csv"]
    route = sim["model_info"]["route"]

    nca = await call_tool_ok(mcp_client, NCA_TOOL, {
        "data_file": csv, "route": route, "conc_unit": "ug/mL",
    })
    assert nca["mode"] == "population"
    assert nca["n_subjects"] == 6
    assert nca["source_file"] == csv
    assert len(nca["individual_results"]) == 6
    for subj in nca["individual_results"]:
        assert subj["Cmax"]["value"] > 0
        assert subj["half_life"]["value"] > 0


# ==================== benchmark mode (multi-model -> one CSV) ====================

@pytest.mark.asyncio
async def test_library_benchmark_manifest(mcp_client):
    """benchmark mode runs several models into one combined CSV and returns a manifest."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "benchmark", "models": "PK_1cmt,PK_2cmt_no_depot",
        "output_profile": "mean", "mean_type": "geometric",
        "n_subjects": "20", "seed": "42", "output_file": "test_bench_manifest.csv",
    })
    assert result["mode"] == "benchmark"
    assert result["n_models_included"] == 2
    assert result["n_drugs"] == 2
    assert result["n_failed"] == 0
    assert result["output_files"]["csv"] == "test_bench_manifest.csv"
    names = {m["name"]: m for m in result["manifest"]}
    assert "PK_1cmt" in names and "PK_2cmt_no_depot" in names
    for m in result["manifest"]:
        assert m["status"] == "ok"
        assert m["route"] in ("iv_bolus", "extravascular")
        assert m["terminal_half_life_h"] > 0
        assert m["n_profiles"] == 1                 # one mean profile per drug


@pytest.mark.asyncio
async def test_library_benchmark_reports_failures(mcp_client):
    """A model with unresolvable covariates is reported as a failure, not a crash."""
    result = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "benchmark", "models": "PK_1cmt,NoSuchModel_xyz",
        "output_file": "test_bench_fail.csv",
    })
    assert result["n_models_included"] == 1
    assert result["n_failed"] == 1
    assert any(f["name"] == "NoSuchModel_xyz" for f in result["failures"])


# ==================== multi-drug NCA (DRUG grouping + mixed routes) ====================

@pytest.mark.asyncio
async def test_benchmark_to_multidrug_nca(mcp_client):
    """benchmark CSV (mixed routes) -> /NCA groups by DRUG with per-drug routes."""
    bench = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "benchmark",
        "models": "PK_1cmt,PK_2cmt_no_depot,Li_2006_meropenem",  # oral, iv, iv
        "output_profile": "mean", "mean_type": "geometric",
        "n_subjects": "20", "seed": "42", "output_file": "test_bench_nca.csv",
    })
    csv = bench["output_files"]["csv"]
    assert bench["n_drugs"] == 3

    nca = await call_tool_ok(mcp_client, NCA_TOOL, {"data_file": csv})
    assert nca["mode"] == "population"
    assert nca["n_drugs"] == 3
    assert nca["source_file"] == csv

    # DRUG column carries the drug NAME (full model reference stays in USUBJID).
    sbd = nca["summary_by_drug"]
    assert set(sbd.keys()) == {"PK_1cmt", "PK_2cmt_no_depot", "meropenem"}

    # Per-subject DRUG tag + route carried through; routes are mixed in one dataset
    routes = {r["drug"]: r["route"] for r in nca["individual_results"]}
    assert routes["PK_1cmt"] == "extravascular"
    assert routes["PK_2cmt_no_depot"] == "iv_bolus"
    assert routes["meropenem"] == "iv_bolus"
    for r in nca["individual_results"]:
        assert r["Cmax"]["value"] > 0
        assert r["half_life"]["value"] > 0


@pytest.mark.asyncio
async def test_benchmark_numeric_route_roundtrip(mcp_client):
    """benchmark with route_format=numeric -> /NCA ingests the numeric codes (1/2)."""
    bench = await call_tool_ok(mcp_client, LIBRARY_TOOL, {
        "mode": "benchmark", "models": "PK_1cmt,PK_2cmt_no_depot",  # extravascular, iv
        "output_profile": "mean", "mean_type": "geometric",
        "n_subjects": "20", "seed": "42", "route_format": "numeric",
        "output_file": "test_bench_numroute.csv",
    })
    assert bench["settings"]["route_format"] == "numeric"

    nca = await call_tool_ok(mcp_client, NCA_TOOL, {"data_file": bench["output_files"]["csv"]})
    assert nca["mode"] == "population" and nca["n_drugs"] == 2
    routes = {r["drug"]: r["route"] for r in nca["individual_results"]}
    # numeric codes 1/2 normalized back to canonical routes
    assert routes["PK_1cmt"] == "extravascular"      # code 2
    assert routes["PK_2cmt_no_depot"] == "iv_bolus"  # code 1


@pytest.mark.asyncio
async def test_nca_accepts_numeric_route_scalar(mcp_client):
    """/NCA single-subject accepts a numeric route code in the route parameter."""
    res = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,0.25,1,2,4,8", "conc": "100,90,65,45,25,8", "dose": "100", "route": "1",
    })
    # route=1 -> iv_bolus: Cmax at t=0 (C0 back-extrapolated), no "Invalid route" error
    assert "error" not in res
    assert res["analysis_settings"]["route"] == "iv_bolus"
