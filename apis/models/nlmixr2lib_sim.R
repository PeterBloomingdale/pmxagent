# models/nlmixr2lib_sim.R
# Model/simulation layer for the /LIBRARY endpoint. Wraps nlmixr2lib + rxode2.
#
# Verified behavior (Phase 0 spike, nlmixr2lib 0.3.2.9000 / rxode2 5.1.2):
#   * Catalog is nlmixr2lib's `modeldb` data.frame (614 rows): name, description,
#     parameters, DV, linCmt, algebraic, dosing, depends, vignette, label,
#     category, filename. DV == "Cc" marks a PK (concentration-output) model.
#   * modellib(name=) returns a FUNCTION; rxode2::rxode2(fn) yields an rxUi with
#     $omega (published BSV) and $allCovs (required covariates).
#   * Literature models carry their published omega -> rxSolve(nSub=N, omega=om)
#     produces BSV. Most also need covariates, supplied as constants via params=.
#   * Concentration output column is "Cc" (BSV-only IPRED). Per-subject cl/vc/q/vp/ka
#     come back as columns of the solve. Subject id column is "sim.id".
#   * Residual (within-subject) error is applied on top of the IPRED here, in R, from
#     the model's own published error model (extract_residual_error/apply_residual),
#     rather than reading rxode2's "sim" column. This keeps the residual draw
#     deterministic/seed-controlled and lets us clamp negatives + flag BLQ.
#
# Faithful, BSV-only simulation. Terminal half-life is estimated NUMERICALLY from a
# typical-value probe (structure-agnostic) via fit_terminal_half_life().

library(nlmixr2lib)
library(rxode2)

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# Reference covariate values (typical adult) for literature models that require
# covariates to solve. Keys matched case-insensitively. Users may override/extend
# per request; any required covariate without a value is reported as an error.
LIBRARY_REF_COVARIATES <- list(
  WT = 70, BW = 70, WEIGHT = 70, BWT = 70, TBW = 70, FFM = 55, LBM = 55, BSA = 1.9,
  AGE = 40, PNA = 40, PMA = 40, GA = 40, SEX = 1, SEXF = 0, MALE = 1, HT = 170, HEIGHT = 170,
  CRCL = 90, CLCR = 90, EGFR = 90, GFR = 90, SCR = 80, CREAT = 80, CREATININE = 80, CREAT_REF = 80,
  CRP = 5, ALB = 40, ALBUMIN = 40, HCT = 0.40, HGB = 14, HB = 14,
  AST = 25, ALT = 25, BILI = 10, TBIL = 10, GGT = 30, ALP = 80,
  # Common continuous covariates (typical adult values) so more literature models
  # can simulate a sensible reference profile without per-model tuning.
  TUMSLD = 50, TUM_SLD = 50, SLD = 50, TUMSIZE = 50, TUMSZ = 50, TS = 50, BTUMSLD = 50,
  PAGE = 40, PNAGE = 40, GAGE = 40, POSTMENSTRUAL_AGE = 40,
  WBC = 7, EOS = 0.2, NEUT = 4, PLT = 250, LYMPH = 2, ANC = 4,
  IGE = 100, IGG = 10, IGA = 2, IGM = 1, BSCMA = 50, SBCMA = 50,
  BMI = 25, FEV1 = 3, FEV1_PCTPRED = 80, FVC = 4,
  TRIG = 1.5, LDL = 3, HDL = 1.2, CHOL = 5, TCHOL = 5, GLUC = 5, HBA1C = 6,
  FERRITIN = 100, NTPROBNP = 100, BNP = 100, SAPS = 40, SAPS_II = 40, APACHE = 15,
  TBILI = 10, DBILI = 3, BUN = 5, UREA = 5, B2M = 2, LDH = 200, SOD = 140, NA_ION = 140,
  BODYTEMP = 37, TEMP = 37, EASI = 20, CALPRO = 100, PARA = 10000, MAYO = 1,
  WT_BIRTH = 3.3, BWT_BIRTH = 3.3, BIRTHWT = 3.3,
  CYP3A5_EXPR = 0, DONOR_DECEASED = 1, IMMUNOASSAY = 0, ORG_FAIL_COUNT = 0,
  DOSE = 100, AMT = 100
)

# Upper bound (hours) on a plausible terminal half-life for the benchmark. Models
# with an endogenous baseline / zero-order production (e.g. albumin, immunoglobulin,
# endogenous epinephrine) never decline to zero, so the probe fits a ~flat terminal
# slope and reports an astronomically large t1/2. Such profiles violate NCA's
# elimination assumption and are excluded. 4380 h = ~6 months comfortably admits
# long-acting biologics (e.g. nirsevimab ~70-90 d) while rejecting non-eliminating ones.
LIBRARY_MAX_HALF_LIFE_H <- 4380

# A model whose no-dose baseline concentration exceeds this fraction of the dosed
# Cmax is treated as having an endogenous baseline (production / non-zero initial
# condition) -- the profile never returns to zero, so there is no clean terminal
# phase for NCA, and the model is excluded.
LIBRARY_BASELINE_MAX_FRAC <- 0.02

# A model whose dose-proportionality ratio departs from 1 by more than this is
# treated as nonlinear (TMDD / Michaelis-Menten / target-mediated) and excluded:
# NCA and the macro-constant terminal half-life both assume linear disposition.
# Linear controls measure ~1.00-1.09; nonlinear models measure >=1.7.
LIBRARY_LINEARITY_TOL <- 0.25

# Covariate-name patterns (case-insensitive) treated as categorical/indicator
# variables, defaulted to 0 = the model's REFERENCE category (the literature-
# faithful "typical patient" choice). Conservative on purpose: it must never match
# a continuous covariate, since zeroing a power/ratio covariate would zero a
# clearance/volume term. Indicators only ever enter multiplicatively/additively.
LIBRARY_CATEGORICAL_COV_PATTERN <- paste0(
  # Prefixes: study/disease/treatment/genotype/concomitant-med/visit indicators.
  "^(DIS|STUDY|COMBO|RACE|ETHNIC|TUMTP|TUMTYPE|SNP|GENO|ALLELE|ARM|TRT|TREAT|COADMIN|CONMED|",
  "FORM|FORMULATION|REGIMEN|COHORT|GROUP|PRIOR|FED|FAST|SMOK|SEX|REGION|COUNTRY|SITE|INDIC|",
  "ROUTE|OCC|SEASON|PHASE|MONTH|CYCLE|VISIT|PERIOD|WEEK|SAMPLE|HSCT|DIAL|PREG|DIAB|MAYO|",
  "HEPIMP|RENIMP|LIVIMP|NIVO|IPI|LINE|MORTRISK|CLD|SARS|NONECZ|BGENE|MAL_|MIL_|HCT_COND|",
  "CYP|UGT|SLCO|SLC[0-9]|ABCB|ABCG|NAT|ALDH|ADH[0-9]|GST|TPMT|DPYD|HLA|SULT|POR_|VKORC|COMT)",
  # Suffixes: genotype phenotypes, severity tertiles, occasion/route/titer indicators.
  "|_(POS|NEG|YN|FLAG|STATUS|PED|MALE|FEMALE|GE[0-9]+|LT[0-9]+|IM|SM|EM|NM|UM|RM|PM|HET|HOM|",
  "MUT|WTYPE|CARRIER|INH|IND|SLOW|FAST|RAPID|POOR|INTERMEDIATE|EXTENSIVE|HIGH|LOW|MILD|MOD|",
  "MODERATE|SEVERE|MONO|PREM|TITER|COND|RIC|URD|1L|2L|Q3W|Q2W|3Q3W|STER|MTX|CHEMO|RITUX|H2RA)$",
  "|^DOSE_[A-Z0-9]*MG$|^DAY[0-9]+$|^WK[0-9]+$|^VISIT[0-9]+$|^MONTH[0-9]+$|^CYCLE[0-9]*$",
  "|^(MALE|FEMALE|ADOLESCENT|CHILD|INFANT|NEONATE|PEDIATRIC|ADULT|ELDERLY|SMOKER|FED|FASTED|",
  "HEALTHY|ADA|ADAPOS|CIRRHOSIS|DIABETIC|OBESE|OCC|PREG|DIAL|SEASON2|PHASE2)$",
  "|_(HEALTHY|CANCER|PSORIASIS|DLBCL|MCL|BCL|NIGG|NSCLC|ACS|HEFH|DECEASED|COINF|NAIVE|YES|NO|",
  "CD|UC|IBD|STATIN|STER|MONO|3OF8|7OF8|8OF8)$"
)

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------

#' Return the nlmixr2lib model catalog (data.frame, unfiltered).
get_nlmixr2lib_catalog <- function() {
  md <- tryCatch(get("modeldb", envir = asNamespace("nlmixr2lib")),
                 error = function(e) NULL)
  if (is.null(md)) {
    e2 <- new.env()
    tryCatch(utils::data("modeldb", package = "nlmixr2lib", envir = e2),
             error = function(e) NULL)
    md <- e2$modeldb
  }
  if (is.null(md) || !is.data.frame(md)) {
    stop("Could not read the nlmixr2lib model catalog (modeldb).")
  }
  md
}

.library_valid_names <- function() {
  md <- tryCatch(get_nlmixr2lib_catalog(), error = function(e) NULL)
  if (is.null(md)) character(0) else as.character(md$name)
}

#' Load a named model and compile it to an rxUi object.
load_library_model <- function(model_name) {
  fn <- tryCatch(nlmixr2lib::modellib(name = model_name), error = function(e) NULL)
  if (is.null(fn)) {
    valid <- .library_valid_names()
    near  <- valid[grepl(model_name, valid, ignore.case = TRUE)]
    hint  <- if (length(near)) paste(utils::head(near, 12), collapse = ", ")
             else paste(utils::head(valid, 24), collapse = ", ")
    stop(sprintf("model_name '%s' not found in nlmixr2lib (%d models). Try mode=list. Similar/available: %s",
                 model_name, length(valid), hint))
  }
  tryCatch(rxode2::rxode2(fn),
           error = function(e) stop(sprintf("Failed to compile model '%s': %s",
                                            model_name, conditionMessage(e))))
}

# ---------------------------------------------------------------------------
# Native units (read from the model source file)
# ---------------------------------------------------------------------------

#' Conversion factor from a native time unit to hours.
#' Generic-template placeholder ("time_unit") and unknown units default to 1.
time_to_hours_factor <- function(u) {
  if (is.null(u) || length(u) == 0 || is.na(u) || !nzchar(u)) return(1)
  switch(tolower(trimws(u)),
    "day" = 24, "days" = 24, "d" = 24,
    "week" = 168, "weeks" = 168, "wk" = 168,
    "minute" = 1/60, "minutes" = 1/60, "min" = 1/60,
    "hour" = 1, "hours" = 1, "h" = 1, "hr" = 1,
    1)
}

#' Read the native units list from a library model's source file.
#' nlmixr2lib model files carry `units <- list(time=..., dosing=..., concentration=...)`.
#' Placeholder tokens used by the generic templates ("time_unit",
#' "conc_unit/vol_unit") are returned as NA so callers fall back to defaults.
#' @param model_name character model name (matched against the catalog `filename`)
#' @return list(time, dosing, concentration); fields NA when not found.
extract_model_units <- function(model_name) {
  out <- list(time = NA_character_, dosing = NA_character_, concentration = NA_character_)
  md  <- tryCatch(get_nlmixr2lib_catalog(), error = function(e) NULL)
  if (is.null(md) || !("filename" %in% names(md))) return(out)
  row <- md[md$name == model_name, , drop = FALSE]
  if (nrow(row) == 0) return(out)
  base <- system.file("modeldb", package = "nlmixr2lib")
  fn   <- file.path(base, as.character(row$filename[1]))
  if (!nzchar(base) || !file.exists(fn)) return(out)
  txt <- tryCatch(paste(readLines(fn, warn = FALSE), collapse = " "),
                  error = function(e) "")
  # Scope the search to the `units <- list(...)` call to avoid matching prose.
  ulist <- regmatches(txt, regexpr("units\\s*<-\\s*list\\([^)]*\\)", txt))
  scope <- if (length(ulist)) ulist[1] else txt
  grab <- function(key) {
    pat <- sprintf("%s\\s*=\\s*\"[^\"]+\"", key)
    m <- regmatches(scope, regexpr(pat, scope))
    if (length(m) == 0) return(NA_character_)
    sub(sprintf(".*%s\\s*=\\s*\"([^\"]+)\".*", key), "\\1", m[1])
  }
  out$time          <- grab("time")
  out$dosing        <- grab("dosing")
  out$concentration <- grab("concentration")
  if (!is.na(out$time) && out$time == "time_unit") out$time <- NA_character_
  if (!is.na(out$concentration) && grepl("unit", out$concentration)) out$concentration <- NA_character_
  out
}

# ---------------------------------------------------------------------------
# Structure / route / output detection
# ---------------------------------------------------------------------------

.ui_states <- function(ui) tryCatch(rxode2::rxState(ui), error = function(e) character(0))
.ui_lhs    <- function(ui) tryCatch(rxode2::rxLhs(ui),   error = function(e) character(0))

#' Route from compartment names: depot/absorption present -> extravascular.
detect_route <- function(ui) {
  st <- tolower(.ui_states(ui))
  if (any(grepl("depot|absorption|\\babs\\b|gut", st))) "extravascular" else "iv_bolus"
}

#' Compartment to dose into for a route (by name).
.dose_cmt <- function(ui, route) {
  st <- .ui_states(ui); stl <- tolower(st)
  if (length(st) == 0) return(NULL)
  if (route == "extravascular") {
    h <- st[grepl("depot|absorption|gut", stl)]; if (length(h)) return(h[1])
  }
  h <- st[grepl("central|^cent|plasma", stl)]; if (length(h)) return(h[1])
  st[1]
}

#' Disposition compartment count for metadata (linCmt: infer from params).
count_disposition_cmt <- function(ui) {
  pool <- tolower(c(.ui_lhs(ui), .ui_states(ui)))
  if (any(grepl("vp2|q2|^v3$|peripheral2", pool))) return(3L)
  if (any(grepl("vp|^q$|peripheral", pool)))       return(2L)
  1L
}

#' Empirical route label from a deterministic eta=0 profile, matching what the
#' simulated data actually shows. Uses Tmax (the time of maximum concentration):
#'   * **iv_bolus** when the peak is essentially at the dose (Tmax at t=0 or the
#'     first post-dose sample) and concentration then only declines;
#'   * **extravascular** when concentration starts at ~0 and rises to a LATER peak
#'     (absorption or an absorption lag).
#' This is the authoritative ROUTE for the dataset/NCA so the label always matches
#' the profile. Using Tmax (rather than the t=0 value) is robust to the rxode2
#' 'observation at the dose time reads the pre-dose value (0)' artifact for fast IV
#' drugs (e.g. landiolol, Tmax at the first post-dose sample -> iv_bolus) while a
#' real absorption/lag profile peaks later (e.g. ethambutol's 1 h lag, methylphenidate
#' Tmax 0.2 -> extravascular). The grid is in native time, so the 0.02 cutoff scales
#' with each model's timescale.
empirical_route <- function(ui, route_dose, conc_var, cov_values = NULL) {
  eta <- tryCatch(rownames(as.matrix(ui$omega)), error = function(e) NULL)
  ez  <- if (!is.null(eta) && length(eta)) stats::setNames(rep(0, length(eta)), eta) else NULL
  pp  <- c(cov_values, ez)
  dc  <- .dose_cmt(ui, route_dose)
  grid <- c(0, 0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 18, 24)
  ev <- if (!is.null(dc)) rxode2::et(rxode2::et(amt = 100, cmt = dc), time = grid)
        else rxode2::et(rxode2::et(amt = 100), time = grid)
  s <- tryCatch(as.data.frame(rxode2::rxSolve(ui, events = ev, params = pp)), error = function(e) NULL)
  if (is.null(s)) return(route_dose)
  cv <- if (conc_var %in% names(s)) conc_var else detect_conc_output(ui, names(s))
  if (!cv %in% names(s)) return(route_dose)
  x <- s[[cv]]; tt <- s$time
  xf <- replace(x, !is.finite(x), -Inf)
  if (max(xf) <= 0) return(route_dose)
  tmax <- tt[which.max(xf)]
  if (tmax <= 0.02) "iv_bolus" else "extravascular"   # peak at dose -> IV; later peak -> absorption
}

#' Detect the BSV-only concentration output column (avoids residual 'sim'/'dv').
detect_conc_output <- function(ui, sim_cols = NULL) {
  cand <- c("Cc", "Cp", "cp", "conc", "ipredSim", "ipred")
  pool <- unique(c(.ui_lhs(ui), sim_cols))
  pool <- pool[!tolower(pool) %in% c("sim", "dv", "y")]
  for (c0 in cand) if (c0 %in% pool) return(c0)
  m <- pool[grepl("^c[cp]$|conc|ipred", tolower(pool))]
  if (length(m)) return(m[1])
  if (!is.null(sim_cols) && "Cc" %in% sim_cols) return("Cc")
  "Cc"  # nlmixr2lib convention
}

# ---------------------------------------------------------------------------
# Residual (within-subject) error
# ---------------------------------------------------------------------------

#' Describe a model's residual error model from its rxUi.
#'
#' The error TYPE is read from ui$predDf$errType (always populated for a valid UI:
#' prop / add / lnorm / combinations). Best-effort proportional & additive SD values
#' are pulled from ui$iniDf$err for reporting, but note some models parameterize the
#' residual SD as a derived/route-conditional variable or use transform-both-sides
#' (e.g. lnorm), so those SDs may not surface here — the actual residual is applied by
#' rxode2's own machinery via the simulated DV column (see simulate_library_population).
#' @param ui rxUi
#' @return list(prop, add, type, has_error) — type "none" when no error model exists
extract_residual_error <- function(ui) {
  pd <- tryCatch(as.data.frame(ui$predDf), error = function(e) NULL)
  type <- "none"
  if (!is.null(pd) && "errType" %in% names(pd) && nrow(pd) > 0) {
    ets <- unique(as.character(pd$errType))
    ets <- ets[!is.na(ets) & nzchar(ets)]
    if (length(ets)) type <- paste(sort(ets), collapse = "+")
    # A log/transform-both-sides residual reports errType "add" on the log scale; surface
    # it as "lnorm" so it is not conflated with untransformed additive error.
    if ("transform" %in% names(pd)) {
      trs <- tolower(unique(as.character(pd$transform)))
      if (any(grepl("lnorm|log", trs))) type <- "lnorm"
    }
  }
  ini <- tryCatch(as.data.frame(ui$iniDf), error = function(e) NULL)
  prop <- 0; add <- 0
  if (!is.null(ini) && "err" %in% names(ini) && "est" %in% names(ini)) {
    err_rows <- ini[!is.na(ini$err), , drop = FALSE]
    for (i in seq_len(nrow(err_rows))) {
      et <- tolower(as.character(err_rows$err[i]))
      ev <- suppressWarnings(as.numeric(err_rows$est[i]))
      if (!is.finite(ev)) next
      if (grepl("prop", et))     prop <- ev
      else if (grepl("add", et)) add  <- ev
    }
  }
  list(prop = prop, add = add, type = type, has_error = type != "none")
}

#' Detect rxode2's simulated DV column (residual-inclusive), if present.
detect_dv_output <- function(sim_cols) {
  for (c0 in c("sim", "dv", "y")) if (c0 %in% sim_cols) return(c0)
  NULL
}

#' Clamp a DV vector at zero and flag genuinely below-zero draws as BLQ. A structural
#' zero (e.g. the t=0 extravascular baseline) is not flagged.
#' @return list(dv, blq) — dv clamped at 0; blq = 1L where the raw draw was < 0
clamp_dv <- function(dv) {
  blq <- as.integer(dv < 0)
  dv[dv < 0] <- 0
  list(dv = dv, blq = blq)
}

#' Default residual (proportional CV) applied when a model defines no usable error
#' model on the plasma output.
DEFAULT_RESIDUAL_PROP_CV <- 0.20

#' Apply residual error manually to an IPRED vector with a deterministic base-R RNG.
#' Combined model sd = sqrt((prop*ipred)^2 + add^2); falls back to a default
#' proportional CV when neither SD is available. Used when rxode2's own DV endpoint
#' does not perturb the plasma prediction (e.g. multi-output brain-PK models).
manual_residual <- function(ipred, prop = 0, add = 0, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  if (!(prop > 0) && !(add > 0)) prop <- DEFAULT_RESIDUAL_PROP_CV
  sd_vec <- sqrt((prop * ipred)^2 + add^2)
  clamp_dv(ipred + sd_vec * stats::rnorm(length(ipred)))
}

# ---------------------------------------------------------------------------
# Covariates
# ---------------------------------------------------------------------------

#' Resolve constant covariate values for a model from user overrides, reference
#' defaults, and a categorical->0 (reference-category) fallback. Errors only if a
#' required covariate is neither known nor recognizably categorical.
#' @param ui rxUi
#' @param user_cov named numeric (optional) user-supplied covariate values
#' @return list(values=named numeric or NULL, supplied=chr, defaulted=chr, zeroed=chr)
resolve_covariates <- function(ui, user_cov = NULL) {
  covs <- tryCatch(ui$allCovs, error = function(e) character(0))
  covs <- covs[nzchar(covs)]
  if (length(covs) == 0)
    return(list(values = NULL, supplied = character(0), defaulted = character(0), zeroed = character(0)))

  refU  <- stats::setNames(LIBRARY_REF_COVARIATES, toupper(names(LIBRARY_REF_COVARIATES)))
  userU <- if (!is.null(user_cov) && length(user_cov)) stats::setNames(as.numeric(user_cov), toupper(names(user_cov))) else numeric(0)

  vals <- numeric(0); from_user <- character(0); from_ref <- character(0)
  zeroed <- character(0); missing <- character(0)
  for (cv in covs) {
    key <- toupper(cv)
    if (key %in% names(userU))      { vals[cv] <- userU[[key]]; from_user <- c(from_user, cv) }
    else if (key %in% names(refU))  { vals[cv] <- refU[[key]];  from_ref  <- c(from_ref, cv) }
    else if (grepl(LIBRARY_CATEGORICAL_COV_PATTERN, key)) {
      vals[cv] <- 0; zeroed <- c(zeroed, cv)   # reference category
    }
    else                             missing  <- c(missing, cv)
  }
  if (length(missing)) {
    stop(sprintf(
      "Model requires covariate value(s) with no default: %s. Pass them via the 'covariates' parameter, e.g. covariates=\"%s\".",
      paste(missing, collapse = ", "),
      paste(sprintf("%s=<value>", missing), collapse = ",")))
  }
  list(values = vals, supplied = from_user, defaulted = from_ref, zeroed = zeroed)
}

# ---------------------------------------------------------------------------
# Analytical (macro-constant) terminal half-life
# ---------------------------------------------------------------------------

#' Identify the disposition macro constants from one solve's computed columns.
#' Maps heterogeneous nlmixr2lib parameter names to canonical keys. Returns a list
#' with finite-or-NA CL, VC (=V1, central), Q, VP (=V2, peripheral), KA, plus
#' rate-constant alternatives K10/K12/K21 for models parameterized in micro rates.
.extract_macro_params <- function(sim) {
  nm <- names(sim); lc <- tolower(nm)
  pick <- function(aliases) {
    i <- which(lc %in% aliases)
    if (length(i)) unname(sim[[nm[i[1]]]][1]) else NA_real_
  }
  list(
    CL  = pick(c("cl", "cl1", "clt")),
    VC  = pick(c("vc", "v1", "v", "vcentral", "vc1", "vd")),
    Q   = pick(c("q", "q1", "cld", "cld1")),
    VP  = pick(c("vp", "v2", "vperipheral", "vp1")),
    KA  = pick(c("ka", "ka1", "k01")),
    K10 = pick(c("k10", "kel", "ke", "k")),
    K12 = pick(c("k12")),
    K21 = pick(c("k21")),
    Q2  = pick(c("q2")),
    VP2 = pick(c("vp2", "v3"))
  )
}

#' Analytical terminal half-life (native time units) from disposition macro/micro
#' constants -- exact for 1- and 2-compartment linear mammillary models.
#'   1-cmt: ke = CL/V1.
#'   2-cmt: k10=CL/V1, k12=Q/V1, k21=Q/V2; beta = 1/2[(k10+k12+k21) -
#'          sqrt((k10+k12+k21)^2 - 4 k10 k21)] (terminal disposition rate).
#' Extravascular flip-flop: the terminal phase is governed by the slowest rate, so
#' the terminal rate is min(disposition rate, Ka). Accepts either CL/V/Q/V2 or the
#' micro rate constants K10/K12/K21. Returns NA when the constants are unavailable.
terminal_halflife_macro <- function(params, route = "iv_bolus") {
  g <- function(k) { v <- params[[k]]; if (is.null(v) || !is.finite(v)) NA_real_ else v }
  CL <- g("CL"); V1 <- g("VC"); Q <- g("Q"); V2 <- g("VP"); KA <- g("KA")
  K10 <- g("K10"); K12 <- g("K12"); K21 <- g("K21")

  has2 <- FALSE
  if (is.finite(CL) && is.finite(V1) && CL > 0 && V1 > 0) {
    k10 <- CL / V1
    if (is.finite(Q) && is.finite(V2) && Q > 0 && V2 > 0) { k12 <- Q / V1; k21 <- Q / V2; has2 <- TRUE }
  } else if (is.finite(K10) && K10 > 0) {
    k10 <- K10
    if (is.finite(K12) && is.finite(K21) && K12 > 0 && K21 > 0) { k12 <- K12; k21 <- K21; has2 <- TRUE }
  } else {
    return(NA_real_)
  }

  if (has2) {
    a <- k10 + k12 + k21
    disc <- a * a - 4 * k10 * k21; if (disc < 0) disc <- 0
    rate <- 0.5 * (a - sqrt(disc))          # beta, the terminal disposition rate
  } else {
    rate <- k10
  }
  if (route == "extravascular" && is.finite(KA) && KA > 0) rate <- min(rate, KA)  # flip-flop
  if (!is.finite(rate) || rate <= 0) return(NA_real_)
  log(2) / rate
}

# ---------------------------------------------------------------------------
# Typical-value probe: analytical (primary) + numerical (fallback) half-life
# ---------------------------------------------------------------------------

#' Dose-proportionality ratio: `(AUC(10x) / AUC(1x)) / 10`. Equals ~1 for a linear
#' model (NCA and the macro-constant terminal half-life both assume linearity) and
#' departs from 1 for TMDD / Michaelis-Menten / target-mediated (saturable)
#' elimination. eta=0, deterministic. Returns NA if either solve fails.
dose_proportionality_ratio <- function(ui, route, conc_var, cov_values = NULL) {
  eta_names <- tryCatch(rownames(as.matrix(ui$omega)), error = function(e) NULL)
  ez <- if (!is.null(eta_names) && length(eta_names)) stats::setNames(rep(0, length(eta_names)), eta_names) else NULL
  pp <- c(cov_values, ez); dc <- .dose_cmt(ui, route)
  grid <- sort(unique(c(0, exp(seq(log(0.1), log(2000), length.out = 60)))))
  auc <- function(D) {
    ev <- if (!is.null(dc)) rxode2::et(rxode2::et(amt = D, cmt = dc), time = grid)
          else rxode2::et(rxode2::et(amt = D), time = grid)
    s <- tryCatch(as.data.frame(rxode2::rxSolve(ui, events = ev, params = pp)), error = function(e) NULL)
    if (is.null(s)) return(NA_real_)
    cv <- if (conc_var %in% names(s)) conc_var else detect_conc_output(ui, names(s))
    if (!cv %in% names(s)) return(NA_real_)
    x <- s[[cv]]; x[!is.finite(x) | x < 0] <- 0
    sum(diff(s$time) * (utils::head(x, -1) + utils::tail(x, -1)) / 2)
  }
  a1 <- auc(100); a10 <- auc(1000)
  if (!is.finite(a1) || !is.finite(a10) || a1 <= 0) return(NA_real_)
  (a10 / a1) / 10
}

#' Detect an endogenous baseline: solve the eta=0 model with NO dose and compare the
#' baseline concentration to the dosed Cmax. A non-trivial baseline (production /
#' non-zero initial condition) means the profile never returns to zero, so there is
#' no clean terminal phase for NCA. Returns max(baseline)/Cmax (0 if no baseline).
.baseline_fraction <- function(ui, conc_var, probe_params, dosed_cmax) {
  if (!is.finite(dosed_cmax) || dosed_cmax <= 0) return(0)
  grid <- c(0, 0.05, 0.25, 1, 4, 12, 24, 48)
  s0 <- tryCatch(as.data.frame(rxode2::rxSolve(ui, events = rxode2::et(time = grid), params = probe_params)),
                 error = function(e) NULL)
  if (is.null(s0)) return(0)
  cv0 <- if (conc_var %in% names(s0)) conc_var else detect_conc_output(ui, names(s0))
  if (!cv0 %in% names(s0)) return(0)
  base <- suppressWarnings(max(abs(s0[[cv0]]), na.rm = TRUE))
  if (!is.finite(base)) return(0)
  base / dosed_cmax
}

#' Profile-validated terminal half-life: read the terminal log-linear slope off the
#' deterministic eta=0 curve. Because the eta=0 profile is the model's exact
#' solution, its terminal slope IS the true terminal rate constant -- this captures
#' flip-flop absorption, deep/3rd compartments, and odd parameterizations that
#' name-based macro-constant extraction misses, and is immune to extraction over- or
#' under-estimation. The fit is restricted to the physically meaningful, numerically
#' stable region -- post-peak, above Cmax * 1e-3, and BEFORE any negative/zero value
#' (ODE solvers can go unstable and produce negative concentrations far below Cmax,
#' which otherwise corrupt the slope) -- then the standard best-adjusted-R^2 terminal
#' fit (`fit_terminal_half_life`) is applied to that clean region.
#' @param window native-time simulation window (sized generously, ~10x the estimate)
#' @return t_half (native time units) or NA.
.profile_terminal_halflife <- function(ui, route, conc_var, probe_params, dose_cmt, window) {
  if (!is.finite(window) || window <= 0) return(NA_real_)
  grid <- sort(unique(c(0, exp(seq(log(window / 1e4), log(window), length.out = 150)))))
  ev <- if (!is.null(dose_cmt)) rxode2::et(rxode2::et(amt = 100, cmt = dose_cmt), time = grid)
        else rxode2::et(rxode2::et(amt = 100), time = grid)
  sim <- tryCatch(as.data.frame(rxode2::rxSolve(ui, events = ev, params = probe_params)),
                  error = function(e) NULL)
  if (is.null(sim)) return(NA_real_)
  cv <- if (conc_var %in% names(sim)) conc_var else detect_conc_output(ui, names(sim))
  if (!cv %in% names(sim)) return(NA_real_)
  cc <- sim[[cv]]; tt <- sim$time
  cmax <- suppressWarnings(max(cc[is.finite(cc)], na.rm = TRUE))
  if (!is.finite(cmax) || cmax <= 0) return(NA_real_)
  tmax_t <- tt[which.max(cc)]

  # End the usable region at the first post-peak non-positive / non-finite value
  # (numerical instability), so the garbage tail can't bias the slope.
  bad <- which(tt > tmax_t & (!is.finite(cc) | cc <= 0))
  end_t <- if (length(bad)) min(tt[bad]) else Inf

  # Physically meaningful, stable terminal region: post-peak, within 3 logs of Cmax.
  keep <- tt > tmax_t & tt < end_t & is.finite(cc) & cc > cmax * 1e-3
  if (sum(keep) < 4) return(NA_real_)
  fit_terminal_half_life(tt[keep], cc[keep])$t_half_h
}

#' Estimate terminal half-life + typical parameters from an eta=0 probe simulation.
#' The half-life is the profile-validated terminal: the macro-constant formula
#' (exact algebra) when it agrees with the exact eta=0 curve terminal, otherwise the
#' curve terminal itself (robust to flip-flop / deep compartments / mis-extraction).
#' Also reports the endogenous baseline fraction so callers can exclude
#' baseline-contaminated models.
#' @return list(t_half_h, t_half_macro, t_half_numeric, t_half_profile, lambda_z,
#'   r_squared, n_points, method, params, baseline_fraction)
probe_model <- function(ui, route, conc_var, cov_values = NULL, min_drop_logs = 3) {
  dose_cmt <- .dose_cmt(ui, route)
  windows  <- c(168, 840, 2520, 8760, 17520)  # 1wk,5wk,15wk,1y,2y
  best <- list(t_half_h = NA_real_, lambda_z = NA_real_, r_squared = NA_real_, n_points = 0L)
  params <- list(); dosed_cmax <- NA_real_
  # Force eta=0 (true typical value, fully deterministic) by supplying the model's
  # etas as zero. rxSolve on a UI that carries an omega otherwise draws ONE random
  # subject, which makes the probe nondeterministic and perturbs the RNG state used
  # by the subsequent population simulation.
  eta_names <- tryCatch(rownames(as.matrix(ui$omega)), error = function(e) NULL)
  eta_zero  <- if (!is.null(eta_names) && length(eta_names)) {
    stats::setNames(rep(0, length(eta_names)), eta_names)
  } else NULL
  probe_params <- c(cov_values, eta_zero)
  for (W in windows) {
    grid <- sort(unique(c(0, exp(seq(log(0.1), log(W), length.out = 48)))))
    ev <- if (!is.null(dose_cmt)) rxode2::et(amt = 100, cmt = dose_cmt) else rxode2::et(amt = 100)
    ev <- rxode2::et(ev, time = grid)
    sim <- tryCatch(as.data.frame(rxode2::rxSolve(ui, events = ev, params = probe_params)),
                    error = function(e) NULL)
    if (is.null(sim)) next
    cv <- if (conc_var %in% names(sim)) conc_var else detect_conc_output(ui, names(sim))
    if (!cv %in% names(sim)) next
    cc <- sim[[cv]]; tt <- sim$time
    pos <- is.finite(cc) & cc > 0
    if (sum(pos) < 4) next
    if (!is.finite(dosed_cmax)) dosed_cmax <- max(cc[pos])
    if (length(params) == 0) params <- .extract_macro_params(sim)
    fit <- fit_terminal_half_life(tt, cc)
    if (is.finite(fit$t_half_h)) best <- fit
    drop_logs <- log10(max(cc[pos])) - log10(min(cc[pos]))
    if (is.finite(fit$t_half_h) && drop_logs >= min_drop_logs) break
  }

  # Macro-constant half-life from the extracted parameters (exact algebra).
  t_macro <- terminal_halflife_macro(params, route)

  # Profile-validated terminal: read the exact terminal off the eta=0 curve over a
  # window sized to reach it. The largest of the two estimates ensures the terminal
  # phase is captured whether macro (flat 2-cmt) or the rough numeric (flip-flop /
  # deep cmt) is the larger; the same value places the terminal fit band.
  ests  <- c(t_macro, best$t_half_h); ests <- ests[is.finite(ests) & ests > 0]
  t_profile <- if (length(ests)) {
    .profile_terminal_halflife(ui, route, conc_var, probe_params, dose_cmt, 10 * max(ests))
  } else NA_real_

  # Use the macro value when it agrees with the profile terminal (clean linear
  # case, exact); otherwise use the profile terminal (flip-flop / deep cmt /
  # mis-extracted); fall back to the rough numeric only if both are unavailable.
  agree <- is.finite(t_macro) && is.finite(t_profile) && abs(log(t_macro / t_profile)) <= log(1.5)
  if (agree)                      { primary <- t_macro;   method <- "macro_constant" }
  else if (is.finite(t_profile))  { primary <- t_profile; method <- "profile_terminal" }
  else if (is.finite(t_macro))    { primary <- t_macro;   method <- "macro_constant" }
  else                            { primary <- best$t_half_h; method <- "terminal_slope" }

  base_frac <- .baseline_fraction(ui, conc_var, probe_params, dosed_cmax)
  # Report only the identified (finite) typical parameters.
  rep_params <- params[vapply(params, function(x) is.finite(x), logical(1))]

  list(t_half_h = primary, t_half_macro = t_macro, t_half_numeric = best$t_half_h,
       t_half_profile = t_profile, lambda_z = best$lambda_z, r_squared = best$r_squared,
       n_points = best$n_points, method = method, params = rep_params,
       baseline_fraction = base_frac)
}

# ---------------------------------------------------------------------------
# Faithful BSV-only population simulation
# ---------------------------------------------------------------------------

#' Simulate a population of the full model: between-subject variability from the
#' model's published omega, plus within-subject residual error applied on top of the
#' IPRED (see extract_residual_error/apply_residual). One rxSolve per dose group.
#' @param residual logical; when TRUE add residual error and BLQ flags (default TRUE)
#' @param resid_err optional pre-extracted list(prop, add, type); computed if NULL
#' @return long data.frame {subject_id, time, ipred, concentration(=DV), blq, dose,
#'   dose_label}; attr "used_omega", "residual_error"
simulate_library_population <- function(ui, doses, times, n_subjects, route,
                                        conc_var, cov_values = NULL, seed = NULL,
                                        dose_unit = "mg", residual = TRUE,
                                        resid_err = NULL) {
  dose_cmt   <- .dose_cmt(ui, route)
  n_subjects <- as.integer(n_subjects)
  ndose      <- length(doses)
  om         <- tryCatch(ui$omega, error = function(e) NULL)
  use_omega  <- !is.null(om) && length(om) > 0 && nrow(as.matrix(om)) > 0
  if (residual && is.null(resid_err)) resid_err <- extract_residual_error(ui)

  if (ndose > 1) {
    per <- rep(n_subjects %/% ndose, ndose)
    rem <- n_subjects - sum(per)
    if (rem > 0) per[seq_len(rem)] <- per[seq_len(rem)] + 1L
  } else {
    per <- n_subjects
  }

  all_rows <- list(); offset <- 0L
  for (g in seq_len(ndose)) {
    ng <- per[g]; if (ng < 1) next
    d  <- doses[g]
    ev <- if (!is.null(dose_cmt)) rxode2::et(amt = d, cmt = dose_cmt) else rxode2::et(amt = d)
    ev <- rxode2::et(ev, time = times)
    grp_seed <- if (!is.null(seed)) as.integer(seed) + g else NULL

    # rxSetSeed controls rxode2's internal RNG; required (alongside seed=) for
    # reproducible between-subject variability sampling.
    if (!is.null(grp_seed)) rxode2::rxSetSeed(grp_seed)
    sim <- as.data.frame(rxode2::rxSolve(
      ui, events = ev, nSub = ng, seed = grp_seed,
      params = cov_values,
      omega  = if (use_omega) om else NULL,
      cores  = 1))

    cv <- if (conc_var %in% names(sim)) conc_var else detect_conc_output(ui, names(sim))
    id_col <- intersect(c("sim.id", "id", "ID"), names(sim))
    subj_idx <- if (length(id_col)) as.integer(factor(sim[[id_col[1]]])) else rep(1L, nrow(sim))

    ipred <- sim[[cv]]
    if (residual) {
      manual_seed <- if (!is.null(grp_seed)) grp_seed + 100000L else NULL
      dv_col  <- detect_dv_output(names(sim))
      use_sim <- FALSE
      if (!is.null(dv_col) && isTRUE(resid_err$has_error)) {
        # rxode2 already simulated the DV from the model's own (possibly lnorm /
        # derived-SD / transform-both-sides) error model, seeded via rxSetSeed/seed=.
        dvraw <- sim[[dv_col]]
        # Transform-both-sides (log) error models are undefined at IPRED==0 (e.g. the
        # t=0 extravascular baseline) and return NaN/Inf there; fall back to IPRED.
        nf <- !is.finite(dvraw)
        if (any(nf)) dvraw[nf] <- ipred[nf]
        # Some models expose a `sim` endpoint that is NOT the plasma Cc (e.g. multi-
        # output brain-PK models), so Cc's DV is left unperturbed. Only trust the sim
        # column when it actually perturbed the prediction; otherwise apply manually.
        if (any(abs(dvraw - ipred) > 1e-8 * pmax(abs(ipred), 1))) {
          rr <- clamp_dv(dvraw); use_sim <- TRUE
        }
      }
      if (!use_sim) {
        # No usable error model on Cc: apply residual manually (model SDs if available,
        # else a default proportional CV), with a deterministic base-R RNG.
        rr <- manual_residual(ipred, resid_err$prop, resid_err$add, seed = manual_seed)
      }
      dv  <- rr$dv; blq <- rr$blq
      # Residual error must not manufacture drug where the structural prediction is
      # exactly zero (e.g. the extravascular predose at t=0: the central compartment is
      # empty, so C(0)=0 by construction). Additive/combined error would otherwise add
      # noise to that structural zero. Force such points back to 0 with BLQ=0 (a true
      # predose, not a censored measurement). This is a deterministic post-step that does
      # not consume the RNG stream, so all non-zero observations remain reproducible/
      # unchanged. Proportional and log-normal error already preserve zeros.
      zero_ipred <- ipred == 0
      if (any(zero_ipred)) { dv[zero_ipred] <- 0; blq[zero_ipred] <- 0L }
    } else {
      dv  <- ipred; blq <- rep(0L, length(ipred))
    }

    all_rows[[g]] <- data.frame(
      subject_id    = sprintf("SUBJ%03d", offset + subj_idx),
      time          = sim$time,
      ipred         = ipred,
      concentration = dv,
      blq           = blq,
      dose          = d,
      dose_label    = paste(d, dose_unit),
      stringsAsFactors = FALSE)
    offset <- offset + ng
  }

  out <- do.call(rbind, all_rows)
  if (is.null(out) || nrow(out) == 0) stop("Simulation produced no rows.")
  reported <- if (!residual) list(prop = 0, add = 0, type = "none")
              else if (isTRUE(resid_err$has_error)) resid_err
              else list(prop = DEFAULT_RESIDUAL_PROP_CV, add = 0, type = "prop(default)")
  attr(out, "used_omega") <- use_omega
  attr(out, "residual_error") <- reported
  out[order(out$dose, out$subject_id, out$time), ]
}

#' Deterministic typical-value (eta=0) profile at the given times, one profile per
#' dose group. Forces all model etas to zero so the result is fully reproducible
#' and noise-free (the population "typical" individual, not a mean of N).
#' @return long data.frame {subject_id="TYPICAL", time, concentration, dose, dose_label}
simulate_library_typical <- function(ui, doses, times, route, conc_var,
                                     cov_values = NULL, dose_unit = "mg") {
  dose_cmt  <- .dose_cmt(ui, route)
  eta_names <- tryCatch(rownames(as.matrix(ui$omega)), error = function(e) NULL)
  eta_zero  <- if (!is.null(eta_names) && length(eta_names))
    stats::setNames(rep(0, length(eta_names)), eta_names) else NULL
  pp <- c(cov_values, eta_zero)

  rows <- list()
  for (g in seq_along(doses)) {
    d  <- doses[g]
    ev <- if (!is.null(dose_cmt)) rxode2::et(amt = d, cmt = dose_cmt) else rxode2::et(amt = d)
    ev <- rxode2::et(ev, time = times)
    sim <- as.data.frame(rxode2::rxSolve(ui, events = ev, params = pp))
    cv  <- if (conc_var %in% names(sim)) conc_var else detect_conc_output(ui, names(sim))
    rows[[g]] <- data.frame(
      subject_id    = "TYPICAL",
      time          = sim$time,
      ipred         = sim[[cv]],
      concentration = sim[[cv]],
      blq           = 0L,
      dose          = d,
      dose_label    = paste(d, dose_unit),
      stringsAsFactors = FALSE)
  }
  out <- do.call(rbind, rows)
  if (is.null(out) || nrow(out) == 0) stop("Typical-value simulation produced no rows.")
  out[order(out$dose, out$time), ]
}
