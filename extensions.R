# extensions.R — Post hoc extensions (pre-registered in CLAUDE.md, S16).
# Run AFTER pipeline.R (it reads its saved outputs): source("extensions.R")
# Never rewrites predictions.rds: the primary results stay as they are.

source("R/01_data.R")
source("R/02_features.R")
source("R/03_models.R")
source("R/04_walkforward.R")
source("R/05_inference.R")
source("R/06_backtest.R")
source("R/10_extensions.R")

features    <- readRDS(FEATURES_PATH)
predictions <- readRDS(PREDICTIONS_PATH)
extensions  <- if (file.exists(EXTENSIONS_PATH)) readRDS(EXTENSIONS_PATH) else list()

# E1 — Information or algorithm? -------------------------------------------
# har_x = HAR + the asset's implied vol (OLS); ols_b2_iv = OLS on exactly the
# inputs of lasso_b2_iv. Same walk-forward, embargo and Jensen correction.
e1 <- run_extension_e1(features, predictions)
extensions$e1 <- e1

message("\n== E1 (post hoc): QLIKE / HAR, 2017-2026 (< 1 beats HAR)")
print(e1$qlike_vs_har)
message("\n== E1: Diebold-Mariano vs HAR (< -1.96: significantly better than HAR)")
print(e1$dm_vs_har)
message("\n== E1: Diebold-Mariano vs lasso_b2_iv (> 1.96: the Lasso is significantly better)")
print(e1$dm_vs_lasso, digits = 3)
message("\n== E1: Mincer-Zarnowitz on log vol (good forecast: a = 0, b = 1)")
print(e1$mz[e1$mz$asset %in% c("oil", "gold"), ], digits = 2)
message("\n== E1: QLIKE / HAR by year, oil")
print(e1$by_year_oil)
message("\n== E1: har_x coefficients by training window, oil")
print(coef_wide(e1$coef_har_x, "oil"))
message("\n== E1: har_x coefficients by training window, gold")
print(coef_wide(e1$coef_har_x, "gold"))
message("\n== E1 verdict for oil (pre-registered rule): ", e1$verdict)

# E2 — Forecast combinations --------------------------------------------------
# Fixed equal weights on variance forecasts. The two best on pooled QLIKE over
# 2017-2025 are the ones added to the live job (forward test).
e2 <- run_extension_e2(features, predictions, e1$predictions)
extensions$e2 <- e2

message("\n== E2 (post hoc): QLIKE / HAR, 2017-2026")
print(e2$qlike_vs_har)
message("\n== E2: var_ratio (mean forecast / mean realised variance, 1 = right level)")
print(e2$var_ratio)
message("\n== E2: Diebold-Mariano vs HAR (< -1.96: significantly better than HAR)")
print(e2$dm_vs_har)
message("\n== E2: Diebold-Mariano vs har_x (< -1.96: the combination is significantly better)")
print(e2$dm_vs_harx)
message("\n== E2: QLIKE / HAR by year, pooled")
print(e2$by_year)
message("\n== E2: vol targeting at 10% (average over assets; risk_rmse lower is better)")
print(e2$backtest[e2$backtest$asset == "all", ], digits = 3, row.names = FALSE)
message("\n== E2: chosen for the live job (best pooled QLIKE, 2017-2025): ",
        paste(e2$selected, collapse = ", "))

saveRDS(extensions, EXTENSIONS_PATH)
message("\nSaved ", EXTENSIONS_PATH)
