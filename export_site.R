# export_site.R — Write the JSON files the website reads (site/data/).
# Run AFTER pipeline.R and robustness.R: source("export_site.R")

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")
source("R/05_inference.R")
source("R/06_backtest.R")
source("R/07_portfolio.R")
source("R/08_export.R")

features    <- readRDS(FEATURES_PATH)
predictions <- readRDS(PREDICTIONS_PATH)
results     <- readRDS(RESULTS_PATH)
backtest    <- readRDS(BACKTEST_PATH)
robust_path <- file.path("data", "processed", "robustness.rds")
robust      <- if (file.exists(robust_path)) readRDS(robust_path) else NULL

paths <- export_site_data(features, predictions, results,
                          backtest_summary(backtest), robust)

print(data.frame(file = paths, kb = round(file.size(paths) / 1024, 1)))
