# utils/validation.R
# Input validation functions for PMxAgent R API

#' Validate string input is not empty or whitespace
#' @param str String to validate
#' @param name Parameter name for error messages
#' @return invisible(TRUE) if valid, stops with error if not
validate_string_input <- function(str, name) {
  # Check for NULL
  if (is.null(str)) {
    stop(sprintf("Missing required parameter: %s cannot be NULL", name))
  }
  # Check for NA
  if (length(str) == 0 || any(is.na(str))) {
    stop(sprintf("Missing required parameter: %s cannot be NA or empty", name))
  }
  # Check for empty string or whitespace-only
  if (nchar(trimws(str)) == 0) {
    stop(sprintf("Missing required parameter: %s cannot be empty or whitespace", name))
  }
  return(invisible(TRUE))
}

#' Validate numeric vector input
#' @param vec Vector to validate
#' @param name Parameter name for error messages
#' @param min_length Minimum required length (default: 2)
#' @param allow_negative Whether negative values are allowed (default: FALSE)
#' @return invisible(TRUE) if valid, stops with error if not
validate_numeric_vector <- function(vec, name, min_length = 2, allow_negative = FALSE) {
  if (any(is.na(vec))) {
    stop(sprintf("Missing or invalid values in %s", name))
  }
  if (length(vec) < min_length) {
    stop(sprintf("%s must have at least %d values, got %d", name, min_length, length(vec)))
  }
  if (length(vec) > MAX_DATA_POINTS) {
    stop(sprintf("%s exceeds maximum size of %d data points", name, MAX_DATA_POINTS))
  }
  if (!allow_negative && any(vec < 0)) {
    stop(sprintf("%s contains negative values", name))
  }
  return(invisible(TRUE))
}

#' Validate time-concentration pairs for PK data
#' @param time Time vector
#' @param conc Concentration vector
#' @return invisible(TRUE) if valid, stops with error if not
validate_pk_data <- function(time, conc) {
  if (length(time) != length(conc)) {
    stop(sprintf("Length mismatch: time (%d) and conc (%d) must be equal", length(time), length(conc)))
  }
  validate_numeric_vector(time, "time", allow_negative = FALSE)
  validate_numeric_vector(conc, "conc", allow_negative = FALSE)

  # Check for strictly increasing time (monotonic)
  if (is.unsorted(time, strictly = TRUE)) {
    stop("Time points must be strictly increasing")
  }

  return(invisible(TRUE))
}

#' Validate dose value
#' @param dose Dose amount
#' @return invisible(TRUE) if valid, stops with error if not
validate_dose <- function(dose) {
  if (is.na(dose) || !is.numeric(dose)) {
    stop("Dose must be a numeric value")
  }
  if (dose <= 0) {
    stop(sprintf("Dose must be positive, got %f", dose))
  }
  if (dose > 1e6) {
    stop(sprintf("Dose value %f seems unreasonably large", dose))
  }
  return(invisible(TRUE))
}

#' Validate PK parameters for compartment models
#' @param CL Clearance
#' @param V1 Central volume
#' @param V2 Peripheral volume (optional)
#' @param Q Intercompartmental clearance (optional)
#' @return invisible(TRUE) if valid, stops with error if not
validate_pk_params <- function(CL, V1, V2 = NULL, Q = NULL) {
  # Validate required parameters
  if (CL <= 0) stop(sprintf("CL must be positive, got %f", CL))
  if (V1 <= 0) stop(sprintf("V1 must be positive, got %f", V1))

  # Validate two-compartment parameters if provided
  if (!is.null(V2) && !is.null(Q)) {
    if (V2 <= 0) stop(sprintf("V2 must be positive, got %f", V2))
    if (Q <= 0) stop(sprintf("Q must be positive, got %f", Q))
  } else if (!is.null(V2) || !is.null(Q)) {
    stop("For two-compartment model, both V2 and Q must be provided")
  }

  return(invisible(TRUE))
}

#' Validate NCA unit parameters
#' @param dose_unit Dose unit (mg or mg/kg)
#' @param conc_unit Concentration unit
#' @param time_unit Time unit
#' @param BW Body weight (required if dose_unit is mg/kg)
#' @return invisible(TRUE) if valid, stops with error if not
validate_nca_units <- function(dose_unit, conc_unit, time_unit, BW = NULL) {
  # Validate dose_unit
  if (!dose_unit %in% VALID_DOSE_UNITS) {
    stop(sprintf("Invalid dose_unit '%s'. Valid options: %s",
                 dose_unit, paste(VALID_DOSE_UNITS, collapse = ", ")))
  }

  # Validate conc_unit
  if (!conc_unit %in% VALID_CONC_UNITS) {
    stop(sprintf("Invalid conc_unit '%s'. Valid options: %s",
                 conc_unit, paste(VALID_CONC_UNITS, collapse = ", ")))
  }

  # Validate time_unit
  if (!time_unit %in% VALID_TIME_UNITS) {
    stop(sprintf("Invalid time_unit '%s'. Valid options: %s",
                 time_unit, paste(VALID_TIME_UNITS, collapse = ", ")))
  }

  # If dose_unit is mg/kg, BW must be provided and valid
  if (dose_unit == "mg/kg") {
    if (is.null(BW) || is.na(BW)) {
      stop("BW (body weight) is required when dose_unit is 'mg/kg'")
    }
    if (!is.numeric(BW) || BW <= 0) {
      stop(sprintf("BW must be a positive number, got %s", as.character(BW)))
    }
    if (BW > 500) {
      stop(sprintf("BW value %f kg seems unreasonably large", BW))
    }
  }

  return(invisible(TRUE))
}

#' Normalize time unit string to standard format
#' @param time_unit Input time unit
#' @return Normalized time unit string
normalize_time_unit <- function(time_unit) {
  time_unit <- tolower(trimws(time_unit))
  # Map common variants to standard
  mapping <- list(
    "h" = "h", "hr" = "h", "hrs" = "h", "hour" = "h", "hours" = "h",
    "min" = "min", "mins" = "min", "minute" = "min", "minutes" = "min",
    "d" = "d", "day" = "d", "days" = "d"
  )
  if (time_unit %in% names(mapping)) {
    return(mapping[[time_unit]])
  }
  return(time_unit)
}

#' Normalize concentration unit string to standard format
#' @param conc_unit Input concentration unit
#' @return Normalized concentration unit string
normalize_conc_unit <- function(conc_unit) {
  conc_unit <- trimws(conc_unit)
  mapping <- list("mcg/mL" = "ug/mL", "mcg/ml" = "ug/mL")
  if (conc_unit %in% names(mapping)) return(mapping[[conc_unit]])
  return(conc_unit)
}

# ==================== Enhanced NCA Validation Functions ====================

#' Validate route of administration
#' @param route Route string
#' @param infusion_duration Duration for IV infusion (required if route is iv_infusion)
#' @return invisible(TRUE) if valid, stops with error if not
validate_route <- function(route, infusion_duration = NULL) {
  if (!route %in% VALID_ROUTES) {
    stop(sprintf("Invalid route '%s'. Valid options: %s",
                 route, paste(VALID_ROUTES, collapse = ", ")))
  }

  # IV infusion requires duration
  if (route == "iv_infusion") {
    if (is.null(infusion_duration) || is.na(infusion_duration)) {
      stop("infusion_duration is required when route='iv_infusion'")
    }
    if (!is.numeric(infusion_duration) || infusion_duration <= 0) {
      stop(sprintf("infusion_duration must be a positive number, got %s",
                   as.character(infusion_duration)))
    }
  }

  return(invisible(TRUE))
}

#' Validate dosing scenario
#' @param dosing_scenario Dosing scenario string
#' @param tau Dosing interval (required for repeat and steady_state)
#' @return invisible(TRUE) if valid, stops with error if not
validate_dosing_scenario <- function(dosing_scenario, tau = NULL) {
  if (!dosing_scenario %in% VALID_DOSING_SCENARIOS) {
    stop(sprintf("Invalid dosing_scenario '%s'. Valid options: %s",
                 dosing_scenario, paste(VALID_DOSING_SCENARIOS, collapse = ", ")))
  }

  # Repeat and steady_state require tau
  if (dosing_scenario %in% c("repeat", "steady_state")) {
    if (is.null(tau) || is.na(tau)) {
      stop(sprintf("tau (dosing interval) is required when dosing_scenario='%s'",
                   dosing_scenario))
    }
    if (!is.numeric(tau) || tau <= 0) {
      stop(sprintf("tau must be a positive number, got %s", as.character(tau)))
    }
  }

  return(invisible(TRUE))
}

#' Validate BLQ handling options
#' @param blq_first BLQ handling for first samples
#' @param blq_middle BLQ handling for middle samples
#' @param blq_last BLQ handling for last samples
#' @return invisible(TRUE) if valid, stops with error if not
validate_blq_handling <- function(blq_first, blq_middle, blq_last) {
  if (!blq_first %in% VALID_BLQ_OPTIONS) {
    stop(sprintf("Invalid blq_first '%s'. Valid options: %s",
                 blq_first, paste(VALID_BLQ_OPTIONS, collapse = ", ")))
  }

  if (!blq_middle %in% VALID_BLQ_OPTIONS) {
    stop(sprintf("Invalid blq_middle '%s'. Valid options: %s",
                 blq_middle, paste(VALID_BLQ_OPTIONS, collapse = ", ")))
  }

  if (!blq_last %in% VALID_BLQ_OPTIONS) {
    stop(sprintf("Invalid blq_last '%s'. Valid options: %s",
                 blq_last, paste(VALID_BLQ_OPTIONS, collapse = ", ")))
  }

  return(invisible(TRUE))
}

#' Validate business rules
#' @param auc_method AUC calculation method
#' @param min_hl_points Minimum points for half-life
#' @param min_hl_r_squared Minimum R-squared for half-life
#' @param max_aucinf_pext Maximum percent extrapolation
#' @param first_tmax Use first Tmax if tied (logical or string)
#' @return invisible(TRUE) if valid, stops with error if not
validate_business_rules <- function(auc_method, min_hl_points, min_hl_r_squared,
                                     max_aucinf_pext, first_tmax) {
  # Validate AUC method
  if (!auc_method %in% VALID_AUC_METHODS) {
    stop(sprintf("Invalid auc_method '%s'. Valid options: %s",
                 auc_method, paste(VALID_AUC_METHODS, collapse = ", ")))
  }

  # Validate min_hl_points
  if (!is.numeric(min_hl_points) || min_hl_points < 2) {
    stop(sprintf("min_hl_points must be >= 2, got %s", as.character(min_hl_points)))
  }
  if (min_hl_points > 20) {
    stop(sprintf("min_hl_points seems unreasonably large (%d), maximum is 20",
                 min_hl_points))
  }

  # Validate min_hl_r_squared
  if (!is.numeric(min_hl_r_squared) || min_hl_r_squared < 0 || min_hl_r_squared > 1) {
    stop(sprintf("min_hl_r_squared must be between 0 and 1, got %s",
                 as.character(min_hl_r_squared)))
  }

  # Validate max_aucinf_pext
  if (!is.numeric(max_aucinf_pext) || max_aucinf_pext < 0 || max_aucinf_pext > 100) {
    stop(sprintf("max_aucinf_pext must be between 0 and 100, got %s",
                 as.character(max_aucinf_pext)))
  }

  # Validate first_tmax (convert string to logical if needed)
  if (is.character(first_tmax)) {
    first_tmax <- tolower(first_tmax) %in% c("true", "yes", "1")
  }
  if (!is.logical(first_tmax)) {
    stop("first_tmax must be a logical value (true/false)")
  }

  return(invisible(TRUE))
}

#' Validate preferred output units
#' @param conc_unit_out Preferred output concentration unit
#' @param time_unit_out Preferred output time unit
#' @return invisible(TRUE) if valid, stops with error if not
validate_preferred_units <- function(conc_unit_out = NULL, time_unit_out = NULL) {
  # Validate concentration unit if provided
  if (!is.null(conc_unit_out) && nchar(trimws(conc_unit_out)) > 0) {
    if (!conc_unit_out %in% VALID_CONC_UNITS) {
      stop(sprintf("Invalid conc_unit_out '%s'. Valid options: %s",
                   conc_unit_out, paste(VALID_CONC_UNITS, collapse = ", ")))
    }
  }

  # Validate time unit if provided
  if (!is.null(time_unit_out) && nchar(trimws(time_unit_out)) > 0) {
    normalized <- normalize_time_unit(time_unit_out)
    if (!normalized %in% VALID_TIME_UNITS) {
      stop(sprintf("Invalid time_unit_out '%s'. Valid options: %s",
                   time_unit_out, paste(VALID_TIME_UNITS, collapse = ", ")))
    }
  }

  return(invisible(TRUE))
}

#' Parse boolean string to logical
#' @param value String or logical value
#' @param default Default value if NULL or empty
#' @return Logical value
parse_boolean <- function(value, default = TRUE) {
  if (is.null(value) || (is.character(value) && nchar(trimws(value)) == 0)) {
    return(default)
  }
  if (is.logical(value)) {
    return(value)
  }
  if (is.character(value)) {
    return(tolower(trimws(value)) %in% c("true", "yes", "1"))
  }
  return(as.logical(value))
}
