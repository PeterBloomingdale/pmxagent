# utils/data_processing.R
# Data reading, cleaning, and standardization utilities for pharmacometric analyses.
# v1 supports ADPC (NCA-ready) output; designed for future PopPK/NONMEM extension.

#' Read a data file (CSV or Excel)
#'
#' @param full_path Absolute path to the file
#' @return data.frame
read_data_file <- function(full_path) {
  ext <- tolower(tools::file_ext(full_path))

  if (ext == "csv") {
    df <- read.csv(full_path, stringsAsFactors = FALSE, check.names = FALSE)
  } else if (ext %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop("readxl package is required for Excel files. Install with: install.packages('readxl')")
    }
    df <- as.data.frame(readxl::read_excel(full_path))
  } else {
    stop(sprintf(
      "Unsupported file type '.%s'. Supported: .csv, .xlsx, .xls",
      ext
    ))
  }

  if (nrow(df) == 0) {
    stop("File is empty or contains no data rows")
  }

  df
}

#' Validate that required columns exist in a data frame
#'
#' @param df data.frame to check
#' @param required_cols Character vector of required column names
#' @param context_label Human-readable label for error messages (e.g. "conc_col")
validate_file_columns <- function(df, required_cols, context_labels = NULL) {
  avail <- names(df)
  for (i in seq_along(required_cols)) {
    col <- required_cols[i]
    if (!col %in% avail) {
      label <- if (!is.null(context_labels) && length(context_labels) >= i) context_labels[i] else col
      stop(sprintf(
        "Column '%s' not found. Available: %s. Use %s parameter to specify the correct column name.",
        col,
        paste(avail, collapse = ", "),
        label
      ))
    }
  }
  invisible(NULL)
}

#' Extract dose per subject from a data frame
#'
#' Strategy: first non-zero, non-NA value in dose_col per subject.
#' Works for NONMEM AMT-style (sparse) and constant-per-subject columns.
#' Falls back to fallback_dose if dose_col is absent or yields no values.
#'
#' @param df data.frame
#' @param subject_col Column name for subject ID
#' @param dose_col Column name for dose (may be NULL)
#' @param fallback_dose Numeric fallback dose
#' @return Named numeric vector: names = subject IDs, values = doses
extract_dose_per_subject <- function(df, subject_col, dose_col, fallback_dose) {
  subjects <- unique(df[[subject_col]])

  if (is.null(dose_col) || !dose_col %in% names(df)) {
    # No dose column: use fallback for all subjects
    doses <- setNames(rep(as.numeric(fallback_dose), length(subjects)), as.character(subjects))
    return(doses)
  }

  doses <- sapply(subjects, function(subj) {
    subj_rows <- df[[dose_col]][df[[subject_col]] == subj]
    non_zero <- subj_rows[!is.na(subj_rows) & as.numeric(subj_rows) != 0]
    if (length(non_zero) == 0) {
      return(as.numeric(fallback_dose))
    }
    as.numeric(non_zero[1])
  })

  setNames(doses, as.character(subjects))
}

#' Prepare ADPC dataset from raw PK data
#'
#' Standardizes raw data to a CDISC ADaM ADPC-aligned format ready for NCA.
#'
#' @param df data.frame of raw input data
#' @param col_mapping Named list: subject, time, conc, dose (column names in df), blq (optional)
#' @param metadata Named list: conc_unit, dose_unit, route, dosno (defaults to 1)
#' @return List with:
#'   \item{data}{Cleaned ADPC data.frame}
#'   \item{n_subjects}{Number of unique subjects}
#'   \item{n_records}{Number of observation records}
#'   \item{subjects}{Character vector of subject IDs}
#'   \item{time_range}{Numeric vector c(min, max)}
#'   \item{conc_range}{Numeric vector c(min, max)}
#'   \item{dose_per_subject}{Named numeric vector of doses by subject}
prepare_adpc <- function(df, col_mapping, metadata) {
  subject_col <- col_mapping$subject
  time_col    <- col_mapping$time
  conc_col    <- col_mapping$conc
  dose_col    <- col_mapping$dose   # may be NULL
  blq_col     <- col_mapping$blq    # may be NULL

  conc_unit <- metadata$conc_unit
  dose_unit <- metadata$dose_unit
  route     <- metadata$route
  dosno     <- if (!is.null(metadata$dosno)) metadata$dosno else 1
  fallback_dose <- if (!is.null(metadata$fallback_dose)) metadata$fallback_dose else 1

  # Validate required columns
  validate_file_columns(
    df,
    required_cols  = c(subject_col, time_col, conc_col),
    context_labels = c("subject_col", "time_col", "conc_col")
  )

  # Extract dose per subject (before filtering to observations only)
  dose_per_subject <- extract_dose_per_subject(df, subject_col, dose_col, fallback_dose)

  # Build ADPC data frame — keep only observation rows
  # NONMEM AMT-style: dosing event rows have AMT > 0, observation rows have AMT = 0.
  # Constant-dose style (e.g. PK simulation output): DOSE is non-zero for every row.
  # Distinguish by checking for a mix of zero and non-zero values: only apply
  # AMT-style filtering when both are present (indicating dosing + observation rows).
  obs_mask <- rep(TRUE, nrow(df))
  if (!is.null(dose_col) && dose_col %in% names(df)) {
    dose_vals <- suppressWarnings(as.numeric(df[[dose_col]]))
    has_zeros    <- any(!is.na(dose_vals) & dose_vals == 0)
    has_nonzero  <- any(!is.na(dose_vals) & dose_vals != 0)
    if (has_zeros && has_nonzero) {
      # NONMEM AMT-style: keep only observation rows (dose == 0 or NA)
      obs_mask <- is.na(dose_vals) | dose_vals == 0
    }
    # Otherwise constant-dose column — keep all rows
  }

  adpc <- data.frame(
    USUBJID = as.character(df[[subject_col]][obs_mask]),
    ATPTN   = as.numeric(df[[time_col]][obs_mask]),
    AVAL    = suppressWarnings(as.numeric(df[[conc_col]][obs_mask])),
    stringsAsFactors = FALSE
  )

  # Filter to observation rows (AVAL not NA)
  adpc <- adpc[!is.na(adpc$AVAL), ]

  if (nrow(adpc) == 0) {
    stop(sprintf(
      "No valid observation rows found. Column '%s' contains no numeric values after filtering NA.",
      conc_col
    ))
  }

  # Add DOSE column (looked up per subject)
  adpc$DOSE <- dose_per_subject[adpc$USUBJID]

  # Add constant metadata columns
  adpc$AVALU <- conc_unit
  adpc$DOSEU <- dose_unit
  adpc$DOSNO <- as.integer(dosno)
  adpc$ROUTE <- route

  # Add BLQ column
  if (!is.null(blq_col) && blq_col %in% names(df)) {
    # Match rows: apply obs_mask then filter non-NA AVAL (same as adpc filtering above)
    aval_obs <- suppressWarnings(as.numeric(df[[conc_col]][obs_mask]))
    aval_mask <- !is.na(aval_obs)
    blq_vals  <- df[[blq_col]][obs_mask][aval_mask]
    adpc$BLQ <- as.integer(blq_vals)
  } else {
    adpc$BLQ <- 0L
  }

  # Sort by subject then time
  adpc <- adpc[order(adpc$USUBJID, adpc$ATPTN), ]
  rownames(adpc) <- NULL

  # Ensure column order
  adpc <- adpc[, c("USUBJID", "ATPTN", "AVAL", "AVALU", "DOSE", "DOSEU", "DOSNO", "ROUTE", "BLQ")]

  # Summary statistics
  subjects <- unique(adpc$USUBJID)

  list(
    data             = adpc,
    n_subjects       = length(subjects),
    n_records        = nrow(adpc),
    subjects         = subjects,
    time_range       = c(min(adpc$ATPTN, na.rm = TRUE), max(adpc$ATPTN, na.rm = TRUE)),
    conc_range       = c(min(adpc$AVAL, na.rm = TRUE), max(adpc$AVAL, na.rm = TRUE)),
    dose_per_subject = dose_per_subject
  )
}
