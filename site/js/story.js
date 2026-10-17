/* story.js — the four chapters: risk bars, availability timeline, 2x2 grid,
 * block heatmap. Every number comes from the JSON exported by R.
 * Exposes window.Story = { init(data, helpers) }.
 */
(function () {
  "use strict";

  // ---- 01 Risk bars: buy & hold vs steered (HAR), per asset -------------------

  function riskBars(el, data, h) {
    const rows = data.assets.map(a => {
      const pick = s => data.backtest.per_asset.find(r => r.asset === a.id && r.strategy === s);
      return { asset: a, hold: pick("buy_hold").ann_vol, steered: pick("har").ann_vol };
    });
    const target = data.meta.target_vol;

    const width = Math.max(320, el.clientWidth);
    const rowH = 54;
    const m = { top: 56, right: 64, bottom: 8, left: 112 };
    const height = m.top + rows.length * rowH + m.bottom;
    const x = d3.scaleLinear().domain([0, d3.max(rows, r => r.hold) * 1.05]).range([m.left, width - m.right]);

    const svg = d3.select(el).selectAll("svg").data([null]).join("svg")
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .attr("aria-label", "Realised volatility per commodity: held as is versus steered to 10%. " +
        rows.map(r => `${r.asset.name} ${h.pct(r.hold)} held, ${h.pct(r.steered)} steered`).join("; "));
    svg.selectAll("*").remove();

    // Legend
    const legend = svg.append("g").attr("class", "legend").attr("transform", "translate(0,14)");
    legend.append("rect").attr("width", 14).attr("height", 6).attr("y", -6).attr("fill", "var(--smoke)");
    legend.append("text").attr("x", 20).attr("y", 0).text("Held as is");
    legend.append("rect").attr("x", 96).attr("width", 14).attr("height", 6).attr("y", -6).attr("fill", "var(--champagne)");
    legend.append("text").attr("x", 116).attr("y", 0).text("Steered with forecasts");

    const g = svg.append("g").selectAll("g").data(rows).join("g")
      .attr("transform", (d, i) => `translate(0,${m.top + i * rowH})`);

    g.append("text").attr("class", "asset-label").attr("x", 0).attr("y", 22).text(d => d.asset.name);

    g.append("rect").attr("x", m.left).attr("y", 6).attr("height", 14).attr("rx", 3)
      .attr("fill", d => h.colors[d.asset.id]).attr("fill-opacity", 0.35)
      .attr("width", d => x(d.hold) - m.left);
    g.append("text").attr("class", "value").attr("x", d => x(d.hold) + 6).attr("y", 18).text(d => h.pct(d.hold));

    g.append("rect").attr("x", m.left).attr("y", 24).attr("height", 14).attr("rx", 3)
      .attr("fill", "var(--champagne)")
      .attr("width", d => x(d.steered) - m.left);
    g.append("text").attr("class", "value").attr("x", d => x(d.steered) + 6).attr("y", 36).text(d => h.pct(d.steered));

    // Target line
    const t = svg.append("g").attr("class", "target");
    t.append("line").attr("x1", x(target)).attr("x2", x(target)).attr("y1", m.top - 6).attr("y2", height - m.bottom);
    t.append("text").attr("x", x(target) + 4).attr("y", m.top - 10).text(`target ${h.pct(target, 0)}`);

  }


  // ---- 02 Availability timeline -------------------------------------------------
  // Same dates as the EIA / GPR tests in tests/test_features.R.

  const DAYS = ["2015-01-09", "2015-01-10", "2015-01-11", "2015-01-12",
                "2015-01-13", "2015-01-14", "2015-01-15", "2015-01-16"];
  const SOURCES = [
    { name: "ETF closing prices", note: "GLD, USO, CPER, UNG, CORN, UUP", measured: 0, published: null, usable: 0 },
    { name: "Implied volatility", note: "VIX, OVX, GVZ via FRED", measured: 0, published: null, usable: 3 },
    { name: "Weather", note: "Open-Meteo, 10 US cities", measured: 0, published: null, usable: 3 },
    { name: "Geopolitical risk", note: "Updated every Monday", measured: 0, published: 3, usable: 5 },
    { name: "Crude oil stocks", note: "EIA, week to Friday", measured: 0, published: 5, usable: 6 },
    { name: "Gas storage", note: "EIA, week to Friday", measured: 0, published: 6, usable: 7 }
  ];

  function timeline(el) {
    const day = s => new Date(`${s}T00:00:00Z`);
    const label = s => day(s).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", timeZone: "UTC" });
    const weekend = s => [0, 6].includes(day(s).getUTCDay());

    let html = `<div class="tl-head" role="columnheader"></div>` +
      DAYS.map(d => `<div class="tl-head${weekend(d) ? " is-weekend" : ""}" role="columnheader">${label(d)}</div>`).join("");

    SOURCES.forEach(s => {
      html += `<div class="tl-label" role="rowheader">${s.name}<small>${s.note}</small></div>`;
      DAYS.forEach((d, i) => {
        let mark = "";
        if (i === s.usable) mark = `<span class="tl-mark tl-mark--usable">usable</span>`;
        else if (i === s.published) mark = `<span class="tl-mark tl-mark--published">published</span>`;
        else if (i === s.measured) mark = `<span class="tl-mark tl-mark--measured">measured</span>`;
        const waiting = i > s.measured && i < s.usable;
        html += `<div class="tl-cell${weekend(d) ? " is-weekend" : ""}${waiting ? " is-wait" : ""}" role="cell">${mark}</div>`;
      });
    });
    el.innerHTML = html;
  }


  // ---- 03 The 2x2 design ----------------------------------------------------------

  function grid2x2(el, data, h) {
    const t = data.results.design_2x2;
    const cell = v => `<div class="g-cell" role="cell"><span class="num">${v.toFixed(2)}</span>` +
      `<span>${Math.round((v - 1) * 100)}% ${v > 1 ? "higher" : "lower"} loss than HAR</span></div>`;
    el.innerHTML =
      `<span></span><span class="g-head">Own returns only</span><span class="g-head">With external data</span>` +
      t.map(r => `<span class="g-row">${r.model === "random forest" ? "Random forest" : "Lasso"}</span>` +
        cell(r.own_returns_only) + cell(r.with_external_data)).join("");
  }


  // ---- 04 Block heatmap -------------------------------------------------------------

  const BLOCKS = [
    { key: "B1_own_returns",  label: "Own returns",       suffix: "_base" },
    { key: "B2_implied_vol",  label: "+ implied vol",     suffix: "_b2_iv" },
    { key: "B3_gpr",          label: "+ geopolitics",     suffix: "_b3_gpr" },
    { key: "B4_fundamentals", label: "+ stocks, weather", suffix: "_b4_fund" }
  ];

  function heatmap(el, data, h, family) {
    const table = data.results[`blocks_${family}`];
    const order = data.assets.map(a => a.id).concat("all");
    const dm = data.results.dm;
    const sig = (asset, model) => dm.find(r => r.asset === asset && r.model === model);

    // Below 1: champagne, stronger as the gain grows; above 1: dark, fading.
    const fill = v => v < 1
      ? `color-mix(in srgb, var(--champagne) ${Math.min(85, 25 + (1 - v) * 300)}%, var(--char))`
      : `color-mix(in srgb, var(--smoke) ${Math.min(100, 40 + (v - 1) * 300)}%, var(--char))`;
    const ink = v => (v < 0.9 ? "var(--obsidian)" : "var(--bone)");

    let html = `<div class="hm-head" role="columnheader"></div>` +
      BLOCKS.map(b => `<div class="hm-head" role="columnheader">${b.label}</div>`).join("");
    order.forEach(id => {
      const row = table.find(r => r.asset === id);
      const asset = data.assets.find(a => a.id === id);
      const name = asset ? asset.name : "All five";
      const dot = asset ? `<i style="--dot:${h.colors[id]}"></i>` : "";
      html += `<div class="hm-label${asset ? "" : " is-all"}" role="rowheader">${dot}${name}</div>`;
      BLOCKS.forEach(b => {
        const v = row[b.key];
        const test = sig(id, family + b.suffix);
        let mark = "";
        if (test && test.p_value < 0.05) mark = v < 1 ? `<span class="sig" title="significantly better">▲</span>`
                                                       : `<span class="sig" title="significantly worse">▼</span>`;
        const p = test ? `, Diebold-Mariano p = ${test.p_value.toFixed(3)}` : "";
        html += `<div class="hm-cell" role="cell" style="background:${fill(v)};color:${ink(v)}" ` +
          `aria-label="${name}, ${b.label}: ${v.toFixed(2)} times HAR's loss${p}">${v.toFixed(2)}${mark}</div>`;
      });
    });
    el.innerHTML = html;
  }


  window.Story = {
    init(data, helpers) {
      const bars = document.getElementById("risk-bars");
      riskBars(bars, data, helpers);
      timeline(document.getElementById("timeline"));
      grid2x2(document.getElementById("grid-2x2"), data, helpers);

      const hm = document.getElementById("heatmap");
      heatmap(hm, data, helpers, "lasso");
      document.querySelectorAll(".toggle-btn").forEach(btn => btn.addEventListener("click", () => {
        document.querySelectorAll(".toggle-btn").forEach(b => b.setAttribute("aria-pressed", String(b === btn)));
        heatmap(hm, data, helpers, btn.dataset.family);
      }));

      let t;
      window.addEventListener("resize", () => { clearTimeout(t); t = setTimeout(() => riskBars(bars, data, helpers), 150); });
    }
  };
})();
