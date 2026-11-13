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


# ---- E2 ------------------------------------------------------------------------

fake_pred <- function(model, var, asset = "oil", dates = as.Date("2020-01-01") + 0:2,
                      year = 2020) {
  data.frame(asset = asset, model = model, test_year = year, date = dates,
             train_end = as.Date("2019-12-01"), pred_log_vol = log(var) / 2,
             pred_var = var, pred_var_raw = var * 0.9, target = log(0.2),
             realized_var = 0.04)
}

test_that("a combination averages the members' variance forecasts", {
  p <- rbind(fake_pred("har", c(0.04, 0.09, 0.16)), fake_pred("ewma", c(0.02, 0.03, 0.04)))
  out <- combine_predictions(p, c("har", "ewma"), "comb")
  expect_equal(out$pred_var, c(0.03, 0.06, 0.10))
  expect_equal(out$pred_var_raw, 0.9 * c(0.03, 0.06, 0.10))
  expect_equal(out$pred_log_vol, log(out$pred_var) / 2)
  expect_equal(unique(out$model), "comb")
})

test_that("a combination keeps only the days where every member forecasts", {
  p <- rbind(fake_pred("har", c(0.04, 0.09, 0.16)),
             fake_pred("ewma", c(0.02, 0.03), dates = as.Date("2020-01-02") + 0:1))
  out <- combine_predictions(p, c("har", "ewma"), "comb")
  expect_equal(out$date, as.Date("2020-01-02") + 0:1)
  expect_equal(out$pred_var, c((0.09 + 0.02) / 2, (0.16 + 0.03) / 2))
})

test_that("selection ignores the years outside the selection window", {
  good_early <- fake_pred("a", rep(0.04, 3), year = 2020)       # perfect in 2020
  bad_late   <- fake_pred("a", rep(0.5, 3), year = 2026, dates = as.Date("2026-01-01") + 0:2)
  b_ok       <- fake_pred("b", rep(0.05, 3), year = 2020)
  b_late     <- fake_pred("b", rep(0.04, 3), year = 2026, dates = as.Date("2026-01-01") + 0:2)
  c_bad      <- fake_pred("c", rep(0.2, 3), year = 2020)
  sel <- select_combinations(rbind(good_early, bad_late, b_ok, b_late, c_bad), years = 2017:2025)
  expect_equal(sel, c("a", "b"))
})
