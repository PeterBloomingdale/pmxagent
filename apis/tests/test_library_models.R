# apis/tests/test_library_models.R
# Unit tests for the pure /LIBRARY helpers (no nlmixr2lib/rxode2 required).
# Run in container: docker compose exec rapi Rscript /home/rstudio/apis/tests/test_library_models.R

source("/home/rstudio/apis/utils/library_utils.R")

cat("Testing /LIBRARY pure helpers...\n\n")

# ============================================================================
# Test 1: assign_tier() boundaries
# ============================================================================
cat("Test 1: assign_tier() boundary classification\n")
stopifnot(assign_tier(1)    == "tier1")   # < 24h
stopifnot(assign_tier(23.9) == "tier1")
stopifnot(assign_tier(24)   == "tier2")   # [24, 168)
stopifnot(assign_tier(167)  == "tier2")
stopifnot(assign_tier(168)  == "tier3")   # [168, 840)
stopifnot(assign_tier(839)  == "tier3")
stopifnot(assign_tier(840)  == "tier4")   # >= 840
stopifnot(assign_tier(5000) == "tier4")
stopifnot(is.na(assign_tier(0)))
stopifnot(is.na(assign_tier(-5)))
stopifnot(is.na(assign_tier(NA_real_)))
stopifnot(is.na(assign_tier(Inf)))
cat("  OK tier boundaries correct\n\n")

# ============================================================================
# Test 2: build_sampling_schedule() structure
# ============================================================================
cat("Test 2: build_sampling_schedule() structure\n")
sch <- build_sampling_schedule(12, route = "iv_bolus")
stopifnot(0 %in% sch$times)                          # includes time 0
stopifnot(abs(sch$window_h - 60) < 1e-9)             # 5 * 12
stopifnot(abs(max(sch$times) - sch$window_h) < 1e-9) # window is the last point
stopifnot(!is.unsorted(sch$times))                   # sorted ascending
stopifnot(length(sch$times) == length(unique(sch$times)))  # unique
stopifnot(length(sch$times) >= 10)                   # reasonably dense
stopifnot(sch$tier == "tier1")
# tier3: window = min(5*500, 2520) = 2500
sch3 <- build_sampling_schedule(500)
stopifnot(sch3$tier == "tier3")
stopifnot(abs(sch3$window_h - 2500) < 1e-9)
# tier4: window capped at 1 year (8760h) when 3*t_half exceeds it
sch4 <- build_sampling_schedule(5000)
stopifnot(sch4$tier == "tier4")
stopifnot(abs(sch4$window_h - 8760) < 1e-9)
stopifnot(abs(max(sch4$times) - 8760) < 1e-9)
# Invalid input errors
stopifnot(inherits(try(build_sampling_schedule(0), silent = TRUE), "try-error"))
cat("  OK schedule structure correct\n\n")

# ============================================================================
# Test 3: fit_terminal_half_life() vs analytical (mono-exponential)
# ============================================================================
cat("Test 3: fit_terminal_half_life() recovers known half-life\n")
# Mono-exponential: C = C0 * exp(-k t), t_half = ln(2)/k
k_true <- 0.0578                  # ~12 h half-life
t_half_true <- log(2) / k_true
times <- c(0, 1, 2, 4, 8, 12, 18, 24, 36, 48)
conc  <- 100 * exp(-k_true * times)
res <- fit_terminal_half_life(times, conc)
cat(sprintf("  true t_half = %.3f h, fitted = %.3f h\n", t_half_true, res$t_half_h))
stopifnot(abs(res$t_half_h - t_half_true) < 0.05)
stopifnot(res$r_squared > 0.999)
stopifnot(res$n_points >= 3)

# Bi-exponential: terminal phase governed by the slower rate (beta)
A <- 60; alpha <- 1.0; B <- 40; beta <- 0.02
t_half_beta <- log(2) / beta
tb <- c(0, 0.25, 0.5, 1, 2, 4, 8, 24, 48, 96, 168, 240)
cb <- A * exp(-alpha * tb) + B * exp(-beta * tb)
resb <- fit_terminal_half_life(tb, cb)
cat(sprintf("  true terminal t_half = %.1f h, fitted = %.1f h\n", t_half_beta, resb$t_half_h))
stopifnot(abs(resb$t_half_h - t_half_beta) / t_half_beta < 0.10)  # within 10%

# Degenerate input -> NA, no crash
stopifnot(is.na(fit_terminal_half_life(c(0, 1), c(10, 8))$t_half_h))
cat("  OK half-life fitting matches analytical\n\n")

# ============================================================================
# Test 4: categorize_from_filename()
# ============================================================================
cat("Test 4: categorize_from_filename()\n")
stopifnot(categorize_from_filename("specificDrugs/Trastuzumab.R") == "specificDrugs")
stopifnot(categorize_from_filename("pharmacokinetics/PK_1cmt.R") == "pharmacokinetics")
stopifnot(categorize_from_filename("therapeuticArea/oncology/Foo.R") == "therapeuticArea")
stopifnot(categorize_from_filename("modeldb/specificDrugs/Imatinib.R") == "specificDrugs")
stopifnot(is.na(categorize_from_filename("PK_1cmt.R")))
cat("  OK category extraction correct\n\n")

# ============================================================================
# Test 5: filter_pk_models() include / exclude / flag (real modeldb columns)
# ============================================================================
cat("Test 5: filter_pk_models() logic\n")
catalog <- data.frame(
  name = c("PK_1cmt", "PK_2cmt", "PK_3cmt", "Trastuzumab_iv",
           "Tacrolimus_oral", "Delor_2013_alzheimer", "SomeTMDD_model",
           "trastuzumab_emtansine"),
  DV   = c("Cc", "Cc", "Cc", "Cc", "Cc", "ADAS", "Cc", "Cc"),
  dosing = c("depot,central", "depot,central", "depot,central", "central",
             "depot,central", "central", "central", "central"),
  category = c("other", "other", "other", "specificDrugs",
               "specificDrugs", "therapeuticArea", "specificDrugs", "specificDrugs"),
  stringsAsFactors = FALSE
)
f <- filter_pk_models(catalog)
rownames(f) <- f$name
stopifnot(f["PK_1cmt", "included"] && f["PK_1cmt", "route"] == "extravascular")
stopifnot(f["PK_2cmt", "included"] && f["PK_2cmt", "n_cmt"] == 2)
stopifnot(f["Trastuzumab_iv", "included"] && f["Trastuzumab_iv", "route"] == "iv_bolus")
stopifnot(f["Tacrolimus_oral", "included"])
stopifnot(grepl("extravascular", f["Tacrolimus_oral", "flags"]))   # depot -> oral flagged
stopifnot(!f["PK_3cmt", "included"] && f["PK_3cmt", "exclude_reason"] == "gt_2cmt")
stopifnot(!f["Delor_2013_alzheimer", "included"])                  # DV != Cc
stopifnot(f["Delor_2013_alzheimer", "exclude_reason"] == "non_pk_output")
stopifnot(!f["SomeTMDD_model", "included"] && f["SomeTMDD_model", "exclude_reason"] == "tmdd")
stopifnot(!f["trastuzumab_emtansine", "included"] &&
          f["trastuzumab_emtansine", "exclude_reason"] == "multi_analyte")
cat("  OK filtering include/exclude/flag correct\n\n")

# ============================================================================
# Test 6: filter_pk_models() new exclusion reasons
# ============================================================================
cat("Test 6: filter_pk_models() extended exclusions (algebraic / non_human / null_route / 3cmt-desc / combination)\n")
catalog6 <- data.frame(
  name = c("Good_2020_druga", "Mbma_2015_naproxen_mbma", "Bender_2009_pregabalin_rat_binary",
           "Combo_2018_naltrexone_bupropion", "Hidden_2017_propofol3", "NoRoute_2016_xyz"),
  DV       = c("Cc", "Cc", "Cc", "Cc", "Cc", "Cc"),
  dosing   = c("central", "central", "central", "central", "central", NA),
  category = c("specificDrugs", "specificDrugs", "specificDrugs", "specificDrugs", "specificDrugs", "other"),
  algebraic = c(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE),
  description = c("Two-compartment IV model.", "MBMA Emax.", "Rat PK model.",
                 "Combination model.", "A three-compartment IV model.", "Model."),
  filename = c("specificDrugs/Good_2020_druga.R", "specificDrugs/Mbma_2015_naproxen_mbma.R",
               "specificDrugs/Bender_2009_pregabalin_rat_binary.R",
               "specificDrugs/Combo_2018_naltrexone_bupropion.R",
               "specificDrugs/Hidden_2017_propofol3.R", "other/NoRoute_2016_xyz.R"),
  stringsAsFactors = FALSE
)
f6 <- filter_pk_models(catalog6); rownames(f6) <- f6$name
stopifnot(f6["Good_2020_druga", "included"])
stopifnot(!f6["Mbma_2015_naproxen_mbma", "included"] && f6["Mbma_2015_naproxen_mbma", "exclude_reason"] == "algebraic")
stopifnot(!f6["Bender_2009_pregabalin_rat_binary", "included"] && f6["Bender_2009_pregabalin_rat_binary", "exclude_reason"] == "non_human")
stopifnot(!f6["Combo_2018_naltrexone_bupropion", "included"] && f6["Combo_2018_naltrexone_bupropion", "exclude_reason"] == "combination")
stopifnot(!f6["Hidden_2017_propofol3", "included"] && f6["Hidden_2017_propofol3", "exclude_reason"] == "gt_2cmt_desc")
stopifnot(!f6["NoRoute_2016_xyz", "included"] && f6["NoRoute_2016_xyz", "exclude_reason"] == "null_route")
cat("  OK extended exclusions correct\n\n")

# ============================================================================
# Test 7: name/description metadata parsers
# ============================================================================
cat("Test 7: parse_model_year / parse_drug_stem / n_cmt_from_description\n")
stopifnot(parse_model_year("Li_2006_meropenem") == 2006)
stopifnot(parse_model_year("Boer-Perez_2026_piperacillin") == 2026)
stopifnot(is.na(parse_model_year("PK_2cmt")))
stopifnot(parse_drug_stem("Bruno_2005_trastuzumab") == "trastuzumab")
stopifnot(parse_drug_stem("Lu_2019_tacrolimus_industry_meta") == "tacrolimus_industry_meta")
stopifnot(parse_drug_stem("Bajaj_2017_nivolumab_ddmore") == "nivolumab")
stopifnot(parse_drug_stem("PK_2cmt") == "pk_2cmt")
stopifnot(n_cmt_from_description("Two-compartment population PK model") == 2)
stopifnot(n_cmt_from_description("One compartment with first-order absorption") == 1)
stopifnot(n_cmt_from_description("A three-compartment disposition model") == 3)
stopifnot(is.na(n_cmt_from_description(NA_character_)))
cat("  OK metadata parsers correct\n\n")

# ============================================================================
# Test 8: select_benchmark_models() dedup-latest-year + route restriction + index
# ============================================================================
cat("Test 8: select_benchmark_models() selection\n")
catalog8 <- data.frame(
  name = c("Old_2010_drugx", "New_2018_drugx", "Auth_2015_drugy",
           "PK_1cmt", "PK_2cmt", "Bad_2019_drugz3"),
  DV       = rep("Cc", 6),
  dosing   = c("central", "central", "depot,central", "depot,central", "depot,central", "central"),
  category = c("specificDrugs", "specificDrugs", "specificDrugs", "other", "other", "specificDrugs"),
  algebraic = rep(FALSE, 6),
  description = c("Two-compartment IV.", "Two-compartment IV.", "One-compartment oral.",
                 "One compartment.", "Two compartment.", "Three-compartment IV."),
  filename = paste0("x/", c("Old_2010_drugx", "New_2018_drugx", "Auth_2015_drugy",
                            "PK_1cmt", "PK_2cmt", "Bad_2019_drugz3"), ".R"),
  stringsAsFactors = FALSE
)
sel <- select_benchmark_models(catalog8, dedup = TRUE)
stopifnot(!"Old_2010_drugx" %in% sel$name)          # older duplicate dropped
stopifnot("New_2018_drugx" %in% sel$name)           # latest year kept
stopifnot("Auth_2015_drugy" %in% sel$name)
stopifnot(all(c("PK_1cmt", "PK_2cmt") %in% sel$name))  # generics preserved as distinct
stopifnot(!"Bad_2019_drugz3" %in% sel$name)         # 3cmt excluded
stopifnot(all(sel$route %in% c("iv_bolus", "extravascular")))
stopifnot(identical(sort(sel$bench_index), seq_len(nrow(sel))))  # stable 1..K index
# dedup=FALSE keeps both drugx papers
sel_nd <- select_benchmark_models(catalog8, dedup = FALSE)
stopifnot(all(c("Old_2010_drugx", "New_2018_drugx") %in% sel_nd$name))
cat("  OK benchmark selection correct\n\n")

# ============================================================================
# Test 9: terminal_halflife_macro() analytical half-life (needs models/ source)
# ============================================================================
.sim_src <- "/home/rstudio/apis/models/nlmixr2lib_sim.R"
if (file.exists(.sim_src)) suppressWarnings(suppressMessages(try(source(.sim_src), silent = TRUE)))
if (exists("terminal_halflife_macro")) {
  cat("Test 9: terminal_halflife_macro() analytical formula\n")
  # 1-cmt: t_half = ln2 * V / CL
  stopifnot(abs(terminal_halflife_macro(list(CL = 2, VC = 10), "iv_bolus") - log(2) * 10 / 2) < 1e-9)
  # 2-cmt: closed-form beta root from macro constants
  k10 <- 1/10; k12 <- 2/10; k21 <- 2/20
  beta <- 0.5 * ((k10 + k12 + k21) - sqrt((k10 + k12 + k21)^2 - 4 * k10 * k21))
  stopifnot(abs(terminal_halflife_macro(list(CL = 1, VC = 10, Q = 2, VP = 20), "iv_bolus") - log(2) / beta) < 1e-9)
  # micro-constant input gives the same answer
  stopifnot(abs(terminal_halflife_macro(list(K10 = k10, K12 = k12, K21 = k21), "iv_bolus") - log(2) / beta) < 1e-9)
  # flip-flop: slow oral absorption (Ka < ke) governs the terminal phase
  stopifnot(abs(terminal_halflife_macro(list(CL = 10, VC = 10, KA = 0.1), "extravascular") - log(2) / 0.1) < 1e-9)
  # IV (no flip-flop) uses ke even when Ka present
  stopifnot(abs(terminal_halflife_macro(list(CL = 10, VC = 10, KA = 0.1), "iv_bolus") - log(2) / 1) < 1e-9)
  # missing constants -> NA
  stopifnot(is.na(terminal_halflife_macro(list(VC = 10), "iv_bolus")))
  cat("  OK macro-constant formula correct\n\n")
} else {
  cat("Test 9: SKIPPED (terminal_halflife_macro not loadable in this environment)\n\n")
}

# ============================================================================
# Test 10: library_drug_name() — drug name for the DRUG column
# ============================================================================
cat("Test 10: library_drug_name()\n")
stopifnot(library_drug_name("Li_2006_meropenem") == "meropenem")
stopifnot(library_drug_name("Bruno_2005_trastuzumab") == "trastuzumab")
stopifnot(library_drug_name("Goel_2016_Sonidegib") == "Sonidegib")          # case preserved
stopifnot(library_drug_name("Garmann_2017_BAY81_8973") == "BAY81_8973")
stopifnot(library_drug_name("Bajaj_2017_nivolumab_ddmore") == "nivolumab")  # _ddmore stripped
stopifnot(library_drug_name("PK_2cmt_no_depot") == "PK_2cmt_no_depot")      # generic unchanged
cat("  OK drug-name extraction correct\n\n")

# ============================================================================
# Test 11: normalize_route() — numeric administration codes <-> strings
# ============================================================================
.val_src <- "/home/rstudio/apis/utils/validation.R"
if (file.exists(.val_src)) suppressWarnings(suppressMessages(try(source(.val_src), silent = TRUE)))
if (exists("normalize_route")) {
  cat("Test 11: normalize_route()\n")
  stopifnot(normalize_route("1") == "iv_bolus")
  stopifnot(normalize_route("2") == "extravascular")
  stopifnot(normalize_route("3") == "iv_infusion")
  stopifnot(normalize_route(2) == "extravascular")              # numeric input
  stopifnot(normalize_route(" 1 ") == "iv_bolus")               # trimmed
  stopifnot(normalize_route("iv_bolus") == "iv_bolus")          # string passthrough
  stopifnot(normalize_route("extravascular") == "extravascular")
  stopifnot(normalize_route("garbage") == "garbage")            # unknown returned as-is (validate rejects)
  cat("  OK route normalization correct\n\n")
} else {
  cat("Test 11: SKIPPED (normalize_route not loadable)\n\n")
}

cat("All /LIBRARY pure-helper tests passed.\n")
