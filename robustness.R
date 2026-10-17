# robustness.R — Checks that the main results do not depend on our choices.
# Run AFTER pipeline.R (it reads its saved outputs): source("robustness.R")

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")
source("R/05_inference.R")
source("R/06_backtest.R")
source("R/07_portfolio.R")

raw         <- download_all()
features    <- readRDS(FEATURES_PATH)
predictions <- readRDS(PREDICTIONS_PATH)
robust      <- list()

# 1. Trading assumptions of the per-asset backtest -------------------------
robust$sensitivity <- backtest_sensitivity(predictions, features)
message("\n== Sensitivity: risk_rmse (average over assets) under other trading rules")
print(sensitivity_wide(robust$sensitivity, "risk_rmse"), digits = 3)
message("\n== Sensitivity: annual return net of costs")
print(sensitivity_wide(robust$sensitivity, "ann_ret"), digits = 3)

# 2. Inverse-volatility portfolio of the five ETFs -------------------------
robust$portfolio <- portfolio_summary(run_portfolio(predictions, features))
message("\n== Vol-targeted inverse-vol portfolio (5 ETFs)")
print(robust$portfolio, digits = 3)

# 3. Extension: forecast horizon = rebalancing horizon (5 days) -----------
# Every horizon-dependent step (target, embargo, CV purge, HAC lag) reads
# HORIZON, so changing it here rebuilds the whole study at 5 days.
# Forest settings reused from the main study (per asset, min node 200).
HORIZON <- 5
HAC_LAG <- 5
features_5 <- build_features(raw)
block_b2   <- function(a) block_features("b2", a)
models_5   <- c(BASELINE_MODELS,
                list(make_lasso("lasso_b2_iv", block_b2),
                     make_rf("rf_b2_iv", block_b2, pooled = FALSE, min_node_size = 200)))
predictions_5 <- walk_forward(features_5, models_5)

robust$evaluation_5 <- evaluate(predictions_5)
robust$backtest_5   <- backtest_summary(run_backtest(predictions_5, features_5))
robust$portfolio_5  <- portfolio_summary(run_portfolio(predictions_5, features_5))
HORIZON <- 21                                   # restore the main setting
HAC_LAG <- 21

message("\n== Horizon 5 days: pooled QLIKE (forecast accuracy)")
e5 <- robust$evaluation_5
print(e5[e5$asset == "all", c("model", "qlike", "qlike_vs_har", "var_ratio")], digits = 3)

message("\n== Risk tracking (risk_rmse, average over assets): 21-day vs 5-day forecasts")
b21 <- backtest_summary(run_backtest(predictions, features))
b21 <- b21[b21$asset == "all", c("strategy", "risk_rmse")]
b5  <- robust$backtest_5[robust$backtest_5$asset == "all", c("strategy", "risk_rmse")]
print(merge(b21, b5, by = "strategy", suffixes = c("_h21", "_h5")), digits = 3)

message("\n== Portfolio, 5-day forecasts")
print(robust$portfolio_5, digits = 3)

saveRDS(robust, file.path("data", "processed", "robustness.rds"))
