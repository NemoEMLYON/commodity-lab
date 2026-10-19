# 08_export.R — Export the results to JSON files for the website.
#
# The site only displays what R computed: nothing is recalculated in the
# browser except the interactive simulator (validated against R).
# Series are thinned to one point per week to keep the files small.

library(jsonlite)

SITE_DATA_DIR <- file.path("site", "data")

ASSET_INFO <- data.frame(
  id       = c("gold", "oil", "copper", "natgas", "corn"),
  name     = c("Gold", "Crude oil", "Copper", "Natural gas", "Corn"),
  ticker   = c("GLD", "USO", "CPER", "UNG", "CORN"),
  material = c("gold", "oil", "copper", "gas", "corn")
)


# ---- Helpers ----------------------------------------------------------------

# TRUE for the last trading day of each ISO week.
last_of_week <- function(dates) {
  week <- format(dates, "%G-%V")
  c(week[-1] != week[-length(week)], TRUE)
}

# Full precision, for the validation cases (no rounding of the reference).
write_json_full <- function(x, name, dir = SITE_DATA_DIR) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, paste0(name, ".json"))
  write_json(x, path, auto_unbox = TRUE, digits = NA, dataframe = "rows", na = "null")
  path
}

write_site_json <- function(x, name, dir = SITE_DATA_DIR) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, paste0(name, ".json"))
  write_json(x, path, auto_unbox = TRUE, digits = 4, dataframe = "rows",
             Date = "ISO8601", na = "null")
  path
}


# ---- Content ----------------------------------------------------------------

# Snapshot per asset: last price, 1-year return, current and typical vol.
asset_snapshot <- function(features) {
  rows <- lapply(seq_len(nrow(ASSET_INFO)), function(i) {
    info <- ASSET_INFO[i, ]
    df   <- features[features$asset == info$id, ]
    df   <- df[order(df$date), ]
    n    <- nrow(df)
    vol  <- exp(df$har_m)                       # trailing 22-day realised vol
    data.frame(
      info,
      first_date   = format(df$date[1]),
      last_date    = format(df$date[n]),
      last_price   = round(df$close[n], 2),
      return_1y    = df$close[n] / df$close[n - 252] - 1,
      vol_now      = vol[n],
      vol_median   = median(vol, na.rm = TRUE),
      vol_pctile   = mean(vol <= vol[n], na.rm = TRUE)   # where today sits
    )
  })
  do.call(rbind, rows)
}

# Weekly trailing 22-day realised vol per asset, full history.
vol_history <- function(features) {
  out <- lapply(ASSET_INFO$id, function(a) {
    df <- features[features$asset == a & !is.na(features$har_m), ]
    df <- df[order(df$date), ]
    df <- df[last_of_week(df$date), ]
    list(asset = a, date = format(df$date), vol = round(exp(df$har_m), 4))
  })
  names(out) <- ASSET_INFO$id
  out
}

# Weekly out-of-sample forecasts vs what happened next, for chosen models.
forecast_history <- function(predictions, models) {
  out <- list()
  for (a in ASSET_INFO$id) {
    p <- predictions[predictions$asset == a & predictions$model %in% models, ]
    dates <- sort(unique(p$date))
    keep  <- dates[last_of_week(dates)]
    entry <- list(asset = a, date = format(keep))
    first <- p[p$model == models[1], ]
    entry$realized <- round(sqrt(first$realized_var[match(keep, first$date)]), 4)
    for (m in models) {
      pm <- p[p$model == m, ]
      entry[[m]] <- round(sqrt(pm$pred_var[match(keep, pm$date)]), 4)
    }
    out[[a]] <- entry
  }
  out
}

export_site_data <- function(features, predictions, results, backtest_summary_table,
                             robust = NULL,
                             forecast_models = c("har", "ewma", "lasso_b2_iv", "rf_b2_iv")) {
  meta <- list(
    generated    = format(Sys.Date()),
    sample_start = format(min(features$date)),
    sample_end   = format(max(features$date)),
    test_start   = format(min(predictions$date)),
    test_end     = format(max(predictions$date)),
    horizon_days = HORIZON,
    target_vol   = TARGET_VOL,
    sources      = c("Yahoo Finance (ETF prices)", "FRED (VIX, OVX, GVZ)",
                     "EIA API v2 (crude and gas inventories)",
                     "Caldara & Iacoviello (Geopolitical Risk index, CC BY)",
                     "Open-Meteo (weather, CC BY 4.0)")
  )
  ev <- results$evaluation
  paths <- c(
    write_site_json(meta, "meta"),
    write_site_json(asset_snapshot(features), "assets"),
    write_site_json(vol_history(features), "vol_history"),
    write_site_json(forecast_history(predictions, forecast_models), "forecasts"),
    write_site_json(list(
      evaluation   = ev,
      design_2x2   = results$design_2x2,
      blocks_lasso = results$blocks_lasso,
      blocks_rf    = results$blocks_rf,
      dm           = results$dm,
      mz           = results$mz,
      by_year      = results$by_year,
      by_year_oil  = results$by_year_oil
    ), "results"),
    write_site_json(list(
      per_asset   = backtest_summary_table,
      portfolio   = if (!is.null(robust)) robust$portfolio else NULL,
      sensitivity = if (!is.null(robust)) robust$sensitivity else NULL,
      backtest_5  = if (!is.null(robust)) robust$backtest_5 else NULL,
      portfolio_5 = if (!is.null(robust)) robust$portfolio_5 else NULL
    ), "backtest")
  )
  paths
}


# ---- Simulator (the site's interactive backtest) -------------------------------
#
# The site re-runs simulate_strategy() in JavaScript. It needs, per asset and
# per out-of-sample day: the asset's simple return and each model's forecast
# vol. Values are rounded here, and the validation cases below are computed
# from the SAME rounded numbers, so R and JavaScript start from identical
# inputs and must give identical outputs (up to floating-point noise).

SIM_MODELS <- c("naive", "ewma", "har", "lasso_b2_iv", "rf_b2_iv")

simulator_data <- function(predictions, features, models = SIM_MODELS) {
  out <- list()
  for (a in ASSET_INFO$id) {
    p <- predictions[predictions$asset == a & predictions$model %in% models, ]
    dates <- sort(unique(p$date))
    f <- features[features$asset == a, ]
    entry <- list(
      date = format(dates),
      ret  = round(exp(f$ret[match(dates, f$date)]) - 1, 8)     # simple returns
    )
    first <- p[p$model == models[1], ]
    vols <- list(oracle = round(sqrt(first$realized_var[match(dates, first$date)]), 6))
    for (m in models) {
      pm <- p[p$model == m, ]
      vols[[m]] <- round(sqrt(pm$pred_var[match(dates, pm$date)]), 6)
    }
    entry$vol <- vols
    out[[a]] <- entry
  }
  out
}

# Settings checked against the JavaScript port (study default + two extremes).
SIM_CHECK_SETTINGS <- list(
  default = list(target = 0.10, cap = 2.0, every = 5,  band = 0.10, cost_bp = 5),
  tight   = list(target = 0.15, cap = 1.5, every = 1,  band = 0.00, cost_bp = 0),
  loose   = list(target = 0.08, cap = 3.0, every = 21, band = 0.20, cost_bp = 20)
)
SIM_CHECK_STRATEGIES <- c("har", "ewma", "oracle", "buy_hold")

# Reference results computed in R from the exported (rounded) inputs.
simulator_fixtures <- function(sim, settings = SIM_CHECK_SETTINGS,
                               strategies = SIM_CHECK_STRATEGIES) {
  rows <- list()
  for (a in names(sim)) {
    for (s_name in names(settings)) {
      s <- settings[[s_name]]
      for (strat in strategies) {
        desired <- if (strat == "buy_hold") rep(1, length(sim[[a]]$ret))
                   else pmin(s$target / sim[[a]]$vol[[strat]], s$cap)
        bt <- simulate_strategy(sim[[a]]$ret, desired, rebalance_every = s$every,
                                band = s$band, cost_bp = s$cost_bp)
        m <- strategy_metrics(bt$ret, bt$traded, target = s$target)
        rows[[length(rows) + 1]] <- data.frame(
          asset = a, setting = s_name, strategy = strat, m,
          sum_ret = sum(bt$ret), last_weight = bt$weight[length(bt$weight)]
        )
      }
    }
  }
  list(settings = settings, cases = do.call(rbind, rows))
}


# ---- CSV downloads (offered on the site's method section) -----------------------

export_site_csv <- function(predictions, results, backtest_summary_table,
                            dir = file.path(SITE_DATA_DIR, "csv"),
                            models = c("naive", "ewma", "har", "lasso_b2_iv", "rf_b2_iv")) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  # Daily out-of-sample forecasts, wide: one column per model (annualised vol).
  p <- predictions[predictions$model %in% models, ]
  base <- unique(p[, c("asset", "date", "realized_var")])
  wide <- data.frame(asset = base$asset, date = format(base$date),
                     realised_vol_next_21d = round(sqrt(base$realized_var), 6))
  for (m in models) {
    pm <- p[p$model == m, ]
    key <- paste(pm$asset, pm$date)
    wide[[paste0("forecast_", m)]] <- round(sqrt(pm$pred_var[match(paste(base$asset, base$date), key)]), 6)
  }
  wide <- wide[order(wide$asset, wide$date), ]

  paths <- c(
    file.path(dir, "forecasts_daily.csv"),
    file.path(dir, "model_evaluation.csv"),
    file.path(dir, "backtest_summary.csv")
  )
  write.csv(wide, paths[1], row.names = FALSE)
  write.csv(results$evaluation, paths[2], row.names = FALSE)
  write.csv(backtest_summary_table, paths[3], row.names = FALSE)
  paths
}
