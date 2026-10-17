# pipeline.R — Run the offline pipeline, step by step.
# Run from the project root: source("pipeline.R")

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")
source("R/05_inference.R")

# Step 1 — raw data (downloaded once, then read from data/raw/)
raw <- download_all()
print(summarise_data(raw))
print(check_prices(raw))

# Step 2 — modelling table: target + features, one row per (asset, day)
features <- build_features(raw)
dir.create(dirname(FEATURES_PATH), recursive = TRUE, showWarnings = FALSE)
saveRDS(features, FEATURES_PATH)
print(summarise_features(features))

# Step 3 — choose the random forest settings on 2015-2016 only,
# before looking at any 2017+ result
validation      <- walk_forward(features, c(list(model_har), rf_candidate_models()),
                                test_years = VALIDATION_YEARS)
validation_eval <- evaluate(validation)
rf_config <- select_rf_config(validation_eval)
message("Forest settings chosen on 2015-2016: ", rf_config$name)

# Step 4 — walk-forward out-of-sample forecasts, 2017+ (yearly refit):
# baselines, the 2x2 design, and the asset-specific feature blocks
all_models <- c(BASELINE_MODELS,
                ml_models(rf_config$pooled, rf_config$min_node_size),
                block_models(rf_config$min_node_size))
predictions <- walk_forward(features, all_models)
saveRDS(predictions, PREDICTIONS_PATH)

# Step 5 — evaluation and statistical tests
evaluation <- evaluate(predictions)
dm         <- dm_table(predictions)
key_models <- c("ewma", "lasso_full", "rf_full", "lasso_b2_iv", "rf_b2_iv", "lasso_b4_fund")

results <- list(
  evaluation   = evaluation,
  design_2x2   = design_2x2(evaluation),
  blocks_lasso = block_matrix(evaluation, "lasso"),
  blocks_rf    = block_matrix(evaluation, "rf"),
  dm           = dm,
  mz           = mz_table(predictions, c("har", key_models)),
  by_year      = evaluate_by_year(predictions, key_models),
  by_year_oil  = evaluate_by_year(predictions, key_models, asset = "oil")
)
saveRDS(results, RESULTS_PATH)

message("\n== Pooled QLIKE (5 assets), all models")
print(evaluation[evaluation$asset == "all", ], digits = 3)
message("\n== 2x2 design: QLIKE / HAR")
print(results$design_2x2, digits = 3)
message("\n== Blocks, Lasso: QLIKE / HAR")
print(results$blocks_lasso)
message("\n== Blocks, random forest: QLIKE / HAR")
print(results$blocks_rf)
message("\n== Diebold-Mariano statistic vs HAR (< -1.96: significantly better)")
print(dm_wide(dm, key_models))
message("\n== Mincer-Zarnowitz on log vol (good forecast: a = 0, b = 1)")
print(results$mz, digits = 2)
message("\n== QLIKE / HAR by year, pooled")
print(results$by_year)
message("\n== QLIKE / HAR by year, oil")
print(results$by_year_oil)
