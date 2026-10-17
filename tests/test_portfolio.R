# Tests for R/07_portfolio.R.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)
source(file.path("..", "R", "06_backtest.R"), chdir = TRUE)
source(file.path("..", "R", "07_portfolio.R"), chdir = TRUE)

test_that("inverse-vol weights give equal risk and hit the target", {
  vols <- c(0.10, 0.20)
  corr <- diag(2)                                   # uncorrelated
  w <- portfolio_weights(vols, corr, target = 0.10, cap = 2)
  expect_equal(w[1] * vols[1], w[2] * vols[2])      # same standalone risk
  expect_equal(sqrt(sum((w * vols)^2)), 0.10)       # portfolio vol = target
})

test_that("total exposure is capped", {
  w <- portfolio_weights(c(0.01, 0.01), diag(2), target = 0.10, cap = 2)
  expect_equal(sum(w), 2)
})

test_that("with one asset, the portfolio simulator matches the single-asset one", {
  set.seed(16)
  r <- rnorm(40, 0, 0.01)
  d <- runif(40, 0.5, 1.5)
  single <- simulate_strategy(r, d, rebalance_every = 5, band = 0.1, cost_bp = 5)
  multi  <- simulate_portfolio(matrix(r), matrix(d), rebalance_every = 5, band = 0.1, cost_bp = 5)
  expect_equal(multi$ret, single$ret)
  expect_equal(multi$gross, single$weight)
})

test_that("each weight drifts with its own asset", {
  r <- rbind(c(0, 0), c(0.10, -0.10))
  sim <- simulate_portfolio(r, rbind(c(0.5, 0.5), c(NA, NA)),
                            rebalance_every = 1, band = 0, cost_bp = 0)
  expect_equal(sim$ret[2], 0)                       # +5% and -5% cancel out
  expect_equal(sim$gross[2], (0.55 + 0.45) / 1)
})

test_that("the correlation at t only uses returns up to t", {
  set.seed(17)
  x <- matrix(rnorm(600), 300, 2)
  base <- trailing_corr(x, 200, window = 100)
  x[201:300, ] <- 0                                 # change the future
  expect_equal(trailing_corr(x, 200, window = 100), base)
})
