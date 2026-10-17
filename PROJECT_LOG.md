# Project log

Newest session first. Each entry: done / next / decisions / open issues.

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
