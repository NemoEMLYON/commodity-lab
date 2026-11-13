# Tests for the live layer (R/09_live.R), on synthetic data.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)
source(file.path("..", "R", "03_models.R"), chdir = TRUE)
source(file.path("..", "R", "04_walkforward.R"), chdir = TRUE)
source(file.path("..", "R", "06_backtest.R"), chdir = TRUE)
source(file.path("..", "R", "08_export.R"), chdir = TRUE)
source(file.path("..", "R", "09_live.R"), chdir = TRUE)

# Synthetic data ends in 2016: freeze the 2015 models.
TEST_YEAR <- 2015
raw       <- make_fake_raw()
features  <- build_features(raw)
live_inputs <- raw[c(ASSETS, "vix", "ovx", "gvz")]
frozen    <- freeze_models(features, year = TEST_YEAR)


# ---- Same features as the pipeline ------------------------------------------

test_that("live features are identical to the pipeline's on every shared column", {
  live <- build_live_features(live_inputs)
  cmp  <- compare_features(live, features)
  expect_equal(cmp$n_common[1], nrow(features))
  expect_true(all(cmp$max_gap == 0))
  expect_true(all(cmp$na_differ == 0))
})


# ---- Frozen models = walk-forward models --------------------------------------

test_that("the frozen models reproduce the walk-forward forecasts of their year", {
  wf    <- walk_forward(features, LIVE_MODELS, test_years = TEST_YEAR)
  check <- check_frozen(frozen, features, wf)
  expect_setequal(check$model, c("naive", "ewma", "har", "lasso_b2_iv", "rf_b2_iv", "har_x"))
  expect_true(all(check$gap < 1e-12))
  expect_true(all(check$n_compared > 1000))
})

test_that("T0 is 21 trading days before the first test day", {
  calendar <- sort(unique(features$date))
  expect_equal(match(frozen$first_test, calendar) - match(frozen$t0, calendar), HORIZON)
  expect_equal(format(frozen$first_test, "%Y"), as.character(TEST_YEAR))
})


# ---- No look-ahead in the live track record -----------------------------------

test_that("no forecast before the frozen model existed", {
  preds <- predict_frozen(frozen, build_live_features(live_inputs))
  expect_equal(min(preds$date), frozen$first_test)
})

test_that("a forecast does not change when later data changes or disappears", {
  cutoff <- as.Date("2015-09-15")
  full   <- predict_frozen(frozen, build_live_features(live_inputs))

  # Data as it was at the close of `cutoff` (implied vol published next day).
  past <- lapply(names(live_inputs), function(n) {
    x <- live_inputs[[n]]
    if (n %in% ASSETS) x[as.Date(index(x)) <= cutoff] else x[as.Date(index(x)) < cutoff]
  })
  names(past) <- names(live_inputs)
  then <- predict_frozen(frozen, build_live_features(past))

  key_f <- paste(full$asset, full$model, full$date)
  key_t <- paste(then$asset, then$model, then$date)
  expect_equal(max(then$date), cutoff)
  expect_equal(then$pred_log_vol, full$pred_log_vol[match(key_t, key_f)])
})


# ---- Track record ------------------------------------------------------------

test_that("the last 21 days of each asset are pending, the rest are scored", {
  preds <- predict_frozen(frozen, build_live_features(live_inputs))
  track <- live_track_record(preds, forward_from = character(0))   # every model from day 1
  per_asset <- track[track$asset != "all", ]
  expect_true(all(per_asset$n_pending == HORIZON))
  expect_equal(track$qlike_vs_har[track$model == "har"], rep(1, 6))
  expect_true(all(is.na(track$coverage80[track$model %in% c("naive", "ewma")])))
  expect_true(all(track$coverage80[track$model == "har"] > 0.5))
})

test_that("a model added later is scored only from that day, against HAR on the same days", {
  preds <- predict_frozen(frozen, build_live_features(live_inputs))
  added <- as.Date("2016-06-01")
  track <- live_track_record(preds, forward_from = c(har_x = format(added)))

  hx  <- preds[preds$model == "har_x" & preds$date >= added & !is.na(preds$target), ]
  har <- preds[preds$model == "har" & !is.na(preds$target) &
               paste(preds$asset, preds$date) %in% paste(hx$asset, hx$date), ]
  row <- track[track$model == "har_x" & track$asset == "all", ]
  expect_equal(row$n_scored, nrow(hx))
  expect_equal(row$scored_from, added)
  expect_equal(row$qlike_vs_har,
               mean(qlike(hx$realized_var, hx$pred_var)) / mean(qlike(har$realized_var, har$pred_var)))
  # The original models still start on the first live day
  expect_equal(track$scored_from[track$model == "har" & track$asset == "all"], min(preds$date))
})

test_that("a model with no outcome known yet has no score, only pending days", {
  preds <- predict_frozen(frozen, build_live_features(live_inputs))
  last  <- max(preds$date)
  added <- sort(unique(preds$date))[length(unique(preds$date)) - 9]   # 10 days before the end
  track <- live_track_record(preds, forward_from = c(har_x = format(added)))
  row <- track[track$model == "har_x" & track$asset == "oil", ]
  expect_equal(row$n_scored, 0)
  expect_equal(row$n_pending, 10)
  expect_true(is.na(row$qlike_vs_har) && is.na(row$coverage80))
  expect_true(last >= added)
})

test_that("live combinations average the members' variance forecasts", {
  preds <- predict_frozen(frozen, build_live_features(live_inputs))
  out <- add_live_combinations(preds, list(comb_har_ewma = c("har", "ewma")))
  comb <- out[out$model == "comb_har_ewma", ]
  har  <- preds[preds$model == "har", ]
  ewma <- preds[preds$model == "ewma", ]
  key <- function(p) paste(p$asset, p$date)
  expect_equal(comb$pred_var,
               (har$pred_var[match(key(comb), key(har))] + ewma$pred_var[match(key(comb), key(ewma))]) / 2)
  expect_true(all(comb$resid_var == 0))
  track <- live_track_record(out, forward_from = character(0))
  expect_true(all(is.na(track$coverage80[track$model == "comb_har_ewma"])))
  expect_equal(nrow(out), nrow(preds) + nrow(har))
})

test_that("every live combination is built from served models and has a start date", {
  served <- vapply(LIVE_MODELS, `[[`, "", "name")
  for (name in names(LIVE_COMBINATIONS)) {
    expect_true(all(LIVE_COMBINATIONS[[name]] %in% served), info = name)
    expect_true(name %in% names(LIVE_FORWARD_FROM), info = name)
  }
  preds <- add_live_combinations(predict_frozen(frozen, build_live_features(live_inputs)))
  expect_true(all(names(LIVE_COMBINATIONS) %in% preds$model))
})

test_that("a frozen file saved before a model was added still predicts the others", {
  old <- frozen
  old$fitted$har_x <- NULL
  preds <- predict_frozen(old, build_live_features(live_inputs))
  expect_false("har_x" %in% preds$model)
  expect_setequal(unique(preds$model), c("naive", "ewma", "har", "lasso_b2_iv", "rf_b2_iv"))
})

test_that("the 80% interval surrounds the forecast", {
  m <- interval_multipliers(c(0.04, 0.09))
  expect_true(all(m$lo < 1 & m$hi > 1))
  # Probability mass: log vol between pred - z s and pred + z s is 80%.
  s <- 0.2
  expect_equal(log(interval_multipliers(s^2)$hi / interval_multipliers(s^2)$lo),
               2 * INTERVAL_Z * s)
})


# ---- Fallback ------------------------------------------------------------------

test_that("a successful download is live and saved as the new snapshot", {
  snap_path <- tempfile(fileext = ".rds")
  s <- get_live_snapshot(snap_path, raw_dir = tempdir(), fetch = function() live_inputs)
  expect_equal(s$mode, "live")
  expect_true(file.exists(snap_path))
  expect_equal(s$asof, as.Date("2016-12-30"))
})

test_that("a failed download falls back to the snapshot, then to the cache", {
  snap_path <- tempfile(fileext = ".rds")
  saveRDS(live_inputs, snap_path)
  s <- get_live_snapshot(snap_path, raw_dir = tempdir(), fetch = function() NULL)
  expect_equal(s$mode, "offline")
  expect_equal(s$source, "last live snapshot")

  cache <- tempfile(); dir.create(cache)
  for (a in ASSETS) saveRDS(live_inputs[[a]], file.path(cache, paste0("yahoo_", YAHOO_TICKERS[[a]], ".rds")))
  for (n in names(FRED_SERIES)) saveRDS(live_inputs[[n]], file.path(cache, paste0("fred_", FRED_SERIES[[n]], ".rds")))
  s <- get_live_snapshot(tempfile(), raw_dir = cache, fetch = function() NULL)
  expect_equal(s$source, "pipeline data cache")

  expect_error(get_live_snapshot(tempfile(), raw_dir = tempfile(), fetch = function() NULL),
               "nothing to show")
})

test_that("LIVE_DISABLED=1 never calls the network", {
  snap_path <- tempfile(fileext = ".rds")
  saveRDS(live_inputs, snap_path)
  Sys.setenv(LIVE_DISABLED = "1")
  on.exit(Sys.unsetenv("LIVE_DISABLED"))
  s <- get_live_snapshot(snap_path, fetch = function() stop("network called"))
  expect_equal(s$mode, "offline")
})

test_that("without any data the previous live.json is kept and marked offline", {
  dir <- tempfile(); dir.create(dir)
  preds   <- predict_frozen(frozen, build_live_features(live_inputs))
  snap    <- list(data = live_inputs, mode = "live", asof = as.Date("2016-12-30"), source = "test")
  payload <- live_payload(snap, frozen, preds, build_live_features(live_inputs))
  path    <- write_site_json(payload, "live", dir = dir)
  mark_offline(path)
  after <- read_json(path)
  expect_equal(after$run$mode, "offline")
  expect_equal(after$run$last_close, "2016-12-30")
  expect_length(after$today, 5)
})


# ---- Freshness ------------------------------------------------------------------

test_that("an input older than its availability rule is flagged", {
  fresh <- freshness_table(live_inputs, as.Date("2016-12-30"))
  expect_true(all(fresh$status == "current"))

  late <- live_inputs
  late$ovx <- late$ovx[as.Date(index(late$ovx)) <= as.Date("2016-12-20")]
  fresh <- freshness_table(late, as.Date("2016-12-30"))
  expect_equal(fresh$status[fresh$series == "OVXCLS"], "behind")
  expect_equal(sum(fresh$status == "behind"), 1)
})


# ---- FRED CSV export ------------------------------------------------------------

test_that("the FRED CSV parser reads both file versions and missing days", {
  new <- "observation_date,VIXCLS\n2026-11-10,17.5\n2026-11-11,\n2026-11-12,18.25\n"
  old <- "DATE,VIXCLS\n2026-11-10,17.5\n2026-11-11,.\n2026-11-12,18.25\n"
  for (text in c(new, old)) {
    x <- parse_fred_csv(text, "VIXCLS")
    expect_equal(format(index(x)), c("2026-11-10", "2026-11-11", "2026-11-12"))
    expect_equal(as.numeric(x), c(17.5, NA, 18.25))
    expect_equal(colnames(x), "VIXCLS")
  }
})

test_that("the FRED CSV parser refuses anything else", {
  expect_error(parse_fred_csv("<html><body>Error</body></html>", "VIXCLS"), "Unexpected")
  expect_error(parse_fred_csv("observation_date,OVXCLS\n2026-11-10,30\n", "VIXCLS"), "Unexpected")
})

test_that("CSV values feed the implied vol columns like the API values", {
  csv <- parse_fred_csv("observation_date,VIXCLS\n2016-12-28,20\n2016-12-29,\n2016-12-30,25\n", "VIXCLS")
  cal <- as.Date(c("2016-12-28", "2016-12-29", "2016-12-30", "2017-01-03"))
  iv  <- implied_vol_feature(csv, cal)
  expect_equal(iv$available, as.Date(c("2016-12-29", "2017-01-03")))   # next trading day
  expect_equal(iv$log_iv, log(c(0.20, 0.25)))
})


# ---- Today's session ---------------------------------------------------------------

test_that("today's bar is kept only once the New York session is over", {
  x <- fake_prices(as.Date(c("2026-11-11", "2026-11-12")), c(0, 0.01))
  # 12 Nov 2026, 15:00 New York = 20:00 UTC (EST, UTC-5): session still open
  open_now   <- as.POSIXct("2026-11-12 20:00:00", tz = "UTC")
  # 12 Nov 2026, 17:30 New York = 22:30 UTC: when the daily job runs
  closed_now <- as.POSIXct("2026-11-12 22:30:00", tz = "UTC")
  # 13 Nov 2026, 00:05 in Paris = 18:05 New York on the 12th: closed
  paris_now  <- as.POSIXct("2026-11-13 00:05:00", tz = "Europe/Paris")

  expect_equal(format(index(completed_sessions(x, open_now))), "2026-11-11")
  expect_equal(format(index(completed_sessions(x, closed_now))), c("2026-11-11", "2026-11-12"))
  expect_equal(format(index(completed_sessions(x, paris_now))), c("2026-11-11", "2026-11-12"))
})
