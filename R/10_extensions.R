# 10_extensions.R — Post hoc extensions, pre-registered in CLAUDE.md (S16).
#
# Decided after seeing the 2017-2026 results, so reported apart and never
# mixed into the primary comparison. Each extension reads the saved
# predictions of pipeline.R and adds its own models next to them.
#
# Needs 03_models.R, 04_walkforward.R and 05_inference.R.

EXTENSIONS_PATH <- file.path("data", "processed", "extensions.rds")

# Models from pipeline.R that the extensions are compared with.
E1_REFERENCE_MODELS <- c("naive", "ewma", "har", "lasso_b2_iv", "rf_b2_iv")
E1_MODELS <- c("har_x", "ols_b2_iv")

# Asset x model table of one evaluate() column (default: QLIKE / HAR).
wide_by_asset <- function(evaluation, models, value = "qlike_vs_har") {
  assets <- unique(evaluation$asset)
  out <- sapply(models, function(m) {
    rows <- evaluation[evaluation$model == m, ]
    rows[[value]][match(assets, rows$asset)]
  })
  data.frame(asset = assets, round(out, 3), row.names = NULL)
}

# Pre-registered reading rule for oil: DM of ols_b2_iv against lasso_b2_iv
# (d = loss(OLS) - loss(Lasso); positive = the Lasso is better).
e1_verdict <- function(dm_vs_lasso, level = 0.05) {
  row <- dm_vs_lasso[dm_vs_lasso$asset == "oil" & dm_vs_lasso$model == "ols_b2_iv", ]
  if (nrow(row) != 1) return(NA_character_)
  if (row$p_value >= level) {
    "information: OLS on the same inputs is not significantly worse than the Lasso"
  } else if (row$dm_stat > 0) {
    "algorithm: the Lasso is significantly better than OLS on the same inputs"
  } else {
    "shrinkage costs: OLS on the same inputs is significantly better than the Lasso"
  }
}

# E1: information or algorithm? Runs har_x and ols_b2_iv through the same
# walk-forward and compares them with the saved models.
run_extension_e1 <- function(features, predictions, test_years = TEST_YEARS) {
  new_pred <- walk_forward(features, extension_e1_models(), test_years)
  both <- rbind(predictions[predictions$model %in% E1_REFERENCE_MODELS, names(new_pred)],
                new_pred)

  evaluation  <- evaluate(both)
  dm_har      <- dm_table(both, benchmark = "har")
  dm_lasso    <- dm_table(both[both$model %in% c("lasso_b2_iv", E1_MODELS), ],
                          benchmark = "lasso_b2_iv")
  har_x       <- extension_e1_models()[[1]]

  list(
    predictions = new_pred,
    qlike_vs_har = wide_by_asset(evaluation, c("ewma", "lasso_b2_iv", "rf_b2_iv", E1_MODELS)),
    evaluation  = evaluation[evaluation$model %in% c("har", "lasso_b2_iv", E1_MODELS), ],
    dm_vs_har   = dm_wide(dm_har, c("lasso_b2_iv", E1_MODELS)),
    dm_vs_lasso = dm_lasso,
    mz          = mz_table(both, c("har", "lasso_b2_iv", E1_MODELS)),
    by_year_oil = evaluate_by_year(both, c("lasso_b2_iv", E1_MODELS), asset = "oil"),
    coef_har_x  = rbind(ols_coefficients(features, har_x, "oil", test_years),
                        ols_coefficients(features, har_x, "gold", test_years)),
    verdict     = e1_verdict(dm_lasso)
  )
}

# Coefficients as a term x year table (one asset, one model).
coef_wide <- function(coefs, asset) {
  c1 <- coefs[coefs$asset == asset, ]
  out <- tapply(c1$estimate, list(c1$term, c1$test_year), identity)
  round(out[unique(c1$term), , drop = FALSE], 3)
}


# ---- E2: forecast combinations (S17) ------------------------------------------
#
# Fixed equal weights, nothing estimated: the combined variance forecast is
# the mean of the members' variance forecasts (Jensen-corrected). Averaging
# variances, not log vols, keeps the level of the members.

E2_COMBINATIONS <- list(
  comb_har_ewma       = c("har", "ewma"),
  comb_har_harx       = c("har", "har_x"),
  comb_har_ewma_lasso = c("har", "ewma", "lasso_b2_iv")
)
E2_SELECTION_YEARS <- 2017:2025   # the two best are chosen on these years only

# One combination as prediction rows (same columns as walk_forward()).
# Only the (asset, date) pairs where every member has a forecast.
combine_predictions <- function(predictions, members, name) {
  parts <- lapply(members, function(m) predictions[predictions$model == m, ])
  key   <- function(p) paste(p$asset, p$date)
  common <- Reduce(intersect, lapply(parts, key))
  parts <- lapply(parts, function(p) { p <- p[key(p) %in% common, ]; p[order(p$asset, p$date), ] })

  out <- parts[[1]]
  out$model        <- name
  out$pred_var     <- Reduce(`+`, lapply(parts, `[[`, "pred_var")) / length(parts)
  out$pred_var_raw <- Reduce(`+`, lapply(parts, `[[`, "pred_var_raw")) / length(parts)
  out$pred_log_vol <- log(out$pred_var) / 2      # log vol consistent with the variance
  rownames(out) <- NULL
  out
}

# The two combinations with the lowest pooled QLIKE on the selection years.
select_combinations <- function(combined, years = E2_SELECTION_YEARS, n = 2) {
  p <- combined[combined$test_year %in% years, ]
  loss <- tapply(qlike(p$realized_var, p$pred_var), p$model, mean)
  names(sort(loss))[seq_len(n)]
}

run_extension_e2 <- function(features, predictions, e1_predictions,
                             combinations = E2_COMBINATIONS) {
  base <- rbind(predictions[predictions$model %in% E1_REFERENCE_MODELS, names(e1_predictions)],
                e1_predictions)
  combined <- do.call(rbind, lapply(names(combinations), function(n)
    combine_predictions(base, combinations[[n]], n)))
  all_pred <- rbind(base, combined)
  combos   <- names(combinations)

  evaluation <- evaluate(all_pred)
  bt_models  <- c("har", "ewma", "har_x", combos)
  list(
    predictions  = combined,
    qlike_vs_har = wide_by_asset(evaluation, c("ewma", "lasso_b2_iv", "har_x", combos)),
    var_ratio    = wide_by_asset(evaluation, c("har", "ewma", "har_x", combos), "var_ratio"),
    dm_vs_har    = dm_wide(dm_table(all_pred, benchmark = "har"), c("har_x", combos)),
    dm_vs_harx   = dm_wide(dm_table(all_pred[all_pred$model %in% c("har_x", combos), ],
                                    benchmark = "har_x"), combos),
    by_year      = evaluate_by_year(all_pred, c("har_x", combos)),
    selected     = select_combinations(combined),
    backtest     = backtest_summary(run_backtest(all_pred, features, models = bt_models))
  )
}
