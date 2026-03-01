# endpoints/pk.R
# Pharmacokinetic simulation endpoint
# Supports single-subject, multi-subject (explicit params), and population (TV + OMEGA) simulations

#* Pharmacokinetic simulation (IV; 1- or 2-CM)
#* Simulates plasma concentration-time profile for a one or two compartment model with a single IV bolus dose.
#* Supports three modes:
#* 1. Single-subject: Single values for dose, CL, V1, etc.
#* 2. Multi-subject (explicit): Comma-separated CL, V1, etc. for each subject
#* 3. Population (BSV): Use n_subjects with per-kg values (CL, V1, etc.) and CV for between-subject variability
#* @param dose Dose amount(s) in mg - single value or comma-separated for multiple subjects/doses (string)
#* @param CL Clearance per kg (mL/h/kg) - default 0.15 (Betts 2018)
#* @param V1 Central volume per kg (mL/kg) - default 46.31 (Betts 2018)
#* @param V2 Peripheral volume per kg (mL/kg) - default 31.47 (Betts 2018, optional)
#* @param Q Intercompartmental clearance per kg (mL/h/kg) - default 0.27 (Betts 2018, optional)
#* @param t Comma-separated times in hours, e.g. "0,0.5,1,2,4,8,12,24,48,72,168,336,504,672,1008,1344"
#* @param model Model type: "auto", "1cm", or "2cm" (default: "auto")
#* @param subject_id Comma-separated subject IDs for multi-subject (string, optional)
#* @param dose_label Comma-separated dose labels for grouping, e.g. "10 mg,10 mg,30 mg" (string, optional)
#* @param n_subjects Number of subjects for population simulation using TV values (string, optional)
#* @param n_per_dose Number of subjects per dose level when multiple doses provided (string, optional)
#* @param cv Coefficient of variation for BSV in population mode (string, default "0.30" = 30%)
#* @param BW Body weight in kg (string, default "70")
#* @param seed Random seed for reproducibility in population mode (string, optional)
#* @param time_unit Time unit for plot display: "auto", "hours", "days", or "weeks" (default: "auto" - selects based on range)
#* @param conc_unit Concentration unit label for plot y-axis (default: "ug/mL")
#* @param figure_dir Output directory for figures (default: "/figures")
#* @param save_csv If "true", saves simulated concentration-time data as CSV to output_dir (default: "false")
#* @param output_dir Output directory for CSV file when save_csv="true" (default: "/data")
#* @post /PK
#* @serializer unboxedJSON
function(dose = "10,30,100",
         CL = "0.15",
         V1 = "46.31",
         V2 = "31.47",
         Q = "0.27",
         t = "0,0.5,1,2,4,8,12,24,48,72,168,336,504,672",
         model = "2cm",
         subject_id = NULL,
         dose_label = NULL,
         n_subjects = "60",
         n_per_dose = "20",
         cv = "0.30",
         BW = "70",
         seed = "42",
         time_unit = "auto",
         conc_unit = "ug/mL",
         figure_dir = "/figures",
         save_csv = "false",
         output_dir = "/data") {

  tryCatch({
    # Parse save_csv flag
    do_save_csv <- isTRUE(trimws(tolower(save_csv)) == "true")

    # Helper: save simulation data as CSV and return output filename
    save_pk_csv <- function(individual_data_list, out_dir, conc_unit_label) {
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
      timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
      out_name  <- sprintf("pk_simulation_%s.csv", timestamp)
      out_path  <- file.path(out_dir, out_name)

      rows <- lapply(individual_data_list, function(subj) {
        data.frame(
          USUBJID   = subj$subject_id,
          TIME      = subj$times,
          CONC      = subj$concentrations,
          DOSE      = subj$dose,
          CONC_UNIT = conc_unit_label,
          stringsAsFactors = FALSE
        )
      })
      csv_df <- do.call(rbind, rows)
      write.csv(csv_df, out_path, row.names = FALSE)
      out_name
    }

    # Validate required inputs
    validate_string_input(dose, "dose")
    validate_string_input(t, "t")

    # Parse time points
    ts <- as.numeric(strsplit(t, ",")[[1]])
    validate_numeric_vector(ts, "time", allow_negative = FALSE)

    # Parse dose(s)
    doses <- as.numeric(strsplit(dose, ",")[[1]])

    # Determine mode based on parameters
    is_population_mode <- !is.null(n_subjects) && nchar(trimws(n_subjects)) > 0

    if (is_population_mode) {
      # ========== POPULATION MODE (TV + OMEGA) ==========
      n_subj <- as.integer(n_subjects)
      if (is.na(n_subj) || n_subj < 1) {
        stop("n_subjects must be a positive integer")
      }
      if (n_subj > MAX_SUBJECTS) {
        stop(sprintf("n_subjects (%d) exceeds maximum (%d)", n_subj, MAX_SUBJECTS))
      }

      # Parse population parameters
      cv_val <- as.numeric(cv)
      bw_val <- as.numeric(BW)
      if (is.na(cv_val) || cv_val <= 0 || cv_val > 1) {
        stop("cv must be between 0 and 1 (e.g., 0.25 for 25%)")
      }
      if (is.na(bw_val) || bw_val <= 0) {
        stop("BW must be a positive number")
      }

      # CL/V1/V2/Q are per-kg values with Betts 2018 defaults
      # Parse first value from each (in case comma-separated list provided)
      tvcl_val <- as.numeric(strsplit(CL, ",")[[1]])[1]    # mL/h/kg
      tvv1_val <- as.numeric(strsplit(V1, ",")[[1]])[1]    # mL/kg
      tvv2_val <- if (!is.null(V2) && nchar(trimws(V2)) > 0) as.numeric(strsplit(V2, ",")[[1]])[1] else 31.47  # mL/kg
      tvq_val <- if (!is.null(Q) && nchar(trimws(Q)) > 0) as.numeric(strsplit(Q, ",")[[1]])[1] else 0.27       # mL/h/kg

      # Parse seed
      seed_val <- NULL
      if (!is.null(seed) && nchar(trimws(seed)) > 0) {
        seed_val <- as.integer(seed)
      }

      # Handle dose assignment for population
      n_doses <- length(doses)
      if (n_doses > 1) {
        # Multiple doses provided - distribute subjects across doses
        if (!is.null(n_per_dose) && nchar(trimws(n_per_dose)) > 0) {
          n_per <- as.integer(n_per_dose)
          if (n_per * n_doses != n_subj) {
            stop(sprintf("n_subjects (%d) must equal n_per_dose (%d) * number of doses (%d)",
                        n_subj, n_per, n_doses))
          }
        }
        # Assign doses evenly across subjects
        dose_assignment <- rep(doses, each = n_subj / n_doses)
        if (length(dose_assignment) != n_subj) {
          # Handle uneven distribution
          dose_assignment <- rep(doses, length.out = n_subj)
        }
      } else {
        # Single dose for all subjects
        dose_assignment <- rep(doses[1], n_subj)
      }

      # Determine model type
      use_two_cm <- model != "1cm"  # Default to 2CM for population mode
      model_used <- if (use_two_cm) "two-compartment" else "one-compartment"

      # Simulate population
      if (use_two_cm) {
        pop_result <- simulate_population_2cm(
          n_subjects = n_subj,
          doses = dose_assignment,
          TVCL = tvcl_val,
          TVV1 = tvv1_val,
          TVV2 = tvv2_val,
          TVQ = tvq_val,
          BW = bw_val,
          cv = cv_val,
          times = ts,
          seed = seed_val
        )
      } else {
        pop_result <- simulate_population_1cm(
          n_subjects = n_subj,
          doses = dose_assignment,
          TVCL = tvcl_val,
          TVV1 = tvv1_val,
          BW = bw_val,
          cv = cv_val,
          times = ts,
          seed = seed_val
        )
      }

      # Generate subject IDs and dose labels
      subject_ids <- sprintf("SUBJ%03d", 1:n_subj)
      dose_labels <- paste(dose_assignment, "mg")

      # Get concentration conversion factor (model outputs mg/mL, convert to display unit)
      conc_factor <- get_conc_conversion_factor(conc_unit)

      # Build individual data from simulation results
      individual_data <- list()
      all_conc_df <- data.frame()

      for (i in 1:n_subj) {
        subj_data <- pop_result[pop_result$ID == i, ]
        # Ensure we only take the requested time points
        subj_data <- subj_data[order(subj_data$time), ]

        # Apply unit conversion to concentrations (model outputs mg/mL)
        converted_conc <- subj_data$CP * conc_factor

        individual_data[[i]] <- list(
          subject_id = subject_ids[i],
          dose = dose_assignment[i],
          dose_label = dose_labels[i],
          times = subj_data$time,
          concentrations = round(converted_conc, 4),
          CL = subj_data$CL[1],
          V1 = subj_data$VC[1],
          V2 = if (use_two_cm) subj_data$VP[1] else NA,
          Q = if (use_two_cm) subj_data$Q[1] else NA
        )

        # Build concentration dataframe for this subject (already converted)
        subj_df <- data.frame(
          subject_id = subject_ids[i],
          dose_label = dose_labels[i],
          time = subj_data$time,
          concentration = converted_conc,
          stringsAsFactors = FALSE
        )
        all_conc_df <- rbind(all_conc_df, subj_df)
      }

      # Calculate summary statistics by dose group
      unique_doses <- unique(dose_labels)
      summary_by_dose <- lapply(unique_doses, function(dl) {
        idx <- all_conc_df$dose_label == dl
        subj_ids <- unique(all_conc_df$subject_id[idx])
        n <- length(subj_ids)

        time_stats <- do.call(rbind, lapply(ts, function(tm) {
          conc_at_t <- all_conc_df$concentration[idx & all_conc_df$time == tm]
          data.frame(
            time = tm,
            mean = mean(conc_at_t, na.rm = TRUE),
            sd = sd(conc_at_t, na.rm = TRUE),
            n = length(conc_at_t)
          )
        }))

        list(
          dose_label = dl,
          n = n,
          times = time_stats$time,
          mean = time_stats$mean,
          sd = time_stats$sd
        )
      })
      names(summary_by_dose) <- unique_doses

      # Create population plot with unit parameters
      p <- create_population_pk_plot(all_conc_df, unique_doses, model_used,
                                     time_unit = time_unit, conc_unit = conc_unit)
      outfile <- save_pmx_plot(p, "PK", outdir = figure_dir)

      # Optionally save CSV
      csv_filename <- if (do_save_csv) {
        save_pk_csv(individual_data, output_dir, conc_unit)
      } else NULL

      # Return population results
      pop_result_out <- list(
        mode = "population",
        model_used = model_used,
        n_subjects = n_subj,
        units = list(
          time = "h",
          concentration = conc_unit
        ),
        variability = list(
          cv = cv_val,
          omega = sqrt(log(1 + cv_val^2)),
          description = sprintf("%.0f%% CV on all PK parameters (lognormal BSV)", cv_val * 100)
        ),
        typical_values = list(
          CL = tvcl_val,
          V1 = tvv1_val,
          V2 = if (use_two_cm) tvv2_val else NULL,
          Q = if (use_two_cm) tvq_val else NULL,
          BW = bw_val,
          source = "Betts et al. 2018 (defaults)"
        ),
        individual_data = individual_data,
        summary_by_dose = summary_by_dose,
        plot_path = outfile,
        seed = seed_val
      )
      if (!is.null(csv_filename)) pop_result_out$output_file <- csv_filename
      return(pop_result_out)

    } else {
      # ========== EXPLICIT PARAMETER MODE (per-kg values scaled by BW) ==========
      validate_string_input(CL, "CL")
      validate_string_input(V1, "V1")

      # Parse per-kg values
      CLs_perkg <- as.numeric(strsplit(CL, ",")[[1]])
      V1s_perkg <- as.numeric(strsplit(V1, ",")[[1]])
      V2s_perkg <- if (!is.null(V2) && nchar(trimws(V2)) > 0) as.numeric(strsplit(V2, ",")[[1]]) else NA
      Qs_perkg <- if (!is.null(Q) && nchar(trimws(Q)) > 0) as.numeric(strsplit(Q, ",")[[1]]) else NA
      bw_val <- as.numeric(BW)

      # Scale to absolute values for simulation
      CLs <- CLs_perkg * bw_val  # mL/h
      V1s <- V1s_perkg * bw_val  # mL
      V2s <- if (!all(is.na(V2s_perkg))) V2s_perkg * bw_val else NA
      Qs <- if (!all(is.na(Qs_perkg))) Qs_perkg * bw_val else NA

      # Detect multi-subject mode
      n_subj <- max(length(CLs), length(V1s), length(doses))
      is_multi <- n_subj > 1

      if (is_multi) {
        # ========== MULTI-SUBJECT MODE ==========
        if (n_subj > MAX_SUBJECTS) {
          stop(sprintf("Number of subjects (%d) exceeds maximum (%d)", n_subj, MAX_SUBJECTS))
        }

        # Expand single values
        if (length(doses) == 1) doses <- rep(doses, n_subj)
        if (length(CLs) == 1) CLs <- rep(CLs, n_subj)
        if (length(V1s) == 1) V1s <- rep(V1s, n_subj)
        if (length(V2s) == 1) V2s <- rep(V2s, n_subj)
        if (length(Qs) == 1) Qs <- rep(Qs, n_subj)

        # Validate lengths
        if (!all(c(length(doses), length(CLs), length(V1s)) == n_subj)) {
          stop("For multi-subject mode, dose, CL, and V1 must have the same length or be single values")
        }

        # Parse subject IDs
        subject_ids <- NULL
        if (!is.null(subject_id) && nchar(trimws(subject_id)) > 0) {
          subject_ids <- trimws(strsplit(subject_id, ",")[[1]])
          if (length(subject_ids) != n_subj) {
            stop(sprintf("subject_id length (%d) must match number of subjects (%d)",
                        length(subject_ids), n_subj))
          }
        } else {
          subject_ids <- sprintf("SUBJ%03d", seq_len(n_subj))
        }

        # Parse dose labels
        dose_labels <- NULL
        if (!is.null(dose_label) && nchar(trimws(dose_label)) > 0) {
          dose_labels <- trimws(strsplit(dose_label, ",")[[1]])
          if (length(dose_labels) != n_subj) {
            stop(sprintf("dose_label length (%d) must match number of subjects (%d)",
                        length(dose_labels), n_subj))
          }
        } else {
          dose_labels <- paste(doses, "mg")
        }

        # Determine model type
        use_two_cm <- !all(is.na(V2s)) && !all(is.na(Qs))
        if (model == "2cm" && !use_two_cm) {
          stop("For model='2cm', V2 and Q must be provided")
        }
        if (model == "1cm") {
          use_two_cm <- FALSE
        }
        model_used <- if (use_two_cm) "two-compartment" else "one-compartment"

        # Get concentration conversion factor (model outputs mg/mL, convert to display unit)
        conc_factor <- get_conc_conversion_factor(conc_unit)

        # Simulate each subject
        individual_data <- list()
        all_conc_df <- data.frame()

        for (i in seq_len(n_subj)) {
          validate_dose(doses[i])
          if (use_two_cm) {
            validate_pk_params(CLs[i], V1s[i], V2s[i], Qs[i])
            conc <- simulate_2cm(doses[i], CLs[i], V1s[i], V2s[i], Qs[i], ts)
          } else {
            validate_pk_params(CLs[i], V1s[i])
            conc <- simulate_1cm(doses[i], CLs[i], V1s[i], ts)
          }

          # Apply unit conversion to concentrations (model outputs mg/mL)
          converted_conc <- conc * conc_factor

          individual_data[[i]] <- list(
            subject_id = subject_ids[i],
            dose = doses[i],
            dose_label = dose_labels[i],
            times = ts,
            concentrations = round(converted_conc, 4)
          )

          subj_df <- data.frame(
            subject_id = subject_ids[i],
            dose_label = dose_labels[i],
            time = ts,
            concentration = converted_conc,
            stringsAsFactors = FALSE
          )
          all_conc_df <- rbind(all_conc_df, subj_df)
        }

        # Calculate summary statistics by dose group
        unique_doses <- unique(dose_labels)
        summary_by_dose <- lapply(unique_doses, function(dl) {
          idx <- all_conc_df$dose_label == dl
          subj_ids <- unique(all_conc_df$subject_id[idx])
          n <- length(subj_ids)

          time_stats <- do.call(rbind, lapply(ts, function(tm) {
            conc_at_t <- all_conc_df$concentration[idx & all_conc_df$time == tm]
            data.frame(
              time = tm,
              mean = mean(conc_at_t, na.rm = TRUE),
              sd = sd(conc_at_t, na.rm = TRUE),
              n = length(conc_at_t)
            )
          }))

          list(
            dose_label = dl,
            n = n,
            times = time_stats$time,
            mean = time_stats$mean,
            sd = time_stats$sd
          )
        })
        names(summary_by_dose) <- unique_doses

        # Create population plot with unit parameters
        p <- create_population_pk_plot(all_conc_df, unique_doses, model_used,
                                       time_unit = time_unit, conc_unit = conc_unit)
        outfile <- save_pmx_plot(p, "PK", outdir = figure_dir)

        # Optionally save CSV
        csv_filename_ms <- if (do_save_csv) {
          save_pk_csv(individual_data, output_dir, conc_unit)
        } else NULL

        multi_result <- list(
          mode = "population",
          model_used = model_used,
          n_subjects = n_subj,
          units = list(
            time = "h",
            concentration = conc_unit
          ),
          individual_data = individual_data,
          summary_by_dose = summary_by_dose,
          plot_path = outfile
        )
        if (!is.null(csv_filename_ms)) multi_result$output_file <- csv_filename_ms
        return(multi_result)

      } else {
        # ========== SINGLE-SUBJECT MODE ==========
        dose_val <- doses[1]
        CL_val <- CLs[1]
        V1_val <- V1s[1]
        V2_val <- if (length(V2s) > 0 && !is.na(V2s[1])) V2s[1] else NA
        Q_val <- if (length(Qs) > 0 && !is.na(Qs[1])) Qs[1] else NA

        validate_dose(dose_val)

        model_used <- NULL
        conc <- NULL

        if (model == "1cm") {
          validate_pk_params(CL_val, V1_val)
          conc <- simulate_1cm(dose_val, CL_val, V1_val, ts)
          model_used <- "one-compartment"
        } else if (model == "2cm") {
          if (is.na(V2_val) || is.na(Q_val)) {
            stop("For model='2cm', V2 and Q must be provided")
          }
          validate_pk_params(CL_val, V1_val, V2_val, Q_val)
          conc <- simulate_2cm(dose_val, CL_val, V1_val, V2_val, Q_val, ts)
          model_used <- "two-compartment"
        } else {
          use_two_cm <- !is.na(V2_val) && !is.na(Q_val)
          if (use_two_cm) {
            validate_pk_params(CL_val, V1_val, V2_val, Q_val)
            conc <- simulate_2cm(dose_val, CL_val, V1_val, V2_val, Q_val, ts)
            model_used <- "two-compartment"
          } else {
            validate_pk_params(CL_val, V1_val)
            conc <- simulate_1cm(dose_val, CL_val, V1_val, ts)
            model_used <- "one-compartment"
          }
        }

        # Determine time unit for display
        display_time_unit <- if (time_unit == "auto") auto_select_time_unit(ts) else time_unit
        display_times <- convert_time_for_display(ts, display_time_unit)

        # Get conversion factor: model outputs mg/mL, convert to display unit
        conc_factor <- get_conc_conversion_factor(conc_unit)

        # Apply conversion to concentrations
        converted_conc <- conc * conc_factor

        # Create plot with unit labels (apply conversion for display)
        df <- data.frame(time = display_times, concentration = converted_conc)
        p <- ggplot(df, aes(x = time, y = concentration)) +
          geom_line(color = 'blue', linewidth = 1.2) +
          geom_point(color = 'red', size = 2) +
          labs(
            title = paste('PK Simulation (', model_used, ', Bolus)', sep = ''),
            x = get_time_label(display_time_unit),
            y = get_conc_label(conc_unit)
          ) +
          scale_y_log10() +
          get_pmx_theme()

        outfile <- save_pmx_plot(p, "PK", outdir = figure_dir)

        # Optionally save CSV (single subject)
        single_individual_data <- list(list(
          subject_id = "SUBJ001",
          times = ts,
          concentrations = round(converted_conc, 4),
          dose = dose_val
        ))
        csv_filename_single <- if (do_save_csv) {
          save_pk_csv(single_individual_data, output_dir, conc_unit)
        } else NULL

        single_result <- list(
          mode = "single",
          times = ts,
          concentrations = round(converted_conc, 4),
          units = list(
            time = "h",
            concentration = conc_unit
          ),
          model_used = model_used,
          plot_path = outfile
        )
        if (!is.null(csv_filename_single)) single_result$output_file <- csv_filename_single
        single_result
      }
    }

  }, error = function(e) {
    stop(sprintf("PK simulation failed: %s", e$message))
  })
}
