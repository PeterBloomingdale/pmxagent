# utils/constants.R
# Configuration constants for PMxAgent R API

# Plot settings
PLOT_WIDTH <- 6
PLOT_HEIGHT <- 4
PLOT_DPI <- 300
FIGURES_DIR <- "/figures"

# ER Gold Standard Plot Dimensions (two-panel layout)
ER_PLOT_WIDTH <- 8
ER_PLOT_HEIGHT <- 6
ER_TOP_PANEL_RATIO <- 2    # Top panel height ratio (2:1 as per gold standard)
ER_BOTTOM_PANEL_RATIO <- 1 # Bottom panel height ratio

# ER Plot Jitter Settings (for binary response)
ER_JITTER_AMOUNT <- 0.05   # Vertical jitter amount for binary data points (matches geom_jitter height)

# Default units
DEFAULT_TIME_UNIT <- "auto"        # Display unit (auto-select based on range)
DEFAULT_CONC_UNIT <- "ug/mL"       # Concentration unit
DEFAULT_AUC_UNIT <- "h*ug/mL"      # AUC unit (for exposure)

# ER model fitting bounds (multipliers for calculating search bounds)
ER_IC50_LOWER_MULTIPLIER <- 0.01
ER_IC50_UPPER_MULTIPLIER <- 3.0
ER_E0_LOWER_MULTIPLIER <- 0.0
ER_E0_UPPER_MULTIPLIER <- 3.0
ER_EMAX_LOWER_MULTIPLIER <- 0.0
ER_EMAX_UPPER_MULTIPLIER <- 3.0

# Default values
DEFAULT_DOSE <- 1.0
DEFAULT_BW <- 70  # Body weight in kg

# Case study configuration
CASE_STUDY_DOSES <- c(10, 30, 100)  # Standard dose levels in mg
RESPONSE_PROB <- list(
  "10 mg" = 0.10,   # 10% response at 10 mg
  "30 mg" = 0.50,   # 50% response at 30 mg
  "100 mg" = 0.90   # 90% response at 100 mg
)

# Security limits
MAX_DATA_POINTS <- 10000
MAX_SUBJECTS <- 5000  # Maximum number of subjects for multi-subject endpoints

# NCA Unit Settings
DEFAULT_DOSE_UNIT <- "mg"           # Dose unit for NCA
DEFAULT_TIME_UNIT_NCA <- "h"        # Time unit for NCA input data
VALID_DOSE_UNITS <- c("mg", "mg/kg")
VALID_CONC_UNITS <- c("ug/mL", "ng/mL", "mg/L", "g/L", "umol/L", "nmol/L")
VALID_TIME_UNITS <- c("h", "min", "d")

# Enhanced NCA - Route of Administration
VALID_ROUTES <- c("iv_bolus", "iv_infusion", "extravascular")
DEFAULT_ROUTE <- "extravascular"

# Enhanced NCA - Dosing Scenarios
VALID_DOSING_SCENARIOS <- c("single", "repeat", "steady_state")
DEFAULT_DOSING_SCENARIO <- "single"

# Enhanced NCA - AUC Calculation Methods
VALID_AUC_METHODS <- c("lin up/log down", "linear", "lin-log")
DEFAULT_AUC_METHOD <- "lin up/log down"

# Enhanced NCA - BLQ Handling Options
VALID_BLQ_OPTIONS <- c("keep", "drop", "zero")
DEFAULT_BLQ_FIRST <- "keep"
DEFAULT_BLQ_MIDDLE <- "drop"
DEFAULT_BLQ_LAST <- "keep"

# Enhanced NCA - Business Rule Defaults
DEFAULT_MIN_HL_POINTS <- 3
DEFAULT_MIN_HL_R_SQUARED <- 0.9
DEFAULT_MAX_AUCINF_PEXT <- 20
DEFAULT_FIRST_TMAX <- TRUE

# PKNCA Parameter Categories
# Primary parameters (always calculated)
PKNCA_PRIMARY_PARAMS <- c("cmax", "tmax", "auclast", "half.life")

# Exposure parameters (AUC variants)
PKNCA_EXPOSURE_PARAMS <- c(
  "aucall", "aucinf.obs", "aucinf.pred", "aucint.last", "aucint.all",
  "aumclast", "aumcall", "aumcinf.obs", "aumcinf.pred"
)

# Clearance and volume parameters
# cl.f.obs / vz.f.obs are accepted aliases for extravascular apparent CL/F and Vz/F;
# they are normalised to cl.obs / vz.obs before being passed to PKNCA.
PKNCA_CL_V_PARAMS <- c(
  "cl.last", "cl.obs", "cl.pred", "cl.f.obs", "cl.f.pred",
  "vz.obs", "vz.pred", "vss.obs", "vss.pred", "vd.last",
  "vz.f.obs", "vz.f.pred"
)

# Half-life quality metrics
PKNCA_HL_QUALITY_PARAMS <- c(
  "lambda.z", "lambda.z.n.points", "r.squared", "adj.r.squared",
  "lambda.z.time.first", "span.ratio", "pext.obs", "pext.pred"
)

# MRT parameters
PKNCA_MRT_PARAMS <- c("mrt.last", "mrt.iv.last")

# Other parameters
PKNCA_OTHER_PARAMS <- c(
  "cmin", "ctrough", "cav", "tlast", "clast.obs", "c0",
  "thalf.eff", "swing", "accumulation.index", "tlag"
)

# All available PKNCA parameters (comprehensive list)
PKNCA_ALL_PARAMS <- c(
  PKNCA_PRIMARY_PARAMS,
  PKNCA_EXPOSURE_PARAMS,
  PKNCA_CL_V_PARAMS,
  PKNCA_HL_QUALITY_PARAMS,
  PKNCA_MRT_PARAMS,
  PKNCA_OTHER_PARAMS
)

# NCA parameter unit derivation rules (legacy - kept for backwards compatibility)
# Each parameter maps to a function of (time_unit, conc_unit, dose_unit)
NCA_UNIT_RULES <- list(
  # Concentration-related
  cmax = function(tu, cu, du) cu,
  cmin = function(tu, cu, du) cu,
  clast.obs = function(tu, cu, du) cu,

  # Time-related
  tmax = function(tu, cu, du) tu,
  tlag = function(tu, cu, du) tu,
  tlast = function(tu, cu, du) tu,
  "half.life" = function(tu, cu, du) tu,

  # Rate constants (1/time)
  "lambda.z" = function(tu, cu, du) paste0("1/", tu),

  # AUC-related (time*conc)
  auclast = function(tu, cu, du) paste0(tu, "*", cu),
  "aucinf.obs" = function(tu, cu, du) paste0(tu, "*", cu),
  "aucinf.pred" = function(tu, cu, du) paste0(tu, "*", cu),
  aucall = function(tu, cu, du) paste0(tu, "*", cu),

  # AUMC-related (time^2*conc)
  aumclast = function(tu, cu, du) paste0(tu, "^2*", cu),
  "aumcinf.obs" = function(tu, cu, du) paste0(tu, "^2*", cu),

  # MRT (time)
  "mrt.last" = function(tu, cu, du) tu,
  "mrt.iv.last" = function(tu, cu, du) tu,
  "mrt.md.last" = function(tu, cu, du) tu,

  # Clearance: dose_unit / (time_unit * conc_unit) — no simplification, units faithfully reflect inputs
  "cl.obs" = function(tu, cu, du) paste0(du, "/(", tu, "*", cu, ")"),
  "cl.pred" = function(tu, cu, du) paste0(du, "/(", tu, "*", cu, ")"),
  "cl.last" = function(tu, cu, du) paste0(du, "/(", tu, "*", cu, ")"),

  # Volume of distribution: dose_unit / conc_unit
  "vz.obs" = function(tu, cu, du) paste0(du, "/", cu),
  "vz.pred" = function(tu, cu, du) paste0(du, "/", cu),
  "vss.obs" = function(tu, cu, du) paste0(du, "/", cu),
  "vss.last" = function(tu, cu, du) paste0(du, "/", cu)
)
