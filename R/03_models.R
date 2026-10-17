# 03_models.R — Forecasting models with a common interface.
#
# Every model is a list with:
#   name     short label used in result tables
#   pooled   TRUE: one model fitted on all assets at once (panel);
#            FALSE: one model per asset
#   fit      function(train) -> fitted object; must contain `resid_var`,
#            the in-sample variance of the log-vol residuals (0 if the
#            model is not fitted)
#   predict  function(fitted, test) -> predicted log vol for each test row
#
# Same idea as scikit-learn's fit()/predict(). All models predict the
# target of 02_features.R: log annualised realised vol over t+1 .. t+21.

library(glmnet)
library(ranger)

# ---- Feature sets (the two columns of the 2x2 design) -----------------------

# Information from the asset's own returns only.
BASE_FEATURES <- c("har_d", "har_w", "har_m", "neg_d", "neg_w", "neg_m", "ewma")

# External information: implied vol, dollar, inventories, geopolitics, weather.
EXTERNAL_FEATURES <- c("log_vix", "log_ovx", "log_gvz", "usd_ret_22", "usd_vol_22",
                       "crude_dev", "gas_dev", "log_gpr_7", "log_gpr_30",
                       "gpr_shock", "hdd_anomaly")

FULL_FEATURES <- c(BASE_FEATURES, EXTERNAL_FEATURES)


# ---- Baselines --------------------------------------------------------------

# Naive: next month's vol = vol of the last 22 days.
model_naive <- list(
  name    = "naive",
  pooled  = FALSE,
  fit     = function(train) list(resid_var = 0),
  predict = function(fitted, test) test$har_m
)

# EWMA (RiskMetrics, lambda = 0.94): flat forecast over the horizon.
model_ewma <- list(
  name    = "ewma",
  pooled  = FALSE,
  fit     = function(train) list(resid_var = 0),
  predict = function(fitted, test) test$ewma
)

# HAR (Corsi, 2009), estimated by OLS on log vols:
#   target = b0 + b_d * har_d + b_w * har_w + b_m * har_m + error
model_har <- list(
  name   = "har",
  pooled = FALSE,
  fit = function(train) {
    ols <- lm(target ~ har_d + har_w + har_m, data = train)
    list(ols = ols, resid_var = mean(residuals(ols)^2))
  },
  predict = function(fitted, test) {
    as.numeric(predict(fitted$ols, newdata = test))
  }
)

BASELINE_MODELS <- list(model_naive, model_ewma, model_har)


# ---- Lasso (glmnet) with purged cross-validation -----------------------------
#
# The penalty lambda is chosen INSIDE the training window. Ordinary k-fold CV
# would leak: neighbouring days share 20 of their 21 target returns. So we use
# contiguous blocks of days as folds and drop ("purge") the `horizon` rows on
# each side of the validation block from the rows used to fit.

CV_FOLDS <- 5

# Fold number of each row: k contiguous blocks of (almost) equal size.
# Rows must be sorted by date (one asset).
cv_blocks <- function(n, k = CV_FOLDS) {
  ceiling(seq_len(n) / n * k)
}

# TRUE for rows within `horizon` positions before or after the block `valid`.
purge_rows <- function(valid, horizon = HORIZON) {
  pos   <- seq_along(valid)
  first <- min(pos[valid])
  last  <- max(pos[valid])
  (pos >= first - horizon & pos < first) | (pos > last & pos <= last + horizon)
}

fit_lasso <- function(train, features, n_folds = CV_FOLDS, horizon = HORIZON) {
  train <- train[order(train$date), ]
  x <- as.matrix(train[, features])
  y <- train$target

  path    <- glmnet(x, y, alpha = 1)          # alpha = 1: Lasso penalty
  lambdas <- path$lambda
  folds   <- cv_blocks(nrow(train), n_folds)

  # Validation MSE for every (fold, lambda).
  errors <- matrix(NA, n_folds, length(lambdas))
  for (k in seq_len(n_folds)) {
    valid  <- folds == k
    fit_on <- !valid & !purge_rows(valid, horizon)
    fit_k  <- glmnet(x[fit_on, ], y[fit_on], alpha = 1, lambda = lambdas)
    pred   <- predict(fit_k, newx = x[valid, , drop = FALSE], s = lambdas)
    errors[k, ] <- colMeans((pred - y[valid])^2)
  }

  # 1-SE rule: the largest lambda (sparsest model) whose CV error is within
  # one standard error of the best one. More robust with noisy targets.
  cv_mean <- colMeans(errors)
  cv_se   <- apply(errors, 2, sd) / sqrt(n_folds)
  best    <- which.min(cv_mean)
  lambda  <- max(lambdas[cv_mean <= cv_mean[best] + cv_se[best]])

  resid <- y - as.numeric(predict(path, newx = x, s = lambda))
  list(glmnet     = path,
       lambda     = lambda,
       n_selected = sum(coef(path, s = lambda)[-1] != 0),
       resid_var  = mean(resid^2))
}

# `features` is a vector of column names, or a function(asset) returning one
# (asset-specific feature blocks, see below).
resolve_features <- function(features, asset) {
  if (is.function(features)) features(asset) else features
}

make_lasso <- function(name, features) {
  force(features)   # evaluate now: R arguments are lazy (see make_rf)
  list(
    name    = name,
    pooled  = FALSE,
    fit     = function(train) {
      cols   <- resolve_features(features, train$asset[1])
      fitted <- fit_lasso(train, cols)
      fitted$features <- cols
      fitted
    },
    predict = function(fitted, test) {
      newx <- as.matrix(test[, fitted$features])
      as.numeric(predict(fitted$glmnet, newx = newx, s = fitted$lambda))
    }
  )
}


# ---- Random forest (ranger) --------------------------------------------------
#
# Per asset, or pooled: the 5 assets stacked, with the asset name as an extra
# (categorical) feature so the forest can still treat them differently.
# resid_var uses out-of-bag predictions: each tree is evaluated on the rows
# it did not see, which is closer to out-of-sample than in-sample residuals.

RF_TREES <- 500
RF_SEED  <- 42

rf_data <- function(df, features, pooled) {
  out <- df[, c("target", features)]
  if (pooled) out$asset <- factor(df$asset, levels = ASSETS)
  out
}

make_rf <- function(name, features, pooled, min_node_size, num_trees = RF_TREES) {
  # R evaluates arguments lazily, only when first used. `features` is only
  # used inside fit(), i.e. much later: if the caller's variable has changed
  # in between (a loop), every model would get its LAST value. force() fixes
  # each argument at creation time.
  force(features); force(pooled); force(min_node_size); force(num_trees)
  list(
    name   = name,
    pooled = pooled,
    fit    = function(train) {
      if (pooled && is.function(features)) stop("asset-specific features need pooled = FALSE")
      cols <- resolve_features(features, train$asset[1])
      data <- rf_data(train, cols, pooled)
      rf <- ranger(target ~ ., data = data,
                   num.trees     = num_trees,
                   min.node.size = min_node_size,       # minimum rows per leaf
                   respect.unordered.factors = "order", # how to split on asset
                   seed          = RF_SEED)
      list(rf = rf, features = cols,
           resid_var = mean((data$target - rf$predictions)^2))
    },
    predict = function(fitted, test) {
      test$target <- NA_real_                     # not used, keeps columns aligned
      predict(fitted$rf, data = rf_data(test, fitted$features, pooled))$predictions
    }
  )
}

# Forest settings compared on the 2015-2016 validation years (full features).
RF_CANDIDATES <- expand.grid(pooled = c(FALSE, TRUE), min_node_size = c(5, 50, 200))

rf_candidate_models <- function(candidates = RF_CANDIDATES, features = FULL_FEATURES) {
  lapply(seq_len(nrow(candidates)), function(i) {
    c_i <- candidates[i, ]
    make_rf(sprintf("rf_%s_node%d", ifelse(c_i$pooled, "pooled", "asset"), c_i$min_node_size),
            features, c_i$pooled, c_i$min_node_size)
  })
}

# The four models of the 2x2 design, with the forest settings chosen.
ml_models <- function(rf_pooled, rf_min_node_size) {
  list(
    make_lasso("lasso_base", BASE_FEATURES),
    make_lasso("lasso_full", FULL_FEATURES),
    make_rf("rf_base", BASE_FEATURES, rf_pooled, rf_min_node_size),
    make_rf("rf_full", FULL_FEATURES, rf_pooled, rf_min_node_size)
  )
}


# ---- Asset-specific feature blocks ------------------------------------------
#
# Blocks are added one at a time, so the gain of each block can be measured:
#   B1 own returns (BASE_FEATURES)          -> models lasso_base / rf_base
#   B2 + implied vol: the asset's own index when one exists (OVX for oil,
#      GVZ for gold), and the VIX for every asset
#   B3 + geopolitical risk
#   B4 + fundamentals relevant to the asset (EIA crude stocks for oil, gas
#      storage and heating degree days for natural gas) and the dollar
# Mapping fixed in the S0 plan: no public implied vol for copper, gas or corn;
# EIA stocks only for oil and gas; HDD mainly relevant for gas.

IMPLIED_VOL_BY_ASSET <- list(oil = c("log_ovx", "log_vix"),
                             gold = c("log_gvz", "log_vix"),
                             copper = "log_vix", natgas = "log_vix", corn = "log_vix")

FUNDAMENTALS_BY_ASSET <- list(oil = "crude_dev",
                              natgas = c("gas_dev", "hdd_anomaly"),
                              gold = character(0), copper = character(0),
                              corn = character(0))

GPR_FEATURES    <- c("log_gpr_7", "log_gpr_30", "gpr_shock")
DOLLAR_FEATURES <- c("usd_ret_22", "usd_vol_22")

block_features <- function(block, asset) {
  b1 <- BASE_FEATURES
  b2 <- c(b1, IMPLIED_VOL_BY_ASSET[[asset]])
  b3 <- c(b2, GPR_FEATURES)
  b4 <- c(b3, FUNDAMENTALS_BY_ASSET[[asset]], DOLLAR_FEATURES)
  list(b1 = b1, b2 = b2, b3 = b3, b4 = b4)[[block]]
}

# Lasso and forest on blocks B2..B4 (B1 = the *_base models of the 2x2).
block_models <- function(rf_min_node_size) {
  blocks <- c(b2_iv = "b2", b3_gpr = "b3", b4_fund = "b4")
  models <- list()
  for (label in names(blocks)) {
    feats <- local({ b <- blocks[[label]]; function(asset) block_features(b, asset) })
    models[[length(models) + 1]] <- make_lasso(paste0("lasso_", label), feats)
    models[[length(models) + 1]] <- make_rf(paste0("rf_", label), feats,
                                            pooled = FALSE, min_node_size = rf_min_node_size)
  }
  models
}
