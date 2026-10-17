# 05_inference.R — Are the differences between models real or noise?
#
#   Diebold-Mariano: is the mean QLIKE of a model different from HAR's?
#   Mincer-Zarnowitz: are forecasts unbiased (realised = forecast on average)?
#   Per-year table and block matrix: where and when do the gains come from?
#
# Overlapping 21-day targets make daily losses strongly autocorrelated, so
# usual standard errors are far too small. We use Newey-West (HAC)
# variances. Needs 04_walkforward.R (qlike) and the sandwich package.

library(sandwich)

HAC_LAG <- 21   # at least horizon - 1 = 20 (overlap of the 21-day targets)

RESULTS_PATH <- file.path("data", "processed", "results.rds")


# ---- Newey-West long-run variance -------------------------------------------

# Long-run variance of a series d (Bartlett weights 1 - j / (lag + 1)):
#   gamma_0 + 2 * sum_j w_j * gamma_j,   gamma_j = autocovariance at lag j.
# Var(mean of d) = long-run variance / n. Written by hand to show the
# formula; checked against sandwich::NeweyWest in the tests.
newey_west_var <- function(d, lag = HAC_LAG) {
  n <- length(d)
  e <- d - mean(d)
  gamma <- function(j) sum(e[(j + 1):n] * e[1:(n - j)]) / n
  lrv <- gamma(0)
  for (j in seq_len(lag)) {
    lrv <- lrv + 2 * (1 - j / (lag + 1)) * gamma(j)
  }
  lrv
}


# ---- Diebold-Mariano ---------------------------------------------------------

# d = loss of the model - loss of the benchmark, ordered by date.
# Negative statistic: the model has the lower loss (better).
dm_test <- function(d, lag = HAC_LAG) {
  stat <- mean(d) / sqrt(newey_west_var(d, lag) / length(d))
  c(mean_diff = mean(d), dm_stat = stat, p_value = 2 * pnorm(-abs(stat)))
}

# DM of every model against the benchmark, per asset and pooled. Pooled:
# the loss difference is first averaged across the assets on each date.
dm_table <- function(predictions, benchmark = "har", lag = HAC_LAG) {
  predictions$loss <- qlike(predictions$realized_var, predictions$pred_var)
  bench <- predictions[predictions$model == benchmark, c("asset", "date", "loss")]
  names(bench)[3] <- "loss_bench"

  models <- setdiff(unique(predictions$model), benchmark)
  rows <- list()
  for (m in models) {
    df <- merge(predictions[predictions$model == m, c("asset", "date", "loss")],
                bench, by = c("asset", "date"))
    df$d <- df$loss - df$loss_bench

    for (a in c(unique(df$asset), "all")) {
      if (a == "all") {
        d <- tapply(df$d, df$date, mean)            # one value per date
      } else {
        d <- df$d[df$asset == a][order(df$date[df$asset == a])]
      }
      rows[[length(rows) + 1]] <- data.frame(asset = a, model = m,
                                             t(dm_test(as.numeric(d), lag)))
    }
  }
  out <- do.call(rbind, rows)
  out <- out[order(out$asset, out$dm_stat), ]
  rownames(out) <- NULL
  out
}


# ---- Mincer-Zarnowitz -------------------------------------------------------

# Regress the realised log vol on the forecast: target = a + b * forecast.
# A good forecast has a = 0 and b = 1. b > 1: forecasts too smooth (they move
# less than reality, e.g. over-shrunk); b < 1: forecasts too jumpy.
# Joint Wald test of (a, b) = (0, 1) with a HAC covariance.
mz_test <- function(target, forecast, lag = HAC_LAG) {
  fit   <- lm(target ~ forecast)
  theta <- coef(fit) - c(0, 1)
  V     <- NeweyWest(fit, lag = lag, prewhite = FALSE)
  wald  <- as.numeric(t(theta) %*% solve(V) %*% theta)
  c(a = unname(coef(fit)[1]), b = unname(coef(fit)[2]),
    wald = wald, p_value = pchisq(wald, df = 2, lower.tail = FALSE))
}

mz_table <- function(predictions, models, lag = HAC_LAG) {
  rows <- list()
  for (m in models) {
    for (a in unique(predictions$asset)) {
      df <- predictions[predictions$model == m & predictions$asset == a, ]
      df <- df[order(df$date), ]
      rows[[length(rows) + 1]] <- data.frame(asset = a, model = m,
                                             t(mz_test(df$target, df$pred_log_vol, lag)))
    }
  }
  do.call(rbind, rows)
}


# ---- Where and when -----------------------------------------------------------

# QLIKE relative to the benchmark, one row per test year, one column per
# model. asset = "all" pools the five assets.
evaluate_by_year <- function(predictions, models, asset = "all", benchmark = "har") {
  p <- predictions[predictions$model %in% c(models, benchmark), ]
  if (asset != "all") p <- p[p$asset == asset, ]
  p$loss <- qlike(p$realized_var, p$pred_var)

  mean_loss <- tapply(p$loss, list(p$test_year, p$model), mean)
  ratio <- mean_loss[, models, drop = FALSE] / mean_loss[, benchmark]
  data.frame(year = as.integer(rownames(ratio)), round(ratio, 3), row.names = NULL)
}

# Compact view of a DM table: one row per asset, one column per model.
dm_wide <- function(dm, models, value = "dm_stat") {
  assets <- unique(dm$asset)
  out <- sapply(models, function(m) {
    rows <- dm[dm$model == m, ]
    rows[[value]][match(assets, rows$asset)]
  })
  data.frame(asset = assets, round(out, 2), row.names = NULL)
}

# Asset x block matrix of QLIKE relative to HAR, for one model family.
# B1 = <family>_base, then <family>_b2_iv, _b3_gpr, _b4_fund.
block_matrix <- function(evaluation, family) {
  models <- paste0(family, c("_base", "_b2_iv", "_b3_gpr", "_b4_fund"))
  assets <- unique(evaluation$asset)
  out <- sapply(models, function(m) {
    evaluation$qlike_vs_har[evaluation$model == m][match(assets, evaluation$asset[evaluation$model == m])]
  })
  out <- data.frame(asset = assets, round(out, 3), row.names = NULL)
  names(out) <- c("asset", "B1_own_returns", "B2_implied_vol", "B3_gpr", "B4_fundamentals")
  out
}
