# 03_models.R — Forecasting models with a common interface.
#
# Every model is a list with:
#   name     short label used in result tables
#   fit      function(train) -> fitted object; must contain `resid_var`,
#            the in-sample variance of the log-vol residuals (0 if the
#            model is not fitted)
#   predict  function(fitted, test) -> predicted log vol for each test row
#
# Same idea as scikit-learn's fit()/predict(). All models predict the
# target of 02_features.R: log annualised realised vol over t+1 .. t+21.

# Naive: next month's vol = vol of the last 22 days.
model_naive <- list(
  name    = "naive",
  fit     = function(train) list(resid_var = 0),
  predict = function(fitted, test) test$har_m
)

# EWMA (RiskMetrics, lambda = 0.94): flat forecast over the horizon.
model_ewma <- list(
  name    = "ewma",
  fit     = function(train) list(resid_var = 0),
  predict = function(fitted, test) test$ewma
)

# HAR (Corsi, 2009), estimated by OLS on log vols:
#   target = b0 + b_d * har_d + b_w * har_w + b_m * har_m + error
model_har <- list(
  name = "har",
  fit = function(train) {
    ols <- lm(target ~ har_d + har_w + har_m, data = train)
    list(ols = ols, resid_var = mean(residuals(ols)^2))
  },
  predict = function(fitted, test) {
    as.numeric(predict(fitted$ols, newdata = test))
  }
)

BASELINE_MODELS <- list(model_naive, model_ewma, model_har)
