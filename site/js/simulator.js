/* simulator.js — JavaScript port of the R backtest (R/06_backtest.R).
 *
 * Same functions, same rules, line for line:
 *   targetWeight     = target_weight()
 *   simulateStrategy = simulate_strategy()
 *   strategyMetrics  = strategy_metrics()
 * Checked against results computed in R (data/simulator_checks.json) by
 * tests/test_simulator.js and, live, by the page itself.
 *
 * Works in the browser (window.Simulator) and in Node (require).
 */
(function (root) {
  "use strict";

  const TRADING_DAYS = 252;

  // Desired exposure: target / forecast vol, capped. NaN when no forecast.
  function targetWeight(vol, target, cap) {
    return vol == null || !(vol > 0) ? NaN : Math.min(target / vol, cap);
  }

  // assetRet[t]: simple return from close t-1 to close t.
  // desired[t]:  weight wanted at the close of day t (NaN: no decision).
  function simulateStrategy(assetRet, desired, opts) {
    const every = opts.every, band = opts.band, costBp = opts.costBp;
    const n = assetRet.length;
    const ret = new Array(n).fill(0);
    const weight = new Array(n).fill(0);
    const traded = new Array(n).fill(0);
    let current = 0;                                   // start in cash

    for (let t = 0; t < n; t++) {
      // 1. Day t: earn yesterday's weight times the asset return, then drift.
      if (t > 0) {
        const r = assetRet[t];
        ret[t] = current * r;
        current = current * (1 + r) / (1 + current * r);
      }
      // 2. Close of day t: rebalance on scheduled days, outside the band.
      //    R counts days from 1, so day t here is day t + 1 in R:
      //    (t + 1 - 1) %% every == 0  <=>  t % every === 0.
      const d = desired[t];
      if (t % every === 0 && !Number.isNaN(d)) {
        const farEnough = current === 0 || Math.abs(d / current - 1) > band;
        if (farEnough) {
          traded[t] = Math.abs(d - current);
          ret[t] -= traded[t] * costBp / 1e4;
          current = d;
        }
      }
      weight[t] = current;
    }
    return { ret, weight, traded };
  }

  const mean = x => x.reduce((s, v) => s + v, 0) / x.length;
  function sd(x) {                                     // n - 1, like R's sd()
    const m = mean(x);
    return Math.sqrt(x.reduce((s, v) => s + (v - m) * (v - m), 0) / (x.length - 1));
  }

  // Mean of x[t-k+1 .. t]; NaN until k values exist (zoo::rollmeanr).
  function rollMean(x, k) {
    const out = new Array(x.length).fill(NaN);
    let sum = 0;
    for (let i = 0; i < x.length; i++) {
      sum += x[i];
      if (i >= k) sum -= x[i - k];
      if (i >= k - 1) out[i] = sum / k;
    }
    return out;
  }

  function rollingVol(ret, window) {
    return rollMean(ret.map(r => r * r), window).map(v => Math.sqrt(TRADING_DAYS * v));
  }

  function strategyMetrics(ret, traded, target, window) {
    const rv = rollingVol(ret, window).filter(v => !Number.isNaN(v));
    const wealth = [];
    let w = 1, peak = 1, maxDd = 0;
    for (const r of ret) {
      w *= 1 + r;
      wealth.push(w);
      peak = Math.max(peak, w);
      maxDd = Math.min(maxDd, w / peak - 1);
    }
    const years = ret.length / TRADING_DAYS;
    return {
      ann_vol: sd(ret) * Math.sqrt(TRADING_DAYS),
      risk_rmse: Math.sqrt(mean(rv.map(v => (v - target) * (v - target)))),
      breach_pct: 100 * mean(rv.map(v => (v > 1.5 * target ? 1 : 0))),
      max_dd: maxDd,
      turnover: traded.reduce((s, v) => s + v, 0) / years,
      ann_ret: Math.pow(wealth[wealth.length - 1], 1 / years) - 1,
      sharpe: mean(ret) / sd(ret) * Math.sqrt(TRADING_DAYS),
      wealth
    };
  }

  // One strategy on one asset. strategy: a model id, "oracle" or "buy_hold".
  function run(series, strategy, s) {
    const desired = strategy === "buy_hold"
      ? series.ret.map(() => 1)
      : series.vol[strategy].map(v => targetWeight(v, s.target, s.cap));
    const bt = simulateStrategy(series.ret, desired, { every: s.every, band: s.band, costBp: s.cost_bp });
    const m = strategyMetrics(bt.ret, bt.traded, s.target, 63);
    return { ...bt, metrics: m, rollingVol: rollingVol(bt.ret, 63) };
  }

  // Compare every reference case computed in R. Returns the worst relative gap.
  function validate(sim, checks) {
    const fields = ["ann_vol", "risk_rmse", "breach_pct", "max_dd", "turnover", "ann_ret", "sharpe"];
    let worst = 0, passed = 0;
    const failures = [];
    for (const c of checks.cases) {
      const res = run(sim[c.asset], c.strategy, checks.settings[c.setting]);
      const got = { ...res.metrics,
                    sum_ret: res.ret.reduce((s, v) => s + v, 0),
                    last_weight: res.weight[res.weight.length - 1] };
      let ok = true;
      for (const f of fields.concat(["sum_ret", "last_weight"])) {
        const gap = Math.abs(got[f] - c[f]) / Math.max(1e-12, Math.abs(c[f]));
        worst = Math.max(worst, gap);
        if (gap > 1e-9) { ok = false; failures.push(`${c.asset}/${c.setting}/${c.strategy}/${f}: R ${c[f]} JS ${got[f]}`); }
      }
      if (ok) passed++;
    }
    return { passed, total: checks.cases.length, worst, failures };
  }

  const api = { targetWeight, simulateStrategy, strategyMetrics, rollingVol, run, validate };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.Simulator = api;
})(typeof window !== "undefined" ? window : globalThis);
