# endpoints/data.R
# Data formatting endpoint for pharmacometric analyses
# Reads raw CSV/Excel files, standardizes to analysis-ready datasets,
# and saves output CSV to /data for downstream endpoints.

#* Format data for pharmacometric analyses
#* Reads a raw PK data file (CSV or Excel) from /data, cleans and standardizes
#* it to a CDISC ADPC-aligned dataset ready for NCA, and saves the output CSV
#* back to /data. Supports NONMEM-style AMT column for dose extraction.
#* @param file_path Filename within /data directory, e.g. "study.csv" (required)
#* @param dataset_type Processing type: "adpc" (default). Future: "nonmem_pk"
#* @param subject_col Column name for subject ID (default "ID")
#* @param time_col Column name for nominal time (default "TIME")
#* @param conc_col Column name for concentration (default "DV")
#* @param dose_col Column name for dose (default "AMT"); first non-zero per subject
#* @param blq_col Column name for BLQ flag (string, optional)
#* @param dose Fallback dose value if dose_col absent or all-zero (default "1")
#* @param conc_unit Concentration unit label for AVALU column (default "ug/mL")
#* @param dose_unit Dose unit label for DOSEU column (default "mg")
#* @param route Route of administration for ROUTE column (default "extravascular")
#* @param output_prefix Output filename prefix; default uses input filename stem
#* @post /DATA
#* @serializer unboxedJSON
function(file_path,
         dataset_type  = "adpc",
         subject_col   = "ID",
         time_col      = "TIME",
         conc_col      = "DV",
         dose_col      = "AMT",
         blq_col       = "",
         dose          = "1",
         conc_unit     = "ug/mL",
         dose_unit     = "mg",
         route         = "extravascular",
         output_prefix = "") {

  tryCatch({
    # ── 1. Resolve file path ────────────────────────────────────────────────
    data_dir  <- "/data"
    full_path <- file.path(data_dir, file_path)

    if (!file.exists(full_path)) {
      available <- list.files(data_dir, pattern = "\\.(csv|xlsx|xls)$", ignore.case = TRUE)
      avail_str <- if (length(available) > 0) paste(available, collapse = ", ") else "(none)"
      stop(sprintf(
        "File not found: '%s'. Available in /data: %s",
        file_path, avail_str
      ))
    }

    # ── 2. Validate dataset_type ────────────────────────────────────────────
    supported_types <- c("adpc")
    if (!dataset_type %in% supported_types) {
      stop(sprintf(
        "Unsupported dataset_type '%s'. Supported in v1: 'adpc'. PopPK support coming in v2.",
        dataset_type
      ))
    }

    # ── 3. Read source file ─────────────────────────────────────────────────
    df <- read_data_file(full_path)

    # ── 4. Build column mapping ─────────────────────────────────────────────
    dose_col_mapped <- if (nchar(trimws(dose_col)) > 0) dose_col else NULL
    blq_col_mapped  <- if (nchar(trimws(blq_col)) > 0) blq_col else NULL

    col_mapping <- list(
      subject = subject_col,
      time    = time_col,
      conc    = conc_col,
      dose    = dose_col_mapped,
      blq     = blq_col_mapped
    )

    metadata <- list(
      conc_unit     = conc_unit,
      dose_unit     = dose_unit,
      route         = route,
      dosno         = 1,
      fallback_dose = as.numeric(dose)
    )

    # ── 5. Process: route to appropriate processor ──────────────────────────
    if (dataset_type == "adpc") {
      result <- prepare_adpc(df, col_mapping, metadata)
    }

    # ── 6. Save output CSV ──────────────────────────────────────────────────
    # Derive stem from input filename
    input_stem <- tools::file_path_sans_ext(basename(file_path))
    prefix     <- if (nchar(trimws(output_prefix)) > 0) output_prefix else input_stem
    timestamp  <- format(Sys.time(), "%Y%m%d_%H%M%S")
    out_name   <- sprintf("%s_%s_%s.csv", prefix, dataset_type, timestamp)
    out_path   <- file.path(data_dir, out_name)

    write.csv(result$data, out_path, row.names = FALSE)

    # ── 7. Return JSON summary ──────────────────────────────────────────────
    list(
      status        = "success",
      dataset_type  = dataset_type,
      source_file   = file_path,
      output_file   = out_name,
      n_subjects    = result$n_subjects,
      n_records     = result$n_records,
      columns       = names(result$data),
      input_column_mapping = list(
        subject_col = subject_col,
        time_col    = time_col,
        conc_col    = conc_col,
        dose_col    = if (!is.null(dose_col_mapped)) dose_col_mapped else "(fallback)",
        blq_col     = if (!is.null(blq_col_mapped)) blq_col_mapped else "(none)"
      ),
      summary = list(
        subjects         = as.list(result$subjects),
        time_range       = result$time_range,
        conc_range       = result$conc_range,
        dose_per_subject = as.list(result$dose_per_subject)
      )
    )

  }, error = function(e) {
    stop(sprintf("DATA processing failed: %s", e$message))
  })
}
