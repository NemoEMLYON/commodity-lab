# 06_backtest.R — Economic value: vol targeting, one asset at a time.
#
# A manager holds one commodity ETF and wants its risk at TARGET_VOL.
# At the close of day t, the forecast of next month's vol gives the desired
# exposure:   weight = TARGET_VOL / forecast vol   (capped at MAX_LEVERAGE).
# The rest is cash (0% return, a simplification). The weight decided at t
# applies from day t+1, so no information from after t is used.
#
# Realism: rebalancing only every REBALANCE_EVERY days, and only if the
# desired weight differs from the current one by more than NO_TRADE_BAND
# (relative); between trades the weight drifts with prices; every trade
# pays COST_BP basis points of the traded amount.
#
# A better forecast should keep the realised risk closer to the target.
# Needs 02_features.R (roll_mean) and the predictions of 04_walkforward.R.

TARGET_VOL      <- 0.10
MAX_LEVERAGE    <- 2
REBALANCE_EVERY <- 5        # trading days (weekly)
NO_TRADE_BAND   <- 0.10     # trade only if |desired / current - 1| > 10%
COST_BP         <- 5        # cost per unit of traded exposure, basis points
RISK_WINDOW     <- 63       # rolling window (~3 months) to judge realised risk

BACKTEST_MODELS <- c("naive", "ewma", "har", "lasso_b2_iv", "rf_b2_iv")
BACKTEST_PATH   <- file.path("data", "processed", "backtest.rds")


# ---- Building blocks --------------------------------------------------------

# Desired exposure from an annualised variance forecast.
target_weight <- function(pred_var, target = TARGET_VOL, cap = MAX_LEVERAGE) {
  pmin(target / sqrt(pred_var), cap)
}

# Simulate one strategy.
#   asset_ret[t]  simple return of the asset from close t-1 to close t
#   desired[t]    weight wanted at the close of day t (NA: no new decision)
# Returns one row per day: strategy return (net of costs), weight held
# after the close, amount traded.
simulate_strategy <- function(asset_ret, desired,
                              rebalance_every = REBALANCE_EVERY,
                              band = NO_TRADE_BAND, cost_bp = COST_BP) {
  n       <- length(asset_ret)
  ret     <- numeric(n)
  weight  <- numeric(n)
  traded  <- numeric(n)
  current <- 0                                   # start in cash

  for (t in seq_len(n)) {
    # 1. Day t: earn the asset return on yesterday's weight, then drift.
    if (t > 1) {
      r       <- asset_ret[t]
      ret[t]  <- current * r
      current <- current * (1 + r) / (1 + current * r)
    }

    # 2. Close of day t: rebalance on scheduled days, outside the band.
    is_rebalance_day <- (t - 1) %% rebalance_every == 0
    if (is_rebalance_day && !is.na(desired[t])) {
      far_enough <- current == 0 || abs(desired[t] / current - 1) > band
      if (far_enough) {
        traded[t] <- abs(desired[t] - current)
        ret[t]    <- ret[t] - traded[t] * cost_bp / 1e4
        current   <- desired[t]
      }
    }
    weight[t] <- current
  }
  data.frame(ret = ret, weight = weight, traded = traded)
}

# Risk and performance of a daily return series.
strategy_metrics <- function(ret, traded, target = TARGET_VOL, window = RISK_WINDOW) {
  rolling_vol <- sqrt(252 * roll_mean(ret^2, window))
  wealth      <- cumprod(1 + ret)
  years       <- length(ret) / 252
  data.frame(
    ann_vol    = sd(ret) * sqrt(252),
    risk_rmse  = sqrt(mean((rolling_vol - target)^2, na.rm = TRUE)),
    breach_pct = 100 * mean(rolling_vol > 1.5 * target, na.rm = TRUE),
    max_dd     = min(wealth / cummax(wealth) - 1),
    turnover   = sum(traded) / years,
    ann_ret    = wealth[length(wealth)]^(1 / years) - 1,
    sharpe     = mean(ret) / sd(ret) * sqrt(252)
  )
}


# ---- Engine -----------------------------------------------------------------

# Daily strategy returns for every asset and strategy over the
# out-of-sample period. Strategies: one per forecasting model, plus
#   buy_hold  weight 1 always (no risk control)
#   oracle    weight from the REALISED future variance: impossible in
#             practice, shows the best that vol targeting could achieve.
run_backtest <- function(predictions, features, models = BACKTEST_MODELS, ...) {
  out <- list()
  for (asset in unique(predictions$asset)) {
    p <- predictions[predictions$asset == asset & predictions$model %in% models, ]
    dates <- sort(unique(p$date))
    f <- features[features$asset == asset, ]
    asset_ret <- exp(f$ret[match(dates, f$date)]) - 1   # log -> simple returns

    first <- p[p$model == models[1], ]
    realized_var <- first$realized_var[match(dates, first$date)]
    desired <- list(buy_hold = rep(1, length(dates)),
                    oracle   = target_weight(realized_var))
    for (m in models) {
      pm <- p[p$model == m, ]
      desired[[m]] <- target_weight(pm$pred_var[match(dates, pm$date)])
    }

    for (s in names(desired)) {
      sim <- simulate_strategy(asset_ret, desired[[s]], ...)
      out[[length(out) + 1]] <- data.frame(asset = asset, strategy = s,
                                           date = dates, sim)
    }
  }
  do.call(rbind, out)
}

# One row per (asset, strategy), plus the average over assets ("all").
backtest_summary <- function(backtest, target = TARGET_VOL) {
  groups <- split(backtest, list(backtest$asset, backtest$strategy), drop = TRUE)
  rows <- lapply(groups, function(df) {
    df <- df[order(df$date), ]
    data.frame(asset = df$asset[1], strategy = df$strategy[1],
               strategy_metrics(df$ret, df$traded, target))
  })
  out <- do.call(rbind, rows)

  avg <- aggregate(out[, -(1:2)], by = list(strategy = out$strategy), FUN = mean)
  out <- rbind(out, data.frame(asset = "all", avg))
  out <- out[order(out$asset, out$risk_rmse), ]
  rownames(out) <- NULL
  out
}


# ---- Sensitivity ------------------------------------------------------------

# Re-run the per-asset backtest under other trading assumptions and keep the
# average over assets. One row per (setting, strategy).
BACKTEST_SETTINGS <- list(
  base    = list(),
  cost_0  = list(cost_bp = 0),
  cost_20 = list(cost_bp = 20),
  daily   = list(rebalance_every = 1),
  monthly = list(rebalance_every = 21),
  no_band = list(band = 0),
  band_20 = list(band = 0.20)
)

backtest_sensitivity <- function(predictions, features, settings = BACKTEST_SETTINGS) {
  rows <- lapply(names(settings), function(name) {
    bt  <- do.call(run_backtest, c(list(predictions, features), settings[[name]]))
    avg <- backtest_summary(bt)
    avg <- avg[avg$asset == "all", c("strategy", "risk_rmse", "ann_ret", "turnover")]
    data.frame(setting = name, avg)
  })
  do.call(rbind, rows)
}

# Wide view: one row per strategy, one column per setting.
sensitivity_wide <- function(sensitivity, value = "risk_rmse") {
  out <- reshape(sensitivity[, c("setting", "strategy", value)],
                 idvar = "strategy", timevar = "setting", direction = "wide")
  names(out) <- sub(paste0(value, "."), "", names(out), fixed = TRUE)
  rownames(out) <- NULL
  out
}
