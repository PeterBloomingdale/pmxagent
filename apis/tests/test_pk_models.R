# apis/tests/test_pk_models.R
# Unit tests for mrgsolve PK compartment model functions

# Source the mrgsolve model functions
library(mrgsolve)
source("/home/rstudio/apis/models/mrgsolve_pk.R")

cat("Initializing mrgsolve PK models...\n")
initialize_pk_models()

cat("Testing mrgsolve PK compartment model functions...\n\n")

# ============================================================================
# Test 1: One-Compartment Model - Ground Truth Validation
# ============================================================================
cat("Test 1: One-Compartment Model Ground Truth (mrgsolve vs analytical)\n")

dose <- 100  # mg
CL <- 1      # L/hr
V1 <- 10     # L
times <- c(0, 1, 2, 4, 8, 12, 24)

# Calculate concentrations using mrgsolve
conc_mrg <- simulate_1cm(dose, CL, V1, times)

# Ground truth: C(t) = (dose/V1) * exp(-k*t), k = CL/V1
k <- CL / V1
expected_conc <- (dose / V1) * exp(-k * times)

# Validate
cat(sprintf("  k = %.3f hr^-1\n", k))
cat("  Time (hr) | mrgsolve   | Analytical | Difference\n")
cat("  ------------------------------------------------\n")
for (i in seq_along(times)) {
  diff <- abs(conc_mrg[i] - expected_conc[i])
  cat(sprintf("  %8.2f | %10.4f | %10.4f | %10.2e\n",
              times[i], conc_mrg[i], expected_conc[i], diff))
  # Allow small tolerance for ODE solver
  stopifnot(diff < 1e-4)
}
cat("-> One-compartment mrgsolve model matches analytical solution\n\n")

# ============================================================================
# Test 2: One-Compartment Model - Monotonic Decrease
# ============================================================================
cat("Test 2: One-Compartment Model Monotonic Decrease\n")

conc_test <- simulate_1cm(100, 2, 15, seq(0, 24, by = 0.5))
for (i in 2:length(conc_test)) {
  stopifnot(conc_test[i] <= conc_test[i - 1])
}
cat("-> Concentrations decrease monotonically over time\n\n")

# ============================================================================
# Test 3: Two-Compartment Model - Positive Concentrations
# ============================================================================
cat("Test 3: Two-Compartment Model Positive Concentrations\n")

dose <- 100
CL <- 1
V1 <- 10
V2 <- 20
Q <- 2
times <- c(0, 0.5, 1, 2, 4, 8, 12, 24, 48)

conc_2cm <- simulate_2cm(dose, CL, V1, V2, Q, times)

cat("  Time (hr) | Concentration\n")
cat("  --------------------------\n")
for (i in seq_along(times)) {
  cat(sprintf("  %8.2f | %13.4f\n", times[i], conc_2cm[i]))
  stopifnot(conc_2cm[i] > 0)  # All concentrations must be positive
  stopifnot(is.finite(conc_2cm[i]))  # No NaN or Inf
}
cat("-> All concentrations are positive and finite\n\n")

# ============================================================================
# Test 4: Two-Compartment Model - Parameter Relationships
# ============================================================================
cat("Test 4: Two-Compartment Model Parameter Relationships\n")

# Micro-constants
k10 <- CL / V1
k12 <- Q / V1
k21 <- Q / V2

cat(sprintf("  k10 = %.4f hr^-1 (elimination from central)\n", k10))
cat(sprintf("  k12 = %.4f hr^-1 (central to peripheral)\n", k12))
cat(sprintf("  k21 = %.4f hr^-1 (peripheral to central)\n", k21))

# Eigenvalues (lambda1 > lambda2 for stable system)
sum_k <- k10 + k12 + k21
sqrt_term <- sqrt(sum_k^2 - 4 * k21 * k10)
lambda1 <- 0.5 * (sum_k + sqrt_term)
lambda2 <- 0.5 * (sum_k - sqrt_term)

cat(sprintf("  lambda1 = %.4f hr^-1 (fast phase)\n", lambda1))
cat(sprintf("  lambda2 = %.4f hr^-1 (slow phase)\n", lambda2))

stopifnot(lambda1 > lambda2)  # Fast phase > slow phase
stopifnot(lambda1 > 0)
stopifnot(lambda2 > 0)
cat("-> Eigenvalues are physically meaningful\n\n")

# ============================================================================
# Test 5: Two-Compartment vs Analytical Solution
# ============================================================================
cat("Test 5: Two-Compartment mrgsolve vs Analytical Solution\n")

# Analytical two-compartment solution
dose <- 100
CL <- 1
V1 <- 10
V2 <- 20
Q <- 2
times <- c(0, 1, 2, 4, 8, 12, 24)

# mrgsolve solution
conc_mrg_2cm <- simulate_2cm(dose, CL, V1, V2, Q, times)

# Analytical solution
k10 <- CL / V1
k12 <- Q / V1
k21 <- Q / V2
sum_k <- k10 + k12 + k21
sqrt_term <- sqrt(sum_k^2 - 4 * k21 * k10)
lambda1 <- 0.5 * (sum_k + sqrt_term)
lambda2 <- 0.5 * (sum_k - sqrt_term)
A <- dose * (lambda1 - k21) / (V1 * (lambda1 - lambda2))
B <- dose * (k21 - lambda2) / (V1 * (lambda1 - lambda2))
conc_analytical <- A * exp(-lambda1 * times) + B * exp(-lambda2 * times)

cat("  Time (hr) | mrgsolve   | Analytical | Difference\n")
cat("  ------------------------------------------------\n")
for (i in seq_along(times)) {
  diff <- abs(conc_mrg_2cm[i] - conc_analytical[i])
  cat(sprintf("  %8.2f | %10.4f | %10.4f | %10.2e\n",
              times[i], conc_mrg_2cm[i], conc_analytical[i], diff))
  # Allow small tolerance for ODE solver
  stopifnot(diff < 1e-3)
}
cat("-> Two-compartment mrgsolve model matches analytical solution\n\n")

# ============================================================================
# Test 6: Initial Concentration Consistency
# ============================================================================
cat("Test 6: Initial Concentration (t=0)\n")

dose <- 100
V1 <- 10
expected_c0 <- dose / V1  # Should be 10 mg/L

# Test 1CM
c0_1cm <- simulate_1cm(dose, 1, V1, 0)
cat(sprintf("  1CM C(0) = %.4f (expected: %.4f)\n", c0_1cm, expected_c0))
stopifnot(abs(c0_1cm - expected_c0) < 1e-4)

# Test 2CM
c0_2cm <- simulate_2cm(dose, 1, V1, 20, 2, 0)
cat(sprintf("  2CM C(0) = %.4f (expected: %.4f)\n", c0_2cm, expected_c0))
stopifnot(abs(c0_2cm - expected_c0) < 1e-4)

cat("-> Initial concentrations match dose/V1\n\n")

# ============================================================================
# Summary
# ============================================================================
cat(paste(rep("=", 50), collapse = ""), "\n", sep = "")
cat("-> All mrgsolve PK model tests passed!\n")
cat(paste(rep("=", 50), collapse = ""), "\n", sep = "")
