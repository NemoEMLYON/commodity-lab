# Unit tests for the parse_*() functions of R/01_data.R, on small synthetic
# inputs shaped like the real API responses. No network needed.
# Run from the project root: testthat::test_dir("tests")

source(file.path("..", "R", "01_data.R"), chdir = TRUE)

test_that("parse_eia builds a dated numeric series", {
  body <- list(response = list(
    total = "2",
    data  = data.frame(period = c("2024-01-05", "2024-01-12"),
                       value  = c("420000", "421500"))   # EIA sends strings
  ))
  x <- parse_eia(body, "WCESTUS1")
  expect_equal(as.numeric(x), c(420000, 421500))
  expect_equal(format(index(x)), c("2024-01-05", "2024-01-12"))
  expect_equal(colnames(x), "WCESTUS1")
})

test_that("parse_eia refuses a truncated result", {
  body <- list(response = list(
    total = "9000",
    data  = data.frame(period = "2024-01-05", value = "1")
  ))
  expect_error(parse_eia(body, "X"), "truncated")
})

test_that("parse_gpr keeps data rows and the three index columns", {
  table <- data.frame(
    DAY         = c(20240101, 20240102, NA),   # last row: a note, not data
    GPRD        = c(100, 120, NA),
    GPRD_ACT    = c(90, 110, NA),
    GPRD_THREAT = c(105, 125, NA),
    event       = c("", "", "")
  )
  x <- parse_gpr(table)
  expect_equal(nrow(x), 2)
  expect_equal(colnames(x), c("GPRD", "GPRD_ACT", "GPRD_THREAT"))
  expect_equal(index(x)[2], as.Date("2024-01-02"))
})

test_that("parse_gpr explains which column is missing", {
  expect_error(parse_gpr(data.frame(DAY = 20240101, GPRD = 1)), "GPRD_ACT")
})

test_that("parse_openmeteo turns nulls into NA", {
  body <- list(daily = list(time = c("2024-01-01", "2024-01-02"),
                            temperature_2m_mean = c(30.5, NA)))
  x <- parse_openmeteo(body)
  expect_equal(as.numeric(x), c(30.5, NA))
})

test_that("check_prices finds the largest move and zero-range days", {
  d <- as.Date("2024-01-01") + 0:3
  x <- xts(cbind(Open = 1, High = c(10, 10, 12, 11), Low = c(10, 9, 10, 10),
                 Close = 1, Volume = c(5, 0, 5, 5),
                 Adjusted = c(10, 10, 15, 15)), d)
  colnames(x) <- paste0("TEST.", colnames(x))   # quantmod naming
  out <- check_prices(list(test = x), tickers = c(test = "TEST"))
  expect_equal(out$zero_range, 1)
  expect_equal(out$zero_volume, 1)
  expect_equal(out$max_abs_ret_on, d[3])
})
