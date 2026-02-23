# endpoints/er.R
# Exposure-Response analysis endpoint
# Following Overgaard et al. (2015) good practices

#* Exposure-response (ER) analysis
#* Fits exposure-response models following Overgaard et al. (2015) good practices.
#* Shows response vs exposure (AUC) with quantile-based data display and optional dose group bars.
#* Supports binary (0/1) response data with logit model.
#* When resp_rate is provided with dose, binary responses are generated from target rates using seed for reproducibility.
#* @param exposure Comma-separated exposure values (AUC). Default: 60 subjects (20 per dose) from PK/NCA case study
#* @param resp Comma-separated responses (continuous or binary 0/1). Default: binary responses following logistic E-R
#* @param dose Comma-separated dose labels (optional). Default: 10 mg, 30 mg, 100 mg groups
#* @param resp_rate Comma-separated target response rates per dose group (e.g. "0.1,0.5,0.9"). When provided with dose, generates binary responses from these rates using seed. Overrides resp.
#* @param seed Random seed for reproducible binary response generation when resp_rate is used (string, optional, default "42")
#* @param model Model type: "auto", "linear", "emax", "imax", or "logit" (default: "auto")
#* @param n_quantiles Number of quantiles for visualization (default: "4")
#* @param subject_id Comma-separated subject IDs for tracking (string, optional)
#* @param auc_unit AUC unit label for x-axis (default: "h*ug/mL")
#* @param figure_dir Output directory for figures (default: "/figures")
#* @post /ER
#* @serializer unboxedJSON
function(exposure = "440.3,582.0,626.1,764.0,769.7,604.1,586.8,833.6,607.8,871.9,880.9,547.5,597.1,897.6,668.8,523.8,793.2,857.4,558.8,655.1,1958.0,1288.0,2372.8,1316.4,1827.4,1655.8,1812.3,2036.1,1580.6,2048.7,1853.4,2383.5,1572.4,2591.1,1650.4,1967.2,2489.9,1836.5,1584.8,2080.1,6887.1,7421.5,6718.6,7315.4,7557.5,5574.1,3952.1,7153.6,9919.6,5926.6,7098.7,6842.8,7253.8,8100.2,7915.5,7583.6,6312.1,8477.2,6723.4,7687.0",
         resp = "0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,1,0,0,1,0,0,0,1,1,0,1,0,1,0,0,0,1,1,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1",
         dose = "10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,10 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,30 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg,100 mg",
         resp_rate = NULL,
         seed = "42",
         model = "auto",
         n_quantiles = "4",
         subject_id = NULL,
         auc_unit = "h*ug/mL",
         figure_dir = "/figures") {

  tryCatch({
    # Validate inputs are not empty
    validate_string_input(exposure, "exposure")

    # Parse exposure
    es <- as.numeric(strsplit(exposure, ",")[[1]])
    n_quant <- as.integer(n_quantiles)

    # Validate exposure
    validate_numeric_vector(es, "exposure")
    if (n_quant < 2 || n_quant > 10) {
      stop("n_quantiles must be between 2 and 10")
    }

    # Parse dose if provided
    dose_vec <- NULL
    if (!is.null(dose) && nchar(trimws(dose)) > 0) {
      dose_vec <- trimws(strsplit(dose, ",")[[1]])
      if (length(dose_vec) != length(es)) {
        stop(sprintf("Length mismatch: dose (%d) must match exposure (%d)", length(dose_vec), length(es)))
      }
    }

    # Generate or parse response
    use_resp_rate <- !is.null(resp_rate) && nchar(trimws(resp_rate)) > 0
    if (use_resp_rate) {
      # Generate binary responses from target rates
      if (is.null(dose_vec)) {
        stop("dose is required when using resp_rate (need dose groups to determine group sizes)")
      }
      rates <- as.numeric(strsplit(resp_rate, ",")[[1]])
      if (any(is.na(rates))) {
        stop("resp_rate contains non-numeric values")
      }
      seed_val <- as.integer(seed)
      rs <- generate_binary_response(dose_vec, rates, seed_val)
    } else {
      validate_string_input(resp, "resp")
      rs <- as.numeric(strsplit(resp, ",")[[1]])
    }

    # Validate response
    validate_numeric_vector(rs, "resp")
    if (length(es) != length(rs)) {
      stop(sprintf("Length mismatch: exposure (%d) and resp (%d) must be equal", length(es), length(rs)))
    }

    # Create data frame (use 'conc' internally to maintain model compatibility)
    df <- data.frame(conc = es, resp = rs)

    # Fit all models
    models <- list()
    fit_stats <- list()
    params <- list()
    aics <- c()

    # Linear model
    linear_result <- fit_linear_model(es, rs)
    models$linear <- linear_result$model
    fit_stats$linear <- list(AIC = linear_result$AIC, R2 = linear_result$R2)
    params$linear <- linear_result$params
    aics <- c(aics, linear = linear_result$AIC)

    # Emax model
    emax_result <- fit_emax_model(es, rs)
    if (emax_result$success) {
      models$emax <- emax_result$model
      fit_stats$emax <- list(AIC = emax_result$AIC, R2 = emax_result$R2)
      params$emax <- emax_result$params
      aics <- c(aics, emax = emax_result$AIC)
    }

    # Imax model
    imax_result <- fit_imax_model(es, rs)
    if (imax_result$success) {
      models$imax <- imax_result$model
      fit_stats$imax <- list(AIC = imax_result$AIC, R2 = imax_result$R2)
      params$imax <- imax_result$params
      aics <- c(aics, imax = imax_result$AIC)
    }

    # Logit model (only for binary data)
    logit_result <- fit_logit_model(es, rs)
    if (logit_result$success) {
      models$logit <- logit_result$model
      fit_stats$logit <- list(AIC = logit_result$AIC)
      params$logit <- logit_result$params
      aics <- c(aics, logit = logit_result$AIC)
    }

    # Select best model
    if (model == "auto") {
      if (length(aics) == 0) stop("No models converged successfully")
      # For binary data, prioritize logit model if it converged
      is_binary <- is_binary_response(rs)
      if (is_binary && "logit" %in% names(aics)) {
        best_model <- "logit"
      } else {
        best_model <- names(which.min(aics))
      }
    } else {
      best_model <- model
      if (!best_model %in% names(models)) {
        stop(sprintf("Model '%s' did not converge or is not available for this data", best_model))
      }
    }

    # Generate predictions for plot with confidence intervals
    pred_exp <- seq(min(es), max(es), length.out = 100)
    pred_df <- NULL

    if (best_model == "linear") {
      pred_df <- calculate_linear_predictions_with_ci(models$linear, pred_exp)
    } else if (best_model == "emax") {
      p <- unlist(params$emax)
      pred <- p["e0"] + (p["emax"] * pred_exp) / (p["ec50"] + pred_exp)
      pred_df <- data.frame(exposure = pred_exp, pred = pred, lower = NA, upper = NA)
    } else if (best_model == "imax") {
      p <- unlist(params$imax)
      pred <- p["e0"] * (1 - (p["imax"] * pred_exp) / (p["ic50"] + pred_exp))
      pred_df <- data.frame(exposure = pred_exp, pred = pred, lower = NA, upper = NA)
    } else if (best_model == "logit") {
      pred_df <- calculate_logit_predictions_with_ci(models$logit, pred_exp)
    }

    # Calculate quantile statistics
    quantile_stats <- calculate_quantile_stats(es, rs, n_quant)

    # Calculate dose statistics if dose provided
    dose_stats <- NULL
    dose_summary <- NULL
    if (!is.null(dose_vec)) {
      dose_stats <- calculate_dose_stats(es, dose_vec)
      dose_summary <- lapply(seq_len(nrow(dose_stats)), function(i) {
        list(
          dose = dose_stats$dose[i],
          n = dose_stats$n[i],
          exposure_mean = dose_stats$exposure_mean[i],
          exposure_min = dose_stats$exposure_min[i],
          exposure_max = dose_stats$exposure_max[i]
        )
      })
    }

    # Create observed data frame for plotting (include dose if available)
    obs_df <- data.frame(exposure = es, resp = rs)
    if (!is.null(dose_vec)) {
      obs_df$dose <- dose_vec
    }

    # Check if response is binary for jittering
    is_binary <- is_binary_response(rs)

    # Create gold standard two-panel plot
    p <- create_er_plot_gold_standard(
      obs_df = obs_df,
      pred_df = pred_df,
      quantile_stats = quantile_stats,
      model_name = best_model,
      auc_unit = auc_unit,
      is_binary = is_binary
    )

    # Save plot to specified directory
    outfile <- save_pmx_plot(p, "ER", outdir = figure_dir)

    # Format quantile summary for output
    quantile_summary <- lapply(seq_len(nrow(quantile_stats)), function(i) {
      list(
        quantile = quantile_stats$quantile[i],
        n = quantile_stats$n[i],
        exposure_median = quantile_stats$exposure_median[i],
        resp_mean = quantile_stats$resp_mean[i],
        resp_ci_lower = quantile_stats$resp_ci_lower[i],
        resp_ci_upper = quantile_stats$resp_ci_upper[i]
      )
    })

    # Return results
    result <- list(
      model_used = best_model,
      parameters = params[[best_model]],
      fit_stats = fit_stats[[best_model]],
      plot_path = outfile,
      quantile_summary = quantile_summary,
      all_models = lapply(names(models), function(m) {
        list(model = m, parameters = params[[m]], fit_stats = fit_stats[[m]])
      })
    )

    # Add dose summary if dose was provided
    if (!is.null(dose_summary)) {
      result$dose_summary <- dose_summary
    }

    # Add resp_rate generation info if used
    if (use_resp_rate) {
      result$resp_rate_generation <- list(
        resp_rate = rates,
        seed = seed_val,
        generated_resp = as.integer(rs)
      )
    }

    return(result)

  }, error = function(e) {
    stop(sprintf("ER analysis failed: %s", e$message))
  })
}
