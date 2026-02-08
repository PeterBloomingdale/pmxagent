# utils/colors.R
# Color scheme utilities using RColorBrewer Pastel1

library(RColorBrewer)

# RColorBrewer Pastel1 palette (9 colors)
PASTEL1_PALETTE <- brewer.pal(9, "Pastel1")

# Dose group colors using Pastel1
# Index mapping: 1=red, 2=blue, 3=green, 4=purple, 5=orange, 6=yellow, 7=brown, 8=pink, 9=gray
DOSE_COLORS <- list(
  "10 mg" = PASTEL1_PALETTE[1],   # Pastel red
  "30 mg" = PASTEL1_PALETTE[2],   # Pastel blue
  "100 mg" = PASTEL1_PALETTE[3]   # Pastel green
)

# ER plot specific colors
ER_LINE_COLOR <- "black"
ER_POINT_COLOR <- "gray50"

#' Get color for a dose group
#' @param dose Dose label (e.g., "10 mg", "30 mg", "100 mg")
#' @return Color string
get_dose_color <- function(dose) {
  if (dose %in% names(DOSE_COLORS)) {
    return(DOSE_COLORS[[dose]])
  }
  # Return a default color from palette for unknown doses
  idx <- (as.numeric(gsub("[^0-9]", "", dose)) %% 9) + 1
  PASTEL1_PALETTE[idx]
}

#' Get colors for multiple dose groups
#' @param doses Vector of dose labels
#' @return Named vector of colors
get_dose_colors_vector <- function(doses) {
  unique_doses <- unique(doses)
  colors <- sapply(unique_doses, get_dose_color)
  names(colors) <- unique_doses
  colors
}

#' Create a Pastel1-based color scale for ggplot2
#' @param n Number of colors needed
#' @return Vector of colors
get_pastel1_scale <- function(n) {
  if (n <= 9) {
    return(PASTEL1_PALETTE[seq_len(n)])
  }
  # If more than 9 colors needed, repeat the palette
  rep(PASTEL1_PALETTE, length.out = n)
}
