# models/er_models.R
# Exposure-Response model fitting functions

#' Calculate quantile statistics for E-R visualization
#' Following Overgaard et al. (2015) good practices
#' @param exposure Vector of exposure values (AUC)
#' @param resp Vector of response values
#' @param n_quantiles Number of quantiles (default 4)
#' @return Data frame with quantile stats
calculate_quantile_stats <- function(exposure, resp, n_quantiles = 4) {
  df <- data.frame(exposure = exposure, resp = resp)

  # Create quantile bins based on exposure
  breaks <- quantile(exposure, probs = seq(0, 1, length.out = n_quantiles + 1))
  # Handle edge case where some quantiles may be identical
  breaks <- unique(breaks)
  if (length(breaks) < 2) {
    breaks <- c(min(exposure), max(exposure))
  }

  df$quantile <- cut(exposure, breaks = breaks, include.lowest = TRUE, labels = FALSE)

  # Calculate statistics for each quantile
  result <- do.call(rbind, lapply(sort(unique(df$quantile)), function(q) {
    subset_df <- df[df$quantile == q, ]
    n <- nrow(subset_df)
    resp_mean <- mean(subset_df$resp)
    resp_sd <- sd(subset_df$resp)
    resp_se <- if (n > 1) resp_sd / sqrt(n) else 0

    data.frame(
      quantile = q,
      n = n,
      exposure_median = median(subset_df$exposure),
      resp_mean = resp_mean,
      resp_se = resp_se,
      resp_ci_lower = resp_mean - 1.96 * resp_se,
      resp_ci_upper = resp_mean + 1.96 * resp_se
    )
  }))

  return(result)
}

#' Calculate dose group exposure statistics
#' @param exposure Vector of exposure values (AUC)
#' @param dose Vector of dose labels
#' @return Data frame with dose group stats
calculate_dose_stats <- function(exposure, dose) {
  df <- data.frame(exposure = exposure, dose = dose, stringsAsFactors = FALSE)

  # Get unique doses in order of appearance
  unique_doses <- unique(dose)

  result <- do.call(rbind, lapply(unique_doses, function(d) {
    subset_exp <- df$exposure[df$dose == d]
    data.frame(
      dose = d,
      n = length(subset_exp),
      exposure_mean = mean(subset_exp),
      exposure_min = min(subset_exp),
      exposure_max = max(subset_exp),
      stringsAsFactors = FALSE
    )
  }))

  return(result)
}

#' Fit linear model to concentration-response data
#' @param conc Concentration vector
#' @param resp Response vector
#' @return List with model object, AIC, R2, and parameters
fit_linear_model <- function(conc, resp) {
  fit <- lm(resp ~ conc)
  list(
    model = fit,
    AIC = AIC(fit),
    R2 = summary(fit)$r.squared,
    params = as.list(coef(fit)),
    success = TRUE
  )
}

#' Fit Emax model to concentration-response data
#' @param conc Concentration vector
#' @param resp Response vector
#' @return List with model object, AIC, R2, and parameters, or success=FALSE
fit_emax_model <- function(conc, resp) {
  # Calculate bounds
  cs_nonzero <- conc[conc > 0]
  ic50_lower <- min(cs_nonzero) * ER_IC50_LOWER_MULTIPLIER
  ic50_upper <- max(conc) * ER_IC50_UPPER_MULTIPLIER
  e0_lower <- ER_E0_LOWER_MULTIPLIER
  e0_upper <- max(resp) * ER_E0_UPPER_MULTIPLIER
  emax_lower <- ER_EMAX_LOWER_MULTIPLIER
  emax_upper <- max(resp) * ER_EMAX_UPPER_MULTIPLIER

  tryCatch({
    fit <- nls(
      resp ~ e0 + (emax * conc) / (ec50 + conc),
      start = list(e0 = min(resp), emax = max(resp) - min(resp), ec50 = median(conc)),
      algorithm = "port",
      lower = c(e0 = e0_lower, emax = emax_lower, ec50 = ic50_lower),
      upper = c(e0 = e0_upper, emax = emax_upper, ec50 = ic50_upper),
      control = nls.control(warnOnly = TRUE)
    )
    list(
      model = fit,
      AIC = AIC(fit),
      R2 = 1 - sum(resid(fit)^2) / sum((resp - mean(resp))^2),
      params = as.list(coef(fit)),
      success = TRUE
    )
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })
}

#' Fit Imax (fractional inhibition) model to concentration-response data
#' @param conc Concentration vector
#' @param resp Response vector
#' @return List with model object, AIC, R2, and parameters, or success=FALSE
fit_imax_model <- function(conc, resp) {
  # Calculate bounds
  cs_nonzero <- conc[conc > 0]
  ic50_lower <- min(cs_nonzero) * ER_IC50_LOWER_MULTIPLIER
  ic50_upper <- max(conc) * ER_IC50_UPPER_MULTIPLIER
  e0_lower <- ER_E0_LOWER_MULTIPLIER
  e0_upper <- max(resp) * ER_E0_UPPER_MULTIPLIER

  tryCatch({
    fit <- nls(
      resp ~ e0 * (1 - (imax * conc) / (ic50 + conc)),
      start = list(e0 = max(resp), imax = 0.5, ic50 = median(conc)),
      algorithm = "port",
      lower = c(e0 = e0_lower, imax = 0, ic50 = ic50_lower),
      upper = c(e0 = e0_upper, imax = 1, ic50 = ic50_upper),
      control = nls.control(warnOnly = TRUE)
    )
    list(
      model = fit,
      AIC = AIC(fit),
      R2 = 1 - sum(resid(fit)^2) / sum((resp - mean(resp))^2),
      params = as.list(coef(fit)),
      success = TRUE
    )
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })
}

#' Fit logistic (binary) model to concentration-response data
#' @param conc Concentration vector
#' @param resp Response vector (must be 0/1)
#' @return List with model object, AIC, parameters including EC50, or success=FALSE
fit_logit_model <- function(conc, resp) {
  # Check if response is binary
  if (!all(resp %in% c(0, 1))) {
    return(list(success = FALSE, error = "Logit model requires binary (0/1) response data"))
  }

  tryCatch({
    fit <- glm(resp ~ conc, family = binomial)
    coefs <- coef(fit)

    # Calculate EC50 (concentration at 50% probability)
    # logit(0.5) = 0 = intercept + slope * EC50
    # EC50 = -intercept / slope
    intercept <- coefs[["(Intercept)"]]
    slope <- coefs[["conc"]]
    ec50 <- if (slope != 0) -intercept / slope else NA

    # Calculate probability predictions for common concentrations
    conc_range <- seq(min(conc), max(conc), length.out = 100)
    prob_pred <- predict(fit, newdata = data.frame(conc = conc_range), type = "response")

    list(
      model = fit,
      AIC = AIC(fit),
      params = list(
        intercept = intercept,
        slope = slope,
        EC50 = ec50
      ),
      predictions = data.frame(
        conc = conc_range,
        probability = prob_pred
      ),
      success = TRUE
    )
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })
}

#' Check if response data is binary (0/1)
#' @param resp Response vector
#' @return TRUE if binary, FALSE otherwise
is_binary_response <- function(resp) {
  all(resp %in% c(0, 1))
}

#' Calculate predictions with confidence intervals for logit model
#' @param model Fitted glm logit model
#' @param pred_exposure Vector of exposure values for prediction
#' @return Data frame with exposure, pred (probability), lower, upper (95% CI)
calculate_logit_predictions_with_ci <- function(model, pred_exposure) {
  newdata <- data.frame(conc = pred_exposure)

  # Predict on link scale (log-odds) with standard errors
  pred_link <- predict(model, newdata = newdata, type = "link", se.fit = TRUE)

  # Calculate 95% CI on link scale
  z <- qnorm(0.975)
  link_lower <- pred_link$fit - z * pred_link$se.fit
  link_upper <- pred_link$fit + z * pred_link$se.fit

  # Transform to probability scale using inverse logit
  inv_logit <- function(x) 1 / (1 + exp(-x))

  data.frame(
    exposure = pred_exposure,
    pred = inv_logit(pred_link$fit),
    lower = inv_logit(link_lower),
    upper = inv_logit(link_upper)
  )
}

#' Calculate predictions with confidence intervals for linear model
#' @param model Fitted lm linear model
#' @param pred_exposure Vector of exposure values for prediction
#' @return Data frame with exposure, pred, lower, upper (95% CI)
calculate_linear_predictions_with_ci <- function(model, pred_exposure) {
  newdata <- data.frame(conc = pred_exposure)

  # Predict with confidence interval
  pred_result <- predict(model, newdata = newdata, interval = "confidence", level = 0.95)

  data.frame(
    exposure = pred_exposure,
    pred = pred_result[, "fit"],
    lower = pred_result[, "lwr"],
    upper = pred_result[, "upr"]
  )
}
