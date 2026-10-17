# 07_portfolio.R — Vol-targeted inverse-volatility portfolio of the five ETFs.
#
# At the close of day t, from the five vol forecasts:
#   1. inverse-vol weights: w_i proportional to 1 / forecast vol_i, sum 1
#      (each asset gets the same standalone risk);
#   2. forecast portfolio vol = sqrt(w' Sigma w), with Sigma built from the
#      forecast vols and the correlation of daily returns over the last
#      PORTFOLIO_CORR_WINDOW days (known at t);
#   3. scale all weights by TARGET_VOL / forecast portfolio vol, with total
#      exposure capped at MAX_LEVERAGE.
# Same trading rules as 06_backtest.R: decision at t applies from t+1,
# weekly rebalancing, no-trade band, costs on the traded amount, drift.

PORTFOLIO_CORR_WINDOW <- 252


# ---- Weights ----------------------------------------------------------------

portfolio_weights <- function(vols, corr, target = TARGET_VOL, cap = MAX_LEVERAGE) {
  w        <- (1 / vols) / sum(1 / vols)
  cov      <- corr * outer(vols, vols)              # Sigma_ij = rho_ij s_i s_j
  port_vol <- sqrt(drop(t(w) %*% cov %*% w))
  scale    <- min(target / port_vol, cap / sum(w))  # sum(w) = 1
  w * scale
}

# Correlation of the daily returns over the `window` days ending at row t.
trailing_corr <- function(returns, t, window = PORTFOLIO_CORR_WINDOW) {
  cor(returns[(t - window + 1):t, , drop = FALSE], use = "pairwise.complete.obs")
}


# ---- Simulation -------------------------------------------------------------

# Multi-asset version of simulate_strategy().
#   asset_ret  matrix days x assets of simple returns (close t-1 -> close t)
#   desired    matrix days x assets of weights wanted at the close of t
simulate_portfolio <- function(asset_ret, desired,
                               rebalance_every = REBALANCE_EVERY,
                               band = NO_TRADE_BAND, cost_bp = COST_BP) {
  n       <- nrow(asset_ret)
  ret     <- numeric(n)
  traded  <- numeric(n)
  gross   <- numeric(n)
  current <- rep(0, ncol(asset_ret))

  for (t in seq_len(n)) {
    if (t > 1) {
      r       <- asset_ret[t, ]
      ret[t]  <- sum(current * r)
      current <- current * (1 + r) / (1 + ret[t])      # each weight drifts
    }

    if ((t - 1) %% rebalance_every == 0 && !anyNA(desired[t, ])) {
      change     <- abs(desired[t, ] / current - 1)   # Inf if current = 0
      far_enough <- all(current == 0) || max(change, na.rm = TRUE) > band
      if (far_enough) {
        traded[t] <- sum(abs(desired[t, ] - current))
        ret[t]    <- ret[t] - traded[t] * cost_bp / 1e4
        current   <- desired[t, ]
      }
    }
    gross[t] <- sum(current)
  }
  data.frame(ret = ret, traded = traded, gross = gross)
}


# ---- Engine -----------------------------------------------------------------

# Portfolio strategies over the out-of-sample period: one per model, plus
#   equal_weight  20% in each ETF, no risk control
#   oracle        realised future vols (infeasible upper bound)
run_portfolio <- function(predictions, features, models = BACKTEST_MODELS, ...) {
  assets <- ASSETS
  dates  <- sort(unique(predictions$date[predictions$model == models[1]]))

  # Daily log returns on the full history (for correlations), and simple
  # returns on the test dates (for the simulation).
  all_dates <- sort(unique(features$date))
  log_ret   <- sapply(assets, function(a) {
    f <- features[features$asset == a, ]
    f$ret[match(all_dates, f$date)]
  })
  test_rows <- match(dates, all_dates)
  asset_ret <- exp(log_ret[test_rows, ]) - 1

  # Correlation known at each test date.
  corrs <- lapply(test_rows, function(t) trailing_corr(log_ret, t))

  vol_matrix <- function(column, model) {
    sapply(assets, function(a) {
      p <- predictions[predictions$model == model & predictions$asset == a, ]
      sqrt(p[[column]][match(dates, p$date)])
    })
  }
  desired_from <- function(vols) {
    t(sapply(seq_along(dates), function(i) {
      if (anyNA(vols[i, ])) return(rep(NA, length(assets)))
      portfolio_weights(vols[i, ], corrs[[i]])
    }))
  }

  desired <- list(
    equal_weight = matrix(1 / length(assets), length(dates), length(assets)),
    oracle       = desired_from(vol_matrix("realized_var", models[1]))
  )
  for (m in models) desired[[m]] <- desired_from(vol_matrix("pred_var", m))

  out <- lapply(names(desired), function(s) {
    data.frame(strategy = s, date = dates, simulate_portfolio(asset_ret, desired[[s]], ...))
  })
  do.call(rbind, out)
}

portfolio_summary <- function(portfolio, target = TARGET_VOL) {
  rows <- lapply(split(portfolio, portfolio$strategy), function(df) {
    df <- df[order(df$date), ]
    data.frame(strategy = df$strategy[1],
               strategy_metrics(df$ret, df$traded, target),
               avg_gross = mean(df$gross))
  })
  out <- do.call(rbind, rows)
  out <- out[order(out$risk_rmse), ]
  rownames(out) <- NULL
  out
}
