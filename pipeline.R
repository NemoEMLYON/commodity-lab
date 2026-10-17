# pipeline.R — Run the offline pipeline, step by step.
# Run from the project root: source("pipeline.R")

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")

# Step 1 — raw data (downloaded once, then read from data/raw/)
raw <- download_all()
print(summarise_data(raw))
print(check_prices(raw))

# Step 2 — modelling table: target + features, one row per (asset, day)
features <- build_features(raw)
dir.create(dirname(FEATURES_PATH), recursive = TRUE, showWarnings = FALSE)
saveRDS(features, FEATURES_PATH)
print(summarise_features(features))
print(feature_start_dates(features))

# Step 3 — walk-forward out-of-sample forecasts (yearly refit from 2017)
predictions <- walk_forward(features, BASELINE_MODELS)
saveRDS(predictions, PREDICTIONS_PATH)
print(evaluate(predictions), digits = 3)
