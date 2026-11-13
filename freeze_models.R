# freeze_models.R — Save the models used by the live layer.
# Run once a year, AFTER pipeline.R: source("freeze_models.R")
#
# Refits the models of the last walk-forward year (FROZEN_YEAR) on the same
# rows with the same settings, checks that they reproduce the walk-forward
# forecasts exactly, then saves them in models/ (versioned: the daily job on
# GitHub needs them and cannot rebuild them without the full data).

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")
source("R/06_backtest.R")
source("R/08_export.R")
source("R/09_live.R")
source("R/10_extensions.R")

features    <- readRDS(FEATURES_PATH)
predictions <- readRDS(PREDICTIONS_PATH)
# har_x (live since S16) comes from extensions.R, not from pipeline.R
e1 <- readRDS(EXTENSIONS_PATH)$e1$predictions
predictions <- rbind(predictions[, names(e1)], e1)

frozen <- freeze_models(features)
message("Frozen year: ", frozen$year,
        " | last training date (T0): ", frozen$t0,
        " | models usable from: ", frozen$first_test)
print(frozen$n_train)

# Must be 0 (or ~1e-15): the frozen models are the walk-forward models.
check <- check_frozen(frozen, features, predictions)
print(check)
stopifnot(max(check$gap) < 1e-10)

dir.create(dirname(FROZEN_MODELS_PATH), showWarnings = FALSE)
saveRDS(frozen, FROZEN_MODELS_PATH, compress = "xz")   # smallest file
message("Saved ", FROZEN_MODELS_PATH, " (", round(file.size(FROZEN_MODELS_PATH) / 1024), " KB)")
