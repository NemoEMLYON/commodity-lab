# 02_features.R — Build the modelling table.
#
# One row per (asset, trading day t) with:
#   - the target: log annualised realised vol over days t+1 .. t+21
#   - features using ONLY information available at the close of day t.
#
# Anti-leakage principle: every external value gets an "available" date
# (the first trading day whose close can use it). Values are attached to the
# trading calendar with an as-of join: on day t we take the latest value
# whose available date is <= t. All rules are documented in CLAUDE.md and
# tested in tests/test_features.R.
#
# Needs the constants of 01_data.R (FRED_SERIES) to be loaded first.

# ---- Configuration ----------------------------------------------------------

ASSETS       <- c("gold", "oil", "copper", "natgas", "corn")
HORIZON      <- 21      # forecast horizon, trading days
TRADING_DAYS <- 252     # annualisation factor
VOL_FLOOR    <- 0.01    # 1% annualised: lower bound before taking logs

# Publication lag after the end of the measured week (a Friday).
EIA_PUBLICATION_LAG_DAYS <- c(crude = 5,   # Wednesday
                              gas   = 6)   # Thursday

# "Average of the same week/day in past years": up to MAX years, at least MIN.
PAST_YEARS_MAX         <- 5    # EIA convention: 5-year average
PAST_YEARS_MIN         <- 3
WEATHER_PAST_YEARS_MAX <- 10

HDD_BASE_F <- 65   # heating degree days: max(0, 65°F - daily mean temperature)

FEATURES_PATH <- file.path("data", "processed", "features.rds")


# ---- Small helpers ----------------------------------------------------------

# x[t + k]: shift a vector k steps into the future (NA at the end).
lead <- function(x, k) {
  c(x[-seq_len(k)], rep(NA, k))
}

# Mean of x[t-k+1 .. t] (right-aligned window, NA until k values exist).
roll_mean <- function(x, k) {
  zoo::rollmeanr(x, k, fill = NA)
}

# Mean squared daily return -> log annualised volatility, floored.
log_vol <- function(mean_sq_return) {
  log(pmax(sqrt(TRADING_DAYS * mean_sq_return), VOL_FLOOR))
}

# First trading day strictly after each date (NA if beyond the calendar).
next_trading_day <- function(dates, calendar) {
  calendar[findInterval(dates, calendar) + 1]
}

# As-of join: for each date in `dates`, the latest value whose `available`
# date is <= that date, NA if nothing is available yet.
# Same idea as pandas.merge_asof(direction = "backward").
# Values with no available date (after the end of the calendar) are dropped.
asof_join <- function(dates, available, values) {
  values    <- values[!is.na(available)]
  available <- available[!is.na(available)]
  ord       <- order(available)
  available <- available[ord]
  values    <- values[ord]

  i   <- findInterval(dates, available)   # how many values are available
  out <- rep(NA_real_, length(dates))
  out[i > 0] <- values[i[i > 0]]
  out
}

# Average of `values` observed lag_days * k days earlier, k = 1..max_years.
# NA if fewer than min_years of those past values exist. Past values only.
past_years_mean <- function(dates, values, lag_days, max_years, min_years) {
  lagged <- do.call(cbind, lapply(seq_len(max_years), function(k) {
    values[match(dates - lag_days * k, dates)]
  }))
  n_found <- rowSums(!is.na(lagged))
  avg     <- rowMeans(lagged, na.rm = TRUE)
  avg[n_found < min_years] <- NA
  avg
}


# ---- Prices, target and HAR features ----------------------------------------

# Adjusted close per trading day. On zero-volume days there was no trade, so
# the close is replaced by the previous close (CLAUDE.md, decision 13).
clean_prices <- function(x) {
  df <- data.frame(date   = as.Date(index(x)),
                   close  = as.numeric(Ad(x)),
                   volume = as.numeric(Vo(x)))
  df <- df[!is.na(df$close), ]

  for (i in seq_len(nrow(df))[-1]) {
    if (df$volume[i] == 0) df$close[i] <- df$close[i - 1]
  }
  df
}

build_asset <- function(prices) {
  df     <- clean_prices(prices)
  ret    <- c(NA, diff(log(df$close)))   # daily log return, known at close t
  ret_sq <- ret^2
  df$ret <- ret

  # Target: realised vol over t+1 .. t+21 (strictly after t).
  df$target <- log_vol(lead(roll_mean(ret_sq, HORIZON), HORIZON))

  # HAR (Corsi, 2009): realised vol over the last 1, 5 and 22 days.
  df$har_d <- log_vol(roll_mean(ret_sq, 1))
  df$har_w <- log_vol(roll_mean(ret_sq, 5))
  df$har_m <- log_vol(roll_mean(ret_sq, 22))

  # Leverage effect: average negative return over the same windows.
  neg <- pmin(ret, 0)
  df$neg_d <- roll_mean(neg, 1)
  df$neg_w <- roll_mean(neg, 5)
  df$neg_m <- roll_mean(neg, 22)

  df
}


# ---- External features (each with its availability date) --------------------

# Implied vol index (VIX, OVX, GVZ), in % -> log of decimal vol.
# Default rule: usable the next trading day.
implied_vol_feature <- function(x, calendar) {
  df <- data.frame(date = as.Date(index(x)), value = as.numeric(x))
  df <- df[!is.na(df$value), ]                 # FRED rows for US holidays
  df$log_iv    <- log(df$value / 100)
  df$available <- next_trading_day(df$date, calendar)
  df
}

# Dollar (UUP ETF): traded on the same exchange, same close as the commodity
# ETFs, so known at the close of its own date.
dollar_features <- function(prices) {
  df  <- clean_prices(prices)
  ret <- c(NA, diff(log(df$close)))
  df$usd_ret_22 <- roll_mean(ret, 22) * 22     # 22-day log return
  df$usd_vol_22 <- log_vol(roll_mean(ret^2, 22))
  df$available  <- df$date
  df
}

# EIA weekly stocks: deviation from the average of the same week in past
# years. Dates are week-end Fridays; 364 days = 52 weeks back = a Friday too.
# Usable the trading day after publication (publication = Friday + lag).
eia_feature <- function(x, publication_lag_days, calendar) {
  df <- data.frame(date = as.Date(index(x)), value = as.numeric(x))
  df$avg_past  <- past_years_mean(df$date, df$value, 364,
                                  PAST_YEARS_MAX, PAST_YEARS_MIN)
  df$deviation <- df$value / df$avg_past - 1
  df$available <- next_trading_day(df$date + publication_lag_days, calendar)
  df
}

# GPR: the daily file is updated weekly on Mondays (next business day if
# holiday). A value for day d is usable from the Wednesday after the first
# Monday strictly after d.
gpr_available_date <- function(d) {
  wday <- as.POSIXlt(d)$wday            # 0 = Sunday, 1 = Monday, ..., 6 = Saturday
  days_to_monday <- (1 - wday) %% 7
  days_to_monday[days_to_monday == 0] <- 7
  d + days_to_monday + 2
}

gpr_features <- function(x) {
  df <- data.frame(date = as.Date(index(x)), gprd = as.numeric(x[, "GPRD"]))
  df$log_gpr_7  <- log(roll_mean(df$gprd, 7))     # level (last week)
  df$log_gpr_30 <- log(roll_mean(df$gprd, 30))    # level (last month)
  df$gpr_shock  <- df$log_gpr_7 - df$log_gpr_30   # change
  df$available  <- gpr_available_date(df$date)
  df
}

# Weather: HDD per city, equal-weighted average, 7-day mean, minus the same
# 7-day mean in past years (365 days back). Usable the next trading day.
weather_features <- function(x, calendar) {
  temps <- coredata(x)                              # one column per city
  df <- data.frame(date = as.Date(index(x)),
                   hdd  = rowMeans(pmax(HDD_BASE_F - temps, 0)))
  df$hdd_7       <- roll_mean(df$hdd, 7)
  df$hdd_normal  <- past_years_mean(df$date, df$hdd_7, 365,
                                    WEATHER_PAST_YEARS_MAX, PAST_YEARS_MIN)
  df$hdd_anomaly <- df$hdd_7 - df$hdd_normal
  df$available   <- next_trading_day(df$date, calendar)
  df
}

# All external features on the trading calendar (one row per trading day).
build_external <- function(raw, calendar) {
  ext <- data.frame(date = calendar)

  for (name in names(FRED_SERIES)) {                # vix, ovx, gvz
    iv <- implied_vol_feature(raw[[name]], calendar)
    ext[[paste0("log_", name)]] <- asof_join(calendar, iv$available, iv$log_iv)
  }

  usd <- dollar_features(raw$dollar)
  ext$usd_ret_22 <- asof_join(calendar, usd$available, usd$usd_ret_22)
  ext$usd_vol_22 <- asof_join(calendar, usd$available, usd$usd_vol_22)

  crude <- eia_feature(raw$crude_stocks, EIA_PUBLICATION_LAG_DAYS[["crude"]], calendar)
  ext$crude_dev <- asof_join(calendar, crude$available, crude$deviation)

  gas <- eia_feature(raw$gas_storage, EIA_PUBLICATION_LAG_DAYS[["gas"]], calendar)
  ext$gas_dev <- asof_join(calendar, gas$available, gas$deviation)

  gpr <- gpr_features(raw$gpr)
  ext$log_gpr_7  <- asof_join(calendar, gpr$available, gpr$log_gpr_7)
  ext$log_gpr_30 <- asof_join(calendar, gpr$available, gpr$log_gpr_30)
  ext$gpr_shock  <- asof_join(calendar, gpr$available, gpr$gpr_shock)

  weather <- weather_features(raw$weather, calendar)
  ext$hdd_anomaly <- asof_join(calendar, weather$available, weather$hdd_anomaly)

  ext
}


# ---- Main entry point -------------------------------------------------------

# Long table: one row per (asset, trading day).
build_features <- function(raw) {
  calendar <- sort(as.Date(index(raw$gold)))   # all ETFs share this calendar
  ext      <- build_external(raw, calendar)

  panel <- lapply(ASSETS, function(asset) {
    df <- build_asset(raw[[asset]])
    df <- merge(df, ext, by = "date", all.x = TRUE)   # left join on the date
    data.frame(asset = asset, df)
  })
  do.call(rbind, panel)
}

# Names of the feature columns (everything that is not an identifier, a
# price, or the target).
feature_columns <- function(features) {
  setdiff(names(features), c("asset", "date", "close", "volume", "ret", "target"))
}


# ---- Quick check ------------------------------------------------------------

# Per asset: rows, first day where target and all features exist, last day
# with a target (21 trading days before the end of the data).
summarise_features <- function(features) {
  cols <- c("target", feature_columns(features))
  rows <- lapply(split(features, features$asset), function(df) {
    complete <- complete.cases(df[, cols])
    data.frame(
      asset          = df$asset[1],
      n_rows         = nrow(df),
      first_complete = min(df$date[complete]),
      last_target    = max(df$date[!is.na(df$target)]),
      n_complete     = sum(complete)
    )
  })
  do.call(rbind, rows)
}

# Per feature: first date with a value (for gold; external features are the
# same for every asset).
feature_start_dates <- function(features, asset = "gold") {
  df <- features[features$asset == asset, ]
  cols <- c("target", feature_columns(features))
  data.frame(
    column     = cols,
    first_date = as.Date(sapply(cols, function(col) min(df$date[!is.na(df[[col]])])))
  )
}
