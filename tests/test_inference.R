# Tests for R/05_inference.R and the asset-specific feature blocks.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)
source(file.path("..", "R", "05_inference.R"), chdir = TRUE)

# AR(1) series: autocorrelated like daily losses on overlapping targets.
ar1 <- function(n, phi, sd = 1) {
  as.numeric(stats::filter(rnorm(n, 0, sd), phi, method = "recursive"))
}


# ---- Newey-West --------------------------------------------------------------

test_that("hand-written Newey-West matches the sandwich package", {
  set.seed(9)
  d <- ar1(500, 0.8)
  ours <- newey_west_var(d, lag = 10) / length(d)
  ref  <- NeweyWest(lm(d ~ 1), lag = 10, prewhite = FALSE, adjust = FALSE)[1, 1]
  expect_equal(ours, ref)
})

test_that("with autocorrelation, the HAC variance is much larger", {
  set.seed(10)
  d <- ar1(2000, 0.9)
  expect_gt(newey_west_var(d, lag = 21), 5 * var(d))
})


# ---- Diebold-Mariano ---------------------------------------------------------

test_that("DM detects a model that is clearly better", {
  set.seed(11)
  d <- -0.5 + ar1(1000, 0.5, sd = 0.5)      # model loss lower on average
  out <- dm_test(d)
  expect_lt(out[["dm_stat"]], -2)
  expect_lt(out[["p_value"]], 0.05)
})

test_that("DM does not reject when there is no difference", {
  set.seed(12)
  d <- ar1(1000, 0.5)                       # mean zero
  expect_gt(dm_test(d)[["p_value"]], 0.05)
})


# ---- Mincer-Zarnowitz ---------------------------------------------------------

test_that("MZ accepts an unbiased forecast and spots an over-shrunk one", {
  set.seed(13)
  signal <- rnorm(3000, -1.5, 0.4)
  target <- signal + rnorm(3000, 0, 0.2)
  good   <- mz_test(target, signal, lag = 5)
  expect_equal(good[["b"]], 1, tolerance = 0.05)
  expect_gt(good[["p_value"]], 0.05)

  shrunk <- mean(signal) + 0.5 * (signal - mean(signal))   # moves half as much
  bad    <- mz_test(target, shrunk, lag = 5)
  expect_equal(bad[["b"]], 2, tolerance = 0.1)
  expect_lt(bad[["p_value"]], 0.05)
})


# ---- Feature blocks ------------------------------------------------------------

test_that("blocks are nested and follow the asset mapping", {
  for (a in ASSETS) {
    b <- lapply(c("b1", "b2", "b3", "b4"), block_features, asset = a)
    expect_true(all(b[[1]] %in% b[[2]]) && all(b[[2]] %in% b[[3]]) && all(b[[3]] %in% b[[4]]))
    expect_true(all(b[[4]] %in% FULL_FEATURES))
  }
  expect_true("log_ovx" %in% block_features("b2", "oil"))
  expect_true("log_gvz" %in% block_features("b2", "gold"))
  expect_false("log_ovx" %in% block_features("b4", "corn"))
  expect_true(all(c("gas_dev", "hdd_anomaly") %in% block_features("b4", "natgas")))
  expect_false("crude_dev" %in% block_features("b4", "gold"))
})

test_that("an asset-specific Lasso uses the features of its own asset", {
  features <- build_features(make_fake_raw())
  data  <- model_rows(features)
  model <- make_lasso("lasso_b2", function(a) block_features("b2", a))
  fit_oil  <- model$fit(data[data$asset == "oil", ])
  fit_corn <- model$fit(data[data$asset == "corn", ])
  expect_true("log_ovx" %in% fit_oil$features)
  expect_false("log_ovx" %in% fit_corn$features)
})

test_that("each block model keeps its own feature block (lazy evaluation trap)", {
  features <- build_features(make_fake_raw())
  data   <- model_rows(features)
  gold   <- data[data$asset == "gold", ]
  models <- block_models(rf_min_node_size = 200)
  names(models) <- sapply(models, function(m) m$name)
  for (family in c("lasso", "rf")) {
    for (label in c("b2_iv", "b3_gpr", "b4_fund")) {
      used <- models[[paste0(family, "_", label)]]$fit(gold)$features
      expect_equal(sort(used), sort(block_features(substr(label, 1, 2), "gold")))
    }
  }
})
