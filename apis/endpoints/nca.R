# endpoints/nca.R
# Non-compartmental analysis endpoint
# Supports both single-subject and multi-subject (population) analysis
# With full unit handling, route of administration, dosing scenarios, and business rules

#* Noncompartmental analysis (NCA)
#* Calculates Cmax, Tmax, auclast, half-life, and additional PK parameters using PKNCA.
#* Supports multi-subject analysis using pipe (|) separator between subjects.
#* All results include units derived from input parameters.
#* @param time Comma-separated time points; use pipe (|) to separate subjects for multi-subject, e.g. "0,1,2,4|0,1,2,4"
#* @param conc Comma-separated concentrations; use pipe (|) to separate subjects, e.g. "10,8,6,4|12,9,7,5"
#* @param params (optional) Comma-separated list of additional PK parameters to return
#* @param dose Dose amount(s) (string, optional, default "1"); pipe-separated for multi-subject
#* @param subject_id Pipe-separated subject IDs (string, optional)
#* @param dose_label Pipe-separated dose labels for grouping (string, optional)
#* @param pk_data JSON-encoded PK data from /PK endpoint for workflow chaining (string, optional)
#* @param dose_unit Unit of dose: "mg" or "mg/kg" (string, optional, default "mg")
#* @param conc_unit Unit of input concentration data (string, optional, default "ug/mL")
#* @param time_unit Unit of input time data: "h", "min", "d" (string, optional, default "h")
#* @param BW Body weight in kg (string, optional, default "70"); required when dose_unit="mg/kg"
#* @param route Route of administration: "iv_bolus", "iv_infusion", "extravascular" (string, optional, default "extravascular")
#* @param infusion_duration Duration of IV infusion in time_unit (string, optional); required when route="iv_infusion"
#* @param dosing_scenario Dosing scenario: "single", "repeat", "steady_state" (string, optional, default "single")
#* @param tau Dosing interval in time_unit (string, optional); required when dosing_scenario != "single"
#* @param blq_first BLQ handling for first samples: "keep", "drop", "zero" (string, optional, default "keep")
#* @param blq_middle BLQ handling for middle samples: "keep", "drop", "zero" (string, optional, default "drop")
#* @param blq_last BLQ handling for last samples: "keep", "drop", "zero" (string, optional, default "keep")
#* @param auc_method AUC calculation method: "lin up/log down", "linear", "lin-log" (string, optional, default "lin up/log down")
#* @param min_hl_points Minimum points for half-life calculation (string, optional, default "3")
#* @param min_hl_r_squared Minimum R-squared for half-life (string, optional, default "0.9")
#* @param max_aucinf_pext Maximum percent extrapolation for AUCinf (string, optional, default "20")
#* @param first_tmax Use first Tmax if tied: "true" or "false" (string, optional, default "true")
#* @param conc_unit_out Preferred output concentration unit (string, optional)
#* @param time_unit_out Preferred output time unit (string, optional)
#* @post /NCA
#* @serializer unboxedJSON
function(time = "0,0.25,0.5,1,2,4,8,12,24",
         conc = "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
         params = NULL,
         dose = "1",
         subject_id = NULL,
         dose_label = NULL,
         pk_data = NULL,
         dose_unit = "mg",
         conc_unit = "ug/mL",
         time_unit = "h",
         BW = "70",
         route = "extravascular",
         infusion_duration = NULL,
         dosing_scenario = "single",
         tau = NULL,
         blq_first = "keep",
         blq_middle = "drop",
         blq_last = "keep",
         auc_method = "lin up/log down",
         min_hl_points = "3",
         min_hl_r_squared = "0.9",
         max_aucinf_pext = "20",
         first_tmax = "true",
         conc_unit_out = NULL,
         time_unit_out = NULL) {

  tryCatch({
    # ========== Parse and validate basic inputs ==========
    bw_value <- as.numeric(BW)
    time_unit <- normalize_time_unit(time_unit)

    # Parse numeric parameters
    infusion_dur_val <- if (!is.null(infusion_duration) && nchar(trimws(infusion_duration)) > 0) {
      as.numeric(infusion_duration)
    } else NULL

    tau_val <- if (!is.null(tau) && nchar(trimws(tau)) > 0) {
      as.numeric(tau)
    } else NULL

    min_hl_pts <- as.numeric(min_hl_points)
    min_hl_rsq <- as.numeric(min_hl_r_squared)
    max_pext <- as.numeric(max_aucinf_pext)
    first_tmax_val <- parse_boolean(first_tmax, default = TRUE)

    # Validate all inputs
    validate_nca_units(dose_unit, conc_unit, time_unit, bw_value)
    validate_route(route, infusion_dur_val)
    validate_dosing_scenario(dosing_scenario, tau_val)
    validate_blq_handling(blq_first, blq_middle, blq_last)
    validate_business_rules(auc_method, min_hl_pts, min_hl_rsq, max_pext, first_tmax_val)

    # Validate preferred output units if provided
    if (!is.null(conc_unit_out) && nchar(trimws(conc_unit_out)) > 0) {
      validate_preferred_units(conc_unit_out, NULL)
    } else {
      conc_unit_out <- NULL
    }
    if (!is.null(time_unit_out) && nchar(trimws(time_unit_out)) > 0) {
      time_unit_out <- normalize_time_unit(time_unit_out)
      validate_preferred_units(NULL, time_unit_out)
    } else {
      time_unit_out <- NULL
    }

    # Build configuration object
    config <- list(
      dose_unit = dose_unit,
      conc_unit = conc_unit,
      time_unit = time_unit,
      bw_value = bw_value,
      route = route,
      infusion_duration = infusion_dur_val,
      dosing_scenario = dosing_scenario,
      tau = tau_val,
      blq_first = blq_first,
      blq_middle = blq_middle,
      blq_last = blq_last,
      auc_method = auc_method,
      min_hl_points = min_hl_pts,
      min_hl_r_squared = min_hl_rsq,
      max_aucinf_pext = max_pext,
      first_tmax = first_tmax_val,
      conc_unit_out = conc_unit_out,
      time_unit_out = time_unit_out,
      params = params
    )

    # Check if pk_data JSON is provided (workflow chaining mode)
    if (!is.null(pk_data) && nchar(trimws(pk_data)) > 0) {
      return(process_pk_data_nca(pk_data, config))
    }

    # Validate inputs are not empty
    validate_string_input(time, "time")
    validate_string_input(conc, "conc")
    validate_string_input(dose, "dose")

    # Detect multi-subject mode by pipe separator
    is_population <- grepl("\\|", time) || grepl("\\|", conc)

    if (is_population) {
      # ========== MULTI-SUBJECT MODE ==========
      return(run_population_nca(time, conc, dose, subject_id, dose_label, config))
    } else {
      # ========== SINGLE-SUBJECT MODE ==========
      return(run_single_subject_nca(time, conc, dose, config))
    }

  }, error = function(e) {
    stop(sprintf("NCA calculation failed: %s", e$message))
  })
}

#' Run NCA for single subject mode (entry point)
#' @param time Time string (comma-separated)
#' @param conc Concentration string (comma-separated)
#' @param dose Dose string
#' @param config Configuration object with all settings
#' @return List with NCA results including units
run_single_subject_nca <- function(time, conc, dose, config) {
  # Parse inputs
  t <- as.numeric(strsplit(time, ",")[[1]])
  c <- as.numeric(strsplit(conc, ",")[[1]])
  dose_amt <- as.numeric(dose)

  # Validate parsed data
  validate_pk_data(t, c)
  validate_dose(dose_amt)

  # Calculate effective dose (handle mg/kg conversion)
  effective_dose <- calculate_effective_dose(dose_amt, config$dose_unit, config$bw_value)

  # Run NCA with full configuration
  nca_results <- run_enhanced_nca(t, c, effective_dose, config)

  # Build response
  result <- list(
    mode = "single",
    analysis_settings = get_analysis_settings(
      config$route, config$dosing_scenario, config$auc_method,
      config$blq_first, config$blq_middle, config$blq_last,
      config$min_hl_points, config$min_hl_r_squared, config$max_aucinf_pext
    ),
    input_units = list(
      time = config$time_unit,
      concentration = config$conc_unit,
      dose = config$dose_unit
    ),
    dose_administered = list(
      value = dose_amt,
      unit = config$dose_unit
    )
  )

  # Add output units if different from input
  output_time <- if (!is.null(config$time_unit_out)) config$time_unit_out else config$time_unit
  output_conc <- if (!is.null(config$conc_unit_out)) config$conc_unit_out else config$conc_unit

  if (!is.null(config$time_unit_out) || !is.null(config$conc_unit_out)) {
    result$output_units <- list(
      time = output_time,
      concentration = output_conc
    )
  }

  # Add effective dose if different (mg/kg case)
  if (config$dose_unit == "mg/kg") {
    result$effective_dose <- list(
      value = effective_dose,
      unit = "mg",
      BW = config$bw_value
    )
  }

  # Format main parameters with units
  result$Cmax <- format_result_param(nca_results, "cmax", config$conc_unit, output_conc)
  result$Tmax <- format_result_param(nca_results, "tmax", config$time_unit, output_time)
  result$auclast <- format_auc_param(nca_results, "auclast", config$time_unit, config$conc_unit, output_time, output_conc)
  result$half_life <- format_result_param(nca_results, "half.life", config$time_unit, output_time)

  # Add all results with proper units
  result$results <- format_all_results(nca_results, config$time_unit, config$conc_unit,
                                        output_time, output_conc, config$dose_unit)

  # Keep available_params for backwards compatibility
  result$available_params <- result$results

  return(result)
}

#' Run NCA for population mode (entry point)
run_population_nca <- function(time, conc, dose, subject_id, dose_label, config) {
  # Split by pipe separator
  time_subjects <- strsplit(time, "\\|")[[1]]
  conc_subjects <- strsplit(conc, "\\|")[[1]]
  dose_subjects <- strsplit(dose, "\\|")[[1]]

  n_subjects <- length(time_subjects)

  if (length(conc_subjects) != n_subjects) {
    stop(sprintf("Number of subjects in time (%d) and conc (%d) must match",
                n_subjects, length(conc_subjects)))
  }

  # Validate subject count
  if (n_subjects > MAX_SUBJECTS) {
    stop(sprintf("Number of subjects (%d) exceeds maximum (%d)", n_subjects, MAX_SUBJECTS))
  }

  # Expand single dose value to all subjects
  if (length(dose_subjects) == 1) {
    dose_subjects <- rep(dose_subjects, n_subjects)
  }
  if (length(dose_subjects) != n_subjects) {
    stop(sprintf("Number of dose values (%d) must be 1 or match number of subjects (%d)",
                length(dose_subjects), n_subjects))
  }

  # Parse subject IDs
  subject_ids <- NULL
  if (!is.null(subject_id) && nchar(trimws(subject_id)) > 0) {
    subject_ids <- strsplit(subject_id, "\\|")[[1]]
    if (length(subject_ids) != n_subjects) {
      stop(sprintf("subject_id count (%d) must match number of subjects (%d)",
                  length(subject_ids), n_subjects))
    }
  } else {
    subject_ids <- sprintf("SUBJ%03d", seq_len(n_subjects))
  }

  # Parse dose labels
  dose_labels <- NULL
  if (!is.null(dose_label) && nchar(trimws(dose_label)) > 0) {
    dose_labels <- strsplit(dose_label, "\\|")[[1]]
    if (length(dose_labels) != n_subjects) {
      stop(sprintf("dose_label count (%d) must match number of subjects (%d)",
                  length(dose_labels), n_subjects))
    }
  } else {
    dose_labels <- paste(as.numeric(dose_subjects), config$dose_unit)
  }

  # Determine output units
  output_time <- if (!is.null(config$time_unit_out)) config$time_unit_out else config$time_unit
  output_conc <- if (!is.null(config$conc_unit_out)) config$conc_unit_out else config$conc_unit

  # Process each subject
  individual_results <- list()
  results_df <- data.frame()

  for (i in seq_len(n_subjects)) {
    # Parse individual data
    t <- as.numeric(strsplit(trimws(time_subjects[i]), ",")[[1]])
    c <- as.numeric(strsplit(trimws(conc_subjects[i]), ",")[[1]])
    d <- as.numeric(trimws(dose_subjects[i]))

    # Validate
    validate_pk_data(t, c)
    validate_dose(d)

    # Calculate effective dose
    effective_dose <- calculate_effective_dose(d, config$dose_unit, config$bw_value)

    # Run NCA for this subject
    nca_results <- run_enhanced_nca(t, c, effective_dose, config)

    # Store individual result with units
    individual_results[[i]] <- list(
      subject_id = subject_ids[i],
      dose_label = dose_labels[i],
      dose_administered = list(value = d, unit = config$dose_unit),
      Cmax = format_result_param(nca_results, "cmax", config$conc_unit, output_conc),
      Tmax = format_result_param(nca_results, "tmax", config$time_unit, output_time),
      auclast = format_auc_param(nca_results, "auclast", config$time_unit, config$conc_unit, output_time, output_conc),
      half_life = format_result_param(nca_results, "half.life", config$time_unit, output_time)
    )

    # Add effective dose if mg/kg
    if (config$dose_unit == "mg/kg") {
      individual_results[[i]]$effective_dose <- list(value = effective_dose, unit = "mg")
    }

    # Extract raw values for summary
    cmax_val <- get_param_value(nca_results, "cmax")
    tmax_val <- get_param_value(nca_results, "tmax")
    auclast_val <- get_param_value(nca_results, "auclast")
    halflife_val <- get_param_value(nca_results, "half.life")

    # Accumulate for summary
    subj_row <- data.frame(
      subject_id = subject_ids[i],
      dose_label = dose_labels[i],
      Cmax = cmax_val,
      Tmax = tmax_val,
      auclast = auclast_val,
      half_life = halflife_val,
      stringsAsFactors = FALSE
    )
    results_df <- rbind(results_df, subj_row)
  }

  # Calculate summary by dose group with units
  unique_doses <- unique(dose_labels)
  summary_by_dose <- lapply(unique_doses, function(dl) {
    idx <- results_df$dose_label == dl
    list(
      dose_label = dl,
      n = sum(idx),
      Cmax_mean = format_value_unit(mean(results_df$Cmax[idx], na.rm = TRUE), output_conc),
      Cmax_sd = format_value_unit(sd(results_df$Cmax[idx], na.rm = TRUE), output_conc),
      Tmax_mean = format_value_unit(mean(results_df$Tmax[idx], na.rm = TRUE), output_time),
      Tmax_sd = format_value_unit(sd(results_df$Tmax[idx], na.rm = TRUE), output_time),
      auclast_mean = format_value_unit(mean(results_df$auclast[idx], na.rm = TRUE), paste0(output_time, "*", output_conc)),
      auclast_sd = format_value_unit(sd(results_df$auclast[idx], na.rm = TRUE), paste0(output_time, "*", output_conc)),
      half_life_mean = format_value_unit(mean(results_df$half_life[idx], na.rm = TRUE), output_time),
      half_life_sd = format_value_unit(sd(results_df$half_life[idx], na.rm = TRUE), output_time)
    )
  })
  names(summary_by_dose) <- unique_doses

  # Build response
  response <- list(
    mode = "population",
    n_subjects = n_subjects,
    analysis_settings = get_analysis_settings(
      config$route, config$dosing_scenario, config$auc_method,
      config$blq_first, config$blq_middle, config$blq_last,
      config$min_hl_points, config$min_hl_r_squared, config$max_aucinf_pext
    ),
    input_units = list(
      time = config$time_unit,
      concentration = config$conc_unit,
      dose = config$dose_unit
    ),
    individual_results = individual_results,
    summary_by_dose = summary_by_dose
  )

  # Add output units if different
  if (!is.null(config$time_unit_out) || !is.null(config$conc_unit_out)) {
    response$output_units <- list(
      time = output_time,
      concentration = output_conc
    )
  }

  return(response)
}

#' Run enhanced NCA with full configuration
#' @param t Time vector
#' @param c Concentration vector
#' @param dose_amt Dose amount (effective dose in mg)
#' @param config Configuration object
#' @return List with NCA results
run_enhanced_nca <- function(t, c, dose_amt, config) {
  # Set PKNCA options for business rules
  set_pknca_options(
    auc_method = config$auc_method,
    min_hl_points = config$min_hl_points,
    min_hl_r_squared = config$min_hl_r_squared,
    max_aucinf_pext = config$max_aucinf_pext,
    first_tmax = config$first_tmax,
    blq_first = config$blq_first,
    blq_middle = config$blq_middle,
    blq_last = config$blq_last
  )

  # Ensure options are reset on exit
  on.exit(reset_pknca_options())

  # Create data frame
  df <- data.frame(time = t, conc = c)

  # Create intervals based on dosing scenario
  intervals <- create_nca_intervals(
    t = t,
    dosing_scenario = config$dosing_scenario,
    tau = config$tau,
    params = config$params,
    route = config$route
  )

  # Set up PKNCA objects
  data_obj <- PKNCAconc(df, conc ~ time)

  # Create dose object with route information
  dose_df <- data.frame(time = min(t), dose = dose_amt)

  # Map route to PKNCA format
  pknca_route <- map_route_to_pknca(config$route)

  # Add duration for IV infusion
  if (config$route == "iv_infusion" && !is.null(config$infusion_duration)) {
    # For IV infusion, pass duration as a numeric value (applies to all doses)
    dose_obj <- PKNCAdose(dose_df, dose ~ time,
                           route = pknca_route,
                           duration = config$infusion_duration)
  } else {
    dose_obj <- PKNCAdose(dose_df, dose ~ time, route = pknca_route)
  }

  # Create PKNCAdata and run NCA
  pk_obj <- PKNCAdata(data.conc = data_obj, data.dose = dose_obj, intervals = intervals)
  result <- pk.nca(pk_obj)

  # Extract results
  return(result)
}

#' Get parameter value from PKNCA result
#' @param pknca_result PKNCA result object
#' @param param_name Parameter name
#' @return Numeric value or NA
get_param_value <- function(pknca_result, param_name) {
  res_df <- pknca_result$result
  idx <- res_df$PPTESTCD == param_name
  if (any(idx)) {
    return(res_df$PPORRES[idx][1])
  }
  return(NA_real_)
}

#' Format a result parameter with value and unit
#' @param pknca_result PKNCA result object
#' @param param_name Parameter name
#' @param input_unit Input unit
#' @param output_unit Output unit (may be different for unit conversion)
#' @return List with value and unit
format_result_param <- function(pknca_result, param_name, input_unit, output_unit = NULL) {
  value <- get_param_value(pknca_result, param_name)
  unit <- if (!is.null(output_unit)) output_unit else input_unit
  format_value_unit(value, unit)
}

#' Format AUC parameter with value and unit
#' @param pknca_result PKNCA result object
#' @param param_name Parameter name
#' @param time_unit Input time unit
#' @param conc_unit Input concentration unit
#' @param output_time Output time unit
#' @param output_conc Output concentration unit
#' @return List with value and unit
format_auc_param <- function(pknca_result, param_name, time_unit, conc_unit, output_time = NULL, output_conc = NULL) {
  value <- get_param_value(pknca_result, param_name)
  t_unit <- if (!is.null(output_time)) output_time else time_unit
  c_unit <- if (!is.null(output_conc)) output_conc else conc_unit
  unit <- paste0(t_unit, "*", c_unit)
  format_value_unit(value, unit)
}

#' Format all NCA results with proper units
#' @param pknca_result PKNCA result object
#' @param time_unit Input time unit
#' @param conc_unit Input concentration unit
#' @param output_time Output time unit
#' @param output_conc Output concentration unit
#' @param dose_unit Dose unit
#' @return List of all parameters with value/unit pairs
format_all_results <- function(pknca_result, time_unit, conc_unit, output_time, output_conc, dose_unit) {
  results <- list()
  res_df <- pknca_result$result

  unique_params <- unique(res_df$PPTESTCD)

  for (param in unique_params) {
    idx <- res_df$PPTESTCD == param
    value <- res_df$PPORRES[idx][1]

    # Derive unit using the helper function
    unit <- derive_param_unit(param, output_time, output_conc, dose_unit)

    results[[param]] <- list(
      value = value,
      unit = unit
    )
  }

  return(results)
}

#' Process PK data JSON for NCA (workflow chaining)
#' @param pk_data_json JSON string from PK endpoint
#' @param config Configuration object
#' @return List with NCA results including units
process_pk_data_nca <- function(pk_data_json, config) {
  # Parse JSON
  pk_data <- jsonlite::fromJSON(pk_data_json)

  # Determine output units
  output_time <- if (!is.null(config$time_unit_out)) config$time_unit_out else config$time_unit
  output_conc <- if (!is.null(config$conc_unit_out)) config$conc_unit_out else config$conc_unit

  if (pk_data$mode == "single") {
    # Single subject from PK
    t <- pk_data$times
    c <- pk_data$concentrations
    dose_amt <- if (!is.null(pk_data$dose)) pk_data$dose else 1

    # Calculate effective dose
    effective_dose <- calculate_effective_dose(dose_amt, config$dose_unit, config$bw_value)

    nca_results <- run_enhanced_nca(t, c, effective_dose, config)

    result <- list(
      mode = "single",
      analysis_settings = get_analysis_settings(
        config$route, config$dosing_scenario, config$auc_method,
        config$blq_first, config$blq_middle, config$blq_last,
        config$min_hl_points, config$min_hl_r_squared, config$max_aucinf_pext
      ),
      input_units = list(
        time = config$time_unit,
        concentration = config$conc_unit,
        dose = config$dose_unit
      ),
      dose_administered = list(value = dose_amt, unit = config$dose_unit),
      Cmax = format_result_param(nca_results, "cmax", config$conc_unit, output_conc),
      Tmax = format_result_param(nca_results, "tmax", config$time_unit, output_time),
      auclast = format_auc_param(nca_results, "auclast", config$time_unit, config$conc_unit, output_time, output_conc),
      half_life = format_result_param(nca_results, "half.life", config$time_unit, output_time)
    )

    if (config$dose_unit == "mg/kg") {
      result$effective_dose <- list(value = effective_dose, unit = "mg", BW = config$bw_value)
    }

    # Add output units if different
    if (!is.null(config$time_unit_out) || !is.null(config$conc_unit_out)) {
      result$output_units <- list(
        time = output_time,
        concentration = output_conc
      )
    }

    # Format all available_params with units
    result$results <- format_all_results(nca_results, config$time_unit, config$conc_unit,
                                          output_time, output_conc, config$dose_unit)
    result$available_params <- result$results

    return(result)

  } else if (pk_data$mode == "population") {
    # Population from PK
    # Note: jsonlite::fromJSON() converts the individual_data array into a data.frame
    # with list columns for times/concentrations, not a list of lists
    individual_data <- pk_data$individual_data
    n_subjects <- nrow(individual_data)

    individual_results <- list()
    results_df <- data.frame()

    for (i in seq_len(n_subjects)) {
      # Access data frame columns properly (times/concentrations are list columns)
      t <- individual_data$times[[i]]
      c <- individual_data$concentrations[[i]]
      d <- individual_data$dose[i]
      subj_id <- individual_data$subject_id[i]
      subj_dose_label <- individual_data$dose_label[i]

      effective_dose <- calculate_effective_dose(d, config$dose_unit, config$bw_value)
      nca_results <- run_enhanced_nca(t, c, effective_dose, config)

      individual_results[[i]] <- list(
        subject_id = subj_id,
        dose_label = subj_dose_label,
        dose_administered = list(value = d, unit = config$dose_unit),
        Cmax = format_result_param(nca_results, "cmax", config$conc_unit, output_conc),
        Tmax = format_result_param(nca_results, "tmax", config$time_unit, output_time),
        auclast = format_auc_param(nca_results, "auclast", config$time_unit, config$conc_unit, output_time, output_conc),
        half_life = format_result_param(nca_results, "half.life", config$time_unit, output_time)
      )

      if (config$dose_unit == "mg/kg") {
        individual_results[[i]]$effective_dose <- list(value = effective_dose, unit = "mg")
      }

      # Extract raw values
      cmax_val <- get_param_value(nca_results, "cmax")
      tmax_val <- get_param_value(nca_results, "tmax")
      auclast_val <- get_param_value(nca_results, "auclast")
      halflife_val <- get_param_value(nca_results, "half.life")

      subj_row <- data.frame(
        subject_id = subj_id,
        dose_label = subj_dose_label,
        Cmax = cmax_val,
        Tmax = tmax_val,
        auclast = auclast_val,
        half_life = halflife_val,
        stringsAsFactors = FALSE
      )
      results_df <- rbind(results_df, subj_row)
    }

    # Calculate summary by dose group with units
    unique_doses <- unique(results_df$dose_label)
    summary_by_dose <- lapply(unique_doses, function(dl) {
      idx <- results_df$dose_label == dl
      list(
        dose_label = dl,
        n = sum(idx),
        Cmax_mean = format_value_unit(mean(results_df$Cmax[idx], na.rm = TRUE), output_conc),
        Cmax_sd = format_value_unit(sd(results_df$Cmax[idx], na.rm = TRUE), output_conc),
        auclast_mean = format_value_unit(mean(results_df$auclast[idx], na.rm = TRUE), paste0(output_time, "*", output_conc)),
        auclast_sd = format_value_unit(sd(results_df$auclast[idx], na.rm = TRUE), paste0(output_time, "*", output_conc)),
        half_life_mean = format_value_unit(mean(results_df$half_life[idx], na.rm = TRUE), output_time),
        half_life_sd = format_value_unit(sd(results_df$half_life[idx], na.rm = TRUE), output_time)
      )
    })
    names(summary_by_dose) <- unique_doses

    response <- list(
      mode = "population",
      n_subjects = n_subjects,
      analysis_settings = get_analysis_settings(
        config$route, config$dosing_scenario, config$auc_method,
        config$blq_first, config$blq_middle, config$blq_last,
        config$min_hl_points, config$min_hl_r_squared, config$max_aucinf_pext
      ),
      input_units = list(
        time = config$time_unit,
        concentration = config$conc_unit,
        dose = config$dose_unit
      ),
      individual_results = individual_results,
      summary_by_dose = summary_by_dose
    )

    if (!is.null(config$time_unit_out) || !is.null(config$conc_unit_out)) {
      response$output_units <- list(
        time = output_time,
        concentration = output_conc
      )
    }

    return(response)

  } else {
    stop("Unknown pk_data mode")
  }
}
