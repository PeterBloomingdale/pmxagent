# tests/test_endpoints.py
# Integration tests for PMxAgent R API endpoints via MCP server

import pytest
from conftest import call_tool_ok

NCA_TOOL  = "r_Noncompartmental_analysis_NCA"
ER_TOOL   = "r_Exposure_response_ER_analysis"
PK_TOOL   = "r_Pharmacokinetic_simulation_IV_1_or_2_CM"
DATA_TOOL = "r_Format_data_for_pharmacometric_analyses"


@pytest.mark.asyncio
async def test_list_all_tools(mcp_client):
    """Test that all expected R API tools are available"""
    tools = await mcp_client.list_tools()
    tool_names = [t.name for t in tools]

    for expected in [NCA_TOOL, ER_TOOL, PK_TOOL, DATA_TOOL]:
        assert expected in tool_names, \
            f"{expected} not found in available tools: {tool_names}"


# ==================== NCA Tests ====================

@pytest.mark.asyncio
async def test_nca_endpoint(mcp_client):
    """Test Non-Compartmental Analysis endpoint with unit handling"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,0.25,0.5,1,2,4,8,12,24",
        "conc": "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
        "dose": "100"
    })

    # Verify response structure
    assert result["mode"] == "single"

    # Verify input_units
    assert result["input_units"]["time"] == "h"
    assert result["input_units"]["concentration"] == "ug/mL"
    assert result["input_units"]["dose"] == "mg"

    # Verify dose_administered
    assert result["dose_administered"]["value"] == 100
    assert result["dose_administered"]["unit"] == "mg"

    # Verify main parameters have value/unit structure
    assert isinstance(result["Cmax"], dict)
    assert result["Cmax"]["value"] > 0
    assert result["Cmax"]["unit"] == "ug/mL"

    assert result["Tmax"]["value"] >= 0
    assert result["Tmax"]["unit"] == "h"

    assert result["auclast"]["value"] > 0
    assert result["auclast"]["unit"] == "h*ug/mL"

    assert result["half_life"]["value"] > 0
    assert result["half_life"]["unit"] == "h"

    # Verify available_params also have value/unit structure
    assert "available_params" in result
    if "cmax" in result["available_params"]:
        assert "value" in result["available_params"]["cmax"]
        assert "unit" in result["available_params"]["cmax"]

    # Verify no population-specific fields in single mode
    assert "individual_results" not in result
    assert "n_subjects" not in result


@pytest.mark.asyncio
async def test_nca_endpoint_multi_subject(mcp_client):
    """Test NCA endpoint with multi-subject (pipe-separated) mode and unit handling"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,1,2,4,8,12,24|0,1,2,4,8,12,24|0,1,2,4,8,12,24",
        "conc": "10,9,7.5,5,2.5,1.2,0.3|30,27,22,15,7.5,3.6,0.9|100,90,75,50,25,12,3",
        "dose": "10|30|100",
        "subject_id": "SUBJ001|SUBJ002|SUBJ003",
        "dose_label": "10 mg|30 mg|100 mg"
    })

    # Verify population mode
    assert result["mode"] == "population"
    assert result["n_subjects"] == 3
    assert result["input_units"]["time"] == "h"
    assert result["input_units"]["concentration"] == "ug/mL"

    # Verify individual results
    assert len(result["individual_results"]) == 3
    first_result = result["individual_results"][0]
    assert "subject_id" in first_result
    assert first_result["dose_administered"]["unit"] == "mg"
    assert first_result["Cmax"]["unit"] == "ug/mL"
    assert first_result["auclast"]["unit"] == "h*ug/mL"
    assert first_result["half_life"]["unit"] == "h"

    # Verify summary by dose
    assert len(result["summary_by_dose"]) == 3
    first_summary = list(result["summary_by_dose"].values())[0]
    assert first_summary["Cmax_mean"]["unit"] == "ug/mL"
    assert first_summary["auclast_mean"]["unit"] == "h*ug/mL"
    assert first_summary["half_life_mean"]["unit"] == "h"


@pytest.mark.asyncio
async def test_nca_with_explicit_units(mcp_client):
    """Test NCA endpoint with explicit unit parameters"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,1,2,4,8,12,24",
        "conc": "100,90,75,50,25,12,3",
        "dose": "50",
        "dose_unit": "mg",
        "conc_unit": "ng/mL",
        "time_unit": "h"
    })

    assert result["input_units"]["concentration"] == "ng/mL"
    assert result["Cmax"]["unit"] == "ng/mL"
    assert result["auclast"]["unit"] == "h*ng/mL"


@pytest.mark.asyncio
async def test_nca_with_mg_kg_dosing(mcp_client):
    """Test NCA endpoint with mg/kg dosing and body weight"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,1,2,4,8,12,24",
        "conc": "100,90,75,50,25,12,3",
        "dose": "1.5",
        "dose_unit": "mg/kg",
        "BW": "70",
        "conc_unit": "ug/mL",
        "time_unit": "h"
    })

    assert result["dose_administered"]["value"] == 1.5
    assert result["dose_administered"]["unit"] == "mg/kg"
    assert result["effective_dose"]["value"] == 105
    assert result["effective_dose"]["unit"] == "mg"
    assert result["effective_dose"]["BW"] == 70
    assert result["Cmax"]["value"] > 0


@pytest.mark.asyncio
async def test_nca_with_minutes_time_unit(mcp_client):
    """Test NCA endpoint with minutes as time unit"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,15,30,60,120,240,480",
        "conc": "100,90,75,50,25,12,3",
        "dose": "50",
        "time_unit": "min"
    })

    assert result["input_units"]["time"] == "min"
    assert result["Tmax"]["unit"] == "min"
    assert result["half_life"]["unit"] == "min"
    assert result["auclast"]["unit"] == "min*ug/mL"


@pytest.mark.asyncio
@pytest.mark.parametrize("route,extra_args,expected_route", [
    ("iv_bolus", {}, "iv_bolus"),
    ("iv_infusion", {"infusion_duration": "1"}, "iv_infusion"),
    ("extravascular", {}, "extravascular"),
])
async def test_nca_routes(mcp_client, route, extra_args, expected_route):
    """Test NCA endpoint with different routes of administration"""
    args = {
        "time": "0,0.25,0.5,1,2,4,8,12,24",
        "conc": "100,90,80,65,45,25,12,6,1.5" if route != "iv_infusion" else "0,50,100,80,50,25,12,6,3",
        "dose": "100",
        "route": route,
        **extra_args
    }
    result = await call_tool_ok(mcp_client, NCA_TOOL, args)

    assert result["analysis_settings"]["route"] == expected_route
    assert result["Cmax"]["value"] > 0


@pytest.mark.asyncio
async def test_nca_repeat_dosing(mcp_client):
    """Test NCA endpoint with repeat dosing scenario"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,1,2,4,8,12,24,25,26,28,32,36,48",
        "conc": "0,5,10,15,12,8,4,9,14,18,14,10,5",
        "dose": "50",
        "route": "extravascular",
        "dosing_scenario": "repeat",
        "tau": "24"
    })

    assert result["analysis_settings"]["dosing_scenario"] == "repeat"
    assert result["Cmax"]["value"] > 0


@pytest.mark.asyncio
@pytest.mark.parametrize("rule_args,expected_settings", [
    (
        {"auc_method": "linear"},
        {"auc_method": "linear"},
    ),
    (
        {"min_hl_points": "4", "min_hl_r_squared": "0.95"},
        {"min_hl_points": 4, "min_hl_r_squared": 0.95},
    ),
    (
        {"max_aucinf_pext": "15"},
        {"max_aucinf_pext": 15},
    ),
])
async def test_nca_business_rules(mcp_client, rule_args, expected_settings):
    """Test NCA endpoint with custom business rules"""
    args = {
        "time": "0,1,2,4,8,12,24",
        "conc": "10,8,6,4,2,1,0.25",
        "dose": "100",
        **rule_args
    }
    result = await call_tool_ok(mcp_client, NCA_TOOL, args)

    for key, value in expected_settings.items():
        assert result["analysis_settings"][key] == value, \
            f"{key} should be {value}"


@pytest.mark.asyncio
async def test_nca_blq_handling(mcp_client):
    """Test NCA endpoint with BLQ handling options"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,1,2,4,8,12,24",
        "conc": "10,8,6,4,2,1,0.25",
        "dose": "100",
        "blq_first": "drop",
        "blq_middle": "zero",
        "blq_last": "keep"
    })

    blq = result["analysis_settings"]["blq_handling"]
    assert blq["first"] == "drop"
    assert blq["middle"] == "zero"
    assert blq["last"] == "keep"


@pytest.mark.asyncio
async def test_nca_results_structure(mcp_client):
    """Test NCA endpoint returns enhanced results structure"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,0.25,0.5,1,2,4,8,12,24",
        "conc": "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
        "dose": "100",
        "route": "iv_bolus"
    })

    results = result["results"]
    for param in ["cmax", "tmax", "auclast", "half.life", "lambda.z"]:
        assert param in results, f"{param} not in results"
        assert "value" in results[param]
        assert "unit" in results[param]

    assert results["cmax"]["unit"] == "ug/mL"
    assert results["lambda.z"]["unit"] == "1/h"


@pytest.mark.asyncio
async def test_nca_population_with_routes(mcp_client):
    """Test NCA endpoint with population mode and route specification"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "0,1,2,4,8,12,24|0,1,2,4,8,12,24",
        "conc": "10,9,7.5,5,2.5,1.2,0.3|30,27,22,15,7.5,3.6,0.9",
        "dose": "10|30",
        "subject_id": "SUBJ001|SUBJ002",
        "dose_label": "10 mg|30 mg",
        "route": "iv_bolus"
    })

    assert result["mode"] == "population"
    assert result["n_subjects"] == 2
    assert result["analysis_settings"]["route"] == "iv_bolus"
    assert len(result["individual_results"]) == 2
    assert result["individual_results"][0]["subject_id"] == "SUBJ001"
    assert result["individual_results"][0]["Cmax"]["value"] > 0


# ==================== ER Tests ====================

@pytest.mark.asyncio
async def test_er_endpoint(mcp_client):
    """Test Exposure-Response analysis endpoint"""
    result = await call_tool_ok(mcp_client, ER_TOOL, {
        "exposure": "0.1,0.5,1,2,5,10,20,50,100",
        "resp": "5,15,25,40,60,75,85,92,95",
        "dose": "10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg",
        "model": "auto"
    })

    assert result["model_used"] in ["linear", "emax", "imax", "logit"]
    assert "parameters" in result
    assert "AIC" in result["fit_stats"]
    assert "plot_path" in result
    assert "all_models" in result


@pytest.mark.asyncio
async def test_er_endpoint_with_exposure_and_dose(mcp_client):
    """Test ER endpoint with exposure parameter and dose groups"""
    result = await call_tool_ok(mcp_client, ER_TOOL, {
        "exposure": "25,30,35,50,60,70,100,120,140,160,180,200",
        "resp": "0.2,0.22,0.25,0.35,0.38,0.4,0.5,0.52,0.55,0.58,0.6,0.62",
        "dose": "60 mg,60 mg,60 mg,120 mg,120 mg,120 mg,240 mg,240 mg,240 mg,240 mg,240 mg,240 mg",
        "model": "auto",
        "n_quantiles": "4"
    })

    assert "model_used" in result
    assert "plot_path" in result

    # Verify quantile summary
    assert len(result["quantile_summary"]) == 4
    first_q = result["quantile_summary"][0]
    for field in ["quantile", "n", "exposure_median", "resp_mean", "resp_ci_lower", "resp_ci_upper"]:
        assert field in first_q, f"{field} missing from quantile_summary"

    # Verify dose summary
    assert len(result["dose_summary"]) == 3
    first_dose = result["dose_summary"][0]
    for field in ["dose", "n", "exposure_mean", "exposure_min", "exposure_max"]:
        assert field in first_dose, f"{field} missing from dose_summary"

    dose_names = [d["dose"] for d in result["dose_summary"]]
    assert "60 mg" in dose_names
    assert "120 mg" in dose_names
    assert "240 mg" in dose_names


@pytest.mark.asyncio
async def test_er_endpoint_binary_response(mcp_client):
    """Test ER endpoint with binary (0/1) response data"""
    result = await call_tool_ok(mcp_client, ER_TOOL, {
        "exposure": "50,55,60,65,70,75,150,160,170,180,190,200,500,520,540,560,580,600",
        "resp": "0,0,1,0,0,1,0,1,0,1,1,1,1,1,1,1,0,1",
        "dose": "10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg",
        "model": "auto",
        "n_quantiles": "3"
    })

    assert result["model_used"] == "logit"
    assert "intercept" in result["parameters"]
    assert "slope" in result["parameters"]
    assert "EC50" in result["parameters"]
    assert "AIC" in result["fit_stats"]
    assert "plot_path" in result
    assert len(result["dose_summary"]) == 3


@pytest.mark.asyncio
async def test_er_endpoint_resp_rate(mcp_client):
    """Test ER endpoint with resp_rate generating binary responses from rates + seed"""
    result = await call_tool_ok(mcp_client, ER_TOOL, {
        "exposure": "50,55,60,65,70,75,150,160,170,180,190,200,500,520,540,560,580,600",
        "dose": "10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg",
        "resp_rate": "0.1,0.5,0.9",
        "seed": "42",
        "model": "auto",
        "n_quantiles": "3"
    })

    assert result["model_used"] == "logit"
    assert "plot_path" in result
    assert len(result["dose_summary"]) == 3

    # Verify resp_rate generation metadata
    assert "resp_rate_generation" in result
    gen = result["resp_rate_generation"]
    assert gen["resp_rate"] == [0.1, 0.5, 0.9]
    assert gen["seed"] == 42
    assert len(gen["generated_resp"]) == 18
    assert all(r in [0, 1] for r in gen["generated_resp"])


@pytest.mark.asyncio
async def test_er_endpoint_resp_rate_reproducibility(mcp_client):
    """Test that resp_rate + seed produces identical results across calls"""
    args = {
        "exposure": "50,55,60,65,70,75,150,160,170,180,190,200,500,520,540,560,580,600",
        "dose": "10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg",
        "resp_rate": "0.1,0.5,0.9",
        "seed": "123",
        "model": "auto"
    }

    result1 = await call_tool_ok(mcp_client, ER_TOOL, args)
    result2 = await call_tool_ok(mcp_client, ER_TOOL, args)

    # Same seed should produce identical binary responses
    assert result1["resp_rate_generation"]["generated_resp"] == result2["resp_rate_generation"]["generated_resp"]
    # And therefore identical model parameters
    assert result1["parameters"] == result2["parameters"]


# ==================== PK Tests ====================

@pytest.mark.asyncio
async def test_pk_endpoint_1cm(mcp_client):
    """Test PK simulation endpoint - one compartment model"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100",
        "CL": "1",
        "V1": "10",
        "n_subjects": "5",
        "t": "0,0.25,0.5,1,2,4,8,12,24",
        "model": "1cm",
        "seed": "42"
    })

    assert result["mode"] == "population"
    assert result["model_used"] == "one-compartment"
    assert "plot_path" in result
    assert len(result["individual_data"]) == 5

    # Concentrations should decrease over time
    first_subj = result["individual_data"][0]
    assert first_subj["concentrations"][0] > first_subj["concentrations"][-1]


@pytest.mark.asyncio
async def test_pk_endpoint_2cm(mcp_client):
    """Test PK simulation endpoint - two compartment model"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100",
        "CL": "1",
        "V1": "10",
        "V2": "20",
        "Q": "2",
        "n_subjects": "5",
        "t": "0,0.25,0.5,1,2,4,8,12,24",
        "model": "2cm",
        "seed": "42"
    })

    assert result["mode"] == "population"
    assert result["model_used"] == "two-compartment"
    assert all(c > 0 for c in result["individual_data"][0]["concentrations"])


@pytest.mark.asyncio
async def test_pk_endpoint_auto_selection(mcp_client):
    """Test PK endpoint auto-selects correct model based on parameters"""
    result_1cm = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100", "CL": "1", "V1": "10",
        "t": "0,1,2,4,8", "model": "1cm"
    })
    assert result_1cm["model_used"] == "one-compartment"

    result_2cm = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100", "CL": "1", "V1": "10", "V2": "20", "Q": "2",
        "t": "0,1,2,4,8", "model": "2cm"
    })
    assert result_2cm["model_used"] == "two-compartment"


@pytest.mark.asyncio
async def test_pk_population_mode(mcp_client):
    """Test PK endpoint with population mode (TV + OMEGA)"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "n_subjects": "30",
        "n_per_dose": "10",
        "dose": "10,30,100",
        "cv": "0.25",
        "BW": "70",
        "t": "0,1,2,4,8,12,24,48,168,336",
        "seed": "42"
    })

    assert result["mode"] == "population"
    assert result["model_used"] == "two-compartment"
    assert result["n_subjects"] == 30

    # Verify variability and typical values
    assert result["variability"]["cv"] == 0.25
    assert "Betts" in result["typical_values"]["source"]
    assert result["typical_values"]["CL"] == 0.15
    assert result["typical_values"]["V1"] == 46.31

    # Verify individual data structure
    assert len(result["individual_data"]) == 30
    first_subj = result["individual_data"][0]
    for field in ["subject_id", "CL", "V1", "concentrations"]:
        assert field in first_subj, f"{field} not in individual data"

    # Verify summary and plot
    assert len(result["summary_by_dose"]) == 3
    assert result["plot_path"].endswith(".png")
    assert result["seed"] == 42


@pytest.mark.asyncio
async def test_pk_endpoint_multi_subject(mcp_client):
    """Test PK endpoint with multi-subject mode using default params"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "10,30,100",
        "n_subjects": "6",
        "n_per_dose": "2",
        "t": "0,1,2,4,8,12,24",
        "model": "2cm",
        "seed": "42"
    })

    assert result["mode"] == "population"
    assert result["model_used"] == "two-compartment"
    assert result["n_subjects"] == 6
    assert len(result["individual_data"]) == 6

    first_subj = result["individual_data"][0]
    for field in ["subject_id", "times", "concentrations"]:
        assert field in first_subj

    assert len(result["summary_by_dose"]) == 3
    assert result["plot_path"].endswith(".png")


@pytest.mark.asyncio
async def test_pk_with_defaults(mcp_client):
    """Test PK endpoint works with default parameters"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "t": "0,0.25,0.5,1,2,4,8,12,24",
        "seed": "42"
    })

    assert result["mode"] == "population"
    assert "model_used" in result
    assert "plot_path" in result
    assert result["n_subjects"] == 60
    assert len(result["summary_by_dose"]) == 3


# ==================== DATA Tests ====================

@pytest.mark.asyncio
async def test_data_tool_in_list(mcp_client):
    """Test that Format_data_for_pharmacometric_analyses appears in tool list"""
    tools = await mcp_client.list_tools()
    tool_names = [t.name for t in tools]
    assert DATA_TOOL in tool_names, \
        f"{DATA_TOOL} not found in tools: {tool_names}"


@pytest.mark.asyncio
async def test_data_endpoint_example_file(mcp_client):
    """Test DATA endpoint with example_pk_data.csv returns correct ADPC structure"""
    result = await call_tool_ok(mcp_client, DATA_TOOL, {
        "file_path": "example_pk_data.csv",
        "route": "extravascular",
        "conc_unit": "ug/mL"
    })

    assert result["status"] == "success"
    assert result["dataset_type"] == "adpc"
    assert result["source_file"] == "example_pk_data.csv"
    assert result["n_subjects"] == 3
    assert result["n_records"] == 15  # 3 subjects × 5 observation time points (dosing row at time 0 filtered)
    assert "output_file" in result
    assert result["output_file"].endswith(".csv")

    # Verify all required ADPC columns present
    expected_cols = ["USUBJID", "ATPTN", "AVAL", "AVALU", "DOSE", "DOSEU", "DOSNO", "ROUTE", "BLQ"]
    for col in expected_cols:
        assert col in result["columns"], f"Column '{col}' missing from ADPC output"

    # Verify column mapping reported
    assert result["input_column_mapping"]["subject_col"] == "ID"
    assert result["input_column_mapping"]["time_col"] == "TIME"
    assert result["input_column_mapping"]["conc_col"] == "DV"
    assert result["input_column_mapping"]["dose_col"] == "AMT"

    # Verify summary
    assert len(result["summary"]["subjects"]) == 3
    assert len(result["summary"]["time_range"]) == 2
    assert len(result["summary"]["conc_range"]) == 2
    assert len(result["summary"]["dose_per_subject"]) == 3


@pytest.mark.asyncio
async def test_data_endpoint_missing_file_error(mcp_client):
    """Test DATA endpoint returns actionable error when file not found"""
    with pytest.raises(Exception) as exc_info:
        await mcp_client.call_tool(DATA_TOOL, {"file_path": "nonexistent_study.csv"})

    error_msg = str(exc_info.value)
    assert "nonexistent_study.csv" in error_msg
    assert "Available in /data" in error_msg


@pytest.mark.asyncio
async def test_data_endpoint_wrong_column_error(mcp_client):
    """Test DATA endpoint returns actionable error when column name is wrong"""
    with pytest.raises(Exception) as exc_info:
        await mcp_client.call_tool(DATA_TOOL, {
            "file_path": "example_pk_data.csv",
            "conc_col": "CONC"  # wrong column name
        })

    error_msg = str(exc_info.value)
    assert "CONC" in error_msg
    assert "Available:" in error_msg


@pytest.mark.asyncio
async def test_data_endpoint_unsupported_type_error(mcp_client):
    """Test DATA endpoint returns actionable error for unsupported dataset_type"""
    with pytest.raises(Exception) as exc_info:
        await mcp_client.call_tool(DATA_TOOL, {
            "file_path": "example_pk_data.csv",
            "dataset_type": "nonmem_pk"
        })

    error_msg = str(exc_info.value)
    assert "nonmem_pk" in error_msg
    assert "v2" in error_msg.lower() or "v1" in error_msg.lower()


# ==================== PK CSV Output Tests ====================

@pytest.mark.asyncio
async def test_pk_save_csv(mcp_client):
    """Test PK endpoint with save_csv=true returns output_file field"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100",
        "n_subjects": "5",
        "t": "0,1,2,4,8,12,24",
        "model": "1cm",
        "seed": "42",
        "save_csv": "true"
    })

    assert "output_file" in result, "output_file field missing when save_csv=true"
    assert result["output_file"].startswith("pk_simulation_")
    assert result["output_file"].endswith(".csv")


@pytest.mark.asyncio
async def test_pk_no_csv_by_default(mcp_client):
    """Test PK endpoint does NOT include output_file when save_csv not set"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100",
        "n_subjects": "5",
        "t": "0,1,2,4,8",
        "model": "1cm",
        "seed": "42"
    })

    assert "output_file" not in result, "output_file should not appear when save_csv is not set"


# ==================== NCA data_file Tests ====================

@pytest.mark.asyncio
async def test_nca_with_data_file(mcp_client):
    """Test NCA endpoint reads ADPC file produced by /DATA and runs population NCA"""
    # Step 1: produce ADPC file via DATA endpoint
    data_result = await call_tool_ok(mcp_client, DATA_TOOL, {
        "file_path": "example_pk_data.csv",
        "route": "extravascular",
        "conc_unit": "ug/mL"
    })
    adpc_file = data_result["output_file"]

    # Step 2: run NCA reading that ADPC file
    nca_result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "data_file": adpc_file,
        "route": "extravascular",
        "conc_unit": "ug/mL"
    })

    assert nca_result["mode"] == "population"
    assert nca_result["n_subjects"] == 3
    assert nca_result["source_file"] == adpc_file
    assert len(nca_result["individual_results"]) == 3

    for subj_result in nca_result["individual_results"]:
        assert subj_result["Cmax"]["value"] > 0
        assert subj_result["auclast"]["value"] > 0


@pytest.mark.asyncio
async def test_nca_data_file_missing_error(mcp_client):
    """Test NCA endpoint returns actionable error when data_file not found"""
    with pytest.raises(Exception) as exc_info:
        await mcp_client.call_tool(NCA_TOOL, {"data_file": "ghost_adpc.csv"})

    error_msg = str(exc_info.value)
    assert "ghost_adpc.csv" in error_msg
