# utils/library_utils.R
# Pure, table-driven helpers for the /LIBRARY endpoint.
#
# These functions carry NO dependency on nlmixr2lib/rxode2 so they can be unit
# tested on synthetic data (see apis/tests/test_library_models.R). The concerns
# here are sampling DESIGN (half-life -> tier -> schedule) and catalog FILTERING.
# Faithful simulation lives in models/nlmixr2lib_sim.R.

# ---------------------------------------------------------------------------
# Sampling design
# ---------------------------------------------------------------------------

#' Assign a sampling tier label from terminal half-life (hours).
#' Boundaries follow the benchmarking study design. Used for metadata/reporting;
#' the actual sampling grid is built by build_sampling_schedule().
#' @param t_half_h numeric terminal half-life in hours
#' @return character: "tier1" (<24h), "tier2" (24-168h), "tier3" (168-840h),
#'         "tier4" (>=840h), or NA for invalid input.
assign_tier <- function(t_half_h) {
  if (length(t_half_h) != 1 || is.na(t_half_h) || !is.finite(t_half_h) || t_half_h <= 0) {
    return(NA_character_)
  }
  if (t_half_h < 24)  return("tier1")
  if (t_half_h < 168) return("tier2")
  if (t_half_h < 840) return("tier3")
  "tier4"
}

#' Build a clinically realistic concentration-time sampling schedule from a
#' tier-based candidate pool scaled to the terminal half-life.
#' Each tier mirrors a real clinical PK study design:
#'   tier1 (<24 h)    — intensive hospital/clinic sampling, up to 3 days
#'   tier2 (24-168 h) — daily then bi-daily over ~5 weeks
#'   tier3 (168-840 h)— weekly clinic visits up to ~3 months (IV/SC biologics)
#'   tier4 (>=840 h)  — bi-weekly to monthly visits up to 1 year
#' @param t_half_h numeric terminal half-life in hours (> 0)
#' @param route character (advisory; same grid for IV/EV within each tier)
#' @return list(times = numeric vector (hours, includes 0 and window_h, sorted unique),
#'              window_h = numeric (observation window in hours), tier = character)
build_sampling_schedule <- function(t_half_h, route = "iv_bolus") {
  if (length(t_half_h) != 1 || is.na(t_half_h) || !is.finite(t_half_h) || t_half_h <= 0) {
    stop(sprintf("build_sampling_schedule: invalid t_half_h (%s)", as.character(t_half_h)))
  }

  tier <- assign_tier(t_half_h)

  if (tier == "tier1") {
    candidates <- c(0, 0.25, 0.5, 1, 2, 4, 6, 8, 12, 24, 36, 48, 60, 72)
    window_h   <- 5 * t_half_h
  } else if (tier == "tier2") {
    candidates <- c(0, 1, 2, 4, 8, 24, 48, 72, 96, 120, 168, 336, 504, 672, 840)
    window_h   <- min(5 * t_half_h, 2016)
  } else if (tier == "tier3") {
    candidates <- c(0, 4, 24, 72, 168, 336, 504, 672, 840, 1008, 1176, 1512, 2016, 2520)
    window_h   <- min(5 * t_half_h, 2520)
  } else {
    # tier4: bi-weekly to monthly up to 1 year
    candidates <- c(0, 24, 72, 168, 336, 504, 672, 840, 1176, 1512,
                    2016, 2520, 3024, 4032, 5040, 6048, 7056, 8760)
    window_h   <- min(3 * t_half_h, 8760)
  }

  window_h <- ceiling(window_h)
  times <- sort(unique(c(candidates[candidates <= window_h], window_h)))
  list(times = times, window_h = window_h, tier = tier)
}

#' Fit terminal elimination half-life from a concentration-time profile by
#' log-linear regression over the terminal phase (PKNCA-style best-fit: grow the
#' window from the last `min_points` points and keep the highest adjusted R^2).
#' Pure math -> unit testable. Used by estimate_terminal_half_life() after a
#' typical-value probe simulation.
#' @param times numeric vector of times
#' @param conc numeric vector of concentrations (same length)
#' @param min_points integer minimum points in the terminal regression (default 3)
#' @return list(t_half_h, lambda_z, r_squared, n_points)
fit_terminal_half_life <- function(times, conc, min_points = 3) {
  na_out <- list(t_half_h = NA_real_, lambda_z = NA_real_,
                 r_squared = NA_real_, n_points = 0L)
  ok <- is.finite(times) & is.finite(conc) & conc > 0
  times <- times[ok]; conc <- conc[ok]
  ord <- order(times)
  times <- times[ord]; conc <- conc[ord]
  if (length(times) < min_points) return(na_out)

  # Terminal phase = points from the peak onward.
  tmax_idx <- which.max(conc)
  idx <- seq.int(tmax_idx, length(times))
  if (length(idx) < min_points) {
    idx <- seq.int(length(times) - min_points + 1L, length(times))
  }
  tt <- times[idx]; cc <- conc[idx]
  n <- length(tt)

  best <- na_out
  best_r2 <- -Inf
  for (k in min_points:n) {
    sel <- seq.int(n - k + 1L, n)
    x <- tt[sel]; y <- log(cc[sel])
    if (length(unique(x)) < 2) next
    fit <- tryCatch(stats::lm(y ~ x), error = function(e) NULL)
    if (is.null(fit)) next
    slope <- unname(stats::coef(fit)[2])
    if (!is.finite(slope) || slope >= 0) next  # terminal phase must decline
    r2 <- suppressWarnings(summary(fit)$adj.r.squared)
    if (!is.finite(r2)) r2 <- summary(fit)$r.squared
    if (is.finite(r2) && r2 > best_r2) {
      best_r2 <- r2
      lz <- -slope
      best <- list(t_half_h = log(2) / lz, lambda_z = lz,
                   r_squared = r2, n_points = as.integer(k))
    }
  }
  best
}

# ---------------------------------------------------------------------------
# Dose extraction from model source text
# ---------------------------------------------------------------------------

# Extract the dose_range field value from model source text.
.extract_dose_range_text <- function(txt) {
  m <- regmatches(txt, regexpr('dose_range\\s*=\\s*"([^"]+)"', txt, perl = TRUE))
  if (length(m) > 0) return(sub('^dose_range\\s*=\\s*"', "", sub('"$', "", m[1])))
  m2 <- regmatches(txt, regexpr('dose_range\\s*=\\s*paste\\([^)]+\\)', txt, perl = TRUE))
  if (length(m2) > 0) {
    strs <- regmatches(m2[1], gregexpr('"[^"]+"', m2[1], perl = TRUE))[[1]]
    return(paste(gsub('^"|"$', "", strs), collapse = " "))
  }
  NA_character_
}

# Extract all numeric values followed by a unit pattern, excluding rates (/min, /h, /d, /L).
.extract_nums_with_unit <- function(txt, unit_pattern) {
  pat <- paste0("([0-9]+(?:\\.[0-9]+)?)\\s*", unit_pattern, "(?!/(?:min|h|d|L|mL))")
  m <- regmatches(txt, gregexpr(pat, txt, perl = TRUE, ignore.case = TRUE))[[1]]
  if (length(m) == 0) return(numeric(0))
  nums <- suppressWarnings(as.numeric(
    regmatches(m, regexpr("^[0-9]+(?:\\.[0-9]+)?", m, perl = TRUE))
  ))
  nums[is.finite(nums) & nums > 0]
}

#' Parse the highest single dose in mg from model source text.
#' Per-kg values use a 70 kg reference weight. Infusion rates (e.g. mg/kg/min)
#' are excluded. Returns \code{default_mg} when no parseable dose is found.
#' Pure text input — no nlmixr2lib dependency; unit-testable.
#' @param txt character model source text (or any string containing dose_range)
#' @param default_mg numeric fallback dose in mg (default 100)
#' @return numeric scalar dose in mg
parse_dose_from_model_text <- function(txt, default_mg = 100) {
  if (!is.character(txt) || !nzchar(trimws(txt))) return(default_mg)
  dr <- .extract_dose_range_text(txt)
  if (is.na(dr) || !nzchar(trimws(dr))) return(default_mg)

  mgkg    <- .extract_nums_with_unit(dr, "mg/kg")
  ugkg    <- .extract_nums_with_unit(dr, "(?:ug|mcg|µg)/kg")
  dr_flat <- gsub("[0-9.]+\\s*(?:mg|ug|mcg)/kg[^,;\\s]*", "", dr, perl = TRUE, ignore.case = TRUE)
  mg_flat <- .extract_nums_with_unit(dr_flat, "mg(?!/kg)")

  all_mg <- c(mgkg * 70, ugkg * 70 / 1000, mg_flat)
  if (length(all_mg) == 0) return(default_mg)
  round(max(all_mg), 4)
}

# ---------------------------------------------------------------------------
# Catalog filtering
# ---------------------------------------------------------------------------

# Source-tree categories (top-level subdirectory under inst/modeldb/).
LIBRARY_PK_CATEGORIES  <- c("pharmacokinetics", "specificdrugs")
LIBRARY_OOS_CATEGORIES <- c("pharmacodynamics", "endogenous",
                            "therapeuticarea", "ddmore")

#' Derive the top-level model category from a catalog filename/path.
#' e.g. "specificDrugs/Trastuzumab.R" -> "specificDrugs";
#'      "therapeuticArea/oncology/Foo.R" -> "therapeuticArea".
#' Returns NA when the filename carries no directory component.
#' @param filename character vector
#' @return character vector of categories (NA where undeterminable)
categorize_from_filename <- function(filename) {
  fn <- as.character(filename)
  vapply(fn, function(f) {
    if (is.na(f) || !grepl("/", f, fixed = TRUE)) return(NA_character_)
    parts <- strsplit(f, "/", fixed = TRUE)[[1]]
    parts <- parts[nzchar(parts)]
    if (length(parts) > 1 && tolower(parts[1]) == "modeldb") parts <- parts[-1]
    if (length(parts) <= 1) return(NA_character_)
    parts[1]
  }, character(1), USE.NAMES = FALSE)
}

# Non-human / preclinical model patterns (filename or name). A clean human PK
# benchmark excludes these even though they output a concentration (DV == "Cc").
# The species token must be delimited by `_`, `.`, or end-of-string so it matches
# both stem-final (`..._rat.R`) and mid-name (`..._rat_binary`) forms -- `\b` does
# not work here because `_` is itself a word character.
LIBRARY_NONHUMAN_PATTERN <- "_(rat|rats|mouse|mice|sheep|cat|cats|pig|pigs|dog|dogs|rabbit|rabbits|monkey|larva|larvae|ovine|canine|porcine|murine)(_|\\.|$)|in_?vitro"

# Curated multi-drug (combination) model names. These pass DV == "Cc" but model two
# analytes / co-administered drugs, which is ambiguous for single-drug NCA.
LIBRARY_COMBINATION_PATTERN <- paste(
  "naltrexone_bupropion", "imipenem_tobramycin", "meropenem_ciprofloxacin",
  "linezolid_meropenem", "statins_ezetimibe", "sunitinib_irinotecan",
  sep = "|")

#' Parse the 4-digit publication year from an `Author_Year_drug` model name.
#' @return integer year, or NA for names without an embedded year (e.g. PK_2cmt).
parse_model_year <- function(name) {
  m <- regmatches(name, regexpr("(?<![0-9])(19|20)[0-9]{2}(?![0-9])", name, perl = TRUE))
  if (length(m) == 0) NA_integer_ else as.integer(m[1])
}

#' Parse the drug stem from a model name. Strips a leading `Author_Year_` prefix and
#' a trailing `_ddmore`; falls back to the whole name when no year is present.
#' Returns a lowercase stem used for dedup-by-drug.
parse_drug_stem <- function(name) {
  s <- sub("_ddmore$", "", name, ignore.case = TRUE)
  stem <- sub("^[A-Za-z.À-ſ-]+_(19|20)[0-9]{2}_", "", s)
  tolower(stem)
}

#' Display drug name for a model: the `parse_drug_stem` content with **original
#' case preserved** (e.g. `Li_2006_meropenem` -> `meropenem`, `Goel_2016_Sonidegib`
#' -> `Sonidegib`). Generic templates / names without an `Author_Year_` prefix
#' (e.g. `PK_2cmt_no_depot`) are returned unchanged. Used for the benchmark `DRUG`
#' column, with the full model name retained in `USUBJID` for source traceability.
library_drug_name <- function(name) {
  s <- sub("_ddmore$", "", name, ignore.case = TRUE)
  sub("^[A-Za-z.À-ſ-]+_(19|20)[0-9]{2}_", "", s)
}

#' Best-effort disposition compartment count from a model description.
#' @return 1L/2L/3L or NA.
n_cmt_from_description <- function(desc) {
  if (is.na(desc)) return(NA_integer_)
  d <- tolower(desc)
  if (grepl("(three|3)[ -]?compartment", d)) return(3L)
  if (grepl("(two|2)[ -]?compartment",   d)) return(2L)
  if (grepl("(one|1|mono)[ -]?compartment", d)) return(1L)
  NA_integer_
}

#' Filter a raw nlmixr2lib catalog to human PK 1/2-compartment models.
#'
#' Primary include signal is the catalog `DV` column equal to "Cc" (a
#' concentration-output PK model) -- this cleanly removes PD / disease / count /
#' time-to-event models. The catalog `algebraic` column then removes algebraic
#' (MBMA / cellular-kinetic / disease) models that still output "Cc". Name- and
#' description-pattern exclusions drop >2-compartment (incl. 3-cmt declared only in
#' the description), TMDD / Michaelis-Menten nonlinear, multi-analyte (ADC), and
#' non-human / combination models. Route is read from the catalog `dosing` column
#' (depot present -> extravascular); models with no dosing info (route
#' undeterminable) are excluded. Columns are auto-detected (case-insensitive);
#' missing columns degrade gracefully.
#'
#' @param catalog data.frame (nlmixr2lib `modeldb`-style)
#' @return the input data.frame with added columns:
#'   pk_category (chr|NA), route (chr|NA), n_cmt (int|NA), year (int|NA),
#'   drug_stem (chr), flags (chr, may be ""), included (lgl), exclude_reason (chr|NA)
filter_pk_models <- function(catalog, wide = FALSE) {
  if (!is.data.frame(catalog) || nrow(catalog) == 0) {
    stop("filter_pk_models: catalog must be a non-empty data.frame")
  }
  cols <- names(catalog); lc <- tolower(cols)
  getcol <- function(cands) { i <- match(TRUE, lc %in% cands); if (is.na(i)) NA_character_ else cols[i] }
  name_col   <- getcol(c("name", "model", "model_name"))
  dv_col     <- getcol(c("dv"))
  dosing_col <- getcol(c("dosing"))
  cat_col    <- getcol(c("category"))
  file_col   <- getcol(c("filename", "file", "path", "filepath"))
  alg_col    <- getcol(c("algebraic"))
  desc_col   <- getcol(c("description", "desc"))
  if (is.na(name_col)) stop("filter_pk_models: could not find a model name column")

  n      <- nrow(catalog)
  name   <- as.character(catalog[[name_col]])
  dv     <- if (!is.na(dv_col))     as.character(catalog[[dv_col]])     else rep(NA_character_, n)
  dosing <- if (!is.na(dosing_col)) as.character(catalog[[dosing_col]]) else rep(NA_character_, n)
  alg    <- if (!is.na(alg_col))    as.logical(catalog[[alg_col]])      else rep(FALSE, n)
  desc   <- if (!is.na(desc_col))   as.character(catalog[[desc_col]])   else rep(NA_character_, n)
  fname  <- if (!is.na(file_col))   as.character(catalog[[file_col]])   else rep(NA_character_, n)
  category <- if (!is.na(cat_col)) as.character(catalog[[cat_col]])
              else if (!is.na(file_col)) categorize_from_filename(catalog[[file_col]])
              else rep(NA_character_, n)

  included <- logical(n); reason <- rep(NA_character_, n); flags <- rep("", n)
  route    <- rep(NA_character_, n); n_cmt <- rep(NA_integer_, n)
  year     <- rep(NA_integer_, n); drug_stem <- rep(NA_character_, n)

  for (i in seq_len(n)) {
    nm_l  <- tolower(name[i])
    fn_l  <- tolower(fname[i])
    is_pk <- !is.na(dv[i]) && tolower(trimws(dv[i])) == "cc"
    year[i]      <- parse_model_year(name[i])
    drug_stem[i] <- parse_drug_stem(name[i])

    if (!is.na(dosing[i]) && nzchar(trimws(dosing[i])) && tolower(trimws(dosing[i])) != "na") {
      route[i] <- if (grepl("depot|absorption|gut", tolower(dosing[i]))) "extravascular" else "iv_bolus"
    }

    # Compartment count: name first, then description.
    if      (grepl("3 ?cmt|three.?comp", nm_l)) n_cmt[i] <- 3L
    else if (grepl("2 ?cmt|two.?comp",   nm_l)) n_cmt[i] <- 2L
    else if (grepl("1 ?cmt|one.?comp",   nm_l)) n_cmt[i] <- 1L
    else                                        n_cmt[i] <- n_cmt_from_description(desc[i])

    desc_is_3cmt <- !is.na(desc[i]) && grepl("(three|3)[ -]?compartment", tolower(desc[i]))
    is_nonhuman  <- grepl(LIBRARY_NONHUMAN_PATTERN, fn_l) || grepl(LIBRARY_NONHUMAN_PATTERN, nm_l)
    is_combo     <- grepl(LIBRARY_COMBINATION_PATTERN, nm_l)

    if (!is_pk) {
      included[i] <- FALSE; reason[i] <- "non_pk_output"
    } else if (isTRUE(alg[i])) {
      included[i] <- FALSE; reason[i] <- "algebraic"
    } else if (!wide && grepl("3 ?cmt|three.?comp", nm_l)) {
      included[i] <- FALSE; reason[i] <- "gt_2cmt"
    } else if (!wide && desc_is_3cmt) {
      included[i] <- FALSE; reason[i] <- "gt_2cmt_desc"
    } else if (!wide && grepl("tmdd", nm_l)) {
      included[i] <- FALSE; reason[i] <- "tmdd"
    } else if (grepl("emtansine|deruxtecan|vedotin|govitecan|mechanistic|catenary", nm_l)) {
      included[i] <- FALSE; reason[i] <- "multi_analyte"
    } else if (grepl("^indirect|^idr_|effect_?cmt", nm_l)) {
      included[i] <- FALSE; reason[i] <- "indirect_response"
    } else if (is_nonhuman) {
      included[i] <- FALSE; reason[i] <- "non_human"
    } else if (is_combo) {
      included[i] <- FALSE; reason[i] <- "combination"
    } else if (is.na(route[i])) {
      included[i] <- FALSE; reason[i] <- "null_route"
    } else {
      included[i] <- TRUE
      if (route[i] == "extravascular") flags[i] <- "extravascular"
    }
  }

  catalog$pk_category    <- category
  catalog$route          <- route
  catalog$n_cmt          <- n_cmt
  catalog$year           <- year
  catalog$drug_stem      <- drug_stem
  catalog$flags          <- flags
  catalog$included       <- included
  catalog$exclude_reason <- reason
  catalog
}

#' Select the clean benchmark model set from a raw catalog.
#'
#' Runs filter_pk_models(), keeps included models with a usable route
#' (iv_bolus / extravascular), and optionally deduplicates to one model per drug
#' (latest publication year wins; tie-break specificDrugs > ddmore > other).
#' Returns models ordered by name with a stable integer index in `bench_index`
#' (1..K) used for deterministic per-model seeding so the benchmark dataset is
#' identical regardless of how a generation run is chunked.
#'
#' @param catalog data.frame (nlmixr2lib `modeldb`-style)
#' @param dedup logical, deduplicate by drug stem (default TRUE)
#' @return data.frame (filtered, ordered) with all filter_pk_models() columns plus
#'   `bench_index` (int).
select_benchmark_models <- function(catalog, dedup = TRUE, wide = FALSE) {
  f   <- filter_pk_models(catalog, wide = wide)
  inc <- f[f$included &
             !is.na(f$route) &
             f$route %in% c("iv_bolus", "extravascular"), , drop = FALSE]
  if (nrow(inc) == 0) return(inc)

  if (isTRUE(dedup)) {
    cat_rank <- c(specificdrugs = 1L, ddmore = 2L, other = 3L)
    cat_l <- tolower(ifelse(is.na(inc$pk_category), "other", inc$pk_category))
    rk <- cat_rank[cat_l]; rk[is.na(rk)] <- 3L
    yr <- inc$year; yr[is.na(yr)] <- -Inf  # year-less generics sort last within a key
    # Dedup key: literature models (specificDrugs/ddmore) collapse on the first drug
    # token so the many papers on one drug (e.g. 16 tacrolimus) reduce to one;
    # generic structural templates ("other") keep their full stem so PK_1cmt /
    # PK_2cmt / PK_2cmt_no_depot remain distinct.
    is_lit    <- cat_l %in% c("specificdrugs", "ddmore")
    first_tok <- sub("_.*$", "", inc$drug_stem)
    dedup_key <- ifelse(is_lit, first_tok, inc$drug_stem)
    # Order so the preferred model per key is first: newest year, then better
    # category rank, then name for determinism.
    ord <- order(dedup_key, -yr, rk, inc$name)
    inc <- inc[ord, , drop = FALSE]; dedup_key <- dedup_key[ord]
    inc <- inc[!duplicated(dedup_key), , drop = FALSE]
  }

  inc <- inc[order(inc$name), , drop = FALSE]
  inc$bench_index <- seq_len(nrow(inc))
  rownames(inc) <- NULL
  inc
}
