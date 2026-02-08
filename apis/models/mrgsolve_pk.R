# models/mrgsolve_pk.R
# mrgsolve-based PK compartment models

# Global model cache (populated at startup)
.pk_models <- NULL

#' Initialize mrgsolve PK models
#' Called once at API startup to pre-compile models
initialize_pk_models <- function() {
  if (!is.null(.pk_models)) return(.pk_models)

  build_dir <- "/tmp/mrgsolve_build"
  if (!dir.exists(build_dir)) {
    dir.create(build_dir, recursive = TRUE)
  }

  # Use absolute path to models directory
  models_dir <- "/home/rstudio/apis/models/"

  .pk_models <<- list(
    cm1 = mread_cache("1CM", project = models_dir, soloc = build_dir, quiet = TRUE),
    cm2 = mread_cache("2CM", project = models_dir, soloc = build_dir, quiet = TRUE)
  )

  return(.pk_models)
}

#' Simulate one-compartment IV bolus PK profile
#' @param dose Dose amount
#' @param CL Clearance
#' @param V1 Volume of distribution
#' @param times Vector of time points
#' @return Vector of concentrations
simulate_1cm <- function(dose, CL, V1, times) {
  mod <- .pk_models$cm1

  # Set parameters (BW=1 makes TVVC/TVCL = absolute V1/CL)
  mod <- param(mod, BW = 1, TVVC = V1, TVCL = CL)

  # Create dosing event (IV bolus to central compartment)
  dosing <- ev(amt = dose, time = 0, cmt = 1)

  # Handle time=0 specially: shift to small epsilon to get post-dose concentration
  sim_times <- ifelse(times == 0, 1e-6, times)

  # Run simulation at specified time points only (end=-1 disables default grid)
  result <- mod %>%
    ev(dosing) %>%
    mrgsim(end = -1, add = sim_times, output = "df")

  # Map results back to requested times
  result <- result[!duplicated(result$time), ]
  idx <- match(sim_times, result$time)
  return(result$CP[idx])
}

#' Simulate two-compartment IV bolus PK profile
#' @param dose Dose amount
#' @param CL Clearance
#' @param V1 Central volume
#' @param V2 Peripheral volume
#' @param Q Intercompartmental clearance
#' @param times Vector of time points
#' @return Vector of concentrations
simulate_2cm <- function(dose, CL, V1, V2, Q, times) {
  mod <- .pk_models$cm2

  # Set parameters (BW=1 makes typical values = absolute values)
  mod <- param(mod, BW = 1, TVVC = V1, TVVP = V2, TVCL = CL, TVQ = Q)

  # Create dosing event
  dosing <- ev(amt = dose, time = 0, cmt = 1)

  # Handle time=0 specially: shift to small epsilon to get post-dose concentration
  sim_times <- ifelse(times == 0, 1e-6, times)

  # Run simulation at specified time points only (end=-1 disables default grid)
  result <- mod %>%
    ev(dosing) %>%
    mrgsim(end = -1, add = sim_times, output = "df")

  # Map results back to requested times
  result <- result[!duplicated(result$time), ]
  idx <- match(sim_times, result$time)
  return(result$CP[idx])
}

#' Simulate population one-compartment PK using mrgsolve OMEGA
#' @param n_subjects Number of subjects to simulate
#' @param doses Vector of doses (single value or one per subject)
#' @param TVCL Typical clearance per kg (mL/h/kg)
#' @param TVV1 Typical central volume per kg (mL/kg)
#' @param BW Body weight in kg
#' @param cv Coefficient of variation for BSV (default 0.25 = 25%)
#' @param times Vector of time points
#' @param seed Random seed for reproducibility (optional)
#' @return Data frame with ID, time, CP, and individual parameters
simulate_population_1cm <- function(n_subjects, doses, TVCL, TVV1, BW, cv = 0.25, times, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Calculate omega^2 from CV for lognormal OMEGA matrix
  omega_sq <- log(1 + cv^2)

  # Handle dose assignment
  if (length(doses) == 1) {
    doses <- rep(doses, n_subjects)
  } else if (length(doses) != n_subjects) {
    stop("doses must be length 1 or n_subjects")
  }

  # Create individual data with IDs
  idata <- data.frame(
    ID = 1:n_subjects,
    dose = doses
  )

  # Set typical values and OMEGA matrix
  mod <- .pk_models$cm1 %>%
    param(BW = BW, TVCL = TVCL, TVVC = TVV1) %>%
    omat(dmat(omega_sq, omega_sq))  # diagonal omega for nVC, nCL

  # Handle time=0: shift to small epsilon
  sim_times <- ifelse(times == 0, 1e-6, times)

  # Simulate population - one subject at a time to handle different doses
  all_results <- list()
  for (i in 1:n_subjects) {
    dosing <- ev(amt = idata$dose[i], time = 0, cmt = 1)
    result <- mod %>%
      ev(dosing) %>%
      mrgsim(end = -1, add = sim_times, output = "df")
    result$ID <- i
    result$dose <- idata$dose[i]
    all_results[[i]] <- result
  }

  result_df <- do.call(rbind, all_results)

  # Map times back
  result_df$time <- ifelse(result_df$time < 1e-5, 0, result_df$time)

  # Remove duplicate time points per subject (from epsilon handling)
  result_df <- result_df[!duplicated(result_df[, c("ID", "time")]), ]

  return(result_df)
}

#' Simulate population two-compartment PK using mrgsolve OMEGA
#' @param n_subjects Number of subjects to simulate
#' @param doses Vector of doses (single value or one per subject)
#' @param TVCL Typical clearance per kg (mL/h/kg)
#' @param TVV1 Typical central volume per kg (mL/kg)
#' @param TVV2 Typical peripheral volume per kg (mL/kg)
#' @param TVQ Typical intercompartmental clearance per kg (mL/h/kg)
#' @param BW Body weight in kg
#' @param cv Coefficient of variation for BSV (default 0.25 = 25%)
#' @param times Vector of time points
#' @param seed Random seed for reproducibility (optional)
#' @return Data frame with ID, time, CP, and individual parameters
simulate_population_2cm <- function(n_subjects, doses, TVCL, TVV1, TVV2, TVQ, BW, cv = 0.25, times, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Calculate omega^2 from CV for lognormal OMEGA matrix
  omega_sq <- log(1 + cv^2)

  # Handle dose assignment
  if (length(doses) == 1) {
    doses <- rep(doses, n_subjects)
  } else if (length(doses) != n_subjects) {
    stop("doses must be length 1 or n_subjects")
  }

  # Create individual data with IDs
  idata <- data.frame(
    ID = 1:n_subjects,
    dose = doses
  )

  # Set typical values and OMEGA matrix (diagonal for nVC, nVP, nCL, nQ)
  mod <- .pk_models$cm2 %>%
    param(BW = BW, TVCL = TVCL, TVVC = TVV1, TVVP = TVV2, TVQ = TVQ) %>%
    omat(dmat(omega_sq, omega_sq, omega_sq, omega_sq))

  # Handle time=0: shift to small epsilon
  sim_times <- ifelse(times == 0, 1e-6, times)

  # Simulate population - one subject at a time to handle different doses
  all_results <- list()
  for (i in 1:n_subjects) {
    dosing <- ev(amt = idata$dose[i], time = 0, cmt = 1)
    result <- mod %>%
      ev(dosing) %>%
      mrgsim(end = -1, add = sim_times, output = "df")
    result$ID <- i
    result$dose <- idata$dose[i]
    all_results[[i]] <- result
  }

  result_df <- do.call(rbind, all_results)

  # Map times back
  result_df$time <- ifelse(result_df$time < 1e-5, 0, result_df$time)

  # Remove duplicate time points per subject (from epsilon handling)
  result_df <- result_df[!duplicated(result_df[, c("ID", "time")]), ]

  return(result_df)
}
