# apis/tests/test_nca.R
# Unit tests for enhanced NCA endpoint including:
# - Route of administration
# - Dosing scenarios
# - BLQ handling
# - Business rules
# - Unit handling and conversions

library(PKNCA)

# Source dependencies for unit tests. Absolute paths: the container's working
# directory is / , so relative paths do not resolve.
source("/home/rstudio/apis/utils/constants.R")
source("/home/rstudio/apis/utils/validation.R")
source("/home/rstudio/apis/utils/units.R")
source("/home/rstudio/apis/utils/pknca_units.R")

cat("===== Enhanced NCA Endpoint Unit Tests =====\n\n")

# ========== Test 1: Ground truth NCA calculation ==========
cat("Test 1: NCA calculation ground truth validation...\n")

time <- c(0, 0.25, 0.5, 1, 2, 4, 8, 12, 24)
conc <- c(10, 9.75, 9.51, 9.05, 8.19, 6.70, 4.49, 3.01, 0.91)

df <- data.frame(time = time, conc = conc)
data_obj <- PKNCAconc(df, conc ~ time)
intervals <- data.frame(
  start = 0,
  end = 24,
  cmax = TRUE,
  tmax = TRUE,
  aucinf.obs = TRUE,
  half.life = TRUE
)
dose_df <- data.frame(time = 0, dose = 100)
dose_obj <- PKNCAdose(dose_df, dose ~ time)
pk_obj <- PKNCAdata(data.conc = data_obj, data.dose = dose_obj,
                     intervals = intervals)

result <- pk.nca(pk_obj)

# Verify all required parameters are present
required_params <- c("aucinf.obs", "cmax", "tmax", "half.life")
stopifnot(all(required_params %in% result$result$PPTESTCD))
cat("  OK All required parameters present\n")

# Ground truth values (verified with PKNCA)
truth_auc <- 100.03  # AUCinf.obs from PKNCA
truth_cmax <- 10
truth_tmax <- 0

pknca_auc <- result$result$PPORRES[result$result$PPTESTCD == "aucinf.obs"]
pknca_cmax <- result$result$PPORRES[result$result$PPTESTCD == "cmax"]
pknca_tmax <- result$result$PPORRES[result$result$PPTESTCD == "tmax"]
pknca_hl <- result$result$PPORRES[result$result$PPTESTCD == "half.life"]

stopifnot(abs(pknca_auc - truth_auc) < 0.5)  # Allow small tolerance
stopifnot(abs(pknca_cmax - truth_cmax) < 1e-8)
stopifnot(abs(pknca_tmax - truth_tmax) < 1e-8)
stopifnot(pknca_hl > 0)
cat("  OK NCA calculations match ground truth\n\n")

# ========== Test 2: Unit validation ==========
cat("Test 2: Unit validation...\n")

# Test valid units
validate_nca_units("mg", "ug/mL", "h", 70)
cat("  OK Valid units (mg, ug/mL, h) accepted\n")

validate_nca_units("mg/kg", "ng/mL", "min", 75)
cat("  OK Valid units (mg/kg, ng/mL, min) with BW accepted\n")

# Test invalid dose_unit
tryCatch({
  validate_nca_units("invalid", "ug/mL", "h", 70)
  stop("Should have failed for invalid dose_unit")
}, error = function(e) {
  stopifnot(grepl("Invalid dose_unit", e$message))
  cat("  OK Invalid dose_unit correctly rejected\n")
})

# Test invalid conc_unit
tryCatch({
  validate_nca_units("mg", "invalid", "h", 70)
  stop("Should have failed for invalid conc_unit")
}, error = function(e) {
  stopifnot(grepl("Invalid conc_unit", e$message))
  cat("  OK Invalid conc_unit correctly rejected\n")
})

# Test invalid time_unit
tryCatch({
  validate_nca_units("mg", "ug/mL", "invalid", 70)
  stop("Should have failed for invalid time_unit")
}, error = function(e) {
  stopifnot(grepl("Invalid time_unit", e$message))
  cat("  OK Invalid time_unit correctly rejected\n")
})

# Test mg/kg without BW
tryCatch({
  validate_nca_units("mg/kg", "ug/mL", "h", NULL)
  stop("Should have failed for mg/kg without BW")
}, error = function(e) {
  stopifnot(grepl("BW.*required", e$message))
  cat("  OK mg/kg without BW correctly rejected\n")
})

# Test mg/kg with invalid BW
tryCatch({
  validate_nca_units("mg/kg", "ug/mL", "h", -10)
  stop("Should have failed for negative BW")
}, error = function(e) {
  stopifnot(grepl("positive", e$message))
  cat("  OK Negative BW correctly rejected\n")
})

cat("\n")

# ========== Test 3: Time unit normalization ==========
cat("Test 3: Time unit normalization...\n")

stopifnot(normalize_time_unit("h") == "h")
stopifnot(normalize_time_unit("hr") == "h")
stopifnot(normalize_time_unit("hours") == "h")
stopifnot(normalize_time_unit("HOUR") == "h")
cat("  OK Hour variants normalized to 'h'\n")

stopifnot(normalize_time_unit("min") == "min")
stopifnot(normalize_time_unit("mins") == "min")
stopifnot(normalize_time_unit("minute") == "min")
cat("  OK Minute variants normalized to 'min'\n")

stopifnot(normalize_time_unit("d") == "d")
stopifnot(normalize_time_unit("day") == "d")
stopifnot(normalize_time_unit("days") == "d")
cat("  OK Day variants normalized to 'd'\n")

cat("\n")

# ========== Test 4: Unit derivation ==========
cat("Test 4: NCA parameter unit derivation...\n")

# Test concentration-related parameters
stopifnot(derive_param_unit("cmax", "h", "ug/mL", "mg") == "ug/mL")
stopifnot(derive_param_unit("cmin", "h", "ng/mL", "mg") == "ng/mL")
cat("  OK Concentration parameters get conc_unit\n")

# Test time-related parameters
stopifnot(derive_param_unit("tmax", "h", "ug/mL", "mg") == "h")
stopifnot(derive_param_unit("half.life", "min", "ug/mL", "mg") == "min")
cat("  OK Time parameters get time_unit\n")

# Test AUC parameters
stopifnot(derive_param_unit("auclast", "h", "ug/mL", "mg") == "h*ug/mL")
stopifnot(derive_param_unit("aucinf.obs", "min", "ng/mL", "mg") == "min*ng/mL")
cat("  OK AUC parameters get time*conc_unit\n")

# Test rate constant parameters
stopifnot(derive_param_unit("lambda.z", "h", "ug/mL", "mg") == "1/h")
stopifnot(derive_param_unit("lambda.z", "min", "ug/mL", "mg") == "1/min")
cat("  OK Rate constant parameters get 1/time_unit\n")

# Test clearance parameters - ug/mL and mg/L reduce exactly to L (ug/mL == mg/L)
stopifnot(derive_param_unit("cl.obs", "h", "ug/mL", "mg") == "L/h")
stopifnot(derive_param_unit("cl.pred", "min", "ug/mL", "mg") == "L/min")
stopifnot(derive_param_unit("cl.obs", "h", "mg/L", "mg") == "L/h")
cat("  OK Clearance parameters reduce to L/time_unit\n")

# Test volume parameters
stopifnot(derive_param_unit("vz.obs", "h", "ug/mL", "mg") == "L")
stopifnot(derive_param_unit("vss.obs", "h", "ug/mL", "mg") == "L")
cat("  OK Volume parameters reduce to L\n")

# mg/kg is converted to an effective mg dose before PKNCA, so it reduces too
stopifnot(derive_param_unit("cl.obs", "h", "ug/mL", "mg/kg") == "L/h")
stopifnot(derive_param_unit("vz.obs", "h", "ug/mL", "mg/kg") == "L")
cat("  OK mg/kg dosing reduces like mg\n")

# Concentration units with no exact reduction keep the composite label
stopifnot(derive_param_unit("cl.obs", "h", "ng/mL", "mg") == "mg/(h*ng/mL)")
stopifnot(derive_param_unit("vz.obs", "h", "ng/mL", "mg") == "mg/ng/mL")
stopifnot(derive_param_unit("vz.obs", "h", "g/L", "mg") == "mg/g/L")
stopifnot(derive_param_unit("cl.obs", "h", "umol/L", "mg") == "mg/(h*umol/L)")
stopifnot(derive_param_unit("vz.obs", "h", "nmol/L", "mg") == "mg/nmol/L")
cat("  OK Non-reducible concentration units keep the composite label\n")

# Test percent extrapolation
stopifnot(derive_param_unit("pext.obs", "h", "ug/mL", "mg") == "%")
cat("  OK Percent extrapolation parameters get %%\n")

# Test dimensionless parameters
stopifnot(is.null(derive_param_unit("r.squared", "h", "ug/mL", "mg")))
cat("  OK Dimensionless parameters return NULL\n")

cat("\n")

# ========== Test 5: Effective dose calculation ==========
cat("Test 5: Effective dose calculation (mg/kg conversion)...\n")

# Standard mg dose - no conversion
stopifnot(calculate_effective_dose(100, "mg", 70) == 100)
cat("  OK mg dose unchanged (100 mg -> 100 mg)\n")

# mg/kg dose - multiply by BW
stopifnot(calculate_effective_dose(1.5, "mg/kg", 70) == 105)
cat("  OK mg/kg dose converted (1.5 mg/kg * 70 kg = 105 mg)\n")

stopifnot(calculate_effective_dose(2, "mg/kg", 80) == 160)
cat("  OK mg/kg dose converted (2 mg/kg * 80 kg = 160 mg)\n")

cat("\n")

# ========== Test 6: format_value_unit ==========
cat("Test 6: Value/unit formatting...\n")

result <- format_value_unit(10.5, "ug/mL")
stopifnot(result$value == 10.5)
stopifnot(result$unit == "ug/mL")
cat("  OK format_value_unit creates correct structure\n")

result <- format_value_unit(NA, "h")
stopifnot(is.na(result$value))
stopifnot(result$unit == "h")
cat("  OK format_value_unit handles NA values\n")

cat("\n")

# ========== Test 7: Route validation ==========
cat("Test 7: Route of administration validation...\n")

# Test valid routes
validate_route("iv_bolus", NULL)
cat("  OK iv_bolus route accepted\n")

validate_route("extravascular", NULL)
cat("  OK extravascular route accepted\n")

validate_route("iv_infusion", 1.0)
cat("  OK iv_infusion with duration accepted\n")

# Test invalid route
tryCatch({
  validate_route("invalid_route", NULL)
  stop("Should have failed for invalid route")
}, error = function(e) {
  stopifnot(grepl("Invalid route", e$message))
  cat("  OK Invalid route correctly rejected\n")
})

# Test iv_infusion without duration
tryCatch({
  validate_route("iv_infusion", NULL)
  stop("Should have failed for iv_infusion without duration")
}, error = function(e) {
  stopifnot(grepl("infusion_duration.*required", e$message))
  cat("  OK iv_infusion without duration correctly rejected\n")
})

# Test iv_infusion with invalid duration
tryCatch({
  validate_route("iv_infusion", -1)
  stop("Should have failed for negative duration")
}, error = function(e) {
  stopifnot(grepl("positive", e$message))
  cat("  OK Negative infusion duration correctly rejected\n")
})

cat("\n")

# ========== Test 8: Dosing scenario validation ==========
cat("Test 8: Dosing scenario validation...\n")

# Test valid scenarios
validate_dosing_scenario("single", NULL)
cat("  OK single scenario accepted\n")

validate_dosing_scenario("repeat", 24)
cat("  OK repeat scenario with tau accepted\n")

validate_dosing_scenario("steady_state", 12)
cat("  OK steady_state scenario with tau accepted\n")

# Test invalid scenario
tryCatch({
  validate_dosing_scenario("invalid", NULL)
  stop("Should have failed for invalid scenario")
}, error = function(e) {
  stopifnot(grepl("Invalid dosing_scenario", e$message))
  cat("  OK Invalid dosing_scenario correctly rejected\n")
})

# Test repeat without tau
tryCatch({
  validate_dosing_scenario("repeat", NULL)
  stop("Should have failed for repeat without tau")
}, error = function(e) {
  stopifnot(grepl("tau.*required", e$message))
  cat("  OK repeat without tau correctly rejected\n")
})

# Test steady_state without tau
tryCatch({
  validate_dosing_scenario("steady_state", NULL)
  stop("Should have failed for steady_state without tau")
}, error = function(e) {
  stopifnot(grepl("tau.*required", e$message))
  cat("  OK steady_state without tau correctly rejected\n")
})

cat("\n")

# ========== Test 9: BLQ handling validation ==========
cat("Test 9: BLQ handling validation...\n")

# Test valid BLQ options
validate_blq_handling("keep", "drop", "keep")
cat("  OK Valid BLQ handling (keep, drop, keep) accepted\n")

validate_blq_handling("zero", "zero", "zero")
cat("  OK Valid BLQ handling (zero, zero, zero) accepted\n")

validate_blq_handling("drop", "drop", "drop")
cat("  OK Valid BLQ handling (drop, drop, drop) accepted\n")

# Test invalid BLQ options
tryCatch({
  validate_blq_handling("invalid", "drop", "keep")
  stop("Should have failed for invalid blq_first")
}, error = function(e) {
  stopifnot(grepl("Invalid blq_first", e$message))
  cat("  OK Invalid blq_first correctly rejected\n")
})

tryCatch({
  validate_blq_handling("keep", "invalid", "keep")
  stop("Should have failed for invalid blq_middle")
}, error = function(e) {
  stopifnot(grepl("Invalid blq_middle", e$message))
  cat("  OK Invalid blq_middle correctly rejected\n")
})

tryCatch({
  validate_blq_handling("keep", "drop", "invalid")
  stop("Should have failed for invalid blq_last")
}, error = function(e) {
  stopifnot(grepl("Invalid blq_last", e$message))
  cat("  OK Invalid blq_last correctly rejected\n")
})

cat("\n")

# ========== Test 10: Business rules validation ==========
cat("Test 10: Business rules validation...\n")

# Test valid business rules
validate_business_rules("lin up/log down", 3, 0.9, 20, TRUE)
cat("  OK Valid business rules (default) accepted\n")

validate_business_rules("linear", 4, 0.95, 15, FALSE)
cat("  OK Valid business rules (custom) accepted\n")

# Test invalid AUC method
tryCatch({
  validate_business_rules("invalid_method", 3, 0.9, 20, TRUE)
  stop("Should have failed for invalid auc_method")
}, error = function(e) {
  stopifnot(grepl("Invalid auc_method", e$message))
  cat("  OK Invalid auc_method correctly rejected\n")
})

# Test invalid min_hl_points
tryCatch({
  validate_business_rules("linear", 1, 0.9, 20, TRUE)
  stop("Should have failed for min_hl_points < 2")
}, error = function(e) {
  stopifnot(grepl("min_hl_points must be >= 2", e$message))
  cat("  OK min_hl_points < 2 correctly rejected\n")
})

# Test invalid min_hl_r_squared
tryCatch({
  validate_business_rules("linear", 3, 1.5, 20, TRUE)
  stop("Should have failed for min_hl_r_squared > 1")
}, error = function(e) {
  stopifnot(grepl("min_hl_r_squared must be between 0 and 1", e$message))
  cat("  OK min_hl_r_squared > 1 correctly rejected\n")
})

# Test invalid max_aucinf_pext
tryCatch({
  validate_business_rules("linear", 3, 0.9, 150, TRUE)
  stop("Should have failed for max_aucinf_pext > 100")
}, error = function(e) {
  stopifnot(grepl("max_aucinf_pext must be between 0 and 100", e$message))
  cat("  OK max_aucinf_pext > 100 correctly rejected\n")
})

cat("\n")

# ========== Test 11: Preferred units validation ==========
cat("Test 11: Preferred output units validation...\n")

# Test valid preferred units
validate_preferred_units("ng/mL", NULL)
cat("  OK Valid conc_unit_out accepted\n")

validate_preferred_units(NULL, "min")
cat("  OK Valid time_unit_out accepted\n")

validate_preferred_units("mg/L", "d")
cat("  OK Valid both output units accepted\n")

# Test invalid preferred concentration unit
tryCatch({
  validate_preferred_units("invalid_conc", NULL)
  stop("Should have failed for invalid conc_unit_out")
}, error = function(e) {
  stopifnot(grepl("Invalid conc_unit_out", e$message))
  cat("  OK Invalid conc_unit_out correctly rejected\n")
})

# Test invalid preferred time unit
tryCatch({
  validate_preferred_units(NULL, "invalid_time")
  stop("Should have failed for invalid time_unit_out")
}, error = function(e) {
  stopifnot(grepl("Invalid time_unit_out", e$message))
  cat("  OK Invalid time_unit_out correctly rejected\n")
})

cat("\n")

# ========== Test 12: Route mapping ==========
cat("Test 12: Route mapping to PKNCA format...\n")

stopifnot(map_route_to_pknca("iv_bolus") == "intravascular")
cat("  OK iv_bolus maps to intravascular\n")

stopifnot(map_route_to_pknca("iv_infusion") == "intravascular")
cat("  OK iv_infusion maps to intravascular\n")

stopifnot(map_route_to_pknca("extravascular") == "extravascular")
cat("  OK extravascular maps to extravascular\n")

stopifnot(map_route_to_pknca("unknown") == "extravascular")
cat("  OK Unknown route defaults to extravascular\n")

cat("\n")

# ========== Test 13: Interval creation ==========
cat("Test 13: NCA interval creation...\n")

# Test single dose interval
t_single <- c(0, 1, 2, 4, 8, 12, 24)
intervals_single <- create_nca_intervals(t_single, "single", NULL, NULL, "ext")
stopifnot(nrow(intervals_single) == 1)
stopifnot(intervals_single$start == 0)
stopifnot(intervals_single$end == 24)
stopifnot(intervals_single$cmax == TRUE)
stopifnot(intervals_single$auclast == TRUE)
cat("  OK Single dose interval created correctly\n")

# Test repeat dose intervals
t_repeat <- c(0, 1, 2, 4, 8, 12, 24, 25, 26, 28, 32, 36, 48)
intervals_repeat <- create_nca_intervals(t_repeat, "repeat", 24, NULL, "ext")
stopifnot(nrow(intervals_repeat) == 2)  # Two 24-hour intervals
stopifnot(intervals_repeat$start[1] == 0)
stopifnot(intervals_repeat$end[1] == 24)
stopifnot(intervals_repeat$start[2] == 24)
stopifnot(intervals_repeat$end[2] == 48)
cat("  OK Repeat dose intervals created correctly\n")

# Test steady state interval
intervals_ss <- create_nca_intervals(t_single, "steady_state", 24, NULL, "ext")
stopifnot(nrow(intervals_ss) == 1)
stopifnot(intervals_ss$start == 0)
stopifnot(intervals_ss$end == 24)  # tau
stopifnot("cav" %in% names(intervals_ss))  # SS-specific param
cat("  OK Steady state interval created correctly\n")

cat("\n")

# ========== Test 14: PKNCA options ==========
cat("Test 14: PKNCA options setting...\n")

# Set custom options
set_pknca_options(
  auc_method = "linear",
  min_hl_points = 4,
  min_hl_r_squared = 0.95,
  max_aucinf_pext = 15,
  first_tmax = FALSE,
  blq_first = "drop",
  blq_middle = "zero",
  blq_last = "drop"
)
cat("  OK Custom PKNCA options set successfully\n")

# Reset to defaults
reset_pknca_options()
cat("  OK PKNCA options reset to defaults\n")

cat("\n")

# ========== Test 15: Analysis settings helper ==========
cat("Test 15: Analysis settings helper...\n")

settings <- get_analysis_settings(
  route = "iv_bolus",
  dosing_scenario = "single",
  auc_method = "lin up/log down",
  blq_first = "keep",
  blq_middle = "drop",
  blq_last = "keep",
  min_hl_points = 3,
  min_hl_r_squared = 0.9,
  max_aucinf_pext = 20
)

stopifnot(settings$route == "iv_bolus")
stopifnot(settings$dosing_scenario == "single")
stopifnot(settings$auc_method == "lin up/log down")
stopifnot(settings$blq_handling$first == "keep")
stopifnot(settings$blq_handling$middle == "drop")
stopifnot(settings$blq_handling$last == "keep")
stopifnot(settings$min_hl_points == 3)
stopifnot(settings$min_hl_r_squared == 0.9)
stopifnot(settings$max_aucinf_pext == 20)
cat("  OK Analysis settings helper returns correct structure\n")

cat("\n")

# ========== Test 16: parse_boolean helper ==========
cat("Test 16: Boolean parsing...\n")

stopifnot(parse_boolean("true", FALSE) == TRUE)
stopifnot(parse_boolean("TRUE", FALSE) == TRUE)
stopifnot(parse_boolean("yes", FALSE) == TRUE)
stopifnot(parse_boolean("1", FALSE) == TRUE)
cat("  OK True values parsed correctly\n")

stopifnot(parse_boolean("false", TRUE) == FALSE)
stopifnot(parse_boolean("FALSE", TRUE) == FALSE)
stopifnot(parse_boolean("no", TRUE) == FALSE)
stopifnot(parse_boolean("0", TRUE) == FALSE)
cat("  OK False values parsed correctly\n")

stopifnot(parse_boolean(NULL, TRUE) == TRUE)
stopifnot(parse_boolean(NULL, FALSE) == FALSE)
stopifnot(parse_boolean("", TRUE) == TRUE)
cat("  OK Default values used for NULL/empty\n")

stopifnot(parse_boolean(TRUE, FALSE) == TRUE)
stopifnot(parse_boolean(FALSE, TRUE) == FALSE)
cat("  OK Logical values pass through correctly\n")

cat("\n")

# ========== Summary ==========
cat("===== All enhanced NCA unit tests passed! =====\n")
