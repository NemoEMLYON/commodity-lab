# 04_walkforward.R — Out-of-sample evaluation by walk-forward.
#
# For each asset and each test year Y (2017, 2018, ...):
#   1. Training set = every row whose target was already KNOWN at the first
#      trading day s of Y. The target of day t is known at the close of
#      t + 21, so we keep rows with position(t) <= position(s) - 21. This is
#      the 21-day embargo: no training target overlaps the test period.
#   2. Fit each model once, predict every day of Y (yearly re-estimation).
# The window grows every year (expanding window).
#
# Needs 02_features.R (HORIZON, ASSETS, feature_columns) and 03_models.R.

TEST_YEARS       <- 2017:2026
VALIDATION_YEARS <- 2015:2016   # used only to choose the forest settings
PREDICTIONS_PATH <- file.path("data", "processed", "predictions.rds")


# ---- Building blocks --------------------------------------------------------

# Rows usable by every model: target and all features present. All models
# share these rows, so differences come from the model, not the sample.
model_rows <- function(features) {
  cols <- c("target", feature_columns(features))
  features[complete.cases(features[, cols]), ]
}

# Last training date allowed when forecasting from `test_start`.
training_cutoff <- function(calendar, test_start, horizon = HORIZON) {
  calendar[match(test_start, calendar) - horizon]
}

# Log vol forecast -> variance forecast. If log vol ~ Normal(mean = pred,
# variance = s2), then E[vol^2] = E[exp(2 * log vol)] = exp(2 * pred + 2 * s2).
# Without the "+ 2 * s2" term (Jensen's inequality) variance is underestimated.
to_variance <- function(pred_log_vol, resid_var) {
  exp(2 * pred_log_vol + 2 * resid_var)
}

# QLIKE loss (Patton, 2011) on variances: 0 for a perfect forecast,
# penalises under-prediction of risk more than over-prediction.
qlike <- function(realized_var, pred_var) {
  ratio <- realized_var / pred_var
  ratio - log(ratio) - 1
}


# ---- Engine -----------------------------------------------------------------

# Fit one model on `train`, predict `test`, return the result rows.
fit_and_predict <- function(model, train, test, year, cutoff) {
  fitted <- model$fit(train)
  pred   <- model$predict(fitted, test)
  data.frame(
    asset        = test$asset,
    model        = model$name,
    test_year    = year,
    date         = test$date,
    train_end    = cutoff,
    pred_log_vol = pred,
    pred_var     = to_variance(pred, fitted$resid_var),
    pred_var_raw = exp(2 * pred),            # without Jensen correction
    target       = test$target,
    realized_var = exp(2 * test$target)
  )
}

walk_forward <- function(features, models, test_years = TEST_YEARS) {
  data     <- model_rows(features)
  calendar <- sort(unique(features$date))
  results  <- list()

  for (year in test_years) {
    test_all <- data[format(data$date, "%Y") == as.character(year), ]
    if (nrow(test_all) == 0) next

    # Same cutoff for every asset: they share the trading calendar.
    cutoff    <- training_cutoff(calendar, min(test_all$date))
    train_all <- data[data$date <= cutoff, ]

    for (model in models) {
      if (isTRUE(model$pooled)) {
        results[[length(results) + 1]] <-
          fit_and_predict(model, train_all, test_all, year, cutoff)
      } else {
        for (asset in unique(test_all$asset)) {
          results[[length(results) + 1]] <- fit_and_predict(
            model,
            train_all[train_all$asset == asset, ],
            test_all[test_all$asset == asset, ],
            year, cutoff)
        }
      }
    }
  }
  do.call(rbind, results)
}


# ---- Evaluation -------------------------------------------------------------

# One row per (asset, model), plus pooled rows (asset = "all"):
#   qlike        mean QLIKE on variance (lower is better)
#   qlike_vs_har qlike / qlike of HAR for the same asset (< 1: beats HAR)
#   rmse_log     RMSE on log vol
#   var_ratio    mean forecast variance / mean realised variance (1 = unbiased)
#   var_ratio_raw  same without the Jensen correction
evaluate <- function(predictions) {
  predictions$loss <- qlike(predictions$realized_var, predictions$pred_var)
  pooled <- predictions
  pooled$asset <- "all"
  both <- rbind(predictions, pooled)

  groups <- split(both, list(both$asset, both$model), drop = TRUE)
  rows <- lapply(groups, function(df) {
    data.frame(
      asset         = df$asset[1],
      model         = df$model[1],
      n             = nrow(df),
      qlike         = mean(df$loss),
      rmse_log      = sqrt(mean((df$pred_log_vol - df$target)^2)),
      var_ratio     = mean(df$pred_var) / mean(df$realized_var),
      var_ratio_raw = mean(df$pred_var_raw) / mean(df$realized_var)
    )
  })
  out <- do.call(rbind, rows)

  har <- out[out$model == "har", c("asset", "qlike")]
  out$qlike_vs_har <- out$qlike / har$qlike[match(out$asset, har$asset)]

  out <- out[order(out$asset, out$qlike), ]
  rownames(out) <- NULL
  out
}

# Best forest settings on the validation years: lowest pooled QLIKE.
# Returns the name and settings of the winning candidate.
select_rf_config <- function(validation_eval, candidates = RF_CANDIDATES) {
  names    <- sapply(rf_candidate_models(candidates), function(m) m$name)
  all_rows <- validation_eval[validation_eval$asset == "all" &
                                validation_eval$model %in% names, ]
  best     <- all_rows$model[which.min(all_rows$qlike)]
  c(list(name = best), as.list(candidates[match(best, names), ]))
}

# The 2x2 design in one table: pooled QLIKE relative to HAR (< 1 beats HAR).
design_2x2 <- function(evaluation) {
  all_rows <- evaluation[evaluation$asset == "all", ]
  ratio    <- function(m) all_rows$qlike_vs_har[all_rows$model == m]
  data.frame(
    model              = c("linear (Lasso)", "random forest"),
    own_returns_only   = c(ratio("lasso_base"), ratio("rf_base")),
    with_external_data = c(ratio("lasso_full"), ratio("rf_full"))
  )
}
