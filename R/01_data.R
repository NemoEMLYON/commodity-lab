# 01_data.R — Download raw market data and cache it on disk.
#
# This file only defines constants and functions; pipeline.R calls them.
# Raw data is saved exactly as received from the source. Cleaning, date
# alignment and lags happen later, in 02_features.R.

library(quantmod)

# ---- Configuration ----------------------------------------------------------

# CPER (copper) starts in Nov 2011; earlier days serve as warm-up for the
# 22-day HAR features.
START_DATE <- as.Date("2011-01-01")

RAW_DIR <- file.path("data", "raw")

# Yahoo Finance tickers: daily Open, High, Low, Close, Volume, Adjusted.
YAHOO_TICKERS <- c(
  gold   = "GLD",
  oil    = "USO",
  copper = "CPER",
  natgas = "UNG",
  corn   = "CORN",
  dollar = "UUP"   # dollar index ETF, used as a macro feature
)

# FRED series: Cboe implied volatility indices, daily close.
FRED_SERIES <- c(
  vix = "VIXCLS",  # S&P 500
  ovx = "OVXCLS",  # crude oil (options on USO)
  gvz = "GVZCLS"   # gold (options on GLD)
)


# ---- Cache ------------------------------------------------------------------

# Return the cached copy of `name` if it exists; otherwise call `fetch()`,
# save the result to data/raw/<name>.rds and return it.
# refresh = TRUE forces a new download (the cache is the data snapshot).
fetch_or_load <- function(name, fetch, refresh = FALSE) {
  path <- file.path(RAW_DIR, paste0(name, ".rds"))

  if (file.exists(path) && !refresh) {
    message("[cache] ", name)
    return(readRDS(path))
  }

  message("[fetch] ", name)
  data <- fetch()
  saveRDS(data, path)
  data
}


# ---- Sources ----------------------------------------------------------------

fetch_yahoo <- function(ticker) {
  getSymbols(ticker, src = "yahoo", from = START_DATE, auto.assign = FALSE)
}

fetch_fred <- function(series_id) {
  getSymbols(series_id, src = "FRED", auto.assign = FALSE)
}


# ---- Main entry point -------------------------------------------------------

# Download (or load from cache) every series.
# Returns a named list of xts objects: gold, oil, ..., vix, ovx, gvz.
download_all <- function(refresh = FALSE) {
  dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)

  yahoo <- lapply(YAHOO_TICKERS, function(ticker) {
    fetch_or_load(paste0("yahoo_", ticker), function() fetch_yahoo(ticker), refresh)
  })

  fred <- lapply(FRED_SERIES, function(series_id) {
    fetch_or_load(paste0("fred_", series_id), function() fetch_fred(series_id), refresh)
  })

  c(yahoo, fred)
}


# ---- Quick check ------------------------------------------------------------

# One row per series: date range, number of rows, rows with missing values.
summarise_data <- function(data) {
  rows <- lapply(names(data), function(name) {
    x <- data[[name]]
    data.frame(
      series     = name,
      first      = start(x),
      last       = end(x),
      n_rows     = nrow(x),
      n_rows_na  = sum(!complete.cases(x))
    )
  })
  do.call(rbind, rows)
}
