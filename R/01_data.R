# 01_data.R — Download raw data and cache it on disk.
#
# This file only defines constants and functions; pipeline.R calls them.
# "Raw" means values exactly as received from the source. The only change is
# the container: every series is converted to an xts time series indexed by
# the date given by the source. Cleaning, alignment, lags and derived
# variables (HDD, 5-year averages...) happen later, in 02_features.R.
#
# Each source has two functions:
#   fetch_*()  does the network call (needs internet, sometimes an API key)
#   parse_*()  turns the response into an xts (pure function, unit-tested)

library(quantmod)
library(httr2)
library(readxl)

# ---- Configuration ----------------------------------------------------------

# CPER (copper) starts in Nov 2011; earlier days serve as warm-up for the
# 22-day HAR features.
START_DATE <- as.Date("2011-01-01")

# EIA features compare inventories with their 5-year average, so we need
# five extra years of history before the sample starts.
EIA_START_DATE <- as.Date("2005-01-01")

# The HDD anomaly compares each day with the same calendar day in previous
# years, so we need a few years of weather before the sample starts.
WEATHER_START_DATE <- as.Date("2006-01-01")

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

# EIA weekly series (API v2). The date ("period") is the END OF THE WEEK
# measured, not the publication date: see CLAUDE.md > Data sources.
EIA_SERIES <- list(
  # US commercial crude oil stocks excl. SPR, thousand barrels.
  # Week ending Friday, published the following Wednesday.
  crude_stocks = list(route = "petroleum/stoc/wstk", series = "WCESTUS1"),
  # Lower 48 working gas in underground storage, billion cubic feet.
  # Week ending Friday, published the following Thursday.
  gas_storage = list(route = "natural-gas/stor/wkly", series = "NW2_EPG0_SWO_R48_BCF")
)

# Daily Geopolitical Risk index (Caldara & Iacoviello), CC BY licence.
GPR_URL <- "https://www.matteoiacoviello.com/gpr_files/data_gpr_daily_recent.xls"

# Cities for heating degree days: large metro areas of the Northeast and
# Midwest, where residential gas heating demand is concentrated.
WEATHER_CITIES <- data.frame(
  city = c("new_york", "boston", "philadelphia", "washington", "pittsburgh",
           "cleveland", "detroit", "chicago", "minneapolis", "atlanta"),
  lat  = c(40.71, 42.36, 39.95, 38.91, 40.44, 41.50, 42.33, 41.88, 44.98, 33.75),
  lon  = c(-74.01, -71.06, -75.17, -77.04, -80.00, -81.69, -83.05, -87.63, -93.27, -84.39)
)

# Seconds to wait between two Open-Meteo requests. A request covering many
# years counts as hundreds of "calls" on the free plan (600 per minute).
WEATHER_PAUSE_SECONDS <- 60


# ---- Helpers ----------------------------------------------------------------

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

# Read an API key from the environment (.Renviron). Never print it.
get_api_key <- function(name) {
  key <- Sys.getenv(name)
  if (key == "") {
    stop(name, " is not set. Add it to .Renviron and restart R.")
  }
  key
}


# ---- Yahoo and FRED (via quantmod) ------------------------------------------

fetch_yahoo <- function(ticker) {
  getSymbols(ticker, src = "yahoo", from = START_DATE, auto.assign = FALSE)
}

fetch_fred <- function(series_id) {
  setDefaults(getSymbols.FRED, api.key = get_api_key("FRED_API_KEY"))
  getSymbols(series_id, src = "FRED", auto.assign = FALSE)
}


# ---- EIA (API v2) -----------------------------------------------------------

fetch_eia <- function(route, series) {
  body <- request(paste0("https://api.eia.gov/v2/", route, "/data/")) |>
    req_url_query(
      api_key              = get_api_key("EIA_API_KEY"),
      frequency            = "weekly",
      `data[0]`            = "value",
      `facets[series][]`   = series,
      start                = format(EIA_START_DATE),
      `sort[0][column]`    = "period",
      `sort[0][direction]` = "asc",
      length               = 5000      # API maximum per request
    ) |>
    req_perform() |>
    resp_body_json(simplifyVector = TRUE)

  parse_eia(body, series)
}

# body: parsed JSON with body$response$data = table (period, value, ...).
parse_eia <- function(body, series) {
  rows <- body$response$data

  if (length(rows) == 0 || nrow(rows) == 0) {
    stop("EIA returned no rows for series ", series)
  }
  if (as.numeric(body$response$total) > nrow(rows)) {
    stop("EIA result truncated for series ", series, ": paginate or narrow dates")
  }

  x <- xts(as.numeric(rows$value), order.by = as.Date(rows$period))
  colnames(x) <- series
  x
}


# ---- Geopolitical risk (Excel file) -----------------------------------------

fetch_gpr <- function() {
  # Keep the original file next to the cache, for inspection.
  path <- file.path(RAW_DIR, "gpr_daily_recent.xls")
  download.file(GPR_URL, path, mode = "wb")   # "wb" = binary, needed on Windows
  parse_gpr(read_excel(path))
}

# table: the sheet as read by read_excel(). DAY is a number like 20240115.
parse_gpr <- function(table) {
  needed  <- c("DAY", "GPRD", "GPRD_ACT", "GPRD_THREAT")
  missing <- setdiff(needed, names(table))
  if (length(missing) > 0) {
    stop("GPR file: missing columns ", paste(missing, collapse = ", "),
         ". Columns found: ", paste(names(table), collapse = ", "))
  }

  dates <- as.Date(as.character(table$DAY), format = "%Y%m%d")
  keep  <- !is.na(dates)    # drop rows that are not data (notes, blanks)

  values <- as.data.frame(table[keep, c("GPRD", "GPRD_ACT", "GPRD_THREAT")])
  xts(values, order.by = dates[keep])
}


# ---- Weather (Open-Meteo historical archive) --------------------------------

fetch_city_temperature <- function(lat, lon) {
  body <- request("https://archive-api.open-meteo.com/v1/archive") |>
    req_url_query(
      latitude         = lat,
      longitude        = lon,
      start_date       = format(WEATHER_START_DATE),
      end_date         = format(Sys.Date() - 1),
      daily            = "temperature_2m_mean",
      temperature_unit = "fahrenheit",       # US HDD convention: base 65°F
      timezone         = "auto"              # days in the city's local time
    ) |>
    req_perform() |>
    resp_body_json(simplifyVector = TRUE)

  parse_openmeteo(body)
}

# body: parsed JSON with body$daily$time and body$daily$temperature_2m_mean.
# Days not yet available come back as null, i.e. NA.
parse_openmeteo <- function(body) {
  temps <- as.numeric(body$daily$temperature_2m_mean)
  xts(temps, order.by = as.Date(body$daily$time))
}

# One cache file per city, so an interrupted download resumes where it stopped.
fetch_weather <- function(refresh = FALSE) {
  series <- lapply(seq_len(nrow(WEATHER_CITIES)), function(i) {
    city <- WEATHER_CITIES[i, ]
    fetch_or_load(paste0("openmeteo_", city$city), function() {
      Sys.sleep(WEATHER_PAUSE_SECONDS)
      fetch_city_temperature(city$lat, city$lon)
    }, refresh)
  })

  weather <- do.call(merge, series)   # outer join on dates, one column per city
  colnames(weather) <- WEATHER_CITIES$city
  weather
}


# ---- Main entry point -------------------------------------------------------

# Download (or load from cache) every series.
# Returns a named list of xts objects.
download_all <- function(refresh = FALSE) {
  dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)

  yahoo <- lapply(YAHOO_TICKERS, function(ticker) {
    fetch_or_load(paste0("yahoo_", ticker), function() fetch_yahoo(ticker), refresh)
  })

  fred <- lapply(FRED_SERIES, function(series_id) {
    fetch_or_load(paste0("fred_", series_id), function() fetch_fred(series_id), refresh)
  })

  eia <- lapply(EIA_SERIES, function(s) {
    fetch_or_load(paste0("eia_", s$series), function() fetch_eia(s$route, s$series), refresh)
  })

  gpr     <- fetch_or_load("gpr_daily", fetch_gpr, refresh)
  weather <- fetch_weather(refresh)

  c(yahoo, fred, eia, list(gpr = gpr, weather = weather))
}


# ---- Quality checks ---------------------------------------------------------

# One row per series: date range, rows, rows with a missing value, and the
# longest gap between two consecutive dates (in calendar days).
summarise_data <- function(data) {
  rows <- lapply(names(data), function(name) {
    x <- data[[name]]
    data.frame(
      series    = name,
      first     = start(x),
      last      = end(x),
      n_rows    = nrow(x),
      n_rows_na = sum(!complete.cases(x)),
      max_gap   = max(diff(as.numeric(index(x))))
    )
  })
  do.call(rbind, rows)
}

# Checks specific to daily OHLC prices, one row per ETF:
#   zero_range  days with High == Low (no intraday movement: illiquid or stale)
#   zero_volume days with Volume == 0
#   max_abs_ret largest absolute daily log return of the adjusted close, and
#               its date (an unadjusted split would show up here)
check_prices <- function(data, tickers = YAHOO_TICKERS) {
  rows <- lapply(names(tickers), function(name) {
    x   <- data[[name]]
    ret <- diff(log(as.numeric(Ad(x))))
    i   <- which.max(abs(ret))
    data.frame(
      series         = name,
      zero_range     = sum(Hi(x) == Lo(x)),
      zero_volume    = sum(Vo(x) == 0),
      max_abs_ret    = round(ret[i], 3),
      max_abs_ret_on = index(x)[i + 1]
    )
  })
  do.call(rbind, rows)
}
