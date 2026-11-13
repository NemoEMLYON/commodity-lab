# Tests for the post hoc extensions of R/10_extensions.R.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)
source(file.path("..", "R", "05_inference.R"), chdir = TRUE)
source(file.path("..", "R", "10_extensions.R"), chdir = TRUE)

dm_row <- function(stat, p) data.frame(asset = "oil", model = "ols_b2_iv",
                                       mean_diff = 0, dm_stat = stat, p_value = p)

test_that("E1 verdict follows the pre-registered rule", {
  expect_match(e1_verdict(dm_row(1.2, 0.23)), "^information")
  expect_match(e1_verdict(dm_row(2.5, 0.012)), "^algorithm")
  expect_match(e1_verdict(dm_row(-2.5, 0.012)), "^shrinkage costs")
  expect_true(is.na(e1_verdict(dm_row(1, 0.3)[0, ])))
})

test_that("E1 runs end to end and leaves the saved models untouched", {
  features <- build_features(make_fake_raw())
  models <- c(BASELINE_MODELS,
              list(make_lasso("lasso_b2_iv", function(a) block_features("b2", a)),
                   make_rf("rf_b2_iv", function(a) block_features("b2", a),
                           pooled = FALSE, min_node_size = 50, num_trees = 30)))
  saved <- walk_forward(features, models, test_years = 2014:2015)

  e1 <- run_extension_e1(features, saved, test_years = 2014:2015)

  expect_setequal(unique(e1$predictions$model), E1_MODELS)
  expect_equal(nrow(e1$predictions), 2 * nrow(saved[saved$model == "har", ]))
  # Same rows (asset, date) as the saved models: comparisons are like for like
  har <- saved[saved$model == "har", ]
  hx  <- e1$predictions[e1$predictions$model == "har_x", ]
  expect_equal(hx$asset, har$asset)
  expect_equal(hx$date, har$date)
  expect_setequal(e1$qlike_vs_har$asset, c(ASSETS, "all"))
  expect_true(all(e1$qlike_vs_har$asset != "" & is.finite(e1$qlike_vs_har$har_x)))
  expect_setequal(unique(e1$coef_har_x$asset), c("oil", "gold"))
  expect_true("log_ovx" %in% e1$coef_har_x$term)
  expect_type(e1$verdict, "character")
})
