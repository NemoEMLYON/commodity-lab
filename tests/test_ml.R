# Tests for the Lasso and random forest models of R/03_models.R.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)


# ---- Purged cross-validation ------------------------------------------------

test_that("CV folds are contiguous blocks", {
  expect_equal(cv_blocks(10, 5), c(1, 1, 2, 2, 3, 3, 4, 4, 5, 5))
})

test_that("rows next to the validation block are purged on both sides", {
  valid <- seq_len(100) %in% 41:60
  purged <- which(purge_rows(valid, horizon = 5))
  expect_equal(purged, c(36:40, 61:65))
})


# ---- Lasso ------------------------------------------------------------------

test_that("Lasso keeps the true signal and drops most noise", {
  set.seed(6)
  n <- 1500
  train <- data.frame(date = as.Date("2015-01-01") + seq_len(n),
                      matrix(rnorm(n * 10), n, 10))
  names(train)[-1] <- paste0("x", 1:10)
  train$target <- 2 * train$x1 - 1 * train$x2 + rnorm(n, 0, 0.5)

  fitted <- fit_lasso(train, paste0("x", 1:10))
  beta   <- coef(fitted$glmnet, s = fitted$lambda)[-1]
  expect_true(all(beta[1:2] != 0))
  expect_equal(beta[1], 2, tolerance = 0.1)     # slightly shrunk towards 0
  expect_lte(sum(beta[3:10] != 0), 2)
})


# ---- Random forest ----------------------------------------------------------

test_that("random forest captures a non-linear effect a line cannot", {
  set.seed(7)
  n <- 1000
  df <- data.frame(asset = "gold", x = runif(n, -1, 1))
  df$target <- ifelse(df$x > 0, 1, -1) + rnorm(n, 0, 0.1)    # a step function
  rf <- make_rf("rf", "x", pooled = FALSE, min_node_size = 5, num_trees = 100)
  fitted <- rf$fit(df)
  test <- data.frame(asset = "gold", x = c(-0.5, 0.5))
  expect_equal(rf$predict(fitted, test), c(-1, 1), tolerance = 0.1)
})

test_that("pooled forest uses the asset name as a feature", {
  set.seed(8)
  n <- 600
  df <- data.frame(asset = rep(c("gold", "oil"), each = n / 2), x = rnorm(n))
  df$target <- ifelse(df$asset == "oil", 2, 0) + rnorm(n, 0, 0.1)
  rf <- make_rf("rf", "x", pooled = TRUE, min_node_size = 5, num_trees = 100)
  fitted <- rf$fit(df)
  pred <- rf$predict(fitted, data.frame(asset = c("gold", "oil"), x = 0))
  expect_equal(pred, c(0, 2), tolerance = 0.15)
})


# ---- Engine with ML models --------------------------------------------------

test_that("pooled and Lasso models never use targets unknown at the test start", {
  features <- build_features(make_fake_raw())
  models <- list(make_lasso("lasso", FULL_FEATURES),
                 make_rf("rf", FULL_FEATURES, pooled = TRUE,
                         min_node_size = 50, num_trees = 50))
  base <- walk_forward(features, models, test_years = 2015)

  altered <- features
  late <- altered$date > base$train_end[1]
  altered$target[late] <- altered$target[late] + 1
  again <- walk_forward(altered, models, test_years = 2015)

  expect_equal(again$pred_log_vol, base$pred_log_vol)
  expect_setequal(unique(base$asset), ASSETS)        # pooled: all assets predicted
})


# ---- Extension E1: plain OLS models -------------------------------------------

test_that("OLS model recovers known coefficients", {
  set.seed(16)
  n <- 2000
  train <- data.frame(asset = "oil", har_d = rnorm(n), har_w = rnorm(n), har_m = rnorm(n),
                      log_ovx = rnorm(n), log_vix = rnorm(n))
  train$target <- 0.1 + 0.2 * train$har_m + 0.5 * train$log_ovx + rnorm(n, 0, 0.1)

  model  <- make_ols("har_x", function(a) c(HAR_COLUMNS, IMPLIED_VOL_BY_ASSET[[a]]))
  fitted <- model$fit(train)
  b <- coef(fitted$ols)
  expect_equal(unname(b["log_ovx"]), 0.5, tolerance = 0.02)
  expect_equal(unname(b["har_m"]), 0.2, tolerance = 0.02)
  expect_equal(unname(b["log_vix"]), 0, tolerance = 0.02)
  expect_equal(fitted$resid_var, 0.01, tolerance = 0.1)   # relative tolerance
  expect_equal(model$predict(fitted, train[1:3, ]), as.numeric(fitted(fitted$ols)[1:3]))
})

test_that("har_x and ols_b2_iv use each asset's own columns", {
  m <- extension_e1_models()
  cols <- function(model, asset) {
    n <- 50
    train <- data.frame(asset = asset, matrix(rnorm(n * length(FULL_FEATURES)), n))
    names(train)[-1] <- FULL_FEATURES
    train$target <- rnorm(n)
    model$fit(train)$features
  }
  expect_equal(cols(m[[1]], "oil"), c("har_d", "har_w", "har_m", "log_ovx", "log_vix"))
  expect_equal(cols(m[[1]], "copper"), c("har_d", "har_w", "har_m", "log_vix"))
  expect_equal(cols(m[[2]], "gold"), block_features("b2", "gold"))
})

test_that("OLS extensions never use targets unknown at the test start", {
  features <- build_features(make_fake_raw())
  base <- walk_forward(features, extension_e1_models(), test_years = 2015)

  altered <- features
  late <- altered$date > base$train_end[1]
  altered$target[late] <- altered$target[late] + 1
  again <- walk_forward(altered, extension_e1_models(), test_years = 2015)

  expect_equal(again$pred_log_vol, base$pred_log_vol)
  expect_setequal(unique(base$model), c("har_x", "ols_b2_iv"))
})

test_that("ols_coefficients refits on the same window as the walk-forward", {
  features <- build_features(make_fake_raw())
  model <- extension_e1_models()[[1]]
  coefs <- ols_coefficients(features, model, "oil", 2014:2015)
  pred  <- walk_forward(features, list(model), test_years = 2015)
  pred  <- pred[pred$asset == "oil", ]

  b <- coefs[coefs$test_year == 2015, ]
  test <- model_rows(features)
  test <- test[test$asset == "oil" & format(test$date, "%Y") == "2015", ]
  x <- cbind(1, as.matrix(test[, b$term[-1]]))
  expect_equal(as.numeric(x %*% b$estimate), pred$pred_log_vol)
  expect_setequal(unique(coefs$test_year), 2014:2015)
})

