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

# Step 3 — choose the random forest settings on 2015-2016 only,
# before looking at any 2017+ result
validation      <- walk_forward(features, c(list(model_har), rf_candidate_models()),
                                test_years = VALIDATION_YEARS)
validation_eval <- evaluate(validation)
print(validation_eval[validation_eval$asset == "all", ], digits = 3)
rf_config <- select_rf_config(validation_eval)
message("Forest settings chosen: ", rf_config$name)

# Step 4 — walk-forward out-of-sample forecasts, 2017+ (yearly refit)
all_models  <- c(BASELINE_MODELS, ml_models(rf_config$pooled, rf_config$min_node_size))
predictions <- walk_forward(features, all_models)
saveRDS(predictions, PREDICTIONS_PATH)
evaluation  <- evaluate(predictions)
print(evaluation, digits = 3)
print(design_2x2(evaluation), digits = 3)
