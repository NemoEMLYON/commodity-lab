# Commodity Lab

Do external variables (implied volatility, geopolitical risk, inventories,
weather, the dollar) combined with machine learning forecast commodity
volatility better than the HAR model? And does a better forecast help a
portfolio manager who targets a risk level, after costs?

Course project, "Machine Learning with R", emlyon business school, 2026.

**Website:** the results are presented on a static site in `site/`, published
with GitHub Pages (see below).

## Short answer

- HAR, a three-coefficient regression, is not beaten overall (QLIKE, five
  commodities pooled, 2017–2026).
- One exception: crude oil, where a Lasso using the OVX implied volatility
  index lowers QLIKE by about 20% (Diebold-Mariano p = 0.0035).
- Inventories and weather never help. Geopolitical risk helps copper a little,
  not significantly.
- The value is in using any forecast: targeting 10% volatility cuts risk from
  about 31% to 10% and the worst drawdown from -58% to -24%.

## Live forecasts

Training stays offline; only the forecast is live. Every weekday after the
US close, a GitHub Actions job (`.github/workflows/live.yml`) downloads the
ETF prices and implied volatility indices, rebuilds the features with the
same R functions, applies the models frozen at the start of 2026 and
republishes the site. The "Today" section shows tonight's forecast, its 80%
range, the inputs' freshness and the live track record since January 2026.

## Universe

GLD (gold), USO (crude oil), CPER (copper), UNG (natural gas), CORN (corn),
daily, from 2011. Target: log annualised realised volatility over the next
21 trading days.

## Reproduce

Requirements: R ≥ 4.4, free API keys for EIA and FRED in a `.Renviron` file
at the project root (see `.Renviron.example`; never commit `.Renviron`).

```r
# from the project root
renv::restore()             # install the pinned package versions
source("pipeline.R")        # data, features, walk-forward, tests, backtest
source("robustness.R")      # sensitivity, portfolio, 5-day horizon
source("export_site.R")     # JSON and CSV files for the website
testthat::test_dir("tests") # unit and anti-leakage tests
source("freeze_models.R")   # once a year: save the models used live
source("live.R")            # today's forecasts -> site/data/live.json
```

The simulator on the website is a JavaScript port of the R backtest:
`node site/tests/test_simulator.js` checks it against 60 R reference cases.

## Structure

```
R/              functions, one file per pipeline step (01_data ... 08_export)
pipeline.R      runs the main steps in order
robustness.R    robustness checks
export_site.R   writes site/data/ from the saved results
freeze_models.R saves the models used live (models/, versioned)
live.R          daily forecasts with the frozen models (site/data/live.json)
tests/          unit and anti-leakage tests (testthat)
site/           static website (HTML, CSS, JS, D3, GSAP)
data/raw/       source data as received (not in Git)
data/processed/ derived tables and results (not in Git)
docs/           project guide (PDF, French)
.github/        GitHub Pages deployment
```

## Publish the website

1. On GitHub: Settings > Pages > Build and deployment > Source: **GitHub Actions**.
2. Push to `main`. The workflow `.github/workflows/pages.yml` runs the
   simulator check, then publishes `site/`. The address appears in the
   Actions tab and in Settings > Pages.
3. The daily live update (`live.yml`) needs no setup: it runs every weekday
   at 22:30 UTC, or by hand from the Actions tab. Optional: a repository
   secret `FRED_API_KEY` lets it fall back on the FRED API.

## Data and licences

Yahoo Finance (prices), FRED (Cboe VIX, OVX, GVZ), U.S. Energy Information
Administration (inventories), Caldara and Iacoviello (2022) geopolitical risk
index (CC BY), Open-Meteo.com historical weather (CC BY 4.0). Raw data is not
redistributed; `site/data/` contains derived results only. Not investment
advice.
