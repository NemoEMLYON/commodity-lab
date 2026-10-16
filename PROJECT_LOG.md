# Project log

Newest session first. Each entry: done / next / decisions / open issues.

## S1 — 2026-10-16 — Skeleton and price data

**Done**
- Environment installed: R 4.6.1, VS Code + R extension, Git, GitHub CLI
  (account NemoEMLYON), project packages.
- Project skeleton, `CLAUDE.md`, this log, `.gitignore`.
- `R/01_data.R`: downloads ETF prices (Yahoo) and implied vol (FRED), caches
  them in `data/raw/`. `pipeline.R` runs it and prints a data summary.

**Next (S2)**
- EIA (crude, gas), GPR, Open-Meteo HDD into the cache.
- Data quality report: gaps, splits, zero-range days (High == Low).

**Decisions**
- See `CLAUDE.md` > Decisions.

**Open issues**
- Creative direction document not received yet (needed only for the site).
- Oral format unknown (duration, live code demo?) — changes S7 content.
