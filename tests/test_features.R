# Anti-leakage tests for R/02_features.R.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)
source(file.path("..", "R", "02_features.R"), chdir = TRUE)


# ---- Building blocks --------------------------------------------------------

test_that("asof_join only uses values already available", {
  available <- as.Date(c("2024-01-03", "2024-01-10"))
  dates     <- as.Date(c("2024-01-02", "2024-01-03", "2024-01-09",
                         "2024-01-10", "2024-01-11"))
  expect_equal(asof_join(dates, available, c(1, 2)), c(NA, 1, 1, 2, 2))
})

test_that("next_trading_day is strictly after the date", {
  cal <- as.Date(c("2024-01-05", "2024-01-08", "2024-01-09"))   # Fri, Mon, Tue
  out <- next_trading_day(as.Date(c("2024-01-05", "2024-01-06", "2024-01-09")), cal)
  expect_equal(out, as.Date(c("2024-01-08", "2024-01-08", NA)))
})

test_that("GPR value is usable on the Wednesday after the next Monday", {
  d <- as.Date(c("2024-01-02",    # Tuesday  -> Monday 8th  -> Wednesday 10th
                 "2024-01-07",    # Sunday   -> Monday 8th  -> Wednesday 10th
                 "2024-01-08"))   # Monday   -> Monday 15th -> Wednesday 17th
  expect_equal(gpr_available_date(d), as.Date(c("2024-01-10", "2024-01-10", "2024-01-17")))
})

test_that("past_years_mean uses past values and needs enough years", {
  dates  <- as.Date("2020-01-03") + 364 * 0:4    # same week, 5 years
  values <- c(10, 20, 30, 40, 50)
  avg    <- past_years_mean(dates, values, 364, max_years = 5, min_years = 3)
  expect_equal(avg, c(NA, NA, NA, 20, 25))       # mean of the 3 then 4 past years
})

test_that("zero-volume closes are replaced by the previous close", {
  d <- as.Date("2014-12-01") + 0:3
  x <- fake_prices(d, c(0, 0, 0, 0))
  x[, "TEST.Adjusted"] <- c(19.52, 19.52, 13.05, 19.56)   # bad print on day 3
  x[, "TEST.Volume"]   <- c(100, 100, 0, 100)
  expect_equal(clean_prices(x)$close, c(19.52, 19.52, 19.52, 19.56))
})


test_that("ewma_variance follows the RiskMetrics recursion", {
  ret_sq <- c(NA, 1, 3, 2, 4)
  v <- ewma_variance(ret_sq, lambda = 0.5, init_n = 2)
  expect_equal(v, c(NA, NA, 2, 0.5 * 2 + 0.5 * 2, 0.5 * 2 + 0.5 * 4))
})


# ---- Target and HAR: perturbation tests -------------------------------------
# Change one daily return and check which rows of the output move.

perturb <- function(returns, position) {
  returns[position] <- returns[position] + 0.05
  returns
}

test_that("target at t uses returns t+1 .. t+21 only", {
  set.seed(2)
  dates <- fake_calendar("2020-01-01", "2020-06-30")
  r     <- rnorm(length(dates), 0, 0.01)
  t     <- 50
  base  <- build_asset(fake_prices(dates, r))$target[t]

  target_after <- function(pos) build_asset(fake_prices(dates, perturb(r, pos)))$target[t]
  expect_equal(target_after(t), base)                         # day t: not used
  expect_false(isTRUE(all.equal(target_after(t + 1), base)))  # first day used
  expect_false(isTRUE(all.equal(target_after(t + 21), base))) # last day used
  expect_equal(target_after(t + 22), base)                    # beyond horizon
})

test_that("HAR features at t use returns up to t only", {
  set.seed(3)
  dates <- fake_calendar("2020-01-01", "2020-06-30")
  r     <- rnorm(length(dates), 0, 0.01)
  t     <- 50
  cols  <- c("har_d", "har_w", "har_m", "neg_d", "neg_w", "neg_m", "ewma")
  base  <- build_asset(fake_prices(dates, r))[t, cols]

  har_after <- function(pos) build_asset(fake_prices(dates, perturb(r, pos)))[t, cols]
  expect_equal(har_after(t + 1), base)                              # future: not used
  expect_false(isTRUE(all.equal(har_after(t)$har_d, base$har_d)))   # today: used
  expect_false(isTRUE(all.equal(har_after(t - 21)$har_m, base$har_m)))
  expect_equal(har_after(t - 22)$har_m, base$har_m)                 # 22-day window
})


# ---- Publication dates ------------------------------------------------------

test_that("EIA crude value is usable the day after its Wednesday release", {
  raw   <- make_fake_raw()
  cal   <- fake_calendar()
  crude <- eia_feature(raw$crude_stocks, EIA_PUBLICATION_LAG_DAYS[["crude"]], cal)
  week  <- which(crude$date == as.Date("2015-01-09"))   # week ending Friday 9th
  feat  <- asof_join(cal, crude$available, crude$deviation)

  on <- function(day) feat[cal == as.Date(day)]
  expect_equal(on("2015-01-14"), crude$deviation[week - 1])   # Wed: release day
  expect_equal(on("2015-01-15"), crude$deviation[week])       # Thu: usable
})

test_that("EIA gas value is usable the day after its Thursday release", {
  raw <- make_fake_raw()
  cal <- fake_calendar()
  gas <- eia_feature(raw$gas_storage, EIA_PUBLICATION_LAG_DAYS[["gas"]], cal)
  week <- which(gas$date == as.Date("2015-01-09"))
  feat <- asof_join(cal, gas$available, gas$deviation)

  on <- function(day) feat[cal == as.Date(day)]
  expect_equal(on("2015-01-15"), gas$deviation[week - 1])     # Thu: release day
  expect_equal(on("2015-01-16"), gas$deviation[week])         # Fri: usable
})


# ---- Whole table: vintage test ----------------------------------------------
# Rebuild the table from only the data that was published at a cutoff date.
# If no feature uses unpublished information, every feature on or before the
# cutoff must be identical to the one built from the full history.

test_that("features up to a date only use data published by that date", {
  raw    <- make_fake_raw()
  cutoff <- as.Date("2014-07-02")          # a Wednesday

  full  <- build_features(raw)
  short <- build_features(vintage_raw(raw, cutoff))
  cols  <- feature_columns(full)

  keep <- function(df) {
    df <- df[df$date <= cutoff, c("asset", "date", cols)]
    df[order(df$asset, df$date), ]
  }
  a <- keep(full)
  b <- keep(short)
  rownames(a) <- rownames(b) <- NULL

  expect_equal(nrow(a), nrow(b))
  expect_true(sum(!is.na(as.matrix(a[, cols]))) > 0.8 * length(cols) * nrow(a))
  expect_equal(a, b)
})
