# endpoints/library.R
# /LIBRARY endpoint: list or simulate PK models from the nlmixr2lib literature
# model library. Simulation emits an ADPC-compatible CSV (feeds /NCA data_file)
# plus a concentration-time PNG, following the /PK and /DATA conventions.

# Dependencies (utils/constants.R, utils/validation.R, utils/colors.R,
# utils/plotting.R, utils/library_utils.R, models/nlmixr2lib_sim.R) and the
# ggplot2/nlmixr2lib/rxode2 libraries are sourced/attached by apis/rapi.R at
# startup, following the same convention as the other endpoint modules.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse "WT=70,CRCL=90" -> named numeric c(WT=70, CRCL=90); "" -> NULL
.library_parse_covariates <- function(s) {
  s <- trimws(s)
  if (!nzchar(s)) return(NULL)
  parts <- strsplit(s, ",")[[1]]
  vals  <- numeric(0)
  for (p in parts) {
    kv <- strsplit(p, "=")[[1]]
    if (length(kv) != 2) stop(sprintf("Invalid covariates entry '%s' (use NAME=value,NAME=value)", p))
    v <- suppressWarnings(as.numeric(trimws(kv[2])))
    if (is.na(v)) stop(sprintf("Covariate '%s' value is not numeric", trimws(kv[1])))
    vals[trimws(kv[1])] <- v
  }
  vals
}

# Write the simulated population as an ADPC CSV; returns the filename (not path).
.library_write_adpc <- function(long_df, model_name, conc_unit, dose_unit, route, out_dir) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  adpc <- data.frame(
    USUBJID = long_df$subject_id,
    ATPTN   = long_df$time,
    AVAL    = round(long_df$concentration, 6),
    AVALU   = conc_unit,
    DOSE    = long_df$dose,
    DOSEU   = dose_unit,
    DOSNO   = 1L,
    ROUTE   = route,
    BLQ     = 0L,
    stringsAsFactors = FALSE
  )
  adpc <- adpc[order(adpc$USUBJID, adpc$ATPTN), ]
  ts    <- format(Sys.time(), "%Y%m%d_%H%M%S")
  safe  <- gsub("[^A-Za-z0-9_.-]", "_", model_name)
  fname <- sprintf("LIBRARY_%s_%s.csv", safe, ts)
  utils::write.csv(adpc, file.path(out_dir, fname), row.names = FALSE)
  fname
}

# Per-dose-group summary statistics (mean +- SD profile, Cmax/Tmax).
.library_summary_stats <- function(long_df) {
  res <- list()
  for (dl in unique(long_df$dose_label)) {
    sdf  <- long_df[long_df$dose_label == dl, ]
    subs <- unique(sdf$subject_id)
    cmax <- tapply(sdf$concentration, sdf$subject_id, max)
    tmax <- vapply(subs, function(s) {
      ss <- sdf[sdf$subject_id == s, ]; ss$time[which.max(ss$concentration)]
    }, numeric(1))
    tt    <- sort(unique(sdf$time))
    meanv <- vapply(tt, function(t0) mean(sdf$concentration[sdf$time == t0]), numeric(1))
    sdv   <- vapply(tt, function(t0) stats::sd(sdf$concentration[sdf$time == t0]), numeric(1))
    res[[dl]] <- list(
      n             = length(subs),
      cmax_mean     = round(mean(cmax), 4),
      cmax_sd       = round(stats::sd(cmax), 4),
      tmax_median_h = stats::median(tmax),
      times         = tt,
      mean          = round(meanv, 4),
      sd            = round(sdv, 4)
    )
  }
  res
}

.library_pinned_commit <- function() {
  sha <- Sys.getenv("NLMIXR2LIB_SHA", "")
  if (nzchar(sha)) sha else as.character(utils::packageVersion("nlmixr2lib"))
}

# Collapse a per-subject long df to one representative profile per dose group.
# mean_type "geometric" -> exp(mean(log(conc>0))); "arithmetic" -> mean(conc).
.library_collapse_profile <- function(long_df, mean_type) {
  out <- list()
  for (dl in unique(long_df$dose_label)) {
    sdf <- long_df[long_df$dose_label == dl, ]
    tt  <- sort(unique(sdf$time))
    val <- vapply(tt, function(t0) {
      x <- sdf$concentration[sdf$time == t0]
      x <- x[is.finite(x)]
      if (length(x) == 0) return(NA_real_)
      if (mean_type == "geometric") {
        xp <- x[x > 0]
        if (length(xp) == 0) return(0)
        exp(mean(log(xp)))
      } else {
        mean(x)
      }
    }, numeric(1))
    out[[dl]] <- data.frame(time = tt, concentration = val,
                            dose = sdf$dose[1], dose_label = dl,
                            stringsAsFactors = FALSE)
  }
  do.call(rbind, out)
}

# Simulate one library model and return its long (per-subject) profile plus a
# collapsed representative profile, all with TIME normalized to hours. Reuses the
# existing load/probe/simulate stack; structure-agnostic via the half-life probe.
.library_simulate_core <- function(model_name, doses, n_subj, seed_val, dose_unit,
                                   route_override, times_override, user_cov, mean_type,
                                   wide = FALSE, residual = TRUE) {
  ui       <- load_library_model(model_name)
  route    <- if (nzchar(trimws(route_override))) trimws(route_override) else detect_route(ui)
  conc_var <- detect_conc_output(ui)
  n_cmt    <- count_disposition_cmt(ui)
  cov      <- resolve_covariates(ui, user_cov)

  # In standard scope, keep benchmark strictly 1-2 compartment. In wide scope,
  # 3-compartment models (including TMDD) are allowed.
  if (!wide && !is.na(n_cmt) && n_cmt > 2L) {
    stop(sprintf("'%s' compiles to %d disposition compartments; out of 1-2 compartment benchmark scope.",
                 model_name, n_cmt))
  }

  hl <- probe_model(ui, route, conc_var, cov$values)
  if (!is.finite(hl$t_half_h)) {
    stop(sprintf("Could not estimate a terminal half-life for '%s' (no detectable terminal phase).",
                 model_name))
  }
  # Exclude endogenous-baseline models (production / non-zero initial condition):
  # their profiles plateau at a baseline, so there is no clean terminal phase for NCA.
  if (isTRUE(hl$baseline_fraction > LIBRARY_BASELINE_MAX_FRAC)) {
    stop(sprintf("'%s' has an endogenous baseline (%.0f%% of Cmax); no clean terminal phase for NCA (out of scope).",
                 model_name, 100 * hl$baseline_fraction))
  }
  # In standard scope, exclude nonlinear (TMDD / Michaelis-Menten) models. In wide
  # scope, nonlinear models are intentionally included — NCA is still computed but
  # parameters (CL, Vz) will reflect the dose-specific apparent values.
  dprop <- dose_proportionality_ratio(ui, route, conc_var, cov$values)
  if (!wide && is.finite(dprop) && abs(dprop - 1) > LIBRARY_LINEARITY_TOL) {
    stop(sprintf("'%s' shows nonlinear (dose-dependent) elimination (AUC dose-proportionality %.2f); out of linear-PK / macro-constant scope.",
                 model_name, dprop))
  }

  # Pipeline runs in the model's NATIVE time units; convert to hours only for output.
  nu   <- extract_model_units(model_name)
  tfac <- time_to_hours_factor(nu$time)

  # Reject implausible (non-eliminating / endogenous-baseline) half-lives so the
  # sampling window stays finite and the profile is NCA-analyzable.
  t_half_h_est <- hl$t_half_h * tfac
  if (!is.finite(t_half_h_est) || t_half_h_est > LIBRARY_MAX_HALF_LIFE_H) {
    stop(sprintf("'%s' has an implausible terminal half-life (%.3g h); likely an endogenous-baseline / non-eliminating model, out of NCA scope.",
                 model_name, t_half_h_est))
  }

  if (nzchar(trimws(times_override))) {
    times_h      <- sort(unique(as.numeric(strsplit(trimws(times_override), ",")[[1]])))
    times_h      <- times_h[is.finite(times_h)]
    if (length(times_h) < 3) stop("times_override must contain at least 3 valid time points")
    times_native <- times_h / tfac
    window_h     <- max(times_h)
  } else {
    sched        <- build_sampling_schedule(t_half_h_est, route)  # hours in, hours out
    times_h      <- sched$times
    times_native <- times_h / tfac   # convert to native for simulation
    window_h     <- sched$window_h
  }

  long_native <- if (mean_type == "typical") {
    simulate_library_typical(ui, doses, times_native, route, conc_var, cov$values, dose_unit)
  } else {
    simulate_library_population(ui, doses, times_native, n_subj, route, conc_var,
                                cov$values, seed_val, dose_unit, residual = residual)
  }
  used_omega <- isTRUE(attr(long_native, "used_omega"))
  resid_err  <- attr(long_native, "residual_error") %||% list(prop = 0, add = 0, type = "none")
  long_df <- long_native
  long_df$time <- long_df$time * tfac

  maxc <- suppressWarnings(max(long_df$concentration, na.rm = TRUE))
  if (!is.finite(maxc) || maxc <= 0) {
    stop(sprintf("Simulated concentrations are all ~0 (max=%g) for '%s'.", maxc, model_name))
  }

  # The collapsed mean profile is built from IPRED (BSV-only) so it is not perturbed
  # by the per-observation residual noise carried in `concentration`.
  profile <- if (mean_type == "typical") {
    long_df[, c("time", "concentration", "dose", "dose_label")]
  } else {
    clean <- long_df
    if ("ipred" %in% names(clean)) clean$concentration <- clean$ipred
    .library_collapse_profile(clean, mean_type)
  }

  # Route LABEL is taken empirically from the simulated profile so it always matches
  # what the data shows: a concentration that peaks at the dose -> iv_bolus; one that
  # starts ~0 and rises to a later peak (absorption / lag) -> extravascular. (The dose
  # itself was administered via `route` above; `route_label` describes the result.)
  route_label <- if (nzchar(trimws(route_override))) route
                 else empirical_route(ui, route, conc_var, cov$values)
  route_basis <- if (nzchar(trimws(route_override))) "override" else "empirical_profile"

  list(
    long_df          = long_df,
    profile          = profile,
    route            = route_label,
    route_basis      = route_basis,
    n_cmt            = n_cmt,
    conc_var         = conc_var,
    t_half_h         = hl$t_half_h * tfac,
    tier             = assign_tier(hl$t_half_h * tfac),
    native_time_unit = if (is.na(nu$time)) "hour" else nu$time,
    native_conc_unit = nu$concentration,
    parameters       = hl$params,
    half_life_method = hl$method,
    t_half_macro_h   = if (is.finite(hl$t_half_macro)) hl$t_half_macro * tfac else NA_real_,
    t_half_numeric_h = if (is.finite(hl$t_half_numeric)) hl$t_half_numeric * tfac else NA_real_,
    t_half_profile_h = if (is.finite(hl$t_half_profile)) hl$t_half_profile * tfac else NA_real_,
    baseline_fraction = hl$baseline_fraction,
    dose_proportionality = dprop,
    used_omega       = used_omega,
    residual_error   = resid_err,
    covariates_defaulted = cov$defaulted,
    covariates_zeroed    = cov$zeroed
  )
}

# Map a route string to the numeric administration code used by tools such as
# PKanalix (1 = iv_bolus, 2 = extravascular, 3 = iv_infusion).
.library_route_code <- function(route) {
  m <- c(iv_bolus = 1L, extravascular = 2L, iv_infusion = 3L)
  out <- unname(m[route]); out[is.na(out)] <- 2L  # default extravascular
  out
}

# Write/append the combined multi-drug individual-level CSV.
# Columns: USUBJID, REFERENCE, DRUG, EVID, ATPTN, AVAL, AVALU, DOSE, DOSEU, ROUTE, BLQ.
#   * USUBJID is a per-drug subject integer (1..N) — intentionally NOT unique across
#     drugs; REFERENCE (full model ref) + DRUG identify the group.
#   * Each subject gets a leading dosing-event row (EVID=1, ATPTN=0, AVAL=".") above
#     its observations (EVID=0); single-dose, so no DOSNO column.
#   * AVAL/BLQ are character so the dosing row can carry "." (missing). The NCA reader
#     drops non-numeric AVAL rows automatically, so these dosing rows are NCA-safe.
# route_format: "string" (iv_bolus/extravascular) or "numeric" (1/2/3).
.library_write_benchmark_csv <- function(master_df, output_dir, output_file, append,
                                         route_format = "string") {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  route_col <- if (identical(route_format, "numeric")) .library_route_code(master_df$route)
               else as.character(master_df$route)

  blq_obs <- if (!is.null(master_df$blq)) as.integer(master_df$blq) else 0L
  obs <- data.frame(
    USUBJID   = as.integer(master_df$usubjid),
    REFERENCE = master_df$reference,
    DRUG      = master_df$drug,
    EVID      = 0L,
    ATPTN     = round(master_df$time, 6),
    AVAL      = as.character(round(master_df$concentration, 6)),
    AVALU     = master_df$avalu,
    DOSE      = master_df$dose,
    DOSEU     = master_df$doseu,
    ROUTE     = route_col,
    BLQ       = as.character(blq_obs),
    stringsAsFactors = FALSE
  )

  # One dosing-event row per subject (per REFERENCE + USUBJID), taken from the first
  # observation row of each subject so DOSE/ROUTE/units match.
  key   <- paste(obs$REFERENCE, obs$USUBJID, sep = "\r")
  first <- obs[!duplicated(key), , drop = FALSE]
  dose_rows <- data.frame(
    USUBJID   = first$USUBJID,
    REFERENCE = first$REFERENCE,
    DRUG      = first$DRUG,
    EVID      = 1L,
    ATPTN     = 0,
    AVAL      = ".",
    AVALU     = first$AVALU,
    DOSE      = first$DOSE,
    DOSEU     = first$DOSEU,
    ROUTE     = first$ROUTE,
    BLQ       = ".",
    stringsAsFactors = FALSE
  )

  adpc <- rbind(dose_rows, obs)

  fname <- if (nzchar(trimws(output_file))) trimws(output_file)
           else sprintf("LIBRARY_BENCHMARK_%s.csv", format(Sys.time(), "%Y%m%d_%H%M%S"))
  path  <- file.path(output_dir, fname)

  if (isTRUE(append) && file.exists(path)) {
    old <- tryCatch(utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character"),
                    error = function(e) NULL)
    if (!is.null(old) && all(names(adpc) %in% names(old))) {
      old <- old[, names(adpc)]
      old$USUBJID <- as.integer(old$USUBJID); old$EVID <- as.integer(old$EVID)
      old$ATPTN <- as.numeric(old$ATPTN);     old$DOSE <- as.numeric(old$DOSE)
      adpc <- rbind(old, adpc)
      adpc <- adpc[!duplicated(adpc[, c("REFERENCE", "USUBJID", "EVID", "ATPTN")],
                               fromLast = TRUE), ]
    }
  }
  # Sort so each subject's dosing row (EVID=1) leads its observations (EVID=0).
  adpc <- adpc[order(adpc$DRUG, adpc$REFERENCE, adpc$USUBJID, adpc$ATPTN, -adpc$EVID), ]
  utils::write.csv(adpc, path, row.names = FALSE)
  fname
}

# ---------------------------------------------------------------------------
# Mode: list
# ---------------------------------------------------------------------------

library_list_mode <- function(category_filter = "") {
  catalog  <- get_nlmixr2lib_catalog()
  filtered <- filter_pk_models(catalog)
  inc      <- filtered[filtered$included, , drop = FALSE]

  cf <- trimws(category_filter)
  if (nzchar(cf)) {
    inc <- inc[!is.na(inc$pk_category) &
                 grepl(cf, inc$pk_category, ignore.case = TRUE), , drop = FALSE]
  }

  models <- lapply(seq_len(nrow(inc)), function(i) {
    r    <- inc[i, ]
    desc <- if ("description" %in% names(r)) as.character(r$description) else NA_character_
    if (!is.na(desc) && nchar(desc) > 240) desc <- paste0(substr(desc, 1, 237), "...")
    flags <- if (nzchar(r$flags)) as.list(strsplit(r$flags, ",")[[1]]) else list()
    item <- list(
      name        = r$name,
      category    = r$pk_category,
      flags       = flags,
      description = desc
    )
    if (!is.na(r$route)) item$route <- r$route
    if (!is.na(r$n_cmt)) item$n_compartments <- as.integer(r$n_cmt)
    item
  })

  excl <- filtered[!filtered$included, , drop = FALSE]
  list(
    mode             = "list",
    source           = "nlmixr2lib",
    pinned_commit    = .library_pinned_commit(),
    n_models         = length(models),
    models           = models,
    excluded_count   = nrow(excl),
    excluded_reasons = as.list(table(excl$exclude_reason))
  )
}

# ---------------------------------------------------------------------------
# Mode: simulate
# ---------------------------------------------------------------------------

library_simulate_mode <- function(model_name, dose, n_subjects, seed, conc_unit,
                                  dose_unit, time_unit, covariates, route_override,
                                  times_override, save_csv, figure_dir, output_dir,
                                  residual = TRUE) {
  validate_string_input(model_name, "model_name")
  model_name <- trimws(model_name)

  doses <- as.numeric(strsplit(trimws(dose), ",")[[1]])
  if (length(doses) == 0 || any(is.na(doses)) || any(doses <= 0)) {
    stop("dose must be positive numeric value(s), comma-separated for multiple groups")
  }
  n_subj <- suppressWarnings(as.integer(trimws(n_subjects)))
  if (is.na(n_subj) || n_subj < 1) stop("n_subjects must be a positive integer")
  if (n_subj > MAX_SUBJECTS) stop(sprintf("n_subjects (%d) exceeds maximum (%d)", n_subj, MAX_SUBJECTS))
  seed_val <- suppressWarnings(as.integer(trimws(seed)))
  if (is.na(seed_val)) seed_val <- 42L

  user_cov <- .library_parse_covariates(covariates)

  ui       <- load_library_model(model_name)
  route    <- if (nzchar(trimws(route_override))) trimws(route_override) else detect_route(ui)
  conc_var <- detect_conc_output(ui)
  n_cmt    <- count_disposition_cmt(ui)
  cov      <- resolve_covariates(ui, user_cov)

  # Terminal half-life + typical parameters from a typical-value probe.
  nu   <- extract_model_units(model_name)
  tfac <- time_to_hours_factor(nu$time)
  hl <- probe_model(ui, route, conc_var, cov$values)
  if (!is.finite(hl$t_half_h)) {
    stop(sprintf("Could not estimate a log-linear terminal half-life for '%s' (may be nonlinear/TMDD or out of scope). Provide times_override to simulate anyway.",
                 model_name))
  }
  t_half_h_val <- hl$t_half_h * tfac  # convert native units -> hours

  if (nzchar(trimws(times_override))) {
    times_h <- sort(unique(as.numeric(strsplit(trimws(times_override), ",")[[1]])))
    times_h <- times_h[is.finite(times_h)]
    if (length(times_h) < 3) stop("times_override must contain at least 3 valid time points")
    times    <- times_h / tfac   # native units for simulation
    window_h <- max(times_h)
  } else {
    sched    <- build_sampling_schedule(t_half_h_val, route)  # hours in, hours out
    times_h  <- sched$times
    window_h <- sched$window_h
    times    <- times_h / tfac   # native units for simulation
  }

  long_df    <- simulate_library_population(ui, doses, times, n_subj, route, conc_var,
                                            cov$values, seed_val, dose_unit,
                                            residual = residual)
  used_omega <- isTRUE(attr(long_df, "used_omega"))
  resid_err  <- attr(long_df, "residual_error") %||% list(prop = 0, add = 0, type = "none")

  maxc <- suppressWarnings(max(long_df$concentration, na.rm = TRUE))
  if (!is.finite(maxc) || maxc <= 0) {
    stop(sprintf("Simulated concentrations are all ~0 (max=%g); check dose/units/model.", maxc))
  }

  dose_labels <- unique(long_df$dose_label)
  p <- tryCatch(create_population_pk_plot(long_df, dose_labels, model_name,
                                          time_unit, conc_unit, TRUE),
                error = function(e) NULL)
  plot_path <- if (!is.null(p)) tryCatch(save_pmx_plot(p, "LIBRARY", outdir = figure_dir),
                                         error = function(e) NULL) else NULL

  csv_file <- if (tolower(trimws(save_csv)) == "true") {
    .library_write_adpc(long_df, model_name, conc_unit, dose_unit, route, output_dir)
  } else NULL

  cov_applied <- if (is.null(cov$values)) list() else as.list(round(cov$values, 4))

  list(
    mode = "simulate",
    model_info = list(
      model_name         = model_name,
      n_compartments     = n_cmt,
      route              = route,
      conc_output_var    = conc_var,
      terminal_half_life = list(value = round(t_half_h_val, 3), unit = "h", method = hl$method),
      tier               = assign_tier(t_half_h_val),
      n_timepoints       = length(times_h)
    ),
    simulation_settings = list(
      doses                = doses,
      dose_unit            = dose_unit,
      n_subjects           = n_subj,
      sampling_times_h     = times_h,
      observation_window_h = round(window_h, 2),
      bsv_source           = if (used_omega) "model omega (literature)" else "none (model has no IIV)",
      residual_error       = if (!isTRUE(residual)) "none (disabled)" else resid_err$type,
      covariates_applied   = cov_applied,
      covariates_defaulted = as.list(cov$defaulted),
      seed                 = seed_val
    ),
    parameters    = hl$params,
    summary_stats = .library_summary_stats(long_df),
    units         = list(time = "h", concentration = conc_unit),
    output_files  = list(csv = csv_file, plot = plot_path)
  )
}

# ---------------------------------------------------------------------------
# Mode: benchmark (multi-model -> one combined ADPC CSV with a DRUG column)
# ---------------------------------------------------------------------------

library_benchmark_mode <- function(models, dose, n_subjects, seed, conc_unit, dose_unit,
                                   output_profile, mean_type, covariates, route_override,
                                   times_override, output_file, append, save_csv, output_dir,
                                   route_format = "string", scope = "standard",
                                   dose_ref_file = "", residual = TRUE) {
  route_format <- tolower(trimws(route_format)); if (!nzchar(route_format)) route_format <- "string"
  if (!route_format %in% c("string", "numeric")) {
    stop("route_format must be 'string' or 'numeric'")
  }
  scope <- tolower(trimws(scope)); if (!nzchar(scope)) scope <- "standard"
  if (!scope %in% c("standard", "wide")) stop("scope must be 'standard' or 'wide'")
  wide <- scope == "wide"
  doses <- as.numeric(strsplit(trimws(dose), ",")[[1]])
  if (length(doses) == 0 || any(is.na(doses)) || any(doses <= 0)) {
    stop("dose must be positive numeric value(s), comma-separated for multiple groups")
  }
  n_subj <- suppressWarnings(as.integer(trimws(n_subjects)))
  if (is.na(n_subj) || n_subj < 1) stop("n_subjects must be a positive integer")
  if (n_subj > MAX_SUBJECTS) stop(sprintf("n_subjects (%d) exceeds maximum (%d)", n_subj, MAX_SUBJECTS))
  base_seed <- suppressWarnings(as.integer(trimws(seed)))
  if (is.na(base_seed)) base_seed <- 42L
  user_cov <- .library_parse_covariates(covariates)

  # Optional corrections override: dose_ref_file (MODEL_REF, DOSE_MG) takes
  # priority over auto-extraction for any model listed in it. By default doses
  # are extracted live from each model's dose_range field via
  # parse_dose_from_model_text(); the scalar `doses` is the final fallback.
  dose_map <- NULL
  dr_file  <- trimws(dose_ref_file)
  if (nzchar(dr_file)) {
    dr_path <- file.path(output_dir, dr_file)
    if (!file.exists(dr_path)) {
      warning(sprintf("dose_ref_file '%s' not found in %s — ignoring corrections file", dr_file, output_dir))
    } else {
      dr <- read.csv(dr_path, stringsAsFactors = FALSE)
      if (!all(c("MODEL_REF", "DOSE_MG") %in% colnames(dr))) {
        warning("dose_ref_file must have MODEL_REF and DOSE_MG columns — ignoring corrections file")
      } else {
        dose_map <- stats::setNames(as.numeric(dr$DOSE_MG), dr$MODEL_REF)
        message(sprintf("Loaded dose corrections for %d models from %s", sum(!is.na(dose_map)), dr_file))
      }
    }
  }

  output_profile <- tolower(trimws(output_profile)); if (!nzchar(output_profile)) output_profile <- "mean"
  if (!output_profile %in% c("mean", "individual", "both")) {
    stop("output_profile must be one of: mean, individual, both")
  }
  mean_type <- tolower(trimws(mean_type)); if (!nzchar(mean_type)) mean_type <- "geometric"
  if (!mean_type %in% c("geometric", "arithmetic", "typical")) {
    stop("mean_type must be one of: geometric, arithmetic, typical")
  }

  # Resolve the model list and a stable per-model index for deterministic seeding.
  catalog       <- get_nlmixr2lib_catalog()
  model_base_dir <- system.file("modeldb", package = "nlmixr2lib")
  m_arg   <- tolower(trimws(models))
  if (m_arg %in% c("", "all", "auto")) {
    sel         <- select_benchmark_models(catalog, dedup = TRUE, wide = wide)
    model_names <- sel$name
    index_of    <- stats::setNames(sel$bench_index, sel$name)
  } else {
    model_names <- trimws(strsplit(models, ",")[[1]])
    model_names <- model_names[nzchar(model_names)]
    full     <- tryCatch(select_benchmark_models(catalog, dedup = FALSE, wide = wide), error = function(e) NULL)
    index_of <- if (!is.null(full)) stats::setNames(full$bench_index, full$name) else list()
  }
  if (length(model_names) == 0) stop("No models selected for the benchmark.")

  master <- list(); manifest <- list(); failures <- list(); n_fail <- 0L

  for (mn in model_names) {
    # index_of is a named numeric vector; [[missing]] errors (unlike a list), so
    # guard membership before lookup and fall back to positional index.
    idx <- if (length(index_of) && mn %in% names(index_of)) index_of[[mn]] else NA_integer_
    if (is.null(idx) || is.na(idx)) idx <- which(model_names == mn)[1]
    seed_m <- base_seed + as.integer(idx)

    res <- tryCatch({
      # Priority: corrections file > auto-extracted from model source > scalar `doses`
      model_doses <- if (!is.null(dose_map) && mn %in% names(dose_map) && is.finite(dose_map[[mn]])) {
        c(dose_map[[mn]])
      } else {
        row <- catalog[catalog$name == mn, , drop = FALSE]
        if (nrow(row) > 0) {
          fn <- file.path(model_base_dir, as.character(row$filename[1]))
          if (file.exists(fn)) {
            txt <- paste(readLines(fn, warn = FALSE), collapse = " ")
            c(parse_dose_from_model_text(txt, default_mg = doses[1]))
          } else doses
        } else doses
      }
      core  <- .library_simulate_core(mn, model_doses, n_subj, seed_m, dose_unit,
                                      route_override, times_override, user_cov, mean_type,
                                      wide = wide, residual = residual)
      avalu <- if (!is.na(core$native_conc_unit)) core$native_conc_unit else conc_unit
      # DRUG column = drug name; REFERENCE carries the full model ref; USUBJID is a
      # per-drug subject integer.
      drug_disp <- library_drug_name(mn)
      rows  <- list()

      if (output_profile %in% c("mean", "individual", "both")) {
        if (output_profile %in% c("mean", "both")) {
          prof <- core$profile
          multi <- length(unique(prof$dose_label)) > 1
          usub  <- if (multi) as.integer(factor(prof$dose_label)) else 1L
          rows[[length(rows) + 1]] <- data.frame(
            usubjid = usub, reference = mn, drug = drug_disp, time = prof$time,
            concentration = prof$concentration, blq = 0L,
            avalu = avalu, dose = prof$dose, doseu = dose_unit, route = core$route,
            stringsAsFactors = FALSE)
        }
        if (output_profile %in% c("individual", "both")) {
          ind <- core$long_df
          blq <- if (!is.null(ind$blq)) as.integer(ind$blq) else 0L
          rows[[length(rows) + 1]] <- data.frame(
            usubjid = as.integer(factor(ind$subject_id)), reference = mn, drug = drug_disp,
            time = ind$time, concentration = ind$concentration, blq = blq,
            avalu = avalu, dose = ind$dose, doseu = dose_unit, route = core$route,
            stringsAsFactors = FALSE)
        }
      }
      mdf <- do.call(rbind, rows)
      list(mdf = mdf, manifest = list(
        name                 = mn,
        status               = "ok",
        route                = core$route,
        route_basis          = core$route_basis,
        n_compartments       = core$n_cmt,
        native_time_unit     = core$native_time_unit,
        terminal_half_life_h = round(core$t_half_h, 3),
        half_life_method     = core$half_life_method,
        t_half_macro_h       = if (is.finite(core$t_half_macro_h)) round(core$t_half_macro_h, 3) else NA_real_,
        t_half_numeric_h     = if (is.finite(core$t_half_numeric_h)) round(core$t_half_numeric_h, 3) else NA_real_,
        t_half_profile_h     = if (is.finite(core$t_half_profile_h)) round(core$t_half_profile_h, 3) else NA_real_,
        baseline_fraction    = round(core$baseline_fraction, 4),
        dose_proportionality = if (is.finite(core$dose_proportionality)) round(core$dose_proportionality, 3) else NA_real_,
        tier                 = core$tier,
        avalu                = avalu,
        n_profiles           = length(unique(mdf$usubjid)),
        n_cov_defaulted      = length(core$covariates_defaulted),
        n_cov_zeroed         = length(core$covariates_zeroed),
        bsv_source           = if (core$used_omega) "model omega (literature)" else "none",
        residual_error       = core$residual_error$type,
        dose_mg              = model_doses[1]))
    }, error = function(e) list(error = conditionMessage(e)))

    if (!is.null(res$error)) {
      n_fail <- n_fail + 1L
      failures[[length(failures) + 1]] <- list(name = mn, error = res$error)
      manifest[[length(manifest) + 1]] <- list(name = mn, status = "failed", error = res$error)
    } else {
      master[[length(master) + 1]]     <- res$mdf
      manifest[[length(manifest) + 1]] <- res$manifest
    }
  }

  if (length(master) == 0) {
    stop(sprintf("All %d requested model(s) failed; first error: %s",
                 length(model_names),
                 if (length(failures)) failures[[1]]$error else "unknown"))
  }
  master_df <- do.call(rbind, master)

  csv_file <- if (tolower(trimws(save_csv)) == "true") {
    .library_write_benchmark_csv(master_df, output_dir, output_file,
                                 tolower(trimws(append)) == "true", route_format)
  } else NULL

  list(
    mode          = "benchmark",
    source        = "nlmixr2lib",
    pinned_commit = .library_pinned_commit(),
    settings = list(
      scope            = scope,
      models_requested = length(model_names),
      output_profile   = output_profile,
      mean_type        = mean_type,
      n_subjects       = n_subj,
      doses            = doses,
      dose_unit        = dose_unit,
      seed             = base_seed,
      route_format     = route_format,
      residual         = isTRUE(residual),
      append           = tolower(trimws(append)) == "true"
    ),
    n_models_included = length(master),
    n_failed          = n_fail,
    n_drugs           = length(unique(master_df$drug)),
    n_rows            = nrow(master_df),
    output_files      = list(csv = csv_file),
    failures          = failures,
    manifest          = manifest
  )
}

# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------

#* Simulate PK concentration-time profiles from the nlmixr2lib literature model
#* library, list available models, or build a multi-drug NCA benchmark dataset.
#* Simulate/benchmark modes write ADPC-compatible CSV(s) usable directly by /NCA
#* via data_file; benchmark mode emits ONE combined CSV with a DRUG grouping column.
#* @param mode "list" (catalog), "simulate" (one model), or "benchmark" (many models -> one CSV). Default "list"
#* @param model_name Model name from the library (required for simulate; use mode=list to discover)
#* @param models Benchmark model set: "all"/"auto" (clean deduplicated set) or comma-separated names (default "all")
#* @param scope Benchmark scope: "standard" (linear 1-2CM, default) or "wide" (includes nonlinear, TMDD, 3-compartment)
#* @param dose Dose amount(s) in mg, comma-separated for multiple dose groups (default "100")
#* @param n_subjects Number of subjects in the population simulation (default "20")
#* @param seed Random seed for reproducibility (default "42")
#* @param conc_unit Concentration unit label fallback for output/plot/AVALU when the model's native unit is unknown (default "ug/mL")
#* @param dose_unit Dose unit label for DOSEU (default "mg")
#* @param time_unit Plot display time unit: auto/hours/days/weeks (default "auto")
#* @param output_profile Benchmark: "mean" (one profile/drug), "individual", or "both" (default "mean")
#* @param mean_type Benchmark mean profile: "geometric", "arithmetic", or "typical" eta=0 (default "geometric")
#* @param output_file Benchmark: fixed output CSV filename in output_dir (default "" -> timestamped)
#* @param append Benchmark: append/merge into an existing output_file: "true" or "false" (default "false")
#* @param route_format Benchmark ROUTE column encoding: "string" (iv_bolus/extravascular) or "numeric" (1/2/3 for PKanalix) (default "string")
#* @param covariates Optional covariate overrides, e.g. "WT=70,CRCL=90" (default "")
#* @param route_override Optional route override: iv_bolus, iv_infusion, extravascular (default "")
#* @param times_override Optional comma-separated custom sampling times in hours (default "")
#* @param category_filter Optional list-mode filter on model category (default "")
#* @param dose_ref_file Benchmark: filename (in output_dir) of a CSV with MODEL_REF,DOSE_MG columns for per-model doses; models absent from the file use the scalar `dose` (default "")
#* @param save_csv Save the ADPC CSV to output_dir: "true" or "false" (default "true")
#* @param residual Add within-subject residual error from the model's own error model (default to a 20% proportional CV when a model defines none): "true" or "false" (default "true")
#* @param figure_dir Output directory for the figure (default "/figures")
#* @param output_dir Output directory for the CSV (default "/data")
#* @post /LIBRARY
#* @serializer unboxedJSON
function(mode = "list", model_name = "", models = "all", dose = "100", n_subjects = "20",
         seed = "42", conc_unit = "ug/mL", dose_unit = "mg", time_unit = "auto",
         output_profile = "mean", mean_type = "geometric", output_file = "", append = "false",
         route_format = "string", scope = "standard", covariates = "", route_override = "",
         times_override = "", category_filter = "", dose_ref_file = "", save_csv = "true",
         residual = "true", figure_dir = "/figures", output_dir = "/data") {
  tryCatch({
    mode <- tolower(trimws(mode))
    if (!mode %in% c("list", "simulate", "benchmark")) {
      stop(sprintf("Invalid mode '%s'. Valid options: list, simulate, benchmark", mode))
    }
    residual_on <- !(tolower(trimws(residual)) %in% c("false", "0", "no"))
    if (mode == "list") {
      return(library_list_mode(category_filter))
    }
    if (mode == "benchmark") {
      return(library_benchmark_mode(models, dose, n_subjects, seed, conc_unit, dose_unit,
                                    output_profile, mean_type, covariates, route_override,
                                    times_override, output_file, append, save_csv, output_dir,
                                    route_format, scope, dose_ref_file, residual_on))
    }
    library_simulate_mode(model_name, dose, n_subjects, seed, conc_unit, dose_unit,
                          time_unit, covariates, route_override, times_override,
                          save_csv, figure_dir, output_dir, residual_on)
  }, error = function(e) {
    stop(sprintf("LIBRARY failed: %s", conditionMessage(e)))
  })
}
