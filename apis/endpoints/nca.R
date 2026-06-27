# endpoints/nca.R
# Non-compartmental analysis endpoint
# Supports single-subject and population analysis via data_file (PK→DATA→NCA workflow)
# With full unit handling, route of administration, dosing scenarios, and business rules

#* Noncompartmental analysis (NCA)
#* Calculates Cmax, Tmax, auclast, half-life, and additional PK parameters using PKNCA.
#* For population (multi-subject) analysis, provide data_file with the output of the /DATA endpoint.
#* All results include units derived from input parameters.
#* @param time Comma-separated time points (string)
#* @param conc Comma-separated concentrations (string)
#* @param params (optional) Comma-separated list of additional PK parameters to return
#* @param dose Dose amount (string, optional, default "1")
#* @param subject_id Subject ID label for single-subject use (string, optional)
#* @param dose_label Dose label for grouping (string, optional)
#* @param pk_data JSON-encoded PK data from /PK endpoint for workflow chaining (string, optional)
#* @param dose_unit Unit of dose: "mg" or "mg/kg" (string, optional, default "mg")
#* @param conc_unit Unit of input concentration data (string, optional, default "ug/mL")
#* @param time_unit Unit of input time data: "h", "min", "d" (string, optional, default "h")
#* @param BW Body weight in kg (string, optional, default "70"); required when dose_unit="mg/kg"
#* @param route Route of administration: "iv_bolus", "iv_infusion", "extravascular" (string, optional, default "extravascular")
#* @param infusion_duration Duration of IV infusion in time_unit (string, optional); required when route="iv_infusion"
#* @param dosing_scenario Dosing scenario: "single", "repeat", "steady_state" (string, optional, default "single")
#* @param tau Dosing interval in time_unit (string, optional); required when dosing_scenario != "single"
#* @param blq_first BLQ handling for leading samples (before the first measurable conc): "keep", "drop", "zero" (string, optional, default "zero")
#* @param blq_middle BLQ handling for embedded samples (between measurable concs): "keep", "drop", "zero" (string, optional, default "drop")
#* @param blq_last BLQ handling for trailing samples (after the last measurable conc): "keep", "drop", "zero" (string, optional, default "drop")
#* @param auc_method AUC calculation method: "lin up/log down", "linear", "lin-log" (string, optional, default "lin up/log down")
#* @param min_hl_points Minimum points for half-life calculation (string, optional, default "3")
#* @param min_hl_r_squared Minimum R-squared for half-life (string, optional, default "0.9")
#* @param max_aucinf_pext Maximum percent extrapolation for AUCinf (string, optional, default "20")
#* @param first_tmax Use first Tmax if tied: "true" or "false" (string, optional, default "true")
#* @param conc_unit_out Preferred output concentration unit (string, optional)
#* @param time_unit_out Preferred output time unit (string, optional)
#* @param data_file ADPC CSV filename in /data (output from /DATA endpoint); when provided, reads time/conc/dose/subject_id from file (string, optional)
#* @post /NCA
#* @serializer unboxedJSON list(digits = 10)
function(time = "0,0.25,0.5,1,2,4,8,12,24",
         conc = "10,9.05,8.19,6.70,4.49,3.01,1.83,1.11,0.45",
         params = NULL,
         dose = "1",
         subject_id = NULL,
         dose_label = NULL,
         pk_data = NULL,
         data_file = NULL,
         dose_unit = "mg",
         conc_unit = "ug/mL",
         time_unit = "h",
         BW = "70",
         route = "extravascular",
         infusion_duration = NULL,
         dosing_scenario = "single",
         tau = NULL,
         blq_first = "zero",
         blq_middle = "drop",
         blq_last = "drop",
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
    conc_unit <- normalize_conc_unit(conc_unit)
    route     <- normalize_route(route)   # accept numeric codes 1/2/3 or strings

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
      conc_unit_out <- normalize_conc_unit(conc_unit_out)
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

    # Check if data_file is provided (DATA → NCA file-based workflow)
    if (!is.null(data_file) && nchar(trimws(data_file)) > 0) {
      adpc_path <- file.path("/data", data_file)
      if (!file.exists(adpc_path)) {
        available <- list.files("/data", pattern = "\\.(csv|xlsx|xls)$", ignore.case = TRUE)
        avail_str <- if (length(available) > 0) paste(available, collapse = ", ") else "(none)"
        stop(sprintf("data_file not found: '%s'. Available in /data: %s", data_file, avail_str))
      }

      adpc_df <- read_data_file(adpc_path)

      # Expect ADPC columns: USUBJID, ATPTN, AVAL, DOSE
      required_adpc <- c("USUBJID", "ATPTN", "AVAL", "DOSE")
      validate_file_columns(adpc_df, required_adpc)

      # Convert ADPC to pipe-delimited NCA inputs grouped by subject. Optional DRUG
      # column enables multi-drug datasets; ROUTE/AVALU are read PER SUBJECT so a
      # single file can mix routes and concentration units across drugs.
      has_drug <- "DRUG" %in% names(adpc_df)
      has_ref  <- "REFERENCE" %in% names(adpc_df)
      has_evid <- "EVID" %in% names(adpc_df)
      has_route_col <- "ROUTE" %in% names(adpc_df)
      has_avalu_col <- "AVALU" %in% names(adpc_df)

      # Drop dosing-event rows (EVID==1) and any non-numeric/missing concentrations
      # (e.g. a "." placeholder on the dosing record). NCA runs on observations only.
      adpc_df$AVAL <- suppressWarnings(as.numeric(adpc_df$AVAL))
      if (has_evid) {
        evid_num <- suppressWarnings(as.numeric(adpc_df$EVID))
        adpc_df  <- adpc_df[is.na(evid_num) | evid_num == 0, , drop = FALSE]
      }
      adpc_df <- adpc_df[!is.na(adpc_df$AVAL), , drop = FALSE]
      if (nrow(adpc_df) == 0) stop("No observation rows (all AVAL missing or EVID==1).")

      # Subject identity: USUBJID may be a per-drug integer that repeats across drugs,
      # so group by REFERENCE (or DRUG) + USUBJID to keep each drug's subjects distinct.
      grp_key <- if (has_ref) as.character(adpc_df$REFERENCE)
                 else if (has_drug) as.character(adpc_df$DRUG)
                 else rep("", nrow(adpc_df))
      composite <- paste(grp_key, as.character(adpc_df$USUBJID), sep = "\r")
      groups    <- unique(composite)

      time_parts  <- character(length(groups))
      conc_parts  <- character(length(groups))
      dose_parts  <- character(length(groups))
      subj_labels <- character(length(groups))
      drug_vec    <- if (has_drug || has_ref) character(length(groups)) else NULL
      route_vec   <- if (has_route_col) character(length(groups)) else NULL
      avalu_vec   <- if (has_avalu_col) character(length(groups)) else NULL

      for (i in seq_along(groups)) {
        sdf <- adpc_df[composite == groups[i], ]
        sdf <- sdf[order(sdf$ATPTN), ]
        usub <- as.character(sdf$USUBJID[1])
        ref  <- if (has_ref) as.character(sdf$REFERENCE[1]) else if (has_drug) as.character(sdf$DRUG[1]) else NA
        time_parts[i]  <- paste(sdf$ATPTN, collapse = ",")
        conc_parts[i]  <- paste(sdf$AVAL, collapse = ",")
        dose_parts[i]  <- as.character(sdf$DOSE[1])
        subj_labels[i] <- if (!is.na(ref) && nzchar(ref)) paste(ref, usub, sep = "_") else usub
        if (has_drug || has_ref) drug_vec[i] <- if (has_drug) as.character(sdf$DRUG[1]) else ref
        if (has_route_col) route_vec[i] <- normalize_route(as.character(sdf$ROUTE[1]))
        if (has_avalu_col) avalu_vec[i] <- as.character(sdf$AVALU[1])
      }
      subjects <- subj_labels

      time        <- paste(time_parts, collapse = "|")
      conc        <- paste(conc_parts, collapse = "|")
      dose        <- paste(dose_parts, collapse = "|")
      subject_id  <- paste(subjects, collapse = "|")

      # Determine whether route/units are uniform across the file. Uniform values
      # update the scalar config (existing behavior); mixed values are passed as
      # per-subject vectors to run_population_nca.
      route_uniform <- TRUE
      if (has_route_col) {
        rv <- unique(route_vec[!is.na(route_vec) & nchar(trimws(route_vec)) > 0])
        if (length(rv) == 1 && route == "extravascular") route <- rv[1]
        route_uniform <- length(rv) <= 1
      }
      conc_uniform <- TRUE
      if (has_avalu_col) {
        av <- unique(avalu_vec[!is.na(avalu_vec) & nchar(trimws(avalu_vec)) > 0])
        if (length(av) == 1 && conc_unit == "ug/mL") conc_unit <- av[1]
        conc_uniform <- length(av) <= 1
      }

      # Re-validate after reading ADPC (conc_unit / route may have changed). For
      # mixed datasets, validate each distinct route/unit value.
      validate_nca_units(dose_unit, conc_unit, time_unit, bw_value)
      if (has_route_col && !route_uniform) {
        for (rv1 in unique(route_vec[nchar(trimws(route_vec)) > 0])) validate_route(rv1, infusion_dur_val)
      } else {
        validate_route(route, infusion_dur_val)
      }

      # Update config with potentially updated (uniform) units/route
      config$conc_unit <- conc_unit
      config$route     <- route

      # Always pass route_vec when a ROUTE column exists so per-subject routes
      # are applied even when all subjects share the same route value.
      route_arg <- if (has_route_col) route_vec else NULL
      conc_arg  <- if (has_avalu_col && !conc_uniform)   avalu_vec else NULL

      # Run as population NCA and tag the source file
      result <- run_population_nca(time, conc, dose, subject_id, dose_label, config,
                                   drug_labels = drug_vec, route_vec = route_arg,
                                   conc_unit_vec = conc_arg)
      result$source_file <- data_file
      return(result)
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
  result$half_life_quality <- list(
    adj_r_squared = get_param_value(nca_results, "adj.r.squared"),
    n_points      = as.integer(get_param_value(nca_results, "lambda.z.n.points"))
  )

  # Add all results with proper units
  result$results <- format_all_results(nca_results, config$time_unit, config$conc_unit,
                                        output_time, output_conc, config$dose_unit)

  # Keep available_params for backwards compatibility
  result$available_params <- result$results

  return(result)
}

#' Run NCA for population mode (entry point)
#' @param drug_labels Optional per-subject DRUG grouping labels (character vector);
#'   when supplied, the response gains a `summary_by_drug` block and each individual
#'   result is tagged with `drug`.
#' @param route_vec Optional per-subject route overrides (character vector); lets a
#'   single dataset mix IV and extravascular drugs. Falls back to config$route.
#' @param conc_unit_vec Optional per-subject concentration-unit labels (from AVALU).
run_population_nca <- function(time, conc, dose, subject_id, dose_label, config,
                               drug_labels = NULL, route_vec = NULL, conc_unit_vec = NULL) {
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

  # Determine output units (defaults; may be overridden per subject for multi-drug)
  output_time <- if (!is.null(config$time_unit_out)) config$time_unit_out else config$time_unit
  output_conc <- if (!is.null(config$conc_unit_out)) config$conc_unit_out else config$conc_unit

  has_drug <- !is.null(drug_labels) && length(drug_labels) == n_subjects

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

    # Per-subject config: route (affects t=0 anchor / IV C0 / intervals / PKNCAdose)
    # and concentration-unit label can vary across drugs in one dataset.
    subj_config <- config
    if (!is.null(route_vec) && length(route_vec) == n_subjects &&
        !is.na(route_vec[i]) && nzchar(route_vec[i])) {
      subj_config$route <- route_vec[i]
    }
    if (!is.null(conc_unit_vec) && length(conc_unit_vec) == n_subjects &&
        !is.na(conc_unit_vec[i]) && nzchar(conc_unit_vec[i])) {
      subj_config$conc_unit <- conc_unit_vec[i]
    }
    subj_out_conc <- if (!is.null(config$conc_unit_out)) config$conc_unit_out else subj_config$conc_unit

    # Calculate effective dose
    effective_dose <- calculate_effective_dose(d, subj_config$dose_unit, subj_config$bw_value)

    # Run NCA for this subject
    nca_results <- run_enhanced_nca(t, c, effective_dose, subj_config)

    # Store individual result with units
    individual_results[[i]] <- list(
      subject_id = subject_ids[i],
      dose_label = dose_labels[i],
      dose_administered = list(value = d, unit = subj_config$dose_unit),
      Cmax      = format_result_param(nca_results, "cmax",      subj_config$conc_unit, subj_out_conc),
      Tmax      = format_result_param(nca_results, "tmax",      subj_config$time_unit, output_time),
      auclast   = format_auc_param(nca_results, "auclast",   subj_config$time_unit, subj_config$conc_unit, output_time, subj_out_conc),
      aucinf_obs = format_auc_param(nca_results, "aucinf.obs", subj_config$time_unit, subj_config$conc_unit, output_time, subj_out_conc),
      half_life = format_result_param(nca_results, "half.life", subj_config$time_unit, output_time),
      cl_obs    = format_result_param(nca_results, "cl.obs",
                                      derive_param_unit("cl.obs", output_time, subj_out_conc, subj_config$dose_unit)),
      vz_obs    = format_result_param(nca_results, "vz.obs",
                                      derive_param_unit("vz.obs", output_time, subj_out_conc, subj_config$dose_unit)),
      half_life_quality = list(
        adj_r_squared = get_param_value(nca_results, "adj.r.squared"),
        n_points      = as.integer(get_param_value(nca_results, "lambda.z.n.points"))
      )
    )
    if (has_drug) {
      individual_results[[i]] <- c(
        list(subject_id = subject_ids[i], drug = drug_labels[i], route = subj_config$route),
        individual_results[[i]][setdiff(names(individual_results[[i]]), "subject_id")]
      )
    }

    # Add effective dose if mg/kg
    if (subj_config$dose_unit == "mg/kg") {
      individual_results[[i]]$effective_dose <- list(value = effective_dose, unit = "mg")
    }

    # Extract raw values for summary
    cmax_val      <- get_param_value(nca_results, "cmax")
    tmax_val      <- get_param_value(nca_results, "tmax")
    auclast_val   <- get_param_value(nca_results, "auclast")
    aucinf_val    <- get_param_value(nca_results, "aucinf.obs")
    halflife_val  <- get_param_value(nca_results, "half.life")
    cl_val        <- get_param_value(nca_results, "cl.obs")
    vz_val        <- get_param_value(nca_results, "vz.obs")

    # Accumulate for summary
    subj_row <- data.frame(
      subject_id = subject_ids[i],
      drug = if (has_drug) drug_labels[i] else NA_character_,
      dose_label = dose_labels[i],
      conc_unit = subj_out_conc,
      time_unit = output_time,
      Cmax      = cmax_val,
      Tmax      = tmax_val,
      auclast   = auclast_val,
      aucinf_obs = aucinf_val,
      half_life = halflife_val,
      cl_obs    = cl_val,
      vz_obs    = vz_val,
      adj_r_sq  = get_param_value(nca_results, "adj.r.squared"),
      n_points  = get_param_value(nca_results, "lambda.z.n.points"),
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
      Cmax_mean      = format_value_unit(mean(results_df$Cmax[idx],      na.rm = TRUE), output_conc),
      Cmax_sd        = format_value_unit(sd(results_df$Cmax[idx],        na.rm = TRUE), output_conc),
      Tmax_mean      = format_value_unit(mean(results_df$Tmax[idx],      na.rm = TRUE), output_time),
      Tmax_sd        = format_value_unit(sd(results_df$Tmax[idx],        na.rm = TRUE), output_time),
      auclast_mean   = format_value_unit(mean(results_df$auclast[idx],   na.rm = TRUE), paste0(output_time, "*", output_conc)),
      auclast_sd     = format_value_unit(sd(results_df$auclast[idx],     na.rm = TRUE), paste0(output_time, "*", output_conc)),
      aucinf_obs_mean = format_value_unit(mean(results_df$aucinf_obs[idx], na.rm = TRUE), paste0(output_time, "*", output_conc)),
      aucinf_obs_sd  = format_value_unit(sd(results_df$aucinf_obs[idx],  na.rm = TRUE), paste0(output_time, "*", output_conc)),
      half_life_mean = format_value_unit(mean(results_df$half_life[idx], na.rm = TRUE), output_time),
      half_life_sd   = format_value_unit(sd(results_df$half_life[idx],   na.rm = TRUE), output_time),
      cl_obs_mean    = format_value_unit(mean(results_df$cl_obs[idx],    na.rm = TRUE), paste0("mL/", output_time)),
      cl_obs_sd      = format_value_unit(sd(results_df$cl_obs[idx],      na.rm = TRUE), paste0("mL/", output_time)),
      vz_obs_mean    = format_value_unit(mean(results_df$vz_obs[idx],    na.rm = TRUE), "mL"),
      vz_obs_sd      = format_value_unit(sd(results_df$vz_obs[idx],      na.rm = TRUE), "mL"),
      adj_r_sq_mean  = mean(results_df$adj_r_sq[idx],  na.rm = TRUE),
      n_points_mean  = round(mean(results_df$n_points[idx], na.rm = TRUE), 1)
    )
  })
  names(summary_by_dose) <- unique_doses

  # Optional summary by DRUG (multi-drug benchmark datasets). Each drug carries its
  # own concentration/time unit labels (consistent within the drug).
  summary_by_drug <- NULL
  if (has_drug) {
    unique_drugs <- unique(results_df$drug)
    summary_by_drug <- lapply(unique_drugs, function(dg) {
      idx  <- results_df$drug == dg
      cu   <- results_df$conc_unit[idx][1]
      tu   <- results_df$time_unit[idx][1]
      list(
        drug = dg,
        n = sum(idx),
        route = if (!is.null(route_vec) && length(route_vec) == n_subjects)
                  route_vec[which(idx)[1]] else config$route,
        Cmax_mean      = format_value_unit(mean(results_df$Cmax[idx],      na.rm = TRUE), cu),
        Cmax_sd        = format_value_unit(sd(results_df$Cmax[idx],        na.rm = TRUE), cu),
        Tmax_mean      = format_value_unit(mean(results_df$Tmax[idx],      na.rm = TRUE), tu),
        auclast_mean   = format_value_unit(mean(results_df$auclast[idx],   na.rm = TRUE), paste0(tu, "*", cu)),
        auclast_sd     = format_value_unit(sd(results_df$auclast[idx],     na.rm = TRUE), paste0(tu, "*", cu)),
        aucinf_obs_mean = format_value_unit(mean(results_df$aucinf_obs[idx], na.rm = TRUE), paste0(tu, "*", cu)),
        aucinf_obs_sd  = format_value_unit(sd(results_df$aucinf_obs[idx],  na.rm = TRUE), paste0(tu, "*", cu)),
        half_life_mean = format_value_unit(mean(results_df$half_life[idx], na.rm = TRUE), tu),
        half_life_sd   = format_value_unit(sd(results_df$half_life[idx],   na.rm = TRUE), tu),
        cl_obs_mean    = format_value_unit(mean(results_df$cl_obs[idx],    na.rm = TRUE), paste0("mL/", tu)),
        cl_obs_sd      = format_value_unit(sd(results_df$cl_obs[idx],      na.rm = TRUE), paste0("mL/", tu)),
        vz_obs_mean    = format_value_unit(mean(results_df$vz_obs[idx],    na.rm = TRUE), "mL"),
        vz_obs_sd      = format_value_unit(sd(results_df$vz_obs[idx],      na.rm = TRUE), "mL"),
        adj_r_sq_mean  = mean(results_df$adj_r_sq[idx],  na.rm = TRUE),
        n_points_mean  = round(mean(results_df$n_points[idx], na.rm = TRUE), 1)
      )
    })
    names(summary_by_drug) <- unique_drugs
  }

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
  if (has_drug) {
    response$n_drugs <- length(unique(results_df$drug))
    response$summary_by_drug <- summary_by_drug
  }

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

  # Route-aware pre-dose handling

  # Extravascular: ensure t=0, conc=0 anchor exists so AUC starts at baseline
  if (config$route == "extravascular" && (length(t) == 0 || min(t) > 0)) {
    t <- c(0, t)
    c <- c(0, c)
  }

  # IV bolus: log-linear C0 back-extrapolation when no t=0 sample was collected
  if (config$route == "iv_bolus" && length(t) >= 2 && min(t) > 0) {
    t1 <- t[1]
    c1 <- c[1]
    t2 <- t[2]
    c2 <- c[2]
    if (c1 > 0 && c2 > 0 && t2 > t1) {
      slope <- (log(c2) - log(c1)) / (t2 - t1)
      c0    <- exp(log(c1) - slope * t1)
      if (is.finite(c0) && c0 > 0) {
        t <- c(0, t)
        c <- c(c0, c)
      }
    }
  }

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
      unit = if (is.null(unit)) NA_character_ else unit
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
