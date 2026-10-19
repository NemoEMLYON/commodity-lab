// Checks the JavaScript simulator against the results computed in R.
// Run from the project root (needs Node.js): node site/tests/test_simulator.js
"use strict";

const fs = require("fs");
const path = require("path");
const Sim = require("../js/simulator.js");

const dataDir = path.join(__dirname, "..", "data");
const sim = JSON.parse(fs.readFileSync(path.join(dataDir, "simulator.json"), "utf8"));
const checks = JSON.parse(fs.readFileSync(path.join(dataDir, "simulator_checks.json"), "utf8"));

// Small hand-made cases (same as tests/test_backtest.R)
function eq(a, b, msg) {
  if (Math.abs(a - b) > 1e-12) { console.error(`FAIL ${msg}: ${a} != ${b}`); process.exitCode = 1; }
}
let r = Sim.simulateStrategy([0, 0.10, 0], [0.5, NaN, NaN], { every: 1, band: 0, costBp: 0 });
eq(r.weight[1], 55 / 105, "weight drifts with prices");
r = Sim.simulateStrategy([0, 0], [0.8, NaN], { every: 1, band: 0, costBp: 10 });
eq(r.ret[0], -0.8 * 10 / 1e4, "each trade pays its cost");
r = Sim.simulateStrategy([0, 0, 0], [1, 1.05, 1.2], { every: 1, band: 0.10, costBp: 0 });
eq(r.traded[1], 0, "inside the band: no trade");
eq(r.traded[2], 0.2, "outside the band: trade");
eq(Sim.strategyMetrics([0.10, -0.50, 0.20], [0, 0, 0], 0.1, 63).max_dd, -0.5, "max drawdown");

// Reference cases computed in R
const v = Sim.validate(sim, checks);
console.log(`R reference cases: ${v.passed}/${v.total} match, largest relative gap ${v.worst.toExponential(2)}`);
if (v.failures.length) { console.error(v.failures.slice(0, 10).join("\n")); process.exitCode = 1; }
