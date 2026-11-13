# Tests for R/08_export.R.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)
source(file.path("..", "R", "06_backtest.R"), chdir = TRUE)
source(file.path("..", "R", "08_export.R"), chdir = TRUE)

test_that("last_of_week keeps one day per ISO week", {
  d <- as.Date(c("2024-01-01", "2024-01-03", "2024-01-05",   # Mon, Wed, Fri
                 "2024-01-08", "2024-01-12"))                # Mon, Fri
  expect_equal(last_of_week(d), c(FALSE, FALSE, TRUE, FALSE, TRUE))
})

test_that("the snapshot reports the last real price and a vol percentile in [0, 1]", {
  features <- build_features(make_fake_raw())
  snap <- asset_snapshot(features)
  gold <- features[features$asset == "gold", ]
  expect_equal(snap$last_price[snap$id == "gold"], round(gold$close[nrow(gold)], 2))
  expect_true(all(snap$vol_pctile >= 0 & snap$vol_pctile <= 1))
  expect_setequal(snap$id, ASSETS)
})

test_that("exported JSON reads back with the same values", {
  features <- build_features(make_fake_raw())
  dir  <- tempfile()
  path <- write_site_json(vol_history(features), "vol_history", dir = dir)
  back <- jsonlite::read_json(path, simplifyVector = TRUE)
  expect_equal(back$oil$vol, vol_history(features)$oil$vol)
  expect_equal(length(back$oil$date), length(back$oil$vol))
})


# ---- Weather map ------------------------------------------------------------------

test_that("the mean of the city anomalies is the pipeline's hdd_anomaly", {
  raw <- make_fake_raw()
  colnames(raw$weather) <- WEATHER_CITIES$city
  features <- build_features(raw)
  map <- weather_map_data(raw$weather, features)

  # Pipeline value on the same Fridays, before its availability lag
  w <- weather_features(raw$weather, sort(unique(features$date)))
  expected <- round(w$hdd_anomaly[match(as.Date(map$weeks), w$date)], 1)
  ok <- !is.na(expected)
  expect_true(sum(ok) > 200)
  expect_true(max(abs(map$agg_anomaly[ok] - expected[ok])) <= 0.051)   # both rounded
  expect_true(all(as.POSIXlt(as.Date(map$weeks))$wday == 5))          # Fridays
  expect_length(map$cities, 10)
  expect_equal(map$cities[[8]]$name, "Chicago")
  expect_length(map$cities[[1]]$anomaly, length(map$weeks))
})

test_that("the gas market is taken on the Friday or the last trading day before it", {
  raw <- make_fake_raw()
  colnames(raw$weather) <- WEATHER_CITIES$city
  features <- build_features(raw)
  map <- weather_map_data(raw$weather, features)
  gas <- features[features$asset == "natgas", ]
  k <- which(map$weeks == "2015-07-03")                 # US holiday-like: plain Friday here
  expect_equal(map$ung_vol[k], round(exp(gas$har_m[gas$date == as.Date("2015-07-03")]), 3))
})
