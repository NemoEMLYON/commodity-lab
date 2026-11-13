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

Course: "Machine Learning with R", emlyon. Mid-project oral: 2026-12-31
(the student corrected the date; earlier notes said 2026-10-31).

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
- Writing files to the PC: stage each delivery under a NEW folder
  (outputs/deliver-<time>/...), then read the files back and diff them.
  In S14, re-sending from a path already used wrote the OLD content while
  reporting success (02_features.R, 09_live.R, live.js, PROJECT_LOG.md,
  CLAUDE.md); a fresh path fixed it.
- Execution: Claude writes files into the project folder; the student runs
  them in VS Code (R terminal) and pastes outputs. Claude's cloud workspace
  has R but no access to Yahoo, FRED or EIA, so it can only test logic
  offline (synthetic data).

## Conventions

- Run everything from the project root (VS Code: File > Open Folder).
  All paths are relative to the root.
- `R/` files only define functions and constants; `pipeline.R` calls them.
- Each source has `fetch_*()` (network) and `parse_*()` (pure, unit-tested
  in `tests/`). Run tests with `testthat::test_dir("tests")`.
- `data/raw/`: values exactly as received, only converted to xts indexed by
  the source's own date. Never edited. Ignored by Git (re-downloadable,
  third-party terms).
- `data/processed/`: derived data. Ignored by Git for now.
- The site never calls the network: it reads precomputed JSON files. Only
  the daily job (`live.R` on GitHub Actions) downloads data, see Live layer.
- Secrets (`EIA_API_KEY`, `FRED_API_KEY`) live in `.Renviron`, ignored by
  Git; `.Renviron.example` documents the variables.
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
| Implied vol | VIXCLS, OVXCLS, GVZCLS | FRED via quantmod | Lag 1 business day (default rule); FRED posts with ~1 day delay |
| Geopolitics | Daily GPR index (GPRD, GPRD_ACT, GPRD_THREAT) | matteoiacoviello.com, CC BY | The daily file is updated **weekly, on Mondays** (next business day if holiday). Value of day d usable from the Wednesday after the first Monday strictly after d. Revised series (limitation) |
| Fundamentals | EIA crude stocks WCESTUS1 (week ending Fri, published Wed), gas storage NW2_EPG0_SWO_R48_BCF (week ending Fri, published Thu) | EIA API v2 | `period` = end of measured week. Usable from publication day + 1 business day (Thu for crude, Fri for gas); the buffer also absorbs one-day holiday delays |
| Weather | Daily mean temperature (°F), 10 cities, from 2006 | Open-Meteo archive (ERA5 reanalysis), CC BY 4.0, free plan = non-commercial | Lag 1 business day; reanalysis, not real-time observations (limitation). Site must credit "Weather data by Open-Meteo.com" |

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
9. **App**: superseded in S9 by a static site on GitHub Pages (see Website).
10. **Data snapshot**: raw data is cached on first download and not refreshed
    unless `refresh = TRUE`, so results are reproducible.
11. **HDD cities**: 10 Northeast/Midwest metros (+ Atlanta), equal weights
    (simplification, documented). Base 65°F. Anomaly vs the same calendar
    day in previous years only (no look-ahead).
12. **Site typeface** (changed in S15): GFS Didot (Greek Font Society, free
    Didot revival; the Linotype "Didot" the student asked for is commercial
    and cannot be served by a website). Before: Gloock (S14). SIL OFL 1.1,
    versioned in
    `site/assets/fonts/` with its licence; headings in capitals. Chosen by
    the student among 6 OFL faces rendered on the hero (One Slice felt
    "Halloween" and its licence did not cover a public site; `font/` stays
    ignored). Avoid the usual AI-site faces (Inter, Space Grotesk, Syne,
    Clash Display, Instrument Serif).
13. **Zero-volume days**: when Volume == 0 there was no trade, so Yahoo's
    "close" is not a traded price. In 02_features.R the close of such days
    is replaced by the previous close (raw data untouched). This removes the
    bad print of CPER on 2014-12-04 (13.05 between 19.52 and 19.56, volume 0,
    i.e. -40% then +40%). Only CPER has zero-volume days (329, mostly
    2012–2016, none after 2018).
14. **CPER kept in the universe**, with a documented limitation: stale
    prices in 2012–2016 bias its realised vol downward in the early training
    years; the out-of-sample period (2017+) is mostly clean. Robustness check
    planned: results without CPER, and CPER trained from 2016 only.
15. **Live inference, offline training** (S14): models are trained only by
    pipeline.R; `freeze_models.R` saves the last walk-forward year's models
    (FROZEN_YEAR = 2026) in `models/frozen_models.rds` (versioned). The daily
    job only downloads, predicts and publishes. Refit once a year, in January.

## Modelling table (`data/processed/features.rds`, built by 02_features.R)

One row per (asset, trading day t). Columns:

| Column | Definition | Available at close t because |
|--------|------------|------------------------------|
| target | log annualised realised vol, returns t+1..t+21 | (future: the thing to predict) |
| har_d / har_w / har_m | log annualised realised vol over the last 1 / 5 / 22 days | returns up to t |
| neg_d / neg_w / neg_m | mean of min(return, 0) over 1 / 5 / 22 days | returns up to t |
| ewma | log annualised EWMA vol (λ = 0.94, RiskMetrics) | returns up to t |
| log_vix / log_ovx / log_gvz | log(index / 100) | FRED value of day t-1 (next-day rule) |
| usd_ret_22 / usd_vol_22 | UUP 22-day log return / log realised vol | same exchange close |
| crude_dev / gas_dev | stocks / average of same week in past years (max 5, min 3) - 1 | publication day + 1 trading day |
| log_gpr_7 / log_gpr_30 / gpr_shock | log 7-day and 30-day mean GPR, and their difference | weekly Monday update + buffer |
| hdd_anomaly | 7-day mean HDD (10 cities) minus same window in past years (max 10, min 3) | next-day rule |

Realised vol = sqrt(252 × mean of squared daily log returns), floored at 1%
annualised before the log (zero-return days would give log(0)).

Anti-leakage tests (`tests/test_features.R`): perturbation tests on target
and HAR, publication-date tests (EIA, GPR), and a **vintage test**: the
table rebuilt from only the data published at a cutoff date must match the
full table on every day up to that cutoff. Checked to fail on 4 injected
leaks (HAR 1 day ahead, EIA at week end, GPR rolling window ahead,
implied vol same day).

## Models and evaluation (03_models.R, 04_walkforward.R)

- Common interface: each model is `list(name, fit(train), predict(fitted, test))`;
  `fit` returns `resid_var` (in-sample variance of log-vol residuals, 0 if
  not fitted). Baselines: naive (= har_m), EWMA λ = 0.94 (column `ewma`),
  HAR-OLS on har_d/har_w/har_m.
- Walk-forward: test years 2017–2026, one refit per year and asset,
  expanding window. Training rows = targets already known at the first test
  day s: position(t) <= position(s) - 21 (21-day embargo).
- Variance forecast = exp(2 × pred_log_vol + 2 × resid_var) (Jensen
  correction, lognormal assumption). `pred_var_raw` keeps the uncorrected
  value for comparison.
- Metrics: QLIKE on variance (primary), RMSE on log vol, var_ratio (mean
  forecast / mean realised variance), qlike_vs_har.
- Output: `data/processed/predictions.rds` (one row per asset × model × day).
- Models have a `pooled` flag: pooled models are fitted once per year on
  all assets (asset name as a factor feature), others once per asset.
- Feature sets: BASE (own returns: har_*, neg_*, ewma) and FULL (BASE +
  11 external columns). 2×2 design = {Lasso, RF} × {BASE, FULL}.
- Lasso (glmnet, per asset): lambda chosen inside each training window by
  purged blocked CV (5 contiguous folds, 21 rows purged on each side of the
  validation fold), 1-SE rule. resid_var = in-sample residual variance.
- RF (ranger, 500 trees, seed 42, default mtry): per-asset vs pooled and
  min.node.size ∈ {5, 50, 200} chosen on validation years 2015–2016 only
  (lowest pooled QLIKE, full features), then frozen for 2017+.
  resid_var = out-of-bag residual variance.

## Statistical tests and blocks (05_inference.R, block models in 03_models.R)

- Diebold-Mariano on QLIKE vs HAR, d = loss(model) - loss(HAR); pooled DM
  averages d across assets per date. Newey-West variance written by hand
  (Bartlett, lag 21), checked against sandwich::NeweyWest in the tests.
- Mincer-Zarnowitz on log vol, target = a + b × forecast, HAC Wald test of
  (a, b) = (0, 1) with sandwich::NeweyWest (lag 21). b > 1: forecasts too
  smooth (over-shrunk).
- Asset-specific blocks (nested): B1 own returns; B2 + implied vol (OVX +
  VIX for oil, GVZ + VIX for gold, VIX for others); B3 + GPR; B4 +
  fundamentals (crude_dev for oil; gas_dev + hdd_anomaly for natgas) +
  dollar. Lasso and forest (per asset, settings from validation) on B2–B4;
  B1 = *_base. Mapping as stated in the S0 plan.
- `data/processed/results.rds`: list of all result tables.

## Backtest (06_backtest.R)

- Vol targeting per asset: weight = 10% / forecast vol (sqrt of pred_var,
  Jensen-corrected), capped at 2; rest in cash at 0%. Decision at close t
  applies from day t+1. Rebalance every 5 trading days if |desired /
  current - 1| > 10%; weights drift between trades; costs 5 bp × traded
  exposure.
- Strategies: naive, ewma, har, lasso_b2_iv, rf_b2_iv + buy_hold (weight 1)
  + oracle (weight from the realised future variance: infeasible upper
  bound).
- Metrics: ann_vol, risk_rmse (RMSE of rolling 63-day vol vs target:
  primary), breach_pct (% of days rolling vol > 15%), max drawdown,
  turnover per year, annual return, Sharpe. `data/processed/backtest.rds`.

## Robustness (07_portfolio.R, robustness.R)

- `robustness.R` runs after `pipeline.R` and reads its saved outputs.
- Sensitivity of the per-asset backtest: costs 0 / 20 bp, daily / monthly
  rebalancing, band 0 / 20% (`backtest_sensitivity()`).
- Portfolio: inverse-vol weights from the 5 forecasts, scaled to 10% with
  the trailing 252-day correlation of daily returns, gross exposure ≤ 2;
  same trading rules; references equal_weight (20% each) and oracle.
- Horizon extension: HORIZON = 5 (target, embargo, CV purge) and
  HAC_LAG = 5, baselines + lasso_b2_iv + rf_b2_iv (forest settings reused);
  then both restored to 21. Output `data/processed/robustness.rds`.

## Post hoc extensions (pre-registered in S16, 2026-11-13, before any run)

Everything below was decided AFTER seeing the 2017-2026 results. It is
reported apart, labelled "post hoc", and never replaces the primary
comparison (best ML vs HAR, pooled QLIKE; answer: HAR not beaten). The list
is closed: nothing else is added before the results freeze (2026-12-13).
Script: `extensions.R` (after pipeline.R; reads features.rds and
predictions.rds, never rewrites them) -> `data/processed/extensions.rds`.

- E1 (S16) Information or algorithm? Two unpenalised OLS models, same
  walk-forward, embargo and Jensen correction as the others:
  `har_x` = HAR-IV of the literature: har_d, har_w, har_m + the asset's
  implied vol columns (IMPLIED_VOL_BY_ASSET); `ols_b2_iv` = OLS on exactly
  the Lasso's B2 inputs (block_features("b2", asset)). Reported: QLIKE / HAR
  per asset and pooled, DM vs HAR and vs lasso_b2_iv (lag 21), MZ, oil by
  year. Reading rule, oil (the only asset where lasso_b2_iv beat HAR):
  if DM(ols_b2_iv vs lasso_b2_iv) is not significant at 5%, the gain comes
  from the information (OVX), not from the Lasso; if lasso_b2_iv is
  significantly better, the Lasso's selection / shrinkage adds value.
  Other assets: reported, no claim.
  RESULT (S16): verdict for oil = information (DM ols_b2_iv vs Lasso -0.85).
  Descriptive: OLS + implied vol beats HAR pooled (har_x 0.880, ols_b2_iv
  0.862, DM -3.27) and the Lasso on 4 of 5 assets; gold har_x 0.757.
- E2 (S17) Forecast combinations, fixed equal weights on variance
  forecasts: HAR + EWMA, HAR + har_x, HAR + EWMA + lasso_b2_iv. The two
  best on pooled QLIKE over 2017-2025 are frozen and added to the live job;
  their live record starts the day they are added.
- E3 (S18) Level calibration: Duan smearing (variance = exp(2 pred) x mean
  of exp(2 x in-sample residual)) vs the lognormal correction; Lasso
  lambda.min vs 1-SE. Kept for the extensions if pooled QLIKE of HAR improves.
- E4 (S19) Intervals: 10% / 90% empirical quantiles of the out-of-sample
  log-vol errors of PREVIOUS walk-forward years (at least 2 years), vs the
  current lognormal interval; coverage 2019-2026.
- E5 (S20) Model Confidence Set (Hansen, Lunde, Nason 2011), 90%, T_max
  statistic, block bootstrap (blocks of 21 days, 1,000 draws), on QLIKE,
  per asset and pooled, over naive, ewma, har, lasso_b2_iv, rf_b2_iv,
  har_x, ols_b2_iv and the E2 combinations.
- E6 (S21) Backtest uncertainty: block bootstrap (blocks of 63 days, 1,000
  draws) of risk_rmse(model) - risk_rmse(har), 95% intervals; results
  without CPER and with CPER trained from 2016.
- E7 (S22, optional) HAR on Garman-Klass vols (`har_gk`); forest on the
  residuals of HAR (`rf_har_resid`, B2 inputs).

## Website (decided in S8/S9)

- **Static site** in `site/` (HTML, CSS, JS ES modules, no build step),
  chosen over Shiny for the visual ambition (reference: landonorris.com):
  full control of motion, instant load, free hosting (GitHub Pages).
- Data flow: R computes everything; `export_site.R` (after pipeline.R and
  robustness.R) writes `site/data/*.json` via `R/08_export.R`. The site
  only displays them. Exception: the portfolio simulator, ported to JS and
  validated against R outputs. `site/data/` is versioned (derived data,
  needed by GitHub Pages).
- Libraries (CDN, pinned versions): GSAP 3.13 (+ ScrollTrigger, SplitText)
  for motion, D3 v7 for charts. Native scroll, no scroll hijacking.
  Hero object: WebGL ray-marched liquid metal (S14 rework): one look per
  commodity (mirror gold, black iridescent oil, brushed copper, cold steel
  gas, satin corn), surface ripples = tonight's forecast vol (12% calm ->
  60% turbulent), cursor sphere on a time-based spring (K 70, C 11) with
  the cursor unprojected onto the object's plane (reach 0.85), adaptive
  resolution (starts at 75%, 40-100%). The hero cycles through the five
  commodities, one every 5 s (main.js, requestAnimationFrame timer), each
  as its shape; a 2px bar under the current hero-strip button fills over
  the 5 s (CSS var --progress, colour of the commodity). A click jumps to
  that commodity and restarts its 5 s; the cycle pauses while the pointer
  or keyboard focus (:focus-visible, not a click) is on the strip, when the hero is off screen and when
  the tab is hidden. Each commodity takes its shape (S14, student's choices): gold ingot, oil
  barrel, copper wire coil, gas bottle, corn cob with husk leaves; all
  signed distance functions in the same shader, blended with the liquid
  (u_morph: melt to liquid, switch shape, form), turned towards the cursor
  (yaw/pitch spring) with a slow spin. Morph rate 4.5/s (melt + form in
  about 1.5 s, so a shape stays formed about 3.5 s of its 5 s).
  Two shader programs (#define SHAPES 0/1): the shapes code behind a
  uniform test halved the drop's frame rate (ANGLE/GPUs may not skip it);
  the shapes program is compiled 3 s after load. Ray march: up to 120 steps
  (64 for the drop), hit tolerance 0.001 x (1 + t); a ray that runs out of
  steps INSIDE the bounding sphere counts as a hit (fading those made the
  detailed shapes semi-transparent: student's report, checked on white).
  CSS fallback. Under
  prefers-reduced-motion the metal still moves, slowly (time x0.35, smaller
  wander; the student's Windows has "Animation effects" off, which froze it);
  intro, scroll effects, hero cycle (no bars; the current button's bar
  stays full) and map fly-in stay off. Benchmark (software GL, 1440x900): 12 -> 25 fps.
- Scroll (js/motion.js): hero exit parallax, heading lines rising from a
  mask (SplitText), staggered panels, progress line under the nav. Nothing
  hidden in CSS: without JS or with reduced motion everything is visible.
- Design brief: `Creative Direction/*.docx` (dark warm base, champagne
  gold / copper accents, one material per commodity, purposeful motion,
  data first). Typefaces: GFS Didot (display, capitals, headlines),
  Manrope (text), IBM Plex Mono (numbers, tickers, axes).
- Local preview needs a local server (fetch of JSON fails on file://):
  VS Code "Live Server" extension, or `python -m http.server` in `site/`.
- Sections: hero (with a live strip), today, materials, findings, lab,
  simulator, method. The simulator data is lazy-loaded near its section. Downloads: derived CSVs
  in `site/data/csv/` (written by `export_site_csv()`).
- Findings chapter 05 "The weather test" (js/weathermap.js): 3D model of
  the Northeast/Midwest (three.js 0.170.0 from jsDelivr, loaded only near
  the chapter): extruded states (us-atlas 3.0.1 = Census cartographic
  boundaries, public domain, projected once by tools/build_map_geometry.js
  -> site/data/map_geometry.json), one pillar per weather city = 7-day HDD
  that week, ring = usual level, colour = anomaly (blue colder, amber
  milder, exact colours: toneMapped false), timeline + play + presets
  (Jan 2014 polar vortex, Feb 2015 deep freeze, Dec 2022 storm Elliott),
  side panel with the gas market (storage vs usual, UNG 22-day vol) and two
  clickable sparklines. Drag = orbit, no wheel zoom. Flat SVG fallback
  without WebGL. Data: weather_map_data() in 08_export.R (per-city HDD with
  the pipeline's own helpers; mean of city anomalies = hdd_anomaly, tested).
  Text: block B4 (HDD + storage + dollar) did not lower natural gas loss
  (Lasso 1.27x HAR before and after, forest 1.23 -> 1.32).
- Liquid glass (js/glass.js, S14): only on floating controls, never on
  content (Apple's rule): floating nav pill after the hero (hidden while the
  hero scrolls away), hero forecast strip, hero material label, map badge
  and tooltip. Chromium: per-element SVG filter in backdrop-filter, built
  from a displacement map of the element's exact rounded shape (bevel 16
  px, strength 26 px, R/G/B at 1/1.06/1.12 = slight dispersion, saturate
  1.45); others: frosted blur fallback. Pitfalls found on a striped test
  page: (1) the displacement scale must be POSITIVE (negative samples
  outside the pane: dark bands); (2) NO outer box-shadow on refracting
  glass, even on a pseudo-element: it shifts Chrome's filter box.
- Never put a CSS `transition` on `transform` for an element that GSAP
  animates (motion.js entrance): the transition fought GSAP and left the
  Today cards stuck 36 px low, over the legend (S15). Hover lifts use the
  separate `translate` property.
- Top nav (main.js navSpy): the link of the section in view is yellow
  (--amber) with a short underline, aria-current="true"; section in view =
  last one whose top passed 35% of the window; a click marks its link at
  once and holds it during the smooth scroll. On phones the nav row
  scrolls to the active link.
- Today readouts: "Since last week" green when the forecast rose
  (--better), red when it fell (--worse), as the student asked.
- Simulator charts: hover (or tap) shows a line, a dot per series and a
  tooltip with the date and values; both charts follow the same day.
- Selectors: always scope to the section (`#materials .chart`): several
  sections have `.chart` / `.tooltip` (bug in S14: the materials chart was
  drawn into the Today chart).
- Deployment: GitHub Pages through `.github/workflows/pages.yml` (runs the
  JS simulator test, then publishes `site/`). Pages source = GitHub Actions.

## Live layer (09_live.R, freeze_models.R, live.R, decided in S14)

- Frozen models: naive, EWMA, HAR, lasso_b2_iv, rf_b2_iv (min node 200), per
  asset, refitted on exactly the 2026 walk-forward training rows. T0 = last
  training date (2025-12-02, confirmed: gap 0 on 885 days x 5 models);
  first live forecast = first trading day of 2026 (2026-01-02) (the model needs the 21-day outcomes
  of its training rows, known only then: starting at T0 + 1 would be a
  look-ahead). `check_frozen()` must give gap 0 vs predictions.rds.
- Live sources: 5 ETF prices (Yahoo) + VIXCLS / OVXCLS / GVZCLS from FRED's
  public CSV export (fredgraph.csv, no key; same series and next-day rule as
  training; the API with FRED_API_KEY is the fallback: in S14 the API
  refused VIXCLS while the export worked). Full history is downloaded so the
  22-day windows and the EWMA match the pipeline. EIA, weather, GPR, dollar:
  not downloaded (they only feed B3/B4 models, which are not served).
- Yahoo live download: `to` = today (New York) + 1, because getSymbols()
  stops before `to` (the job was one day late); today's bar is dropped
  before 16:15 New York (`completed_sessions()`: a quote, not a close).
- The daily job commits to main: always `git pull` before pushing.
- Features: `build_features(raw, external = implied_vol_columns)`, the same
  code path as the pipeline (refactor checked by all existing tests).
- Fallback: download (2 attempts, 10 s timeout) -> last live snapshot
  (`data/processed/live_snapshot.rds`, kept between runs by actions/cache)
  -> pipeline cache (data/raw) -> previous live.json marked offline.
  `LIVE_DISABLED=1` forces offline mode.
- Headline model per asset: HAR, except oil (Lasso + OVX). 80% interval:
  lognormal, log vol ~ N(pred, resid_var).
- Track record since the first live day: QLIKE / HAR, RMSE, 80% interval
  coverage; the last 21 days are pending.
- GitHub Actions `.github/workflows/live.yml`: weekdays 22:30 UTC, R 4.6.1 +
  renv, optional secret FRED_API_KEY, commits `site/data/live.json`, then deploys
  Pages itself (a push by the job's token does not trigger pages.yml).
- Site: section `#today` (js/live.js): status badge (live / offline /
  stale after 3 weekdays without update), five readouts, forecast vs outcome
  chart with pending zone, live record, freshness table, disclaimer.

## Known limitations

- USO changed its roll strategy and did a 1-for-8 reverse split in 2020
  (adjusted prices handle the split; robustness check excluding 2020).
- GPR, EIA gas storage and Open-Meteo reanalysis are revised after the fact;
  no real-time vintages available.
- ~120 independent 21-day forecasts per asset out of sample → low test power.
- CPER illiquid in its first years: 595 days with High == Low, 329 days
  with zero volume (see decisions 13–14).
- EIA weekly gas storage (Lower 48) starts 2010-01-01, so a 5-year average
  is only available from 2015. Decision (S3): deviation from the average of
  the available past years, at least 3 → gas_dev starts in early 2013.

## Current status

See the top entry of `PROJECT_LOG.md`.
