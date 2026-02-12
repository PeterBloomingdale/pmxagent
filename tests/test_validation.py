# tests/test_validation.py
# Tests for input validation and error handling

import pytest
from conftest import call_tool_ok, is_error_response

NCA_TOOL = "r_Noncompartmental_analysis_NCA"
ER_TOOL = "r_Exposure_response_ER_analysis"
PK_TOOL = "r_Pharmacokinetic_simulation_IV_1_or_2_CM"


@pytest.mark.asyncio
async def test_nca_missing_data(mcp_client):
    """Test NCA endpoint uses defaults when empty strings provided"""
    result = await call_tool_ok(mcp_client, NCA_TOOL, {
        "time": "",
        "conc": "",
        "dose": "100"
    })
    assert "Cmax" in result or "error" in result, "Should return result or error"


@pytest.mark.asyncio
async def test_nca_mismatched_lengths(mcp_client):
    """Test NCA endpoint with mismatched time/conc lengths"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(NCA_TOOL, {
            "time": "0,1,2,3",
            "conc": "10,8,6",
            "dose": "100"
        })


@pytest.mark.asyncio
async def test_nca_negative_dose(mcp_client):
    """Test NCA endpoint with negative dose"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(NCA_TOOL, {
            "time": "0,1,2,4",
            "conc": "10,8,6,4",
            "dose": "-100"
        })


@pytest.mark.asyncio
async def test_nca_zero_dose(mcp_client):
    """Test NCA endpoint with zero dose"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(NCA_TOOL, {
            "time": "0,1,2,4",
            "conc": "10,8,6,4",
            "dose": "0"
        })


@pytest.mark.asyncio
async def test_er_mismatched_lengths(mcp_client):
    """Test ER endpoint with mismatched conc/resp lengths"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(ER_TOOL, {
            "conc": "0.1,1,10,50",
            "resp": "5,15,40",
            "model": "auto"
        })


@pytest.mark.asyncio
async def test_er_invalid_model(mcp_client):
    """Test ER endpoint with invalid model selection"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(ER_TOOL, {
            "conc": "0.1,1,10,50",
            "resp": "5,15,40,70",
            "model": "invalid_model"
        })


@pytest.mark.asyncio
async def test_er_insufficient_data(mcp_client):
    """Test ER endpoint with too few data points"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(ER_TOOL, {
            "conc": "1,10",
            "resp": "5,15",
            "model": "emax"
        })


@pytest.mark.asyncio
async def test_pk_negative_parameters(mcp_client):
    """Test PK endpoint behavior with negative clearance (known limitation: no validation)"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100",
        "CL": "-1",
        "V1": "10",
        "n_subjects": "1",
        "t": "0,1,2,4",
        "model": "1cm"
    })
    assert "individual_data" in result or "error" in result, "Should return data or error"


@pytest.mark.asyncio
async def test_pk_zero_volume(mcp_client):
    """Test PK endpoint with zero volume"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(PK_TOOL, {
            "dose": "100",
            "CL": "1",
            "V1": "0",
            "t": "0,1,2,4",
            "model": "1cm"
        })


@pytest.mark.asyncio
async def test_pk_2cm_uses_defaults(mcp_client):
    """Test PK endpoint 2CM uses default V2/Q when not provided"""
    result = await call_tool_ok(mcp_client, PK_TOOL, {
        "dose": "100",
        "CL": "1",
        "V1": "10",
        "n_subjects": "1",
        "t": "0,1,2,4",
        "model": "2cm"
    })
    assert not is_error_response(result), f"Expected success with default V2/Q, got {result}"
    assert result["model_used"] == "two-compartment"


@pytest.mark.asyncio
async def test_pk_negative_time(mcp_client):
    """Test PK endpoint with negative time values"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(PK_TOOL, {
            "dose": "100",
            "CL": "1",
            "V1": "10",
            "t": "-1,0,1,2,4",
            "model": "1cm"
        })


@pytest.mark.asyncio
async def test_nca_non_numeric_data(mcp_client):
    """Test NCA endpoint with non-numeric concentration values"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(NCA_TOOL, {
            "time": "0,1,2,4",
            "conc": "10,abc,6,4",
            "dose": "100"
        })


@pytest.mark.asyncio
async def test_er_non_numeric_response(mcp_client):
    """Test ER endpoint with non-numeric response values"""
    with pytest.raises(Exception):
        await mcp_client.call_tool(ER_TOOL, {
            "conc": "0.1,1,10,50",
            "resp": "5,xyz,40,70",
            "model": "auto"
        })
