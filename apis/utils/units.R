# utils/units.R
# Unit formatting functions for NCA parameters
# Note: derive_nca_unit has been deprecated in favor of derive_param_unit
# in pknca_units.R which provides more comprehensive unit derivation

#' Derive the unit for an NCA parameter (deprecated - use derive_param_unit)
#' @param param_code PKNCA parameter code (e.g., "cmax", "auclast", "cl.obs")
#' @param time_unit Input time unit (e.g., "h", "min", "d")
#' @param conc_unit Input concentration unit (e.g., "ug/mL")
#' @param dose_unit Input dose unit (e.g., "mg", "mg/kg")
#' @return Unit string for the parameter
derive_nca_unit <- function(param_code, time_unit, conc_unit, dose_unit) {
  # Forward to derive_param_unit in pknca_units.R if available
  if (exists("derive_param_unit", mode = "function")) {
    return(derive_param_unit(param_code, time_unit, conc_unit, dose_unit))
  }

  # Fallback to legacy NCA_UNIT_RULES lookup
  param_code <- tolower(param_code)

  if (param_code %in% names(NCA_UNIT_RULES)) {
    unit_fn <- NCA_UNIT_RULES[[param_code]]
    return(unit_fn(time_unit, conc_unit, dose_unit))
  }

  # Fallback: try to infer from parameter name patterns
  if (grepl("^auc", param_code)) {
    return(paste0(time_unit, "*", conc_unit))
  }
  if (grepl("^aumc", param_code)) {
    return(paste0(time_unit, "^2*", conc_unit))
  }
  if (grepl("^c[a-z]*$", param_code) || grepl("conc", param_code)) {
    return(conc_unit)
  }
  if (grepl("^t[a-z]*$", param_code) || grepl("time", param_code) ||
      grepl("half", param_code) || grepl("mrt", param_code)) {
    return(time_unit)
  }
  if (grepl("lambda", param_code)) {
    return(paste0("1/", time_unit))
  }
  if (grepl("^cl", param_code)) {
    return(paste0("mL/", time_unit))
  }
  if (grepl("^v[sz]", param_code) || grepl("^vss", param_code)) {
    return("mL")
  }

  # Unknown parameter - return NA
  return(NA_character_)
}

#' Format a value with its unit as a list
#' @param value Numeric value
#' @param unit Unit string (NULL or NA for dimensionless parameters)
#' @return List with value and unit components (unit = NULL renders as JSON null)
format_value_unit <- function(value, unit) {
  # Coerce NULL to NA so jsonlite serializes as JSON null, not {}
  if (is.null(unit)) unit <- NA_character_
  list(
    value = value,
    unit = unit
  )
}

#' Format all NCA results with units
#' @param nca_result List of NCA parameter values (names are parameter codes)
#' @param time_unit Time unit
#' @param conc_unit Concentration unit
#' @param dose_unit Dose unit
#' @return List with each parameter as a value/unit pair
format_nca_results_with_units <- function(nca_result, time_unit, conc_unit,
                                           dose_unit) {
  result <- list()

  for (param_name in names(nca_result)) {
    value <- nca_result[[param_name]]

    # Skip non-numeric values
    if (!is.numeric(value)) {
      result[[param_name]] <- value
      next
    }

    # Derive unit for this parameter
    unit <- derive_nca_unit(param_name, time_unit, conc_unit, dose_unit)

    # Format as value/unit pair
    result[[param_name]] <- format_value_unit(value, unit)
  }

  return(result)
}

#' Calculate effective dose from mg/kg and body weight
#' @param dose Dose value
#' @param dose_unit Dose unit ("mg" or "mg/kg")
#' @param BW Body weight in kg
#' @return Effective dose in mg
calculate_effective_dose <- function(dose, dose_unit, BW) {
  if (dose_unit == "mg/kg") {
    return(dose * BW)
  }
  return(dose)
}
