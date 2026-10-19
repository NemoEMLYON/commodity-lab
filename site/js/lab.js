/* lab.js — the dashboard: every out-of-sample forecast against what followed,
 * forecast quality per model, risk tracking and the horizon finding.
 * Listens to the "material:change" event sent by main.js.
 * Exposes window.Lab = { init(data, helpers) }.
 */
(function () {
  "use strict";

  // Line style per model: colour AND dash pattern, never colour alone.
  const MODELS = [
    { id: "har",         label: "HAR",                  color: "var(--bone)",   dash: null },
    { id: "ewma",        label: "EWMA",                 color: "var(--ash)",    dash: "6 4" },
    { id: "lasso_b2_iv", label: "Lasso + implied vol",  color: "var(--amber)",  dash: null },
    { id: "rf_b2_iv",    label: "Forest + implied vol", color: "var(--m-gas)",  dash: "1.5 3.5" }
  ];
  const SCORE_MODELS = [
    { id: "har", label: "HAR" },
    { id: "ewma", label: "EWMA" },
    { id: "naive", label: "Naive" },
    { id: "lasso_b2_iv", label: "Lasso + implied vol" },
    { id: "rf_b2_iv", label: "Forest + implied vol" }
  ];
  const STRATEGIES = [
    { id: "oracle", label: "Oracle (knows the future)" },
    { id: "ewma", label: "EWMA" },
    { id: "naive", label: "Naive" },
    { id: "har", label: "HAR" },
    { id: "rf_b2_iv", label: "Forest + implied vol" },
    { id: "lasso_b2_iv", label: "Lasso + implied vol" }
  ];

  let data, h, asset = "gold";
  const shown = new Set(["har", "lasso_b2_iv"]);

  const $ = sel => document.querySelector(sel);


  // ---- Controls ---------------------------------------------------------------

  function controls() {
    $("#lab-assets").innerHTML = data.assets.map(a =>
      `<button type="button" class="chip" data-asset="${a.id}" aria-pressed="false">` +
      `<i style="background:${h.colors[a.id]}"></i>${a.name}</button>`).join("");
    $("#lab-assets").addEventListener("click", e => {
      const b = e.target.closest(".chip");
      if (b && window.selectMaterial) window.selectMaterial(b.dataset.asset);
    });

    $("#lab-models").innerHTML = MODELS.map(m =>
      `<button type="button" class="chip" data-model="${m.id}" aria-pressed="${shown.has(m.id)}">` +
      `<svg width="22" height="8" aria-hidden="true"><line x1="1" y1="4" x2="21" y2="4" stroke="${m.color}" ` +
      `stroke-width="2" ${m.dash ? `stroke-dasharray="${m.dash}"` : ""}/></svg>${m.label}</button>`).join("");
    $("#lab-models").addEventListener("click", e => {
      const b = e.target.closest(".chip");
      if (!b) return;
      const id = b.dataset.model;
      if (shown.has(id) && shown.size > 1) shown.delete(id); else shown.add(id);
      b.setAttribute("aria-pressed", String(shown.has(id)));
      document.querySelectorAll("#lab-models .chip").forEach(c => c.setAttribute("aria-pressed", String(shown.has(c.dataset.model))));
      chart();
    });
  }


  // ---- Forecasts vs realised --------------------------------------------------

  function chart() {
    const box = $("#lab-chart");
    const f = data.forecasts[asset];
    const a = data.assets.find(x => x.id === asset);
    const rows = f.date.map((d, i) => {
      const r = { date: new Date(`${d}T00:00:00Z`), iso: d, realized: f.realized[i] };
      MODELS.forEach(m => { r[m.id] = f[m.id][i]; });
      return r;
    }).filter(r => r.realized != null);

    const width = Math.max(320, box.clientWidth);
    const height = Math.round(Math.min(460, Math.max(280, width * 0.45)));
    const m = { top: 16, right: 16, bottom: 28, left: 44 };

    const x = d3.scaleUtc().domain(d3.extent(rows, r => r.date)).range([m.left, width - m.right]);
    const vals = rows.flatMap(r => [r.realized, ...MODELS.filter(mm => shown.has(mm.id)).map(mm => r[mm.id])]).filter(v => v > 0);
    const y = d3.scaleLog().domain([d3.min(vals) * 0.9, d3.max(vals) * 1.1]).range([height - m.bottom, m.top]);
    const ticks = [0.05, 0.1, 0.2, 0.3, 0.5, 1, 1.5, 2].filter(t => t >= y.domain()[0] && t <= y.domain()[1]);

    const svg = d3.select(box).selectAll("svg").data([null]).join("svg")
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .attr("aria-label", `${a.name}: weekly volatility forecasts of ${[...shown].join(", ")} against realised volatility, 2017 to 2026.`);
    svg.selectAll("*").remove();

    svg.append("g").attr("class", "grid").selectAll("line").data(ticks).join("line")
      .attr("x1", m.left).attr("x2", width - m.right).attr("y1", d => y(d)).attr("y2", d => y(d));
    svg.append("g").attr("class", "axis").attr("transform", `translate(${m.left - 8},0)`)
      .call(d3.axisLeft(y).tickValues(ticks).tickFormat(d => h.pct(d, 0)).tickSize(0));
    svg.append("g").attr("class", "axis").attr("transform", `translate(0,${height - m.bottom + 6})`)
      .call(d3.axisBottom(x).ticks(width < 600 ? d3.utcYear.every(2) : d3.utcYear.every(1)).tickSize(0));

    const color = h.colors[asset];
    svg.append("path").attr("fill", color).attr("fill-opacity", 0.16)
      .attr("d", d3.area().x(r => x(r.date)).y0(height - m.bottom).y1(r => y(r.realized)).curve(d3.curveStepAfter)(rows));
    svg.append("path").attr("fill", "none").attr("stroke", color).attr("stroke-opacity", 0.55).attr("stroke-width", 1)
      .attr("d", d3.line().x(r => x(r.date)).y(r => y(r.realized)).curve(d3.curveStepAfter)(rows));

    MODELS.filter(mm => shown.has(mm.id)).forEach(mm => {
      svg.append("path").attr("fill", "none").attr("stroke", mm.color).attr("stroke-width", 1.6)
        .attr("stroke-dasharray", mm.dash)
        .attr("d", d3.line().defined(r => r[mm.id] != null).x(r => x(r.date)).y(r => y(r[mm.id])).curve(d3.curveMonotoneX)(rows));
    });

    // Hover
    const tip = $("#lab-chart .lab-tip");
    const hover = svg.append("line").attr("class", "hover-line").attr("y1", m.top).attr("y2", height - m.bottom).attr("opacity", 0);
    const bisect = d3.bisector(r => r.date).center;
    svg.on("pointermove", e => {
      const [mx] = d3.pointer(e);
      const r = rows[bisect(rows, x.invert(mx))];
      if (!r) return;
      const px = x(r.date);
      hover.attr("x1", px).attr("x2", px).attr("opacity", 1);
      tip.hidden = false;
      tip.style.left = `${Math.min(85, Math.max(15, (px / width) * 100))}%`;
      tip.innerHTML = `<b>${h.longDate(r.iso)}</b><br>Realised next 21 days: ${h.pct(r.realized)}` +
        MODELS.filter(mm => shown.has(mm.id)).map(mm => `<br>${mm.label}: ${h.pct(r[mm.id])}`).join("");
    }).on("pointerleave", () => { hover.attr("opacity", 0); tip.hidden = true; });

    $("#lab-chart-title").textContent = `${a.name}: forecast and outcome`;
    const loss = id => data.results.evaluation.find(e => e.asset === asset && e.model === id);
    const best = SCORE_MODELS.map(s => loss(s.id)).filter(Boolean).sort((p, q) => p.qlike - q.qlike)[0];
    $("#lab-chart-sub").textContent =
      `${a.ticker}, ${rows.length} weekly forecasts. Lowest loss: ${SCORE_MODELS.find(s => s.id === best.model).label}.`;
  }


  // ---- Forecast quality table -----------------------------------------------------

  function score() {
    const ev = id => data.results.evaluation.find(e => e.asset === asset && e.model === id);
    const dm = id => data.results.dm.find(e => e.asset === asset && e.model === id);
    const mz = id => data.results.mz.find(e => e.asset === asset && e.model === id);
    const lo = 0.7, hi = 1.4;
    const pos = v => ((Math.min(hi, Math.max(lo, v)) - lo) / (hi - lo)) * 100;

    const rows = SCORE_MODELS.map(s => {
      const e = ev(s.id), d = dm(s.id), z = mz(s.id);
      const v = e.qlike_vs_har;
      const left = Math.min(pos(v), pos(1)), w = Math.abs(pos(v) - pos(1));
      let verdict = `<span class="pill">benchmark</span>`;
      if (d) {
        const sig = d.p_value < 0.05;
        verdict = `<span class="pill ${sig ? (v < 1 ? "pill--better" : "pill--worse") : ""}">` +
          `${sig ? (v < 1 ? "better" : "worse") : "no clear gap"}, p = ${d.p_value < 0.001 ? "<0.001" : d.p_value.toFixed(3)}</span>`;
      }
      return `<div class="sc-row" role="row">
        <span class="sc-name" role="cell">${s.label}</span>
        <span class="sc-bar" role="cell" aria-label="${v.toFixed(2)} times HAR's loss">
          <span class="sc-track"><span class="sc-one" style="left:${pos(1)}%"></span>
          <span class="sc-fill ${v < 1 ? "is-better" : ""}" style="left:${left}%;width:${w}%"></span></span>
          <span class="num">${v.toFixed(2)}</span></span>
        <span class="sc-dm" role="cell">${verdict}</span>
        <span class="num sc-mz" role="cell">${z ? z.b.toFixed(2) : "–"}</span>
      </div>`;
    }).join("");
    $("#lab-score").innerHTML =
      `<div class="sc-row sc-head" role="row"><span role="columnheader">Model</span><span role="columnheader">Loss vs HAR</span>` +
      `<span role="columnheader">Gap to HAR (Diebold-Mariano)</span><span role="columnheader">Slope</span></div>` + rows;
  }


  // ---- Risk tracking ------------------------------------------------------------

  function risk() {
    const pick = id => data.backtest.per_asset.find(r => r.asset === asset && r.strategy === id);
    const max = d3.max(STRATEGIES, s => pick(s.id).risk_rmse);
    const hold = pick("buy_hold");
    $("#lab-risk").innerHTML = STRATEGIES.map(s => {
      const r = pick(s.id);
      return `<div class="rk-row">
        <span class="rk-name">${s.label}</span>
        <span class="rk-track"><span class="rk-fill ${s.id === "oracle" ? "is-oracle" : ""}" style="width:${(r.risk_rmse / max) * 100}%"></span></span>
        <span class="num">${r.risk_rmse.toFixed(3)}</span>
        <span class="num rk-vol">${h.pct(r.ann_vol)}</span>
      </div>`;
    }).join("") +
      `<p class="rk-note">Held without steering: distance ${hold.risk_rmse.toFixed(3)}, volatility ${h.pct(hold.ann_vol)}, off this scale.</p>`;
  }


  // ---- Horizon finding (pooled) ---------------------------------------------------

  function horizon() {
    const sens = (setting, s) => data.backtest.sensitivity.find(r => r.setting === setting && r.strategy === s).risk_rmse;
    const h5 = s => data.backtest.backtest_5.find(r => r.asset === "all" && r.strategy === s).risk_rmse;
    const cases = [
      { label: "21-day forecasts, weekly trading", gap: sens("base", "har") - sens("base", "ewma") },
      { label: "5-day forecasts, weekly trading", gap: h5("har") - h5("ewma") },
      { label: "21-day forecasts, monthly trading", gap: sens("monthly", "har") - sens("monthly", "ewma") }
    ];
    const max = cases[0].gap;
    $("#lab-horizon").innerHTML = cases.map((c, i) => `
      <div class="hz-row">
        <span class="hz-name">${c.label}</span>
        <span class="rk-track"><span class="rk-fill" style="width:${(c.gap / max) * 100}%"></span></span>
        <span class="num">${c.gap.toFixed(4)}</span>
        <span class="num rk-vol">${i === 0 ? "" : `−${Math.round((1 - c.gap / max) * 100)}%`}</span>
      </div>`).join("");
  }


  function render() {
    document.querySelectorAll("#lab-assets .chip").forEach(c => c.setAttribute("aria-pressed", String(c.dataset.asset === asset)));
    document.querySelectorAll(".lab-asset-name").forEach(el => { el.textContent = data.assets.find(a => a.id === asset).name.toLowerCase(); });
    chart();
    score();
    risk();
  }

  window.Lab = {
    init(d, helpers) {
      data = d; h = helpers;
      controls();
      horizon();
      render();
      document.addEventListener("material:change", e => { asset = e.detail; render(); });
      let t;
      window.addEventListener("resize", () => { clearTimeout(t); t = setTimeout(chart, 150); });
    }
  };
})();
