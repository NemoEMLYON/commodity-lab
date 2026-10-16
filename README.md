# Commodity Lab

Do external variables (geopolitics, inventories, weather) combined with
machine learning improve commodity volatility forecasts over the HAR model?
And does the improvement matter for a portfolio manager who targets a risk
level?

Work in progress — "Machine Learning with R" course project, emlyon.

## Universe

GLD (gold), USO (crude oil), CPER (copper), UNG (natural gas), CORN (corn).
Common sample from late 2011.

## Reproduce

Requirements: R ≥ 4.4.

```r
# from the project root
renv::restore()        # install the pinned package versions
source("pipeline.R")   # download (or load cached) data
```

## Structure

```
R/            functions, one file per pipeline step
pipeline.R    runs the steps in order
tests/        unit and anti-leakage tests
data/raw/     source data as received (not in Git)
data/processed/
app/          Shiny application (later)
```
