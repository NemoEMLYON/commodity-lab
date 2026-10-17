# pipeline.R — Run the offline pipeline, step by step.
# Run from the project root: source("pipeline.R")

source("R/01_data.R")
source("R/02_features.R")

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
