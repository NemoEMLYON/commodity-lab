# CLAUDE.md — Commodity Lab

Read this file and `PROJECT_LOG.md` at the start of every session.

## Project in one paragraph

Forecast the log of annualised realised volatility over the next 21 trading
days for five commodity ETFs (GLD, USO, CPER, UNG, CORN), and test whether
external variables (implied vol, geopolitical risk, EIA inventories, weather,
dollar) combined with machine learning beat the HAR model (Corsi, 2009).
Then measure the economic value: does a better forecast keep a vol-targeted
portfolio closer to its risk target, after costs? The goal is risk control,
not price prediction. "ML does not beat HAR" is a valid result.

Course: "Machine Learning with R", emlyon. Mid-project oral: 2026-10-31.

## Working with the student

- Chat in French. Everything produced (code, comments, README, site text,
  commit messages) is in English.
- New to R, fluent in Python / C++ / JS. When introducing an R concept, give a
  one-sentence Python/pandas or JS analogy.
- He must be able to explain every line in an interview: readable code over
  clever code, no magic, small testable steps.
- Never call code working without running it and showing the output.
- Sessions of 60–90 min, one deliverable announced at the start. At the end:
  update `PROJECT_LOG.md` (done / next / decisions / open issues) and commit.
- Execution: Claude writes files into the project folder; the student runs
  them in VS Code (R terminal) and pastes outputs. Claude's cloud workspace
  has R but no access to Yahoo, FRED or EIA, so it can only test logic
  offline (synthetic data).

## Conventions

- Run everything from the project root (VS Code: File > Open Folder).
  All paths are relative to the root.
- `R/` files only define functions and constants; `pipeline.R` calls them.
- `data/raw/`: data exactly as received from the source, never edited.
  Ignored by Git (re-downloadable, third-party terms).
- `data/processed/`: derived data. Ignored by Git for now.
- The app never calls the network: it reads precomputed `.rds`/JSON files.
- Secrets (EIA API key) live in `.Renviron`, ignored by Git.
- Packages are pinned with renv (`renv.lock`). Few dependencies; every new
  package is justified in one line below.

## Packages

| Package  | Why |
|----------|-----|
| renv     | Pins package versions per project (like venv + requirements.txt) |
| quantmod | Downloads Yahoo prices and FRED series; brings xts/zoo time series |
| httr2    | HTTP requests to EIA and Open-Meteo APIs |
| jsonlite | Parses JSON API responses |
| readxl   | Reads the GPR Excel file |
| dplyr    | Readable table manipulation |
| glmnet   | Reference Lasso (validates the scratch Lasso) |
| ranger   | Reference random forest (validates the scratch forest) |
| sandwich | HAC (Newey-West) standard errors for DM and MZ tests |
| testthat | Unit tests, incl. anti-leakage tests |

## Data sources

| Block | Series | Source | Availability rule |
|-------|--------|--------|-------------------|
| Prices | GLD, USO, CPER, UNG, CORN (OHLC, adjusted) | Yahoo via quantmod | Known at close t |
| Dollar | UUP ETF | Yahoo via quantmod | Known at close t |
| Implied vol | VIXCLS, OVXCLS, GVZCLS | FRED via quantmod | Lag 1 business day (default rule) |
| Geopolitics | Daily GPR index | matteoiacoviello.com | Lag 1 business day; revised series (limitation) |
| Fundamentals | EIA crude stocks (Wed), gas storage (Thu) | EIA API v2 | Known from publication date + 1 business day, never from measurement date |
| Weather | HDD anomaly, ~10 US cities | Open-Meteo archive | Lag 1 business day; reanalysis (limitation) |

## Decisions (with reason)

1. **Target** = log annualised realised vol from close-to-close returns over
   t+1..t+21. OHLC estimators (Garman-Klass, Yang-Zhang) are candidate
   *features*, not the target: the backtest is judged on close-to-close
   returns, OHLC estimators miss the overnight gap (futures trade ~23h), and
   CPER/CORN early high/low data is illiquid.
2. **Dollar**: UUP ETF instead of FRED broad dollar index (FRED series comes
   from the weekly H.10 release → look-ahead risk).
3. **Default lag**: every external variable lagged 1 business day unless
   proven available before the close. Embargo of 21 days between train and
   test (overlapping targets).
4. **Reference packages first** (glmnet, ranger) for the oral; scratch Lasso
   and scratch RF after the oral, validated against them.
5. **2×2 design**: {linear, RF} × {HAR features, HAR + external}, then
   block-by-block additions. Results reported as an asset × block matrix
   (not every block applies to every asset).
6. **Panel RF candidate**: pool the 5 assets with an asset indicator. Choose
   panel vs per-asset on the 2015–2016 validation period, before looking at
   2017+ results.
7. **Tests**: Diebold-Mariano and Mincer-Zarnowitz with HAC errors
   (≥ 20 lags). Primary comparison fixed in advance: best ML vs HAR on QLIKE.
   High-GPR periods analysed descriptively (too few episodes to test).
8. **Backtest**: weekly rebalancing with a no-trade band.
9. **App**: Shiny with `htmlTemplate()`, deployed on Posit Connect Cloud from
   a public GitHub repo. Check free-plan usage credits before deploying.
10. **Data snapshot**: raw data is cached on first download and not refreshed
    unless `refresh = TRUE`, so results are reproducible.

## Known limitations

- USO changed its roll strategy and did a 1-for-8 reverse split in 2020
  (adjusted prices handle the split; robustness check excluding 2020).
- GPR, EIA gas storage and Open-Meteo reanalysis are revised after the fact;
  no real-time vintages available.
- ~120 independent 21-day forecasts per asset out of sample → low test power.

## Current status

See the top entry of `PROJECT_LOG.md`.
