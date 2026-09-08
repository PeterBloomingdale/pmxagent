# utils/pknca_units.R
# PKNCA native unit handling utilities for enhanced NCA endpoint

#' Map API route names to PKNCA route format
#' @param route Route string from API (iv_bolus, iv_infusion, extravascular)
#' @return PKNCA-compatible route string
map_route_to_pknca <- function(route) {
  route_mapping <- list(
    "iv_bolus" = "intravascular",
    "iv_infusion" = "intravascular",
    "extravascular" = "extravascular"
  )

  if (route %in% names(route_mapping)) {
    return(route_mapping[[route]])
  }

  # Default to extravascular if not recognized
  return("extravascular")
}

#' Create PKNCA units table from input units
#' Uses PKNCA's native pknca_units_table() to generate proper unit assignments
#' @param concu Concentration unit (e.g., "ug/mL")
#' @param doseu Dose unit (e.g., "mg")
#' @param timeu Time unit (e.g., "h")
#' @param concu_pref Preferred output concentration unit (optional)
#' @param timeu_pref Preferred output time unit (optional)
#' @return PKNCA units table for use with PKNCAdata
create_pknca_units <- function(concu, doseu, timeu, concu_pref = NULL, timeu_pref = NULL) {
  # Use PKNCA native units table generation
  units_tbl <- pknca_units_table(
    concu = concu,
    doseu = doseu,
    timeu = timeu,
    conversions = PKNCA::pknca_unit_conversion()
  )

  # If preferred output units specified, update the conversion column
  # PKNCA handles unit conversions through the units table
  if (!is.null(concu_pref) && concu_pref != concu) {
    # Update concentration-based parameter units
    conc_params <- units_tbl$PPTESTCD[grepl("^c", units_tbl$PPTESTCD, ignore.case = TRUE)]
    for (p in conc_params) {
      idx <- units_tbl$PPTESTCD == p
      if (any(idx)) {
        units_tbl$conversion[idx] <- concu_pref
      }
    }
  }

  if (!is.null(timeu_pref) && timeu_pref != timeu) {
    # Update time-based parameter units
    time_params <- c("tmax", "tlast", "tlag", "half.life")
    for (p in time_params) {
      idx <- units_tbl$PPTESTCD == p
      if (any(idx)) {
        units_tbl$conversion[idx] <- timeu_pref
      }
    }
  }

  return(units_tbl)
}

#' Create interval data frame based on dosing scenario
#' @param t Time vector
#' @param dosing_scenario "single", "repeat", or "steady_state"
#' @param tau Dosing interval (required for repeat/steady_state)
#' @param params Comma-separated list of parameters to calculate
#' @param route Route of administration
#' @return Intervals data frame for PKNCA
create_nca_intervals <- function(t, dosing_scenario, tau = NULL, params = NULL, route = "extravascular") {
  t_min <- min(t)
  t_max <- max(t)

  # Base parameters always calculated
  base_params <- c("cmax", "tmax", "auclast", "half.life", "lambda.z",
                   "aucinf.obs", "cl.obs", "vz.obs", "r.squared", "adj.r.squared",
                   "lambda.z.n.points")

  # Add route-specific parameters
  if (route %in% c("iv_bolus", "intravascular")) {
    base_params <- c(base_params, "mrt.iv.last", "vss.obs")
  } else {
    base_params <- c(base_params, "mrt.last")
  }

  # Add additional requested parameters
  if (!is.null(params) && nchar(trimws(params)) > 0) {
    extra_params <- trimws(unlist(strsplit(params, ",")))
    # Normalise extravascular aliases: cl.f.obs -> cl.obs, vz.f.obs -> vz.obs, etc.
    # PKNCA computes these under the .obs/.pred names regardless of route.
    extra_params <- gsub("^cl\\.f\\.", "cl.", extra_params)
    extra_params <- gsub("^vz\\.f\\.", "vz.", extra_params)
    base_params <- unique(c(base_params, extra_params))
  }

  # Create intervals based on dosing scenario
  if (dosing_scenario == "single") {
    # Single dose: one interval from start to end
    intervals <- data.frame(
      start = t_min,
      end = t_max
    )

    # Add all requested parameters as TRUE columns
    for (p in base_params) {
      intervals[[p]] <- TRUE
    }

  } else if (dosing_scenario == "repeat" && !is.null(tau)) {
    # Repeat dosing: create intervals at each tau
    n_intervals <- floor((t_max - t_min) / tau)
    if (n_intervals < 1) n_intervals <- 1

    intervals_list <- lapply(0:(n_intervals - 1), function(i) {
      int_start <- t_min + i * tau
      int_end <- min(t_min + (i + 1) * tau, t_max)

      interval_df <- data.frame(start = int_start, end = int_end)

      for (p in base_params) {
        interval_df[[p]] <- TRUE
      }
      return(interval_df)
    })

    intervals <- do.call(rbind, intervals_list)

  } else if (dosing_scenario == "steady_state" && !is.null(tau)) {
    # Steady-state: single interval with tau-specific parameters
    intervals <- data.frame(
      start = t_min,
      end = tau
    )

    # Add steady-state specific parameters
    ss_params <- c(base_params, "cav", "cmin", "swing", "accumulation.index")
    for (p in ss_params) {
      intervals[[p]] <- TRUE
    }

  } else {
    # Fallback to single dose
    intervals <- data.frame(
      start = t_min,
      end = t_max
    )

    for (p in base_params) {
      intervals[[p]] <- TRUE
    }
  }

  return(intervals)
}

#' Set PKNCA options based on business rules
#' @param auc_method AUC calculation method
#' @param min_hl_points Minimum points for half-life calculation
#' @param min_hl_r_squared Minimum R-squared for half-life
#' @param max_aucinf_pext Maximum percent extrapolation for AUCinf
#' @param first_tmax Use first Tmax if tied
#' @param blq_first BLQ handling for first samples
#' @param blq_middle BLQ handling for middle samples
#' @param blq_last BLQ handling for last samples
#' @return Invisible NULL (sets options as side effect)
set_pknca_options <- function(auc_method = "lin up/log down",
                               min_hl_points = 3,
                               min_hl_r_squared = 0.9,
                               max_aucinf_pext = 20,
                               first_tmax = TRUE,
                               blq_first = "zero",
                               blq_middle = "drop",
                               blq_last = "drop") {

  # Set AUC calculation method
  PKNCA.options(auc.method = auc_method)

  # Set half-life calculation criteria
  PKNCA.options(min.hl.points = min_hl_points)
  PKNCA.options(min.hl.r.squared = min_hl_r_squared)

  # Set maximum AUCinf percent extrapolation
  PKNCA.options(max.aucinf.pext = max_aucinf_pext)

  # Set Tmax tie-breaking behavior
  PKNCA.options(first.tmax = first_tmax)

  # Set position-specific BLQ handling. PKNCA's conc.blq natively accepts a list with
  # first/middle/last keys; each value may be "keep", "drop", or a number (e.g. 0).
  # Positions are defined relative to the measurable concentrations:
  #   first  - BLQ before the first measurable conc (leading / ~ before Tmax)
  #   middle - BLQ embedded between measurable concs
  #   last   - BLQ after the last measurable conc (trailing / after Tmax)
  # The defaults (first = 0, middle/last = drop) match Phoenix WinNonlin and PKanalix:
  # zero before Tmax, excluded/missing after Tmax (and embedded excluded, per Phoenix).
  map_blq <- function(v) if (identical(v, "zero")) 0 else v  # "keep"/"drop" pass through
  PKNCA.options(conc.blq = list(
    first  = map_blq(blq_first),
    middle = map_blq(blq_middle),
    last   = map_blq(blq_last)
  ))

  return(invisible(NULL))
}

#' Reset PKNCA options to defaults
#' @return Invisible NULL
reset_pknca_options <- function() {
  PKNCA.options(
    auc.method = "lin up/log down",
    min.hl.points = 3,
    min.hl.r.squared = 0.9,
    max.aucinf.pext = 20,
    first.tmax = TRUE,
    conc.blq = list(first = 0, middle = "drop", last = "drop")
  )
  return(invisible(NULL))
}

#' Restrict PKNCA's terminal-slope (lambda_z) selection to DECLINING windows.
#'
#' PKNCA's automated half-life selection (pk.calc.half.life) chooses the candidate
#' terminal window whose adjusted R-squared is within `adj.r.squared.factor` of the
#' MAXIMUM adjusted R-squared taken over ALL windows -- including non-declining ones.
#' On noisy individual profiles a short non-declining window (e.g. an upward residual
#' blip at the tail) can have the best fit and veto every genuinely declining window,
#' yielding NA. Phoenix WinNonlin ("Best Fit"/ARS) and PKanalix instead select the
#' best-adjusted-R-squared window AMONG DECLINING spans. This patch makes PKNCA match
#' that behavior by restricting the max to windows with lambda.z > 0.
#'
#' Implemented as a minimal, version-guarded runtime patch of the single offending
#' expression. `pk.nca` resolves the half-life function by name
#' (get.interval.cols()[["half.life"]]$FUN == "pk.calc.half.life"), so replacing the
#' binding in the PKNCA namespace takes effect for the whole pipeline.
#' @return invisible(TRUE); errors if the target expression is not found
.patch_pknca_halflife_declining_only <- function() {
  fn  <- PKNCA::pk.calc.half.life
  src <- deparse(body(fn), width.cutoff = 500L)
  target <- "max(half_lives_for_selection$adj.r.squared, na.rm = TRUE)"
  repl   <- "max(half_lives_for_selection$adj.r.squared[half_lives_for_selection$lambda.z > 0], -Inf, na.rm = TRUE)"
  if (!any(grepl(target, src, fixed = TRUE))) {
    stop("PKNCA half-life patch target not found (PKNCA version changed); review pk.calc.half.life")
  }
  src <- gsub(target, repl, src, fixed = TRUE)
  body(fn) <- parse(text = paste(src, collapse = "\n"))[[1]]
  assignInNamespace("pk.calc.half.life", fn, ns = "PKNCA")
  invisible(TRUE)
}

# Apply the declining-only lambda_z selection patch once at startup (PKNCA is loaded
# by rapi.R before this file is sourced).
.patch_pknca_halflife_declining_only()

#' Extract results from PKNCA result object with units
#' @param pknca_result Result from pk.nca()
#' @param time_unit Input time unit
#' @param conc_unit Input concentration unit
#' @param dose_unit Input dose unit
#' @return List of parameter results with value/unit pairs
extract_results_with_units <- function(pknca_result, time_unit, conc_unit, dose_unit) {
  results <- list()

  # Get the results data frame
  res_df <- pknca_result$result

  # PKNCA stores units in PPORRESU column if units were provided
  has_units <- "PPORRESU" %in% names(res_df)

  # Process each unique parameter
  unique_params <- unique(res_df$PPTESTCD)

  for (param in unique_params) {
    idx <- res_df$PPTESTCD == param
    value <- res_df$PPORRES[idx][1]

    # Get unit from PKNCA if available, otherwise derive
    if (has_units && !is.na(res_df$PPORRESU[idx][1])) {
      unit <- res_df$PPORRESU[idx][1]
    } else {
      unit <- derive_param_unit(param, time_unit, conc_unit, dose_unit)
    }

    results[[param]] <- list(
      value = value,
      unit = unit
    )
  }

  return(results)
}

#' Volume unit for dose/conc, only when the reduction is exact.
#' ug/mL and mg/L are numerically identical, so mg/(mg/L) = L exactly. Every other
#' supported concentration unit either lands on an unreadable scale (ng/mL -> 1e3 L)
#' or needs a molecular weight (umol/L, nmol/L), so those keep the composite label.
#' @param dose_unit Dose unit ("mg", or "mg/kg" which is converted to an effective mg dose)
#' @param conc_unit Concentration unit
#' @return "L", or NA_character_ when no exact reduction exists
reduce_dose_conc_to_volume <- function(dose_unit, conc_unit) {
  du <- tolower(trimws(if (is.null(dose_unit)) "" else dose_unit))
  if (identical(du, "mg/kg")) du <- "mg"
  cu <- sub("^mcg/", "ug/", tolower(trimws(if (is.null(conc_unit)) "" else conc_unit)))
  if (identical(du, "mg") && cu %in% c("ug/ml", "mg/l")) return("L")
  NA_character_
}

#' Derive unit for a parameter based on parameter type
#' Fallback when PKNCA units not available
#' @param param Parameter code
#' @param time_unit Time unit
#' @param conc_unit Concentration unit
#' @param dose_unit Dose unit
#' @return Unit string
derive_param_unit <- function(param, time_unit, conc_unit, dose_unit) {
  param <- tolower(param)
  vol_unit <- reduce_dose_conc_to_volume(dose_unit, conc_unit)

  # Concentration parameters
  if (param %in% c("cmax", "cmin", "clast.obs", "c0", "cav", "ctrough")) {
    return(conc_unit)
  }

  # Time parameters
  if (param %in% c("tmax", "tlast", "tlag", "half.life", "mrt.last", "mrt.iv.last",
                   "mrt.md.last", "thalf.eff", "lambda.z.time.first")) {
    return(time_unit)
  }

  # Rate constants (1/time)
  if (param %in% c("lambda.z", "kel")) {
    return(paste0("1/", time_unit))
  }

  # AUC parameters (time*conc)
  if (grepl("^auc", param) || grepl("^aucint", param)) {
    return(paste0(time_unit, "*", conc_unit))
  }

  # AUMC parameters (time^2*conc)
  if (grepl("^aumc", param)) {
    return(paste0(time_unit, "^2*", conc_unit))
  }

  # Clearance parameters: dose_unit / (time_unit * conc_unit), reduced when exact
  if (grepl("^cl", param)) {
    if (!is.na(vol_unit)) return(paste0(vol_unit, "/", time_unit))
    return(paste0(dose_unit, "/(", time_unit, "*", conc_unit, ")"))
  }

  # Volume parameters: dose_unit / conc_unit, reduced when exact
  if (grepl("^v[sz]", param) || grepl("^vss", param) || grepl("^vd", param)) {
    if (!is.na(vol_unit)) return(vol_unit)
    return(paste0(dose_unit, "/", conc_unit))
  }

  # Percent extrapolation
  if (grepl("pext", param)) {
    return("%")
  }

  # Dimensionless parameters
  if (param %in% c("r.squared", "adj.r.squared", "lambda.z.n.points",
                   "span.ratio", "accumulation.index", "swing")) {
    return(NULL)
  }

  # Unknown - return NA
  return(NA_character_)
}

#' Get analysis settings for response
#' @param route Route of administration
#' @param dosing_scenario Dosing scenario
#' @param auc_method AUC method
#' @param blq_first First BLQ handling
#' @param blq_middle Middle BLQ handling
#' @param blq_last Last BLQ handling
#' @param min_hl_points Minimum half-life points
#' @param min_hl_r_squared Minimum R-squared
#' @param max_aucinf_pext Maximum percent extrapolation
#' @return List of analysis settings
get_analysis_settings <- function(route, dosing_scenario, auc_method,
                                   blq_first, blq_middle, blq_last,
                                   min_hl_points, min_hl_r_squared,
                                   max_aucinf_pext) {
  list(
    route = route,
    dosing_scenario = dosing_scenario,
    auc_method = auc_method,
    blq_handling = list(
      first = blq_first,
      middle = blq_middle,
      last = blq_last
    ),
    min_hl_points = min_hl_points,
    min_hl_r_squared = min_hl_r_squared,
    max_aucinf_pext = max_aucinf_pext
  )
}
