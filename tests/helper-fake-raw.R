# Synthetic data shaped like the output of download_all(), for offline tests.
# testthat loads every tests/helper-*.R file before running the tests.

library(xts)

# Weekday calendar (no holidays) between two dates.
fake_calendar <- function(from = "2010-01-01", to = "2016-12-31") {
  d <- seq(as.Date(from), as.Date(to), by = "day")
  d[!as.POSIXlt(d)$wday %in% c(0, 6)]
}

# Quantmod-style OHLCV xts built from daily log returns.
fake_prices <- function(dates, returns, ticker = "TEST", volume = 1000) {
  close <- 100 * exp(cumsum(returns))
  x <- xts(cbind(close, close, close, close, volume, close), order.by = dates)
  colnames(x) <- paste0(ticker, c(".Open", ".High", ".Low", ".Close",
                                  ".Volume", ".Adjusted"))
  x
}

make_fake_raw <- function(seed = 1) {
  set.seed(seed)
  cal  <- fake_calendar()
  days <- seq(as.Date("2006-01-01"), as.Date("2016-12-31"), by = "day")
  fridays <- seq(as.Date("2005-01-07"), as.Date("2016-12-30"), by = "week")

  etf <- function(ticker) fake_prices(cal, rnorm(length(cal), 0, 0.01), ticker)
  iv  <- function() {
    x <- xts(20 + rnorm(length(cal), 0, 2), cal)
    x[seq(10, length(cal), by = 50)] <- NA        # holiday-like gaps
    x
  }
  weekly <- function() xts(1000 + 100 * sin(seq_along(fridays) / 8.3) +
                             rnorm(length(fridays), 0, 10), fridays)

  weather <- xts(matrix(50 + 25 * sin(2 * pi * as.numeric(days) / 365.25) +
                          rnorm(length(days) * 10, 0, 5), ncol = 10), days)
  colnames(weather) <- paste0("city_", 1:10)

  gpr <- xts(cbind(GPRD = 100 + rnorm(length(days), 0, 10),
                   GPRD_ACT = 100, GPRD_THREAT = 100), days)

  list(gold = etf("GLD"), oil = etf("USO"), copper = etf("CPER"),
       natgas = etf("UNG"), corn = etf("CORN"), dollar = etf("UUP"),
       vix = iv(), ovx = iv(), gvz = iv(),
       crude_stocks = weekly(), gas_storage = weekly(),
       gpr = gpr, weather = weather)
}

# The data a user could have downloaded at the close of `cutoff` (a weekday):
# each source keeps only the observations already published by then.
# Written with plain date arithmetic, independently of 02_features.R
# (except the GPR rule, whose dates are tested on their own).
vintage_raw <- function(raw, cutoff) {
  cutoff <- as.Date(cutoff)
  keep <- function(x, published) x[published]
  d    <- function(x) as.Date(index(x))

  out <- raw
  for (name in c("gold", "oil", "copper", "natgas", "corn", "dollar")) {
    out[[name]] <- keep(raw[[name]], d(raw[[name]]) <= cutoff)        # same-day close
  }
  for (name in c("vix", "ovx", "gvz", "weather")) {
    out[[name]] <- keep(raw[[name]], d(raw[[name]]) < cutoff)         # next day
  }
  out$crude_stocks <- keep(raw$crude_stocks, d(raw$crude_stocks) + 5 < cutoff)  # Wed release
  out$gas_storage  <- keep(raw$gas_storage,  d(raw$gas_storage)  + 6 < cutoff)  # Thu release
  out$gpr          <- keep(raw$gpr, gpr_available_date(d(raw$gpr)) <= cutoff)
  out
}
