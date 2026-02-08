# tests/test_endpoints.py
# Integration tests for PMxAgent R API endpoints via MCP server

import json
import math
import pytest
from fastmcp import Client
from fastmcp.client.transports import SSETransport

BASE_URL = "http://127.0.0.1:8000/messages"


def extract_result(raw_msg: str) -> dict:
    """Extract result from MCP response"""
    outer = json.loads(raw_msg)
    # Handle both direct dict response and nested text response
    if isinstance(outer, dict):
        if "text" in outer:
            inner = json.loads(outer["text"])
            return inner
        else:
            return outer
    return outer


@pytest.mark.asyncio
async def test_nca_endpoint():
    """Test Non-Compartmental Analysis endpoint with unit handling"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Verify tool exists
        names = [t.name for t in await c.list_tools()]
        assert "r_Noncompartmental_analysis_NCA" in names, f"NCA tool not found. Available tools: {names}"

        # Call NCA endpoint with test data
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,0.25,0.5,1,2,4,8,12,24",
                "conc": "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
                "dose": "100"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify new response structure with units
        assert "mode" in result, "mode not in result"
        assert result["mode"] == "single", f"Expected single mode, got {result.get('mode')}"

        # Verify input_units section
        assert "input_units" in result, "input_units not in result"
        assert result["input_units"]["time"] == "h", "Default time unit should be h"
        assert result["input_units"]["concentration"] == "ug/mL", "Default conc unit should be ug/mL"
        assert result["input_units"]["dose"] == "mg", "Default dose unit should be mg"

        # Verify dose_administered
        assert "dose_administered" in result, "dose_administered not in result"
        assert result["dose_administered"]["value"] == 100, "dose value should be 100"
        assert result["dose_administered"]["unit"] == "mg", "dose unit should be mg"

        # Verify main parameters have value/unit structure
        assert "Cmax" in result, "Cmax not in result"
        assert isinstance(result["Cmax"], dict), "Cmax should be a dict with value/unit"
        assert "value" in result["Cmax"], "Cmax should have value"
        assert "unit" in result["Cmax"], "Cmax should have unit"
        assert result["Cmax"]["value"] > 0, "Cmax value should be positive"
        assert result["Cmax"]["unit"] == "ug/mL", "Cmax unit should be ug/mL"

        assert "Tmax" in result, "Tmax not in result"
        assert result["Tmax"]["value"] >= 0, "Tmax value should be non-negative"
        assert result["Tmax"]["unit"] == "h", "Tmax unit should be h"

        assert "auclast" in result, "auclast not in result"
        assert result["auclast"]["value"] > 0, "auclast value should be positive"
        assert result["auclast"]["unit"] == "h*ug/mL", "auclast unit should be h*ug/mL"

        assert "half_life" in result, "half_life not in result"
        assert result["half_life"]["value"] > 0, "half_life value should be positive"
        assert result["half_life"]["unit"] == "h", "half_life unit should be h"

        # Verify available_params also have value/unit structure
        assert "available_params" in result, "available_params not in result"
        if "cmax" in result["available_params"]:
            assert "value" in result["available_params"]["cmax"], "available_params.cmax should have value"
            assert "unit" in result["available_params"]["cmax"], "available_params.cmax should have unit"


@pytest.mark.asyncio
async def test_er_endpoint():
    """Test Exposure-Response analysis endpoint"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Verify tool exists
        names = [t.name for t in await c.list_tools()]
        assert "r_Exposure_response_ER_analysis" in names, f"ER tool not found. Available tools: {names}"

        # Call ER endpoint with test data (Emax-like response)
        # dose must match length of exposure/resp
        raw = (await c.call_tool(
            "r_Exposure_response_ER_analysis",
            {
                "exposure": "0.1,0.5,1,2,5,10,20,50,100",
                "resp": "5,15,25,40,60,75,85,92,95",
                "dose": "10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg",
                "model": "auto"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify expected outputs
        assert "model_used" in result, "model_used not in result"
        assert "parameters" in result, "parameters not in result"
        assert "fit_stats" in result, "fit_stats not in result"
        assert "plot_path" in result, "plot_path not in result"
        assert "all_models" in result, "all_models not in result"

        # Verify model was selected
        assert result["model_used"] in ["linear", "emax", "imax", "logit"], \
            f"Unexpected model: {result['model_used']}"

        # Verify fit stats
        assert "AIC" in result["fit_stats"], "AIC not in fit_stats"


@pytest.mark.asyncio
async def test_er_endpoint_with_exposure_and_dose():
    """Test ER endpoint with new exposure parameter and dose groups"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call ER endpoint with exposure parameter and dose groups
        raw = (await c.call_tool(
            "r_Exposure_response_ER_analysis",
            {
                "exposure": "25,30,35,50,60,70,100,120,140,160,180,200",
                "resp": "0.2,0.22,0.25,0.35,0.38,0.4,0.5,0.52,0.55,0.58,0.6,0.62",
                "dose": "60 mg,60 mg,60 mg,120 mg,120 mg,120 mg,240 mg,240 mg,240 mg,240 mg,240 mg,240 mg",
                "model": "auto",
                "n_quantiles": "4"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify basic outputs
        assert "model_used" in result, "model_used not in result"
        assert "parameters" in result, "parameters not in result"
        assert "fit_stats" in result, "fit_stats not in result"
        assert "plot_path" in result, "plot_path not in result"

        # Verify new quantile summary output
        assert "quantile_summary" in result, "quantile_summary not in result"
        quantile_summary = result["quantile_summary"]
        assert len(quantile_summary) == 4, f"Expected 4 quantiles, got {len(quantile_summary)}"

        # Verify quantile structure
        first_quantile = quantile_summary[0]
        assert "quantile" in first_quantile, "quantile field missing"
        assert "n" in first_quantile, "n field missing"
        assert "exposure_median" in first_quantile, "exposure_median field missing"
        assert "resp_mean" in first_quantile, "resp_mean field missing"
        assert "resp_ci_lower" in first_quantile, "resp_ci_lower field missing"
        assert "resp_ci_upper" in first_quantile, "resp_ci_upper field missing"

        # Verify dose summary output
        assert "dose_summary" in result, "dose_summary not in result"
        dose_summary = result["dose_summary"]
        assert len(dose_summary) == 3, f"Expected 3 dose groups, got {len(dose_summary)}"

        # Verify dose structure
        first_dose = dose_summary[0]
        assert "dose" in first_dose, "dose field missing"
        assert "n" in first_dose, "n field missing"
        assert "exposure_mean" in first_dose, "exposure_mean field missing"
        assert "exposure_min" in first_dose, "exposure_min field missing"
        assert "exposure_max" in first_dose, "exposure_max field missing"

        # Verify dose group values
        dose_names = [d["dose"] for d in dose_summary]
        assert "60 mg" in dose_names, "60 mg dose group missing"
        assert "120 mg" in dose_names, "120 mg dose group missing"
        assert "240 mg" in dose_names, "240 mg dose group missing"


@pytest.mark.asyncio
async def test_pk_endpoint_1cm():
    """Test PK simulation endpoint - one compartment model (population mode)"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Verify tool exists
        names = [t.name for t in await c.list_tools()]
        assert "r_Pharmacokinetic_simulation_IV_1_or_2_CM" in names, f"PK tool not found. Available tools: {names}"

        # Call PK endpoint with 1-compartment parameters (uses population mode by default)
        raw = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "dose": "100",
                "CL": "1",
                "V1": "10",
                "n_subjects": "5",
                "t": "0,0.25,0.5,1,2,4,8,12,24",
                "model": "1cm",
                "seed": "42"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode outputs
        assert result.get("mode") == "population", f"Expected population mode, got {result.get('mode')}"
        assert "model_used" in result, "model_used not in result"
        assert "plot_path" in result, "plot_path not in result"
        assert "individual_data" in result, "individual_data not in result"

        # Verify model selection
        assert result["model_used"] == "one-compartment", \
            f"Expected one-compartment, got {result['model_used']}"

        # Verify individual data exists and has expected structure
        assert len(result["individual_data"]) == 5, \
            f"Expected 5 subjects, got {len(result['individual_data'])}"

        # Verify concentrations decrease over time (PK profile sanity check)
        first_subj = result["individual_data"][0]
        concentrations = first_subj["concentrations"]
        assert concentrations[0] > concentrations[-1], \
            "Concentrations should decrease over time"


@pytest.mark.asyncio
async def test_pk_endpoint_2cm():
    """Test PK simulation endpoint - two compartment model (population mode)"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call PK endpoint with 2-compartment parameters
        raw = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "dose": "100",
                "CL": "1",
                "V1": "10",
                "V2": "20",
                "Q": "2",
                "n_subjects": "5",
                "t": "0,0.25,0.5,1,2,4,8,12,24",
                "model": "2cm",
                "seed": "42"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode outputs
        assert result.get("mode") == "population", f"Expected population mode, got {result.get('mode')}"
        assert "model_used" in result, "model_used not in result"
        assert result["model_used"] == "two-compartment", \
            f"Expected two-compartment, got {result['model_used']}"

        # Verify concentrations are positive in individual data
        first_subj = result["individual_data"][0]
        concentrations = first_subj["concentrations"]
        assert all(c > 0 for c in concentrations), \
            "All concentrations should be positive"


@pytest.mark.asyncio
async def test_pk_endpoint_auto_selection():
    """Test PK endpoint auto-selects correct model based on parameters"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Explicitly request 1CM model
        raw_1cm = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "dose": "100",
                "CL": "1",
                "V1": "10",
                "t": "0,1,2,4,8",
                "model": "1cm"
            }
        ))[0].model_dump_json()

        result_1cm = extract_result(raw_1cm)
        assert result_1cm["model_used"] == "one-compartment", \
            "Should use 1CM when explicitly requested"

        # Explicitly request 2CM model
        raw_2cm = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "dose": "100",
                "CL": "1",
                "V1": "10",
                "V2": "20",
                "Q": "2",
                "t": "0,1,2,4,8",
                "model": "2cm"
            }
        ))[0].model_dump_json()

        result_2cm = extract_result(raw_2cm)
        assert result_2cm["model_used"] == "two-compartment", \
            "Should use 2CM when explicitly requested"


@pytest.mark.asyncio
async def test_list_all_tools():
    """Test that all expected R API tools are available"""
    async with Client(SSETransport(BASE_URL)) as c:
        tools = await c.list_tools()
        tool_names = [t.name for t in tools]

        # Verify all main endpoints are available
        expected_tools = [
            "r_Noncompartmental_analysis_NCA",
            "r_Exposure_response_ER_analysis",
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
        ]
        for tool_name in expected_tools:
            assert tool_name in tool_names, \
                f"{tool_name} not found in available tools: {tool_names}"


@pytest.mark.asyncio
async def test_pk_population_mode():
    """Test PK endpoint with population mode (TV + OMEGA)"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call PK endpoint with population mode parameters
        # n_subjects must equal n_per_dose * number of doses
        raw = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "n_subjects": "30",
                "n_per_dose": "10",
                "dose": "10,30,100",
                "cv": "0.25",
                "BW": "70",
                "t": "0,1,2,4,8,12,24,48,168,336",
                "seed": "42"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode outputs
        assert result.get("mode") == "population", f"Expected population mode, got {result.get('mode')}"
        assert result["model_used"] == "two-compartment", \
            f"Expected two-compartment (default), got {result['model_used']}"
        assert result["n_subjects"] == 30, f"Expected 30 subjects, got {result['n_subjects']}"

        # Verify variability info
        assert "variability" in result, "variability not in result"
        assert result["variability"]["cv"] == 0.25, "cv should be 0.25"

        # Verify typical values from Betts 2018
        assert "typical_values" in result, "typical_values not in result"
        tv = result["typical_values"]
        assert "Betts" in tv["source"], f"source should contain Betts, got {tv['source']}"
        assert tv["CL"] == 0.15, "CL should be 0.15"
        assert tv["V1"] == 46.31, "V1 should be 46.31"

        # Verify individual data
        assert "individual_data" in result, "individual_data not in result"
        assert len(result["individual_data"]) == 30, \
            f"Expected 30 individual results, got {len(result['individual_data'])}"

        # Verify individual data structure includes PK params
        first_subj = result["individual_data"][0]
        assert "subject_id" in first_subj, "subject_id not in individual data"
        assert "CL" in first_subj, "CL not in individual data"
        assert "V1" in first_subj, "V1 not in individual data"
        assert "concentrations" in first_subj, "concentrations not in individual data"

        # Verify summary by dose
        assert "summary_by_dose" in result, "summary_by_dose not in result"
        assert len(result["summary_by_dose"]) == 3, \
            f"Expected 3 dose groups, got {len(result['summary_by_dose'])}"

        # Verify plot was generated
        assert "plot_path" in result, "plot_path not in result"
        assert result["plot_path"].endswith(".png"), "plot_path should end with .png"

        # Verify seed was stored
        assert result.get("seed") == 42, "seed should be 42"


@pytest.mark.asyncio
async def test_pk_endpoint_multi_subject():
    """Test PK endpoint with multi-subject (population) mode using default params"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call PK endpoint with 6 subjects (2 per dose group)
        # n_subjects must equal n_per_dose * number of doses
        raw = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "dose": "10,30,100",
                "n_subjects": "6",
                "n_per_dose": "2",
                "t": "0,1,2,4,8,12,24",
                "model": "2cm",
                "seed": "42"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode outputs
        assert result.get("mode") == "population", f"Expected population mode, got {result.get('mode')}"
        assert result["model_used"] == "two-compartment", \
            f"Expected two-compartment, got {result['model_used']}"
        assert result["n_subjects"] == 6, f"Expected 6 subjects, got {result['n_subjects']}"

        # Verify individual data
        assert "individual_data" in result, "individual_data not in result"
        assert len(result["individual_data"]) == 6, \
            f"Expected 6 individual results, got {len(result['individual_data'])}"

        # Verify individual data structure
        first_subj = result["individual_data"][0]
        assert "subject_id" in first_subj, "subject_id not in individual data"
        assert "times" in first_subj, "times not in individual data"
        assert "concentrations" in first_subj, "concentrations not in individual data"

        # Verify summary by dose
        assert "summary_by_dose" in result, "summary_by_dose not in result"
        assert len(result["summary_by_dose"]) == 3, \
            f"Expected 3 dose groups, got {len(result['summary_by_dose'])}"

        # Verify plot was generated
        assert "plot_path" in result, "plot_path not in result"
        assert result["plot_path"].endswith(".png"), "plot_path should end with .png"


@pytest.mark.asyncio
async def test_nca_endpoint_multi_subject():
    """Test NCA endpoint with multi-subject (pipe-separated) mode and unit handling"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call NCA endpoint with 3 subjects using pipe-separated format
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24|0,1,2,4,8,12,24|0,1,2,4,8,12,24",
                "conc": "10,9,7.5,5,2.5,1.2,0.3|30,27,22,15,7.5,3.6,0.9|100,90,75,50,25,12,3",
                "dose": "10|30|100",
                "subject_id": "SUBJ001|SUBJ002|SUBJ003",
                "dose_label": "10 mg|30 mg|100 mg"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode outputs
        assert result.get("mode") == "population", f"Expected population mode, got {result.get('mode')}"
        assert result["n_subjects"] == 3, f"Expected 3 subjects, got {result['n_subjects']}"

        # Verify input_units section
        assert "input_units" in result, "input_units not in result"
        assert result["input_units"]["time"] == "h", "Default time unit should be h"
        assert result["input_units"]["concentration"] == "ug/mL", "Default conc unit should be ug/mL"

        # Verify individual results
        assert "individual_results" in result, "individual_results not in result"
        assert len(result["individual_results"]) == 3, \
            f"Expected 3 individual results, got {len(result['individual_results'])}"

        # Verify individual result structure with units
        first_result = result["individual_results"][0]
        assert "subject_id" in first_result, "subject_id not in individual result"
        assert "dose_administered" in first_result, "dose_administered not in individual result"
        assert first_result["dose_administered"]["unit"] == "mg", "dose unit should be mg"

        # Verify Cmax has value/unit structure
        assert "Cmax" in first_result, "Cmax not in individual result"
        assert "value" in first_result["Cmax"], "Cmax should have value"
        assert "unit" in first_result["Cmax"], "Cmax should have unit"
        assert first_result["Cmax"]["unit"] == "ug/mL", "Cmax unit should be ug/mL"

        assert "auclast" in first_result, "auclast not in individual result"
        assert first_result["auclast"]["unit"] == "h*ug/mL", "auclast unit should be h*ug/mL"

        assert "half_life" in first_result, "half_life not in individual result"
        assert first_result["half_life"]["unit"] == "h", "half_life unit should be h"

        # Verify summary by dose
        assert "summary_by_dose" in result, "summary_by_dose not in result"
        assert len(result["summary_by_dose"]) == 3, \
            f"Expected 3 dose groups, got {len(result['summary_by_dose'])}"

        # Verify summary structure has value/unit pairs
        first_summary = list(result["summary_by_dose"].values())[0]
        assert "Cmax_mean" in first_summary, "Cmax_mean not in summary"
        assert "value" in first_summary["Cmax_mean"], "Cmax_mean should have value"
        assert "unit" in first_summary["Cmax_mean"], "Cmax_mean should have unit"
        assert first_summary["Cmax_mean"]["unit"] == "ug/mL", "Cmax_mean unit should be ug/mL"

        assert "auclast_mean" in first_summary, "auclast_mean not in summary"
        assert first_summary["auclast_mean"]["unit"] == "h*ug/mL", "auclast_mean unit should be h*ug/mL"

        assert "half_life_mean" in first_summary, "half_life_mean not in summary"
        assert first_summary["half_life_mean"]["unit"] == "h", "half_life_mean unit should be h"


@pytest.mark.asyncio
async def test_er_endpoint_binary_response():
    """Test ER endpoint with binary (0/1) response data"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Binary response data: ~10% at low exposure, ~50% at medium, ~90% at high
        raw = (await c.call_tool(
            "r_Exposure_response_ER_analysis",
            {
                "exposure": "50,55,60,65,70,75,150,160,170,180,190,200,500,520,540,560,580,600",
                "resp": "0,0,1,0,0,1,0,1,0,1,1,1,1,1,1,1,0,1",
                "dose": "10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg",
                "model": "auto",
                "n_quantiles": "3"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # For binary data, auto mode should select logit model
        assert result["model_used"] == "logit", \
            f"Expected logit model for binary data, got {result['model_used']}"

        # Verify logit parameters include EC50
        assert "parameters" in result, "parameters not in result"
        params = result["parameters"]
        assert "intercept" in params, "intercept not in logit parameters"
        assert "slope" in params, "slope not in logit parameters"
        assert "EC50" in params, "EC50 not in logit parameters"

        # Verify fit stats
        assert "fit_stats" in result, "fit_stats not in result"
        assert "AIC" in result["fit_stats"], "AIC not in fit_stats"

        # Verify plot was generated
        assert "plot_path" in result, "plot_path not in result"

        # Verify dose summary
        assert "dose_summary" in result, "dose_summary not in result"
        assert len(result["dose_summary"]) == 3, \
            f"Expected 3 dose groups, got {len(result['dose_summary'])}"


@pytest.mark.asyncio
async def test_pk_with_defaults():
    """Test PK endpoint works with default parameters (population mode)"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call PK endpoint with minimal parameters - uses defaults
        # Default: n_subjects=60, n_per_dose=20, dose=10,30,100
        raw = (await c.call_tool(
            "r_Pharmacokinetic_simulation_IV_1_or_2_CM",
            {
                "t": "0,0.25,0.5,1,2,4,8,12,24",
                "seed": "42"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode (default behavior)
        assert result.get("mode") == "population", f"Expected population mode, got {result.get('mode')}"

        # Verify output structure
        assert "model_used" in result, "model_used not in result"
        assert "plot_path" in result, "plot_path not in result"
        assert "individual_data" in result, "individual_data not in result"
        assert "summary_by_dose" in result, "summary_by_dose not in result"

        # Verify default values were used
        assert result["n_subjects"] == 60, f"Expected 60 subjects (default), got {result['n_subjects']}"
        assert len(result["summary_by_dose"]) == 3, "Expected 3 dose groups (10, 30, 100 mg)"


@pytest.mark.asyncio
async def test_nca_backwards_compatibility():
    """Test that single-subject NCA still works (backwards compatible parameters)"""
    async with Client(SSETransport(BASE_URL)) as c:
        # Call NCA endpoint with single subject (original parameters, new response format)
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,0.25,0.5,1,2,4,8,12,24",
                "conc": "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
                "dose": "100"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify single mode
        assert result.get("mode") == "single", f"Expected single mode, got {result.get('mode')}"

        # Verify main parameters exist (now with value/unit structure)
        assert "Cmax" in result, "Cmax not in result"
        assert "Tmax" in result, "Tmax not in result"
        assert "auclast" in result, "auclast not in result"
        assert "half_life" in result, "half_life not in result"
        assert "available_params" in result, "available_params not in result"

        # Verify new unit structure
        assert "input_units" in result, "input_units not in result"
        assert "dose_administered" in result, "dose_administered not in result"

        # Verify values are accessible via new structure
        assert result["Cmax"]["value"] > 0, "Cmax value should be positive"
        assert result["half_life"]["value"] > 0, "half_life value should be positive"

        # Should not have population-specific fields
        assert "individual_results" not in result, "individual_results should not be in single mode"
        assert "n_subjects" not in result, "n_subjects should not be in single mode"


@pytest.mark.asyncio
async def test_nca_with_explicit_units():
    """Test NCA endpoint with explicit unit parameters"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "100,90,75,50,25,12,3",
                "dose": "50",
                "dose_unit": "mg",
                "conc_unit": "ng/mL",
                "time_unit": "h"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify units are reflected in response
        assert result["input_units"]["time"] == "h", "time unit should be h"
        assert result["input_units"]["concentration"] == "ng/mL", "conc unit should be ng/mL"
        assert result["input_units"]["dose"] == "mg", "dose unit should be mg"

        # Verify parameter units reflect input units
        assert result["Cmax"]["unit"] == "ng/mL", "Cmax unit should be ng/mL"
        assert result["Tmax"]["unit"] == "h", "Tmax unit should be h"
        assert result["auclast"]["unit"] == "h*ng/mL", "auclast unit should be h*ng/mL"
        assert result["half_life"]["unit"] == "h", "half_life unit should be h"


@pytest.mark.asyncio
async def test_nca_with_mg_kg_dosing():
    """Test NCA endpoint with mg/kg dosing and body weight"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "100,90,75,50,25,12,3",
                "dose": "1.5",
                "dose_unit": "mg/kg",
                "BW": "70",
                "conc_unit": "ug/mL",
                "time_unit": "h"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify dose handling
        assert result["dose_administered"]["value"] == 1.5, "dose value should be 1.5"
        assert result["dose_administered"]["unit"] == "mg/kg", "dose unit should be mg/kg"

        # Verify effective dose is calculated
        assert "effective_dose" in result, "effective_dose should be present for mg/kg dosing"
        assert result["effective_dose"]["value"] == 105, "effective dose should be 1.5 * 70 = 105"
        assert result["effective_dose"]["unit"] == "mg", "effective dose unit should be mg"
        assert result["effective_dose"]["BW"] == 70, "BW should be recorded"

        # Verify NCA parameters are calculated
        assert result["Cmax"]["value"] > 0, "Cmax should be calculated"


@pytest.mark.asyncio
async def test_nca_with_minutes_time_unit():
    """Test NCA endpoint with minutes as time unit"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,15,30,60,120,240,480",
                "conc": "100,90,75,50,25,12,3",
                "dose": "50",
                "time_unit": "min"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify time unit is reflected
        assert result["input_units"]["time"] == "min", "time unit should be min"
        assert result["Tmax"]["unit"] == "min", "Tmax unit should be min"
        assert result["half_life"]["unit"] == "min", "half_life unit should be min"
        assert result["auclast"]["unit"] == "min*ug/mL", "auclast unit should be min*ug/mL"


# ==================== Enhanced NCA Tests ====================

@pytest.mark.asyncio
async def test_nca_iv_bolus_route():
    """Test NCA endpoint with IV bolus route"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,0.25,0.5,1,2,4,8,12,24",
                "conc": "100,90,80,65,45,25,12,6,1.5",
                "dose": "100",
                "route": "iv_bolus"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings include route
        assert "analysis_settings" in result, "analysis_settings not in result"
        assert result["analysis_settings"]["route"] == "iv_bolus", \
            f"route should be iv_bolus, got {result['analysis_settings']['route']}"

        # Verify NCA parameters are calculated
        assert result["Cmax"]["value"] > 0, "Cmax should be calculated"
        assert result["half_life"]["value"] > 0, "half_life should be calculated"


@pytest.mark.asyncio
async def test_nca_iv_infusion_route():
    """Test NCA endpoint with IV infusion route"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,0.5,1,2,4,8,12,24",
                "conc": "0,50,100,80,50,25,12,3",
                "dose": "100",
                "route": "iv_infusion",
                "infusion_duration": "1"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings
        assert result["analysis_settings"]["route"] == "iv_infusion", \
            "route should be iv_infusion"

        # Verify NCA parameters are calculated
        assert result["Cmax"]["value"] > 0, "Cmax should be calculated"


@pytest.mark.asyncio
async def test_nca_extravascular_route():
    """Test NCA endpoint with extravascular route (default)"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "0,5,10,15,12,8,4",
                "dose": "50",
                "route": "extravascular"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings
        assert result["analysis_settings"]["route"] == "extravascular", \
            "route should be extravascular"

        # Verify NCA parameters
        assert result["Cmax"]["value"] > 0, "Cmax should be calculated"
        assert result["Tmax"]["value"] > 0, "Tmax should be > 0 for extravascular"


@pytest.mark.asyncio
async def test_nca_repeat_dosing():
    """Test NCA endpoint with repeat dosing scenario"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24,25,26,28,32,36,48",
                "conc": "0,5,10,15,12,8,4,9,14,18,14,10,5",
                "dose": "50",
                "route": "extravascular",
                "dosing_scenario": "repeat",
                "tau": "24"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings
        assert result["analysis_settings"]["dosing_scenario"] == "repeat", \
            "dosing_scenario should be repeat"

        # Verify NCA parameters are calculated
        assert result["Cmax"]["value"] > 0, "Cmax should be calculated"


@pytest.mark.asyncio
async def test_nca_custom_auc_method():
    """Test NCA endpoint with custom AUC method"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "10,8,6,4,2,1,0.25",
                "dose": "100",
                "auc_method": "linear"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings
        assert result["analysis_settings"]["auc_method"] == "linear", \
            "auc_method should be linear"

        # Verify AUC is calculated
        assert result["auclast"]["value"] > 0, "auclast should be calculated"


@pytest.mark.asyncio
async def test_nca_custom_half_life_criteria():
    """Test NCA endpoint with custom half-life criteria"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "10,8,6,4,2,1,0.25",
                "dose": "100",
                "min_hl_points": "4",
                "min_hl_r_squared": "0.95"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings
        assert result["analysis_settings"]["min_hl_points"] == 4, \
            "min_hl_points should be 4"
        assert result["analysis_settings"]["min_hl_r_squared"] == 0.95, \
            "min_hl_r_squared should be 0.95"


@pytest.mark.asyncio
async def test_nca_custom_extrapolation_limit():
    """Test NCA endpoint with custom extrapolation limit"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "10,8,6,4,2,1,0.25",
                "dose": "100",
                "max_aucinf_pext": "15"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings
        assert result["analysis_settings"]["max_aucinf_pext"] == 15, \
            "max_aucinf_pext should be 15"


@pytest.mark.asyncio
async def test_nca_blq_handling():
    """Test NCA endpoint with BLQ handling options"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "10,8,6,4,2,1,0.25",
                "dose": "100",
                "blq_first": "drop",
                "blq_middle": "zero",
                "blq_last": "keep"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify analysis settings include BLQ handling
        assert "blq_handling" in result["analysis_settings"], \
            "blq_handling not in analysis_settings"
        blq = result["analysis_settings"]["blq_handling"]
        assert blq["first"] == "drop", "blq_first should be drop"
        assert blq["middle"] == "zero", "blq_middle should be zero"
        assert blq["last"] == "keep", "blq_last should be keep"


@pytest.mark.asyncio
async def test_nca_results_structure():
    """Test NCA endpoint returns enhanced results structure"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,0.25,0.5,1,2,4,8,12,24",
                "conc": "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
                "dose": "100",
                "route": "iv_bolus"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify new results structure
        assert "results" in result, "results not in result"
        results = result["results"]

        # Verify common parameters are present
        assert "cmax" in results, "cmax not in results"
        assert "tmax" in results, "tmax not in results"
        assert "auclast" in results, "auclast not in results"
        assert "half.life" in results, "half.life not in results"
        assert "lambda.z" in results, "lambda.z not in results"

        # Verify each parameter has value/unit structure
        assert "value" in results["cmax"], "cmax should have value"
        assert "unit" in results["cmax"], "cmax should have unit"
        assert results["cmax"]["unit"] == "ug/mL", "cmax unit should be ug/mL"

        assert "value" in results["lambda.z"], "lambda.z should have value"
        assert results["lambda.z"]["unit"] == "1/h", "lambda.z unit should be 1/h"


@pytest.mark.asyncio
async def test_nca_all_business_rules():
    """Test NCA endpoint with all business rules specified"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24",
                "conc": "10,8,6,4,2,1,0.25",
                "dose": "100",
                "route": "extravascular",
                "dosing_scenario": "single",
                "auc_method": "lin up/log down",
                "min_hl_points": "3",
                "min_hl_r_squared": "0.9",
                "max_aucinf_pext": "20",
                "first_tmax": "true",
                "blq_first": "keep",
                "blq_middle": "drop",
                "blq_last": "keep"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify all analysis settings
        settings = result["analysis_settings"]
        assert settings["route"] == "extravascular"
        assert settings["dosing_scenario"] == "single"
        assert settings["auc_method"] == "lin up/log down"
        assert settings["min_hl_points"] == 3
        assert settings["min_hl_r_squared"] == 0.9
        assert settings["max_aucinf_pext"] == 20

        # Verify NCA parameters calculated
        assert result["Cmax"]["value"] > 0
        assert result["auclast"]["value"] > 0


@pytest.mark.asyncio
async def test_nca_population_with_routes():
    """Test NCA endpoint with population mode and route specification"""
    async with Client(SSETransport(BASE_URL)) as c:
        raw = (await c.call_tool(
            "r_Noncompartmental_analysis_NCA",
            {
                "time": "0,1,2,4,8,12,24|0,1,2,4,8,12,24",
                "conc": "10,9,7.5,5,2.5,1.2,0.3|30,27,22,15,7.5,3.6,0.9",
                "dose": "10|30",
                "subject_id": "SUBJ001|SUBJ002",
                "dose_label": "10 mg|30 mg",
                "route": "iv_bolus"
            }
        ))[0].model_dump_json()

        result = extract_result(raw)

        # Verify population mode
        assert result["mode"] == "population", "mode should be population"
        assert result["n_subjects"] == 2, "should have 2 subjects"

        # Verify analysis settings include route
        assert result["analysis_settings"]["route"] == "iv_bolus"

        # Verify individual results
        assert len(result["individual_results"]) == 2
        first_result = result["individual_results"][0]
        assert first_result["subject_id"] == "SUBJ001"
        assert first_result["Cmax"]["value"] > 0
