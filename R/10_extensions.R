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
