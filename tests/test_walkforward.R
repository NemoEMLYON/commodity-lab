# Tests for R/04_walkforward.R: embargo, losses, Jensen correction, and a
# no-peek test on the whole engine.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)

test_that("training stops 21 trading days before the test start", {
  calendar <- as.Date("2020-01-01") + 0:99
  expect_equal(training_cutoff(calendar, calendar[50], horizon = 21), calendar[29])
})

test_that("QLIKE is zero for a perfect forecast and punishes under-prediction more", {
  expect_equal(qlike(0.04, 0.04), 0)
  expect_gt(qlike(0.04, 0.02), qlike(0.04, 0.08))   # half vs double the variance
})

test_that("the Jensen correction makes the variance forecast unbiased", {
  set.seed(4)
  mu <- log(0.2); s2 <- 0.1
  log_vol <- rnorm(1e6, mu, sqrt(s2))
  realized <- mean(exp(2 * log_vol))
  expect_equal(to_variance(mu, s2), realized, tolerance = 0.01)
  expect_lt(exp(2 * mu), 0.9 * realized)            # without it: too low
})

test_that("HAR recovers known coefficients", {
  set.seed(5)
  n <- 2000
  train <- data.frame(har_d = rnorm(n), har_w = rnorm(n), har_m = rnorm(n))
  train$target <- 0.1 + 0.2 * train$har_d + 0.3 * train$har_w + 0.4 * train$har_m +
    rnorm(n, 0, 0.01)
  fitted <- model_har$fit(train)
  expect_equal(unname(coef(fitted$ols)), c(0.1, 0.2, 0.3, 0.4), tolerance = 0.01)
})

test_that("forecasts never use targets that were unknown at the test start", {
  features <- build_features(make_fake_raw())
  year     <- 2015
  base     <- walk_forward(features, list(model_har), test_years = year)

  # Scramble every target after the training cutoff: forecasts must not move.
  cutoff   <- base$train_end[1]
  altered  <- features
  late     <- altered$date > cutoff
  altered$target[late] <- altered$target[late] + 1
  again    <- walk_forward(altered, list(model_har), test_years = year)

  expect_true(all(base$train_end < min(base$date)))
  expect_equal(again$pred_log_vol, base$pred_log_vol)
})
