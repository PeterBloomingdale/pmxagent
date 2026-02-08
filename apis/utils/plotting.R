# utils/plotting.R
# Shared plotting utilities for PMxAgent R API

# ============================================
# Time Unit Conversion Helpers
# ============================================

#' Auto-select time unit based on max time value (in hours)
#' @param times Vector of time values in hours
#' @return Time unit string: "hours", "days", or "weeks"
auto_select_time_unit <- function(times) {
  max_time <- max(times, na.rm = TRUE)
  if (max_time > 168) return("weeks")      # > 1 week
  if (max_time > 24) return("days")        # > 1 day
  return("hours")
}

#' Convert times for display (internal hours -> display unit)
#' @param times Vector of time values in hours
#' @param to_unit Target unit: "hours", "days", or "weeks"
#' @return Converted time vector
convert_time_for_display <- function(times, to_unit = "hours") {
  conversion <- switch(to_unit,
    "hours" = 1,
    "days" = 1/24,
    "weeks" = 1/168,
    1
  )
  times * conversion
}

#' Get formatted time axis label
#' @param unit Time unit string
#' @return Formatted axis label
get_time_label <- function(unit) {
  switch(unit,
    "hours" = "Time (hours)",
    "days" = "Time (days)",
    "weeks" = "Time (weeks)",
    "Time"
  )
}

#' Get formatted concentration axis label
#' @param unit Concentration unit string (default: "ug/mL")
#' @return Formatted axis label
get_conc_label <- function(unit = "ug/mL") {
  paste0("Concentration (", unit, ")")
}

#' Get concentration conversion factor from model output (mg/mL) to display unit
#' Model outputs: dose (mg) / volume (mL) = mg/mL
#' @param unit Target concentration unit string
#' @return Conversion factor (multiply model output by this)
get_conc_conversion_factor <- function(unit = "ug/mL") {
  # Model outputs concentration in mg/mL (dose in mg, volume in mL)
  # Convert to target unit
  switch(tolower(unit),
    "ug/ml" = 1000,       # mg -> ug: multiply by 1000
    "ng/ml" = 1e6,        # mg -> ng: multiply by 1,000,000
    "mg/ml" = 1,          # no conversion
    "mg/l"  = 1000,       # 1 mg/mL = 1000 mg/L (1 mL = 0.001 L)
    "g/l"   = 1,          # 1 mg/mL = 0.001 g/mL = 1 g/L
    "g/ml"  = 0.001,      # mg -> g: divide by 1000
    1000                  # default to ug/mL conversion
  )
}

#' Get formatted AUC/exposure axis label
#' @param unit AUC unit string (default: "h*ug/mL")
#' @return Formatted axis label
get_auc_label <- function(unit = "h*ug/mL") {
  paste0("Exposure (", unit, ")")
}

# ============================================
# Theme and Plot Functions
# ============================================

#' Generate standard ggplot theme for PMxAgent
#' @return ggplot2 theme object
get_pmx_theme <- function() {
  theme_minimal(base_size = 12) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold", size = 14),
      axis.title = ggplot2::element_text(face = "bold")
    )
}

#' Create E-R plot with quantile visualization and optional dose bars (legacy)
#' Following Overgaard et al. (2015) good practices
#' Uses black fitted line, gray data points, and Pastel1 dose bars
#' @param obs_df Data frame with exposure and resp columns (observed data)
#' @param quantile_stats Data frame from calculate_quantile_stats()
#' @param pred_df Data frame with exposure and resp columns (model predictions)
#' @param dose_stats Data frame from calculate_dose_stats() (optional)
#' @param model_name Name of the fitted model for title
#' @param auc_unit AUC unit label for x-axis (default: "h*ug/mL")
#' @return ggplot object
create_er_plot <- function(obs_df, quantile_stats, pred_df, dose_stats = NULL,
                           model_name, auc_unit = "h*ug/mL") {

  # Calculate y-axis range for positioning dose bars
  y_min <- min(obs_df$resp, na.rm = TRUE)
  y_max <- max(obs_df$resp, na.rm = TRUE)
  y_range <- y_max - y_min

  # Base plot with individual points, quantile summaries, and model line
  p <- ggplot2::ggplot() +
    # Individual observed data points (gray, semi-transparent)
    ggplot2::geom_point(data = obs_df, ggplot2::aes(x = exposure, y = resp),
               size = 2, alpha = 0.5, color = ER_POINT_COLOR) +
    # Fitted model line (black)
    ggplot2::geom_line(data = pred_df, ggplot2::aes(x = exposure, y = resp),
              color = ER_LINE_COLOR, linewidth = 1.2) +
    # Quantile error bars (95% CI)
    ggplot2::geom_errorbar(data = quantile_stats,
                  ggplot2::aes(x = exposure_median, ymin = resp_ci_lower, ymax = resp_ci_upper),
                  width = 0, color = ER_LINE_COLOR, linewidth = 0.8) +
    # Quantile mean points (diamond)
    ggplot2::geom_point(data = quantile_stats, ggplot2::aes(x = exposure_median, y = resp_mean),
               shape = 18, size = 4, color = ER_LINE_COLOR) +
    ggplot2::labs(x = get_auc_label(auc_unit), y = "Response",
         title = paste("Exposure-Response Analysis -", model_name)) +
    get_pmx_theme()

  # Add dose group bars if provided
  if (!is.null(dose_stats) && nrow(dose_stats) > 0) {
    # Calculate y positions for dose bars (below main data) - lowered positioning
    n_doses <- nrow(dose_stats)
    y_base <- y_min - y_range * 0.25  # Lowered from 0.15 to 0.25
    dose_stats$y <- y_base - (seq_len(n_doses) - 1) * y_range * 0.10  # Increased spacing
    dose_stats$y_label <- dose_stats$y - y_range * 0.04

    # Use Pastel1 colors for dose bars
    dose_stats$color <- get_pastel1_scale(n_doses)

    # Add dose bar layers using data-driven approach (avoids lazy evaluation issues)
    p <- p +
      # Dose range lines (Pastel1 colors)
      ggplot2::geom_segment(
        data = dose_stats,
        ggplot2::aes(x = exposure_min, xend = exposure_max, y = y, yend = y, color = dose),
        linewidth = 4, lineend = "round", show.legend = FALSE
      ) +
      # Dose mean points (black diamond)
      ggplot2::geom_point(
        data = dose_stats,
        ggplot2::aes(x = exposure_mean, y = y),
        shape = 18, size = 3, color = "black"
      ) +
      # Dose labels
      ggplot2::geom_text(
        data = dose_stats,
        ggplot2::aes(x = exposure_mean, y = y_label, label = dose),
        size = 3, color = "black"
      ) +
      # Manual color scale for dose bars (Pastel1)
      ggplot2::scale_color_manual(values = setNames(dose_stats$color, dose_stats$dose))

    # Expand y-axis to accommodate dose bars
    y_lower <- min(dose_stats$y_label) - y_range * 0.05
    y_upper <- y_max + y_range * 0.05
    p <- p + ggplot2::coord_cartesian(ylim = c(y_lower, y_upper), clip = "off")
  }

  return(p)
}

#' Create gold standard E-R plot with two panels
#' Top: Scatter plot with model fit and confidence band
#' Bottom: Horizontal boxplots by dose group
#' Following Finch Studio visualization standards
#' @param obs_df Data frame with exposure, resp, and optionally dose columns
#' @param pred_df Data frame with exposure, pred, lower, upper columns (predictions with CI)
#' @param quantile_stats Data frame from calculate_quantile_stats()
#' @param model_name Name of the fitted model
#' @param auc_unit AUC unit label for x-axis (default: "h*ug/mL")
#' @param is_binary Whether response is binary (0/1) for jittering
#' @return Combined ggplot object (patchwork)
create_er_plot_gold_standard <- function(obs_df, pred_df, quantile_stats,
                                          model_name, auc_unit = "h*ug/mL",
                                          is_binary = FALSE) {
  library(patchwork)

  # Determine if dose data is available
  has_dose <- "dose" %in% names(obs_df) && !all(is.na(obs_df$dose))

  # Get unique doses and colors if available
  if (has_dose) {
    unique_doses <- unique(obs_df$dose)
    dose_colors <- get_dose_colors_vector(unique_doses)
    # Factor dose to preserve order
    obs_df$dose <- factor(obs_df$dose, levels = unique_doses)
  }

  # Calculate common x-axis limits (slight padding on left for aesthetics)
  x_range <- range(obs_df$exposure, na.rm = TRUE)
  x_limits <- c(-max(x_range) * 0.02, max(x_range) * 1.05)

  # Set y-axis label based on binary vs continuous
  y_label <- if (is_binary) "Probability of Response" else "Response"

  # ============================================
  # TOP PANEL: Scatter plot with model fit
  # ============================================

  # Start with quantile summary data as base (for consistent aes mapping)
  p_scatter <- ggplot2::ggplot(quantile_stats, ggplot2::aes(x = exposure_median, y = resp_mean))

  # Add individual points with jitter (colored by dose if available)
  if (has_dose) {
    p_scatter <- p_scatter +
      ggplot2::geom_jitter(data = obs_df,
                           ggplot2::aes(x = exposure, y = resp, color = dose),
                           height = 0.05, alpha = 0.5, size = 2,
                           inherit.aes = FALSE) +
      ggplot2::scale_color_manual(values = dose_colors, name = "Dose")
  } else {
    p_scatter <- p_scatter +
      ggplot2::geom_jitter(data = obs_df,
                           ggplot2::aes(x = exposure, y = resp),
                           height = 0.05, alpha = 0.5, size = 2,
                           color = ER_POINT_COLOR, inherit.aes = FALSE)
  }

  # Add logistic regression curve with CI using geom_smooth
  if (is_binary) {
    p_scatter <- p_scatter +
      ggplot2::geom_smooth(data = obs_df,
                           ggplot2::aes(x = exposure, y = resp),
                           method = "glm",
                           method.args = list(family = "binomial"),
                           color = "grey10",
                           fill = "grey70",
                           alpha = 0.4,
                           inherit.aes = FALSE)
  } else {
    # For continuous data, use the pre-computed predictions
    has_ci <- all(c("lower", "upper") %in% names(pred_df)) &&
              !all(is.na(pred_df$lower)) && !all(is.na(pred_df$upper))
    if (has_ci) {
      p_scatter <- p_scatter +
        ggplot2::geom_ribbon(data = pred_df,
                             ggplot2::aes(x = exposure, ymin = lower, ymax = upper),
                             fill = "gray70", alpha = 0.4, inherit.aes = FALSE)
    }
    p_scatter <- p_scatter +
      ggplot2::geom_line(data = pred_df,
                         ggplot2::aes(x = exposure, y = pred),
                         color = "grey10", linewidth = 1, inherit.aes = FALSE)
  }

  # Add quantile summary error bars and points (black, simple style)
  p_scatter <- p_scatter +
    ggplot2::geom_errorbar(ggplot2::aes(ymin = resp_ci_lower, ymax = resp_ci_upper),
                           width = 0, linewidth = 0.5, color = "black") +
    ggplot2::geom_point(size = 2.5, color = "black")

  # Apply theme and labels to scatter plot
  p_scatter <- p_scatter +
    ggplot2::labs(y = y_label,
                  x = get_auc_label(auc_unit)) +
    ggplot2::scale_x_continuous(limits = x_limits) +
    get_pmx_theme() +
    ggplot2::theme(
      legend.position = if (has_dose) "right" else "none"
    )

  # ============================================
  # BOTTOM PANEL: Horizontal boxplots by dose
  # ============================================
  if (has_dose) {
    p_box <- ggplot2::ggplot(obs_df, ggplot2::aes(x = exposure, y = dose, fill = dose, color = dose)) +
      # Add whisker caps
      ggplot2::stat_boxplot(geom = "errorbar", width = 0.5) +
      # Boxplot without outliers
      ggplot2::geom_boxplot(outlier.colour = NA, width = 0.7, alpha = 0.5) +
      ggplot2::scale_fill_manual(values = dose_colors) +
      ggplot2::scale_color_manual(values = dose_colors) +
      ggplot2::scale_x_continuous(limits = x_limits) +
      ggplot2::labs(x = get_auc_label(auc_unit), y = "Dose Group") +
      ggplot2::guides(color = "none", fill = "none") +
      get_pmx_theme()

    # Combine panels with patchwork (2:1 height ratio)
    combined_plot <- p_scatter / p_box +
      patchwork::plot_layout(heights = c(ER_TOP_PANEL_RATIO, ER_BOTTOM_PANEL_RATIO))

  } else {
    # No dose data: return single panel
    combined_plot <- p_scatter
  }

  return(combined_plot)
}

#' Create population PK plot with Mean ± SD ribbons by dose group
#' Uses Pastel1 colors and log-scale y-axis
#' @param conc_df Data frame with columns: subject_id, dose_label, time, concentration
#' @param dose_labels Vector of unique dose labels in display order
#' @param model_name Name of the model for title
#' @param time_unit Time unit for display: "auto", "hours", "days", or "weeks" (default: "auto")
#' @param conc_unit Concentration unit label (default: "ug/mL")
#' @param conc_already_converted If TRUE, concentrations are already in target units (default: TRUE)
#' @return ggplot object
create_population_pk_plot <- function(conc_df, dose_labels, model_name,
                                      time_unit = "auto", conc_unit = "ug/mL",
                                      conc_already_converted = TRUE) {
  # Determine time unit if auto
  if (time_unit == "auto") {
    time_unit <- auto_select_time_unit(conc_df$time)
  }

  # Get conversion factor for concentration units (only if data not already converted)
  # Model outputs mg/mL (dose in mg, volume in mL), convert to display unit
  conc_factor <- if (conc_already_converted) 1 else get_conc_conversion_factor(conc_unit)

  # Calculate summary statistics by dose group and time
  summary_df <- do.call(rbind, lapply(dose_labels, function(dl) {
    subset_df <- conc_df[conc_df$dose_label == dl, ]
    do.call(rbind, lapply(unique(subset_df$time), function(tm) {
      # Apply conversion factor to concentrations (factor=1 if already converted)
      conc_at_t <- subset_df$concentration[subset_df$time == tm] * conc_factor
      data.frame(
        dose_label = dl,
        time = tm,
        mean = mean(conc_at_t, na.rm = TRUE),
        sd = sd(conc_at_t, na.rm = TRUE),
        n = length(conc_at_t),
        stringsAsFactors = FALSE
      )
    }))
  }))

  # Convert time for display
  summary_df$time_display <- convert_time_for_display(summary_df$time, time_unit)

  # Calculate CI bounds (mean ± SD)
  summary_df$lower <- pmax(summary_df$mean - summary_df$sd, 1e-10)  # Ensure positive for log scale
  summary_df$upper <- summary_df$mean + summary_df$sd

  # Get Pastel1 colors for dose groups
  dose_colors <- get_dose_colors_vector(dose_labels)

  # Factor dose_label to preserve order
  summary_df$dose_label <- factor(summary_df$dose_label, levels = dose_labels)

  # Create plot with ribbons and mean lines
  p <- ggplot2::ggplot(summary_df, ggplot2::aes(x = time_display, y = mean,
                                                color = dose_label,
                                                fill = dose_label)) +
    # SD ribbons (semi-transparent)
    ggplot2::geom_ribbon(ggplot2::aes(ymin = lower, ymax = upper),
                         alpha = 0.3, color = NA) +
    # Mean lines
    ggplot2::geom_line(linewidth = 1.2) +
    # Mean points
    ggplot2::geom_point(size = 2) +
    # Log scale y-axis
    ggplot2::scale_y_log10() +
    # Pastel1 colors
    ggplot2::scale_color_manual(values = dose_colors, name = "Dose") +
    ggplot2::scale_fill_manual(values = dose_colors, name = "Dose") +
    # Labels with units
    ggplot2::labs(
      title = paste("Population PK Simulation (", model_name, ", Bolus)", sep = ""),
      subtitle = sprintf("Mean ± SD, n = %d per group", summary_df$n[1]),
      x = get_time_label(time_unit),
      y = get_conc_label(conc_unit)
    ) +
    get_pmx_theme() +
    ggplot2::theme(
      legend.position = "right"
    )

  return(p)
}

#' Save plot with standard PMxAgent settings
#' @param plot ggplot object to save
#' @param type Type of plot (e.g., "PK", "ER", "NCA")
#' @param outdir Output directory (default: FIGURES_DIR constant)
#' @param width Plot width in inches (optional, uses type-specific default)
#' @param height Plot height in inches (optional, uses type-specific default)
#' @return Path to saved file
save_pmx_plot <- function(plot, type, outdir = FIGURES_DIR, width = NULL, height = NULL) {
  # Ensure output directory exists
  if (!dir.exists(outdir)) {
    dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
  }

  # Generate timestamp-based filename
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  filename <- sprintf("%s_%s.png", type, timestamp)
  outfile <- file.path(outdir, filename)

  # Determine dimensions (use type-specific defaults if not specified)
  if (is.null(width)) {
    width <- if (type == "ER") ER_PLOT_WIDTH else PLOT_WIDTH
  }
  if (is.null(height)) {
    height <- if (type == "ER") ER_PLOT_HEIGHT else PLOT_HEIGHT
  }

  # Save with determined dimensions
  ggplot2::ggsave(
    filename = outfile,
    plot = plot,
    width = width,
    height = height,
    dpi = PLOT_DPI,
    bg = "white"
  )

  return(outfile)
}
