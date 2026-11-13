# 09_live.R — Live inference with models trained offline.
#
# Principle: "offline training, live inference".
#   - freeze_models() refits, ONCE, the models of the last walk-forward year
#     (same training rows, same settings) and saves them in models/.
#   - Every day, the live layer downloads recent prices and implied vol,
#     rebuilds the features with the SAME functions as the pipeline
#     (02_features.R), applies the frozen models and writes site/data/live.json.
#   - If the download fails, it falls back to the last saved snapshot.
#
# Only five models are served: naive, EWMA, HAR, Lasso + implied vol and
# forest + implied vol (block B2). They need nothing but ETF prices and the
# Cboe implied vol indices, so EIA, weather, GPR and dollar data are not
# downloaded live (blocks B3/B4 never beat B2 out of sample).
#
# Needs 01_data.R, 02_features.R, 03_models.R, 04_walkforward.R,
# 06_backtest.R and 08_export.R to be loaded first.

# ---- Configuration ----------------------------------------------------------

FROZEN_YEAR        <- 2026     # last walk-forward year: its models are frozen
FROZEN_MODELS_PATH <- file.path("models", "frozen_models.rds")
LIVE_SNAPSHOT_PATH <- file.path("data", "processed", "live_snapshot.rds")

# Forest setting chosen on 2015-2016 (pipeline.R step 3, PROJECT_LOG S5).
LIVE_RF_MIN_NODE <- 200

b2_features <- function(asset) block_features("b2", asset)

LIVE_MODELS <- list(
  model_naive,
  model_ewma,
  model_har,
  make_lasso("lasso_b2_iv", b2_features),
  make_rf("rf_b2_iv", b2_features, pooled = FALSE, min_node_size = LIVE_RF_MIN_NODE),
  extension_e1_models()[[1]]        # har_x, added in S16 (see LIVE_FORWARD_FROM)
)

# Forward test of post hoc extensions (S16-S17). These models were added to
# the live job AFTER the study's results were known, so they are scored only
# on forecasts made from the day they were added: new data no one had seen.
# Their earlier 2026 forecasts exist (same frozen fit) but are not scored.
# Both decisions were taken on 2026-11-13 before the US close.
LIVE_FORWARD_FROM <- c(har_x               = "2026-11-13",
                       comb_har_harx       = "2026-11-13",
                       comb_har_ewma_lasso = "2026-11-13")

# Combinations served live: name -> members (equal weights on variance).
# The two best of extensions E2 on pooled QLIKE 2017-2025 (pre-registered
# rule), chosen on 2026-11-13.
LIVE_COMBINATIONS <- list(
  comb_har_harx       = c("har", "har_x"),
  comb_har_ewma_lasso = c("har", "ewma", "lasso_b2_iv")
)

# Model shown first for each asset: the one the study supports out of sample.
# Only oil has a model that beat HAR significantly (Lasso with OVX).
HEADLINE_MODEL <- c(gold = "har", oil = "lasso_b2_iv", copper = "har",
                    natgas = "har", corn = "har")

INTERVAL_Z <- qnorm(0.90)      # 80% interval: 10% below, 10% above


# ---- 1. Freeze the models (run once a year, offline) ------------------------

# Refit every live model on exactly the rows walk_forward() used for
# `year`: rows whose target was known 21 trading days before the first test
# day. Returns the fitted objects (not the functions: those stay in code).
freeze_models <- function(features, year = FROZEN_YEAR, models = LIVE_MODELS) {
  data     <- model_rows(features)
  calendar <- sort(unique(features$date))
  first    <- min(data$date[format(data$date, "%Y") == as.character(year)])
  t0       <- training_cutoff(calendar, first)
  train    <- data[data$date <= t0, ]

  fitted <- list()
  for (model in models) {
    for (asset in ASSETS) {
      fitted[[model$name]][[asset]] <- slim_fitted(model$fit(train[train$asset == asset, ]))
    }
  }
  list(fitted     = fitted,
       year       = year,
       t0         = t0,                          # last training date
       first_test = first,
       n_train    = table(train$asset),
       created    = Sys.Date())
}

# Inputs of the baselines (the ML models store theirs in fitted$features).
BASELINE_INPUTS <- list(naive = "har_m", ewma = "ewma", har = c("har_d", "har_w", "har_m"))

# Drop what a fitted model keeps but never needs to predict, so that
# models/ stays small enough for Git (7 MB -> see freeze_models.R output):
#   lm:     a copy of the training data (model), residuals, fitted values,
#           and the environment of its formula (which drags the whole
#           training table along when saved)
#   ranger: the out-of-bag predictions (resid_var is already computed)
slim_fitted <- function(fitted) {
  if (!is.null(fitted$ols)) {
    fitted$ols[c("model", "residuals", "fitted.values", "effects")] <- NULL
    attr(fitted$ols$terms, ".Environment") <- globalenv()
  }
  if (!is.null(fitted$rf)) fitted$rf$predictions <- NULL
  fitted
}

# Add the live combinations to the frozen models' predictions. Same rule as
# extensions E2: mean of the members' variance forecasts, on the days where
# every member forecasts. No interval (resid_var = 0, like EWMA).
add_live_combinations <- function(preds, combinations = LIVE_COMBINATIONS) {
  out <- list(preds)
  for (name in names(combinations)) {
    members <- combinations[[name]]
    parts <- lapply(members, function(m) preds[preds$model == m, ])
    key   <- function(p) paste(p$asset, p$date)
    common <- Reduce(intersect, lapply(parts, key))
    parts <- lapply(parts, function(p) { p <- p[key(p) %in% common, ]; p[order(p$asset, p$date), ] })
    comb <- parts[[1]]
    comb$model        <- name
    comb$pred_var     <- Reduce(`+`, lapply(parts, `[[`, "pred_var")) / length(parts)
    comb$pred_log_vol <- log(comb$pred_var) / 2
    comb$resid_var    <- 0
    out[[length(out) + 1]] <- comb
  }
  do.call(rbind, out)
}

# Predictions of the frozen models on a features table (full or live).
# One row per (asset, model, date) with all inputs present, from the first
# day of the frozen year. Not from T0 + 1: the model is trained on targets
# that end 21 days after T0, so it only exists from that first test day on.
# Using it earlier would be a look-ahead.
predict_frozen <- function(frozen, features, models = LIVE_MODELS) {
  out <- list()
  for (model in models) {
    for (asset in ASSETS) {
      fitted <- frozen$fitted[[model$name]][[asset]]
      if (is.null(fitted)) next          # model added after this file was frozen
      cols   <- if (is.null(fitted$features)) BASELINE_INPUTS[[model$name]] else fitted$features
      rows <- features[features$asset == asset & features$date >= frozen$first_test, ]
      rows <- rows[complete.cases(rows[, cols, drop = FALSE]), ]
      if (nrow(rows) == 0) next
      pred <- model$predict(fitted, rows)
      out[[length(out) + 1]] <- data.frame(
        asset        = asset,
        model        = model$name,
        date         = rows$date,
        pred_log_vol = pred,
        resid_var    = fitted$resid_var,
        pred_var     = to_variance(pred, fitted$resid_var),
        target       = rows$target,
        realized_var = exp(2 * rows$target))
    }
  }
  do.call(rbind, out)
}

# Largest gap between the frozen models and the walk-forward predictions of
# the same year. Should be 0: same rows, same settings, same seed.
check_frozen <- function(frozen, features, predictions) {
  cols   <- c("asset", "model", "date", "pred_log_vol")
  frozen_pred <- predict_frozen(frozen, model_rows(features))[, cols]
  wf     <- predictions[predictions$test_year == frozen$year, cols]
  both   <- merge(frozen_pred, wf, by = c("asset", "model", "date"),
                  suffixes = c("_frozen", "_walk_forward"))     # inner join
  both$gap <- abs(both$pred_log_vol_frozen - both$pred_log_vol_walk_forward)
  out <- aggregate(gap ~ model, data = both, FUN = max)
  out$n_compared <- as.numeric(table(both$model)[out$model])
  out
}


# ---- 2. Live data with a fallback --------------------------------------------

# Call fetch(); on error wait and try once more. NULL if both attempts fail.
try_twice <- function(fetch, wait = 5) {
  for (attempt in 1:2) {
    result <- tryCatch(fetch(), error = function(e) {
      message("  attempt ", attempt, " failed: ", conditionMessage(e))
      NULL
    })
    if (!is.null(result)) return(result)
    if (attempt == 1) Sys.sleep(wait)
  }
  NULL
}

# Yahoo through quantmod, including today's session once it is over.
# getSymbols() stops BEFORE its `to` date (default: today), so on the
# evening of day t it returned day t-1 as the last close: the daily job ran
# one day late (seen in S14: last close 11 Nov on the evening of 12 Nov).
fetch_yahoo_live <- function(ticker, now = Sys.time()) {
  today_ny <- as.Date(format(now, tz = "America/New_York"))
  x <- getSymbols(ticker, src = "yahoo", from = START_DATE, to = today_ny + 1,
                  auto.assign = FALSE)
  completed_sessions(x, now)
}

# Drop today's bar while the New York session is still open: before the
# close it is a live quote, not a closing price.
US_CLOSE_NY <- "16:15"     # 16:00 close + 15 minutes for the closing prints

completed_sessions <- function(x, now = Sys.time(), close_time = US_CLOSE_NY) {
  today_ny <- as.Date(format(now, tz = "America/New_York"))
  closed   <- format(now, "%H:%M", tz = "America/New_York") >= close_time
  if (closed) x else x[as.Date(index(x)) < today_ny]
}

# FRED's public CSV export: the same series as the API, without a key.
# Used first for the live layer (the API refused requests in S14 while the
# CSV export kept working); the API with the key is the fallback.
FRED_CSV_URL <- "https://fred.stlouisfed.org/graph/fredgraph.csv"

fetch_fred_csv <- function(series_id, timeout_seconds = 10) {
  request(FRED_CSV_URL) |>
    req_url_query(id = series_id) |>        # full history, like the API
    req_timeout(timeout_seconds) |>
    req_perform() |>
    resp_body_string() |>
    parse_fred_csv(series_id)
}

# Text of fredgraph.csv -> xts with one column named after the series.
# Two columns: date ("observation_date", or "DATE" in older files) and value;
# missing days are empty or "." depending on the file version.
parse_fred_csv <- function(text, series_id) {
  df <- read.csv(text = text, stringsAsFactors = FALSE, na.strings = c("", "."))
  if (ncol(df) != 2 || names(df)[2] != series_id) {
    stop("Unexpected FRED response for ", series_id)   # e.g. an HTML error page
  }
  x <- xts(as.numeric(df[[2]]), order.by = as.Date(df[[1]]))
  colnames(x) <- series_id
  x
}

# Full history of the 5 ETFs (Yahoo) and the 3 implied vol indices (FRED),
# with the same sources as the pipeline. Full history, not a short
# window: the 22-day windows and the EWMA need a warm-up, and identical
# inputs give features identical to the pipeline's. NULL if anything fails.
fetch_live_raw <- function(timeout_seconds = 10) {
  old <- options(timeout = timeout_seconds)
  on.exit(options(old))
  raw <- list()
  for (asset in ASSETS) {
    message("[live] Yahoo ", YAHOO_TICKERS[[asset]])
    raw[[asset]] <- try_twice(function() fetch_yahoo_live(YAHOO_TICKERS[[asset]]))
    if (is.null(raw[[asset]])) return(NULL)
  }
  for (name in names(FRED_SERIES)) {
    id <- FRED_SERIES[[name]]
    message("[live] FRED ", id)
    raw[[name]] <- try_twice(function() fetch_fred_csv(id, timeout_seconds))
    if (is.null(raw[[name]]) && Sys.getenv("FRED_API_KEY") != "") {
      message("  CSV export failed, trying the FRED API")
      raw[[name]] <- try_twice(function() fetch_fred(id))
    }
    if (is.null(raw[[name]])) return(NULL)
  }
  raw
}

# The pipeline's own cache (data/raw/), restricted to the live inputs.
# NULL if a file is missing.
load_cached_raw <- function(raw_dir = RAW_DIR) {
  files <- c(setNames(paste0("yahoo_", YAHOO_TICKERS[ASSETS]), ASSETS),
             setNames(paste0("fred_", FRED_SERIES), names(FRED_SERIES)))
  paths <- file.path(raw_dir, paste0(files, ".rds"))
  if (!all(file.exists(paths))) return(NULL)
  setNames(lapply(paths, readRDS), names(files))
}

# Live data if possible, otherwise the last snapshot, otherwise the
# pipeline cache. Never stops while one of them exists.
#   LIVE_DISABLED=1 in the environment forces offline mode (tests).
# Returns list(data, mode = "live" | "offline", asof, source).
get_live_snapshot <- function(snapshot_path = LIVE_SNAPSHOT_PATH, raw_dir = RAW_DIR,
                              fetch = fetch_live_raw) {
  raw <- NULL
  if (Sys.getenv("LIVE_DISABLED") != "1") raw <- fetch()

  if (!is.null(raw)) {
    dir.create(dirname(snapshot_path), recursive = TRUE, showWarnings = FALSE)
    saveRDS(raw, snapshot_path)
    mode <- "live"; source <- "Yahoo Finance and FRED, downloaded now"
  } else if (file.exists(snapshot_path)) {
    raw <- readRDS(snapshot_path)
    mode <- "offline"; source <- "last live snapshot"
  } else {
    raw <- load_cached_raw(raw_dir)
    mode <- "offline"; source <- "pipeline data cache"
    if (is.null(raw)) stop("No live data, no snapshot and no cache: nothing to show.")
  }
  # Last close shared by the 5 ETFs (a lagging ticker holds the date back).
  asof <- min(sapply(ASSETS, function(a) max(as.Date(index(raw[[a]])))))
  list(data = raw, mode = mode, asof = as.Date(asof, origin = "1970-01-01"),
       source = source)
}


# ---- 3. Features, forecasts, track record -------------------------------------

# Same code path as build_features(): own-return features + implied vol.
build_live_features <- function(raw) {
  build_features(raw, external = implied_vol_columns)
}

# One row per input: where it comes from and how recent it is.
#   current: the latest value the availability rules allow is there
#   behind:  older than that (source late or download incomplete)
freshness_table <- function(raw, asof) {
  calendar <- sort(as.Date(index(raw$gold)))
  previous_day <- calendar[max(which(calendar < asof))]
  last_obs <- function(x) max(as.Date(index(x))[!is.na(as.numeric(x[, 1]))])

  etf <- data.frame(
    input    = paste(ASSET_INFO$name, "ETF price"),
    series   = YAHOO_TICKERS[ASSETS],
    source   = "Yahoo Finance",
    rule     = "same close",
    last_obs = as.Date(sapply(ASSETS, function(a) last_obs(raw[[a]])), origin = "1970-01-01"),
    expected = asof)
  iv <- data.frame(
    input    = c("VIX (S&P 500 implied vol)", "OVX (oil implied vol)", "GVZ (gold implied vol)"),
    series   = unname(FRED_SERIES),
    source   = "FRED (Cboe)",
    rule     = "next trading day",
    last_obs = as.Date(sapply(names(FRED_SERIES), function(n) last_obs(raw[[n]])), origin = "1970-01-01"),
    expected = previous_day)
  out <- rbind(etf, iv)
  out$status <- ifelse(out$last_obs >= out$expected, "current", "behind")
  rownames(out) <- NULL
  out
}

# Lognormal 80% interval of annualised vol, as multipliers of the forecast
# sqrt(pred_var). log vol ~ N(pred, s^2) and sqrt(pred_var) = exp(pred + s^2).
interval_multipliers <- function(resid_var, z = INTERVAL_Z) {
  s <- sqrt(resid_var)
  list(lo = exp(-z * s - s^2), hi = exp(z * s - s^2))
}

# First day a model is scored live: the first day of the frozen year, or
# the day a post hoc model was added (LIVE_FORWARD_FROM).
scored_from <- function(model, first_test, forward_from = LIVE_FORWARD_FROM) {
  if (model %in% names(forward_from)) as.Date(forward_from[[model]]) else as.Date(first_test)
}

# Metrics on the days whose 21-day outcome is known, from the day each
# model is scored (scored_from).
#   qlike_vs_har < 1: better than HAR ON THE SAME DAYS
#   coverage80: share of days where realised vol fell inside the 80% interval
#   NA while a model has no scored day yet (its first outcome is 21 days away)
live_track_record <- function(preds, first_test = min(preds$date),
                              forward_from = LIVE_FORWARD_FROM) {
  loss <- qlike(preds$realized_var, preds$pred_var)
  rows <- list()
  for (asset in c(ASSETS, "all")) {
    for (m in unique(preds$model)) {
      keep <- preds$model == m & (asset == "all" | preds$asset == asset) &
              preds$date >= scored_from(m, first_test, forward_from)
      p <- preds[keep, ]
      scored <- p[!is.na(p$target), ]
      n <- nrow(scored)
      # HAR on exactly the same (asset, date) pairs
      har_keep <- preds$model == "har" & !is.na(preds$target) &
                  paste(preds$asset, preds$date) %in% paste(scored$asset, scored$date)
      mult <- interval_multipliers(scored$resid_var)
      vol  <- sqrt(scored$pred_var)
      real <- exp(scored$target)
      rows[[length(rows) + 1]] <- data.frame(
        asset        = asset,
        model        = m,
        scored_from  = scored_from(m, first_test, forward_from),
        n_scored     = n,
        n_pending    = sum(is.na(p$target)),
        qlike        = if (n > 0) mean(loss[keep & !is.na(preds$target)]) else NA_real_,
        qlike_vs_har = if (n > 0) mean(loss[keep & !is.na(preds$target)]) / mean(loss[har_keep]) else NA_real_,
        rmse_log     = if (n > 0) sqrt(mean((scored$pred_log_vol - scored$target)^2)) else NA_real_,
        coverage80   = if (n > 0 && all(scored$resid_var > 0))   # no interval for naive/EWMA
          mean(real >= vol * mult$lo & real <= vol * mult$hi) else NA_real_)
    }
  }
  do.call(rbind, rows)
}

# Today's forecast per asset: every model, the headline model with its 80%
# interval, its rank in the asset's history, and the vol-targeting weight.
today_table <- function(preds, live_features) {
  rows <- list()
  for (asset in ASSETS) {
    p     <- preds[preds$asset == asset, ]
    day   <- max(p$date)
    today <- p[p$date == day, ]
    main  <- today[today$model == HEADLINE_MODEL[[asset]], ]
    vol   <- sqrt(main$pred_var)
    mult  <- interval_multipliers(main$resid_var)

    hist_vol <- exp(live_features$target[live_features$asset == asset])
    hist_vol <- hist_vol[!is.na(hist_vol)]
    f <- live_features[live_features$asset == asset & live_features$date == day, ]

    # Headline forecast one week (5 trading days) earlier, for the trend.
    dates_h  <- sort(unique(p$date[p$model == HEADLINE_MODEL[[asset]]]))
    week_ago <- if (length(dates_h) > 5) dates_h[length(dates_h) - 5] else NA
    prev     <- p[p$model == HEADLINE_MODEL[[asset]] & p$date == week_ago, ]

    rows[[asset]] <- list(
      id             = asset,
      date           = day,
      headline_model = HEADLINE_MODEL[[asset]],
      forecast_vol   = vol,
      lo80           = vol * mult$lo,
      hi80           = vol * mult$hi,
      week_ago_vol   = if (nrow(prev) == 1) sqrt(prev$pred_var) else NA,
      last_month_vol = exp(f$har_m),
      percentile     = mean(hist_vol < vol),      # share of past months calmer
      history_from   = min(live_features$date[live_features$asset == asset & !is.na(live_features$target)]),
      weight_10      = target_weight(main$pred_var),
      models         = setNames(as.list(sqrt(today$pred_var)), today$model))
  }
  unname(rows)
}

# Daily series since T0 for the chart: headline forecast, HAR forecast,
# realised vol over the following 21 days (null while pending).
live_history <- function(preds) {
  out <- list()
  for (asset in ASSETS) {
    main <- preds[preds$asset == asset & preds$model == HEADLINE_MODEL[[asset]], ]
    har  <- preds[preds$asset == asset & preds$model == "har", ]
    main <- main[order(main$date), ]
    mult <- interval_multipliers(main$resid_var[1])
    out[[asset]] <- list(
      date     = format(main$date),
      forecast = round(sqrt(main$pred_var), 4),
      har      = round(sqrt(har$pred_var[match(main$date, har$date)]), 4),
      realised = round(exp(main$target), 4),
      lo_mult  = round(mult$lo, 4),
      hi_mult  = round(mult$hi, 4))
  }
  out
}

# Everything the "Today" section of the site reads, in one list.
live_payload <- function(snapshot, frozen, preds, live_features, run_at = Sys.time()) {
  list(
    run = list(mode       = snapshot$mode,
               source     = snapshot$source,
               last_close = snapshot$asof,
               run_at     = format(run_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
               t0         = frozen$t0,                 # last training date
               live_from  = frozen$first_test,         # first day the model existed
               frozen_year = frozen$year,
               headline   = as.list(HEADLINE_MODEL),
               forward_from = as.list(LIVE_FORWARD_FROM)),
    today     = today_table(preds, live_features),
    history   = live_history(preds),
    track     = live_track_record(preds, frozen$first_test),
    freshness = freshness_table(snapshot$data, snapshot$asof))
}


# ---- 4. Consistency with the pipeline ------------------------------------------

# Largest absolute gap per column between live features and the pipeline's
# features.rds, on the (asset, date) rows present in both.
compare_features <- function(live, pipeline,
                             cols = c("target", BASE_FEATURES, "log_vix", "log_ovx", "log_gvz")) {
  key_l <- paste(live$asset, live$date)
  key_p <- paste(pipeline$asset, pipeline$date)
  common <- intersect(key_l, key_p)
  l <- live[match(common, key_l), ]
  p <- pipeline[match(common, key_p), ]
  data.frame(column    = cols,
             n_common  = length(common),
             max_gap   = sapply(cols, function(c) max(abs(l[[c]] - p[[c]]), na.rm = TRUE)),
             na_differ = sapply(cols, function(c) sum(is.na(l[[c]]) != is.na(p[[c]]))),
             row.names = NULL)
}

# No data at all (download failed, no snapshot): keep the previous forecasts
# and say so on the site, rather than failing the daily job.
mark_offline <- function(path = file.path(SITE_DATA_DIR, "live.json"), run_at = Sys.time()) {
  if (!file.exists(path)) stop("No live data and no previous live.json.")
  payload <- read_json(path, simplifyVector = FALSE)
  payload$run$mode   <- "offline"
  payload$run$source <- "previous update (download failed)"
  payload$run$run_at <- format(run_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  write_json(payload, path, auto_unbox = TRUE, digits = NA, null = "null", na = "null")
  path
}
