# Project log

Newest session first. Each entry: done / next / decisions / open issues.

## S6 — 2026-10-17 — Statistical tests, per-year view, feature blocks

**Done**
- Oral date corrected: 2026-12-31 (not 10-31). Backtest moved to S7.
- `R/03_models.R`: features can depend on the asset; nested blocks
  B1–B4 and `block_models()` (Lasso + forest on B2, B3, B4).
- `R/05_inference.R`: hand-written Newey-West, Diebold-Mariano (per asset
  and pooled), Mincer-Zarnowitz with HAC Wald test, per-year table, block
  matrix, compact DM view. All tables saved to `data/processed/results.rds`.
- `tests/test_inference.R`: NW = sandwich, HAC > naive variance under
  autocorrelation, DM power and size, MZ on unbiased / over-shrunk
  forecasts, block nesting and mapping, asset-specific Lasso. 76 tests
  pass in the cloud workspace.

- First real run (2026-10-17) revealed a **bug**: lasso_b2/b3/b4 (and the
  three forests) gave identical results. Cause: R evaluates function
  arguments lazily; `features` was only read inside fit(), after the loop
  in block_models() had moved on, so every block model used B4. Fixed with
  force() in make_lasso/make_rf; regression test added (fails without the
  fix). Block results of that run are invalid; all other results valid:
  - DM vs HAR (positive = worse): pooled ewma 2.23, lasso_full 2.95,
    rf_full 2.01 → all significantly worse than HAR on the 5 assets.
    **Oil lasso_full -2.90 (p ≈ 0.004): significantly better than HAR.**
    Copper rf_full -1.49 (not significant). Gold ewma -0.09 (tie).
    Natgas and corn: ML significantly worse (DM 2.2 to 4.8).
  - MZ slope b: HAR 0.78–1.12; EWMA 0.44–0.78 (too jumpy); lasso_full
    1.17–1.67 except oil 1.10 (over-shrunk, as predicted; oil passes MZ,
    p = 0.31); rf_full 0.73–1.24.
  - Per year, oil: lasso_full beats HAR in 8 of 10 years (0.448 in 2022,
    0.637 in 2017, 0.653 in 2021; loses in 2024: 1.164; 2026 ≈ 1.00):
    a steady gain, not one episode. 2020 pooled: lasso_full 0.908 vs
    rf_full 1.111; oil 2020: 0.903 vs 1.246 → consistent with forests not
    extrapolating in crises.

- Valid block matrices (QLIKE / HAR), after the fix:

  | Lasso | B1 own | B2 +IV | B3 +GPR | B4 +fund |
  |---|---|---|---|---|
  | all | 1.130 | 1.049 | 1.056 | 1.061 |
  | oil | 0.965 | 0.801 | 0.801 | 0.799 |
  | gold | 1.214 | 1.071 | 1.073 | 1.073 |
  | copper | 1.112 | 1.096 | 1.120 | 1.125 |
  | natgas | 1.295 | 1.239 | 1.265 | 1.266 |
  | corn | 1.162 | 1.216 | 1.203 | 1.228 |

  | Forest | B1 own | B2 +IV | B3 +GPR | B4 +fund |
  |---|---|---|---|---|
  | all | 1.080 | 1.043 | 1.033 | 1.111 |
  | oil | 1.102 | 0.947 | 0.998 | 1.131 |
  | gold | 0.996 | 0.996 | 0.955 | 1.028 |
  | copper | 1.059 | 1.029 | 0.883 | 0.915 |
  | natgas | 1.140 | 1.149 | 1.227 | 1.319 |
  | corn | 1.111 | 1.180 | 1.158 | 1.180 |

  Reading: (1) implied vol is the block that helps, mostly where the asset
  has its own index (oil OVX, gold GVZ), for both models; VIX alone hurts
  corn. (2) GPR adds nothing linearly but helps the forest on copper
  (1.029 → 0.883) and gold (0.996 → 0.955): possible non-linear / threshold
  effect, to be checked with DM (many comparisons → some "wins" by chance).
  (3) Fundamentals + dollar (B4) never help, not even EIA crude for oil or
  gas storage + HDD for natgas. Hypothesis: markets price weather
  *forecasts* and inventory surprises instantly; realised weather and
  slow-moving inventory deviations are already in prices/IV.

- DM of the block models vs HAR:
  - oil lasso_b2_iv -2.92 (p = 0.0035): significant at 1%. Not below a
    strict Bonferroni threshold for ~65 comparisons (0.05/65 ≈ 0.0008),
    but corroborated by lasso_full (p ≈ 0.004), 8/10 winning years, and a
    clear mechanism (OVX). Strongest result of the project so far.
  - copper rf_b3_gpr -1.72 (p = 0.086): weak evidence only.
    gold rf_b3_gpr -0.70 (p = 0.48): noise. → GPR effect NOT established.
  - oil rf_b2_iv -0.34 (p = 0.74): the forest's gain on oil is not
    significant.
  - pooled: lasso_b2_iv 1.56 (p = 0.12), rf_b2_iv 0.84, rf_b3_gpr 0.62 →
    asset-specific blocks are no longer significantly worse than HAR
    (lasso_full / rf_full were), but not better either.
  - copper lasso_b2_iv 2.21 (p = 0.027): significantly worse.

**Conclusion at the end of S6 (for the oral)**
- HAR is not beaten on average over the five commodities (significant).
- One robust exception: oil, where a Lasso using OVX beats HAR by ~20%
  (DM p < 0.01, 8 of 10 years, well calibrated by MZ).
- External variables help only when they are market prices (own implied
  vol). Geopolitical risk: at best a weak non-linear signal on copper.
  Inventories and weather: no gain, even for oil and natural gas.
- Choosing features by asset removes the significant losses of the
  "everything for everyone" models.

**Next (S7)**
- Vol-targeting backtest (per asset and inverse-vol portfolio): weight =
  target vol / forecast vol, leverage cap, weekly rebalancing with a
  no-trade band, costs in bp. Compare naive, EWMA, HAR, lasso_b2_iv (and
  rf_full). Metrics: realised vol vs target, max drawdown, turnover.

**Open issues**
- Post hoc sensitivity (label as such): Lasso lambda.min vs 1-SE, Duan
  smearing for the Jensen correction.
- Multiple comparisons: report the number of tests next to any p-value.

## S5 — 2026-10-17 — Lasso, random forest, 2×2 design

**Done**
- `R/03_models.R`: feature sets BASE / FULL; Lasso with purged blocked CV
  (1-SE rule); random forest per asset or pooled; candidate grid.
- `R/04_walkforward.R`: engine supports pooled models; `select_rf_config()`
  on 2015–2016; `design_2x2()` summary.
- `tests/test_ml.R`: blocks, purge, sparse recovery, non-linear step,
  pooled asset effect, no-peek with Lasso + pooled RF. 50 tests pass in the
  cloud workspace.
- Validation 2015–2016 (pooled QLIKE vs HAR): rf_asset_node200 1.08 (best
  forest), rf_pooled_node200 1.15, node 50: 1.15/1.19, node 5: 1.26/1.26.
  HAR beat every forest. Bigger leaves always better (weak, noisy signal);
  per-asset beat pooled, contrary to our prior. Chosen: per asset, node 200.
- Out-of-sample 2017-01 → 2026-09 (QLIKE / HAR, pooled over 5 assets):

  | 2×2 | own returns only | + external data |
  |---|---|---|
  | Lasso | 1.13 | 1.10 |
  | Random forest | 1.08 | 1.11 |

  HAR 0.253 stays best pooled (EWMA 1.12, naive 1.26).
  By asset, ML beats HAR in two places: **oil, lasso_full 0.819** (-18%;
  lasso_base 0.965) and **copper, rf_full 0.922** (-8%). Gold: EWMA 0.992,
  rf_base 0.996 (tie). Corn and natgas: HAR best; external features hurt
  (corn lasso_full 1.28, natgas lasso_full 1.31, rf_full 1.22 / 1.26).

**Reading (to confirm)**
- Primary, pre-specified comparison: no ML model beats HAR on pooled QLIKE.
- Forests cannot extrapolate beyond the training range (forecast = average
  of training targets in a leaf): in oil 2020 they cap the forecast, while
  a linear model can go higher. Consistent with RF losing on oil and Lasso
  winning there; var_ratio of forests ~0.8.
- Lasso's 1-SE shrinkage pulls forecasts towards the mean → variance level
  too low (var_ratio_raw 0.62–0.71 on natgas/gold) → penalised by QLIKE.
- FULL gives every external column to every asset (e.g. HDD to gold):
  irrelevant columns add noise, especially for forests (mtry = 4 of 18).
- Hypothesis for oil: OVX (implied vol on USO options) carries the gain.
  **Checked** on the 2026 training window (oil, lasso_full, 1-SE):
  only `log_ovx` is kept (coefficient 0.501, intercept -0.716); all HAR,
  GPR, EIA, weather and dollar columns are set to 0. The market's implied
  vol subsumes past vol, and the "fundamental" external variables add
  nothing on top. Negative intercept: implied vol is above realised vol
  on average (variance risk premium). Coefficient 0.5 is heavily shrunk
  by the 1-SE rule. To check: is the selection stable across years?
- Consequence for the research question: the gain on oil comes from
  implied volatility (a market price), not from geopolitics, inventories
  or weather. The block-by-block design (HAR → +implied vol → +GPR →
  +fundamentals/weather) will quantify each block's contribution.

**Next (S6)**
- Diebold-Mariano (HAC) of each model vs HAR, by asset and pooled;
  Mincer-Zarnowitz; per-year breakdown (2020, 2022).
- Asset-specific feature blocks (planned since S0: OVX + EIA crude for oil,
  GVZ for gold, gas storage + HDD for natgas...). Reported as a planned
  extension, the pooled 2×2 above stays the primary result.
- Sensitivity, clearly labelled post hoc: Lasso lambda.min vs 1-SE, Duan
  smearing for the Jensen correction.
- First vol-targeting backtest.

## S4 — 2026-10-17 — Walk-forward engine and baselines

**Done**
- `ewma` column added to the modelling table (RiskMetrics recursion).
- `R/03_models.R`: common fit/predict interface; naive, EWMA, HAR-OLS.
- `R/04_walkforward.R`: yearly expanding-window walk-forward 2017–2026 with
  21-day embargo, Jensen correction, QLIKE / RMSE / var_ratio evaluation.
- `tests/test_walkforward.R`: cutoff, QLIKE, Jensen (simulation), HAR
  coefficient recovery, no-peek test on the engine. 41 tests pass in the
  cloud workspace; removing the embargo makes the no-peek test fail.
- First real run (41/41 tests pass on the student's PC). Out-of-sample
  2017-01 → 2026-09, 2439 days per asset:

  | Pooled (5 assets) | QLIKE | vs HAR | RMSE log | var_ratio | var_ratio_raw |
  |---|---|---|---|---|---|
  | HAR   | 0.253 | 1.000 | 0.321 | 0.880 | 0.740 |
  | EWMA  | 0.283 | 1.120 | 0.340 | 1.000 | 1.000 |
  | naive | 0.319 | 1.261 | 0.355 | 1.000 | 1.000 |

  HAR is best on oil (EWMA +24%), copper, corn and natgas; on gold EWMA is
  marginally better (0.992 × HAR), essentially a tie. Oil has the highest
  loss (2020). Jensen correction moves HAR's variance level from 74% to 88%
  of realised: still ~12% too low (only corn ≈ 1.01).

**Decisions**
- Baseline to beat for the ML models: HAR (QLIKE 0.253 pooled).

**Next (S5)**
- Lasso (glmnet) and random forest (ranger) in the same engine, 2×2 design,
  panel vs per-asset forest chosen on 2015–2016.

**Open issues**
- HAR still under-predicts the variance level after the normal-theory
  correction (in-sample residual variance < out-of-sample error variance,
  fat-tailed residuals). Candidate fix to test in S5/S6: Duan (1983)
  smearing estimator, mean(exp(2 × residual)), which does not assume
  normality. Compare QLIKE and var_ratio.
- Per-year breakdown (2020, 2022) for the oral.

## S3 — 2026-10-17 — Modelling table and anti-leakage tests

**Done**
- `R/02_features.R`: zero-volume rule, target, HAR and leverage features,
  external features with availability dates, as-of join, long panel saved
  to `data/processed/features.rds`. See CLAUDE.md > Modelling table.
- `tests/test_features.R` + `tests/helper-fake-raw.R`: 20 expectations
  (as-of join, next trading day, GPR dates, past-years mean, zero volume,
  target/HAR perturbation, EIA publication dates, vintage test). All 32
  tests pass in the cloud workspace; 4 injected leaks are all detected.

- First run on real data (2026-10-17): 32/32 tests pass on the student's PC.
  Table: 3970 rows per asset (CPER 3750). All features exist from
  2011-02-03 except gas_dev (2013-01-04). Complete rows (target + all
  features): 2013-01-04 → 2026-09-16, 3445 per asset. Last target =
  21 trading days before the last price (2026-10-15).

**Decisions**
- Gas feature: deviation from the average of available past years (min 3).
- Same rule (max 5 / min 3 years) for crude, for consistency.
- All models are trained and evaluated on the same rows (complete cases
  from 2013-01-04), so differences come from the model, not the sample.
  First walk-forward training window: 2013–2016 (4 years).

**Next (S4)**
- `R/04_walkforward.R`: yearly expanding-window walk-forward from 2017,
  21-day embargo; naive, EWMA (λ = 0.94) and HAR-OLS; first out-of-sample
  table (QLIKE on variance, RMSE on log vol); Jensen correction when going
  back from log vol to variance.

## S2 — 2026-10-17 — External data sources and quality checks

**Done**
- `R/01_data.R` extended: EIA crude stocks and gas storage (API v2), daily
  GPR (Excel), Open-Meteo daily mean temperature for 10 cities (one cache
  file per city, 60 s pause between requests), FRED API key support.
- `fetch_*()` / `parse_*()` split; `tests/test_parsers.R` (12 expectations,
  synthetic inputs) passes in the cloud workspace.
- Quality checks: `summarise_data()` now reports the longest date gap;
  `check_prices()` reports zero-range days, zero-volume days and the largest
  daily move per ETF.
- `.Renviron.example`; `.gitignore` now excludes `font/` and `scratch.R`.
- First real run (2026-10-17): all sources downloaded.
  - EIA crude from 2005-01-07, gas from 2010-01-01, both up to the week
    ending 2026-10-09 (next release not out yet: publication lag visible).
  - GPR 1985-01-01 → 2026-10-13, every calendar day.
  - Weather 2006-01-01 → 2026-10-16, no missing value.
  - ETF max gap 5 days (most likely Hurricane Sandy closure, Oct 2012).
  - Largest daily moves checked: USO 2020-03-09, CORN 2011-06-30,
    UUP 2020-03-13, GLD 2026-01-30, UNG 2026-02-02 (real moves; UNG on
    43.7M shares). CPER 2014-12-04 is a bad print on zero volume.
  - CPER zero-volume days per year: 2011: 6, 2012: 87, 2013: 74, 2014: 53,
    2015: 62, 2016: 26, 2017: 15, 2018: 6, then none.

**Decisions**
- GPR daily file is only updated weekly (Mondays) → specific lag rule,
  see CLAUDE.md > Data sources. Good example for the oral.
- Font "One Slice" kept out of Git until the licence question is settled.
- Zero-volume closes replaced by previous close in 02_features.R; CPER kept
  with documented limitation (CLAUDE.md decisions 13–14).

**Next (S3)**
- `R/02_features.R`: align on the ETF calendar, zero-volume rule, target
  (log realised vol t+1..t+21), HAR features, external features with their
  availability dates, anti-leakage tests.
- Choose the gas storage feature: deviation from the average of available
  past years (min 3) vs year-on-year change.

**Open issues**
- Gas storage feature choice (above).

## S1 — 2026-10-16 — Skeleton and price data

**Done**
- Environment installed: R 4.6.1, VS Code + R extension, Git, GitHub CLI
  (account NemoEMLYON), project packages.
- Project skeleton, `CLAUDE.md`, this log, `.gitignore`.
- `R/01_data.R`: downloads ETF prices (Yahoo) and implied vol (FRED), caches
  them in `data/raw/`. `pipeline.R` runs it and prints a data summary.
- First real run (2026-10-16): Yahoo series 2011-01-03 → 2026-10-15,
  3970 rows each (CPER from 2011-11-15, 3750 rows), no missing rows.
  FRED series end 2026-10-14 (one day behind Yahoo) and contain empty rows
  on US holidays (VIX 302, OVX 179, GVZ 169). Second run reads the cache.

**Next (S2)**
- Free FRED API key in `.Renviron`.
- EIA (crude, gas), GPR, Open-Meteo HDD into the cache.
- Data quality report: gaps, splits, zero-range days (High == Low).

**Decisions**
- See `CLAUDE.md` > Decisions.

**Open issues**
- Creative direction document not received yet (needed only for the site).
- Oral format unknown (duration, live code demo?) — changes S7 content.
