# live.R — Today's volatility forecasts with the frozen models.
# Run from the project root: Rscript live.R   (or source("live.R") in R)
# Runs every weekday evening on GitHub Actions (.github/workflows/live.yml).
#
# Writes site/data/live.json. Never fails because of the network: without a
# download it uses the last snapshot; without anything new it keeps the
# previous live.json and marks it offline.

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")
source("R/06_backtest.R")
source("R/08_export.R")
source("R/09_live.R")

frozen <- readRDS(FROZEN_MODELS_PATH)

snapshot <- tryCatch(get_live_snapshot(), error = function(e) {
  message("No data available: ", conditionMessage(e))
  NULL
})

if (is.null(snapshot)) {
  path <- mark_offline()
  message("Kept the previous forecasts, marked offline: ", path)
} else {
  live_features <- build_live_features(snapshot$data)
  preds   <- add_live_combinations(predict_frozen(frozen, live_features))
  payload <- live_payload(snapshot, frozen, preds, live_features)
  path    <- write_site_json(payload, "live")

  message("\nMode: ", snapshot$mode, " (", snapshot$source, ") | last close: ", snapshot$asof)
  today <- do.call(rbind, lapply(payload$today, function(a) data.frame(
    asset = a$id, model = a$headline_model, forecast = round(a$forecast_vol, 3),
    lo80 = round(a$lo80, 3), hi80 = round(a$hi80, 3),
    last_month = round(a$last_month_vol, 3), percentile = round(a$percentile, 2),
    weight_10 = round(a$weight_10, 2))))
  message("\n== Forecast of annualised vol over the next 21 trading days")
  print(today, row.names = FALSE)
  message("\n== Freshness of the inputs")
  print(payload$freshness, row.names = FALSE)
  message("\n== Track record since ", frozen$first_test, " (all assets)")
  print(payload$track[payload$track$asset == "all", ], digits = 3, row.names = FALSE)

  # On the PC only (the pipeline table is not on GitHub): same features?
  if (file.exists(FEATURES_PATH)) {
    message("\n== Live features vs pipeline features (features.rds)")
    print(compare_features(live_features, readRDS(FEATURES_PATH)), row.names = FALSE)
  }
  message("\nWrote ", path)
}
