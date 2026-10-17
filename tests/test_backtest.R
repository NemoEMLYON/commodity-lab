# Tests for R/06_backtest.R.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)
source(file.path("..", "R", "06_backtest.R"), chdir = TRUE)

test_that("weight = target / forecast vol, capped", {
  expect_equal(target_weight(c(0.04, 0.01, 0.0001), target = 0.10, cap = 2),
               c(0.5, 1, 2))     # vol 20% -> 0.5; 10% -> 1; 1% -> capped at 2
})

test_that("weight 1 without costs reproduces the asset (after day 1)", {
  r   <- c(0, 0.01, -0.02, 0.03)
  sim <- simulate_strategy(r, rep(1, 4), rebalance_every = 1, band = 0, cost_bp = 0)
  expect_equal(sim$ret, c(0, 0.01, -0.02, 0.03))
  expect_equal(sim$weight, rep(1, 4))
})

test_that("between trades the weight drifts with prices", {
  r   <- c(0, 0.10, 0)
  sim <- simulate_strategy(r, c(0.5, NA, NA), rebalance_every = 1, band = 0, cost_bp = 0)
  # 50 in the asset, 50 in cash; asset +10% -> 55 / 105
  expect_equal(sim$weight[2], 55 / 105)
})

test_that("each trade pays its cost", {
  sim <- simulate_strategy(c(0, 0), c(0.8, NA), rebalance_every = 1, band = 0, cost_bp = 10)
  expect_equal(sim$traded[1], 0.8)
  expect_equal(sim$ret[1], -0.8 * 10 / 1e4)
})

test_that("small changes inside the band are not traded", {
  sim <- simulate_strategy(rep(0, 3), c(1, 1.05, 1.20), rebalance_every = 1,
                           band = 0.10, cost_bp = 0)
  expect_equal(sim$traded, c(1, 0, 0.20))   # +5%: kept; +20%: traded
})

test_that("trades only happen on rebalancing days", {
  sim <- simulate_strategy(rep(0, 7), c(1, 2, 2, 2, 2, 0.5, 0.5),
                           rebalance_every = 5, band = 0, cost_bp = 0)
  expect_equal(which(sim$traded > 0), c(1, 6))
})

test_that("a decision at day t only affects returns after t", {
  set.seed(14)
  r <- rnorm(30, 0, 0.01)
  d <- rep(1, 30)
  base <- simulate_strategy(r, d, rebalance_every = 1, band = 0, cost_bp = 0)
  d[15] <- 0.3
  alt  <- simulate_strategy(r, d, rebalance_every = 1, band = 0, cost_bp = 0)
  expect_equal(alt$ret[1:15], base$ret[1:15])       # up to and including day 15
  expect_false(isTRUE(all.equal(alt$ret[16], base$ret[16])))
})

test_that("knowing the true vol, vol targeting hits the target", {
  set.seed(15)
  n     <- 252 * 20
  sigma <- rep(c(0.10, 0.40), each = 252, length.out = n)   # calm / stormy years
  r     <- rnorm(n, 0, sigma / sqrt(252))
  oracle <- simulate_strategy(r, target_weight(sigma^2, target = 0.10, cap = 10),
                              rebalance_every = 1, band = 0, cost_bp = 0)
  expect_equal(sd(oracle$ret) * sqrt(252), 0.10, tolerance = 0.05)
  expect_gt(sd(r) * sqrt(252), 0.25)                          # unmanaged
})

test_that("max drawdown is measured from the running peak", {
  m <- strategy_metrics(c(0.10, -0.50, 0.20), traded = c(0, 0, 0))
  expect_equal(m$max_dd, -0.5)
})
