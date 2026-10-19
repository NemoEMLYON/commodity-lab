/* sim-ui.js — the "Steer it yourself" section: controls, KPIs, two charts,
 * and the live check against the R reference results.
 * Uses window.Simulator (simulator.js). Exposes window.SimUI = { init(data, helpers) }.
 */
(function () {
  "use strict";

  const DEFAULTS = { model: "har", target: 0.10, cap: 2, every: 5, band: 0.10, cost_bp: 5 };
  const MODEL_LABELS = { naive: "Naive", ewma: "EWMA", har: "HAR", lasso_b2_iv: "Lasso + implied vol",
                         rf_b2_iv: "Forest + implied vol", oracle: "Oracle" };

  let data, h, asset = "gold";
  const $ = sel => document.querySelector(sel);

  function settings() {
    const f = $("#sim-form");
    return {
      model: f.querySelector('input[name="sim-model"]:checked').value,
      target: Number(f.querySelector("#sim-target").value) / 100,
      cap: Number(f.querySelector("#sim-cap").value),
      every: Number(f.querySelector('input[name="sim-every"]:checked').value),
      band: Number(f.querySelector("#sim-band").value) / 100,
      cost_bp: Number(f.querySelector("#sim-cost").value)
    };
  }

  function showValues(s) {
    $("#sim-target-out").textContent = h.pct(s.target, 0);
    $("#sim-cap-out").textContent = `${s.cap.toFixed(2)}×`;
    $("#sim-band-out").textContent = h.pct(s.band, 0);
    $("#sim-cost-out").textContent = `${s.cost_bp} bp`;
  }

  // ---- KPIs ------------------------------------------------------------------------

  function kpis(s, steer, held) {
    const m = steer.metrics, k = held.metrics;
    const cell = (label, value, ref, note) =>
      `<div class="kpi"><span class="kpi-label">${label}</span><span class="kpi-value num">${value}</span>` +
      `<span class="kpi-ref">${ref}</span>${note ? `<span class="kpi-note">${note}</span>` : ""}</div>`;
    $("#sim-kpis").innerHTML =
      cell("Realised volatility", h.pct(m.ann_vol), `held: ${h.pct(k.ann_vol)}`, `target ${h.pct(s.target, 0)}`) +
      cell("Distance to target", m.risk_rmse.toFixed(3), `held: ${k.risk_rmse.toFixed(3)}`, "3-month vol vs target") +
      cell(`Days above ${h.pct(1.5 * s.target, 0)}`, `${m.breach_pct.toFixed(1)}%`, `held: ${k.breach_pct.toFixed(1)}%`) +
      cell("Worst drawdown", h.pct(m.max_dd, 0), `held: ${h.pct(k.max_dd, 0)}`) +
      cell("Annual return", h.pct(m.ann_ret), `held: ${h.pct(k.ann_ret)}`,
           `Sharpe ${m.sharpe.toFixed(2)}, held ${k.sharpe.toFixed(2)}`) +
      cell("Turnover", `${m.turnover.toFixed(2)}×`, "per year", `${s.cost_bp} bp per unit traded`);
  }

  // ---- Charts ------------------------------------------------------------------------

  function lineChart(box, dates, series, opts) {
    const width = Math.max(300, box.clientWidth);
    const height = Math.round(Math.min(300, Math.max(200, width * 0.32)));
    const m = { top: 12, right: 64, bottom: 26, left: 48 };
    const x = d3.scaleUtc().domain(d3.extent(dates)).range([m.left, width - m.right]);
    const all = series.flatMap(s => s.values).filter(v => Number.isFinite(v) && v > 0);
    if (opts.ref) all.push(opts.ref);
    const y = d3.scaleLog().domain([d3.min(all) * 0.92, d3.max(all) * 1.08]).range([height - m.bottom, m.top]);

    const svg = d3.select(box).selectAll("svg").data([null]).join("svg")
      .attr("viewBox", `0 0 ${width} ${height}`).attr("role", "img").attr("aria-label", opts.label);
    svg.selectAll("*").remove();

    const ticks = y.ticks(5).filter((t, i, arr) => arr.length <= 6 || i % 2 === 0);
    svg.append("g").attr("class", "grid").selectAll("line").data(ticks).join("line")
      .attr("x1", m.left).attr("x2", width - m.right).attr("y1", d => y(d)).attr("y2", d => y(d));
    svg.append("g").attr("class", "axis").attr("transform", `translate(${m.left - 8},0)`)
      .call(d3.axisLeft(y).tickValues(ticks).tickFormat(opts.format).tickSize(0));
    svg.append("g").attr("class", "axis").attr("transform", `translate(0,${height - m.bottom + 6})`)
      .call(d3.axisBottom(x).ticks(width < 600 ? d3.utcYear.every(3) : d3.utcYear.every(2)).tickSize(0));

    if (opts.ref) {
      svg.append("line").attr("class", "median").attr("x1", m.left).attr("x2", width - m.right)
        .attr("y1", y(opts.ref)).attr("y2", y(opts.ref)).attr("stroke", "var(--champagne)");
      svg.append("text").attr("class", "label").attr("x", m.left + 4).attr("y", y(opts.ref) - 5)
        .text(opts.refLabel);
    }
    series.forEach(s => {
      const pts = dates.map((d, i) => [d, s.values[i]]).filter(p => Number.isFinite(p[1]) && p[1] > 0);
      svg.append("path").attr("fill", "none").attr("stroke", s.color).attr("stroke-width", s.width || 1.5)
        .attr("stroke-opacity", s.opacity || 1).attr("stroke-dasharray", s.dash || null)
        .attr("d", d3.line().x(p => x(p[0])).y(p => y(p[1]))(pts));
      const last = pts[pts.length - 1];
      svg.append("text").attr("class", "label").attr("x", width - m.right + 6).attr("y", y(last[1]) + 4)
        .attr("fill", s.color).text(s.name);
    });
  }

  // ---- Main update -------------------------------------------------------------------

  function update() {
    const s = settings();
    showValues(s);
    const series = data.simulator[asset];
    const steer = Simulator.run(series, s.model, s);
    const held = Simulator.run(series, "buy_hold", s);
    kpis(s, steer, held);

    const dates = series.date.map(d => new Date(`${d}T00:00:00Z`));
    const a = data.assets.find(x => x.id === asset);
    lineChart($("#sim-risk"), dates, [
      { name: "held", values: held.rollingVol, color: h.colors[asset], opacity: 0.7, width: 1.2 },
      { name: "steered", values: steer.rollingVol, color: "var(--bone)", width: 1.6 }
    ], { format: d => h.pct(d, 0), ref: s.target, refLabel: `target`,
         label: `${a.name}: 3-month realised volatility, steered with ${MODEL_LABELS[s.model]} versus held as is.` });
    lineChart($("#sim-wealth"), dates, [
      { name: "held", values: held.metrics.wealth, color: h.colors[asset], opacity: 0.7, width: 1.2 },
      { name: "steered", values: steer.metrics.wealth, color: "var(--bone)", width: 1.6 }
    ], { format: d => `$${d.toFixed(d < 1 ? 2 : 1)}`, ref: 1, refLabel: "$1",
         label: `${a.name}: value of 1 dollar invested in January 2017, steered versus held.` });

    $("#sim-asset-name").textContent = a.name;
    const isDefault = Object.keys(DEFAULTS).every(k => s[k] === DEFAULTS[k]);
    $("#sim-default-note").hidden = !isDefault;
  }

  function reset() {
    const f = $("#sim-form");
    f.querySelector(`input[name="sim-model"][value="${DEFAULTS.model}"]`).checked = true;
    f.querySelector(`input[name="sim-every"][value="${DEFAULTS.every}"]`).checked = true;
    f.querySelector("#sim-target").value = DEFAULTS.target * 100;
    f.querySelector("#sim-cap").value = DEFAULTS.cap;
    f.querySelector("#sim-band").value = DEFAULTS.band * 100;
    f.querySelector("#sim-cost").value = DEFAULTS.cost_bp;
    update();
  }

  function check() {
    const v = Simulator.validate(data.simulator, data.simulator_checks);
    const ok = v.passed === v.total;
    $("#sim-check").innerHTML = ok
      ? `<span class="pill pill--better">checked</span> Same results as the R backtest: ${v.passed} of ${v.total} ` +
        `reference cases identical (largest relative gap ${v.worst.toExponential(0)}).`
      : `<span class="pill pill--worse">mismatch</span> ${v.total - v.passed} of ${v.total} reference cases differ ` +
        `from the R backtest. Re-run export_site.R.`;
  }

  // The simulator data is large: fetch it only when the section is near.
  function loadLater(d, helpers) {
    const section = document.getElementById("simulator");
    const obs = new IntersectionObserver(async entries => {
      if (!entries[0].isIntersecting) return;
      obs.disconnect();
      try {
        const [sim, checks] = await Promise.all(["simulator", "simulator_checks"].map(n =>
          fetch(`data/${n}.json`).then(r => { if (!r.ok) throw new Error(n); return r.json(); })));
        d.simulator = sim;
        d.simulator_checks = checks;
        window.SimUI.init(d, helpers);
      } catch (err) {
        document.getElementById("sim-check").textContent =
          "The simulator data could not be loaded. Open the site through a web server.";
      }
    }, { rootMargin: "800px 0px" });
    obs.observe(section);
  }

  window.SimUI = {
    init(d, helpers) {
      data = d; h = helpers;
      if (!window.Simulator) return;
      if (!data.simulator) { loadLater(d, helpers); return; }
      $("#sim-form").addEventListener("input", update);
      $("#sim-form").addEventListener("submit", e => e.preventDefault());
      $("#sim-reset").addEventListener("click", reset);
      document.addEventListener("material:change", e => { asset = e.detail; update(); });
      let t;
      window.addEventListener("resize", () => { clearTimeout(t); t = setTimeout(update, 150); });
      update();
      check();
    }
  };
})();
