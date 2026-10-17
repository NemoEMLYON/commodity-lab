/* main.js — loads the data exported by R and builds the page.
 * Data comes from site/data/*.json (written by export_site.R). The preview
 * build inlines the same files as window.SITE_DATA.
 */
(async function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  async function loadData() {
    if (window.SITE_DATA) return window.SITE_DATA;
    const names = ["meta", "assets", "vol_history", "results", "backtest"];
    const out = {};
    await Promise.all(names.map(async n => {
      const res = await fetch(`data/${n}.json`);
      if (!res.ok) throw new Error(`Could not load data/${n}.json (${res.status})`);
      out[n] = await res.json();
    }));
    return out;
  }

  // ---- Formatting -------------------------------------------------------------

  const css = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const pct = (x, d = 1) => `${(x * 100).toFixed(d)}%`;
  const signed = x => `${x >= 0 ? "+" : "−"}${Math.abs(x * 100).toFixed(1)}%`;
  const price = x => `$${x.toFixed(2)}`;
  const longDate = s => new Date(`${s}T00:00:00Z`).toLocaleDateString("en-GB",
    { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });

  const MATERIAL_TOKEN = { gold: "--m-gold", oil: "--m-oil", copper: "--m-copper", gas: "--m-gas", corn: "--m-corn" };

  let data;
  try {
    data = await loadData();
  } catch (err) {
    document.querySelector(".vol-head p").textContent =
      "The data files could not be loaded. Open the site through a local server (see README).";
    console.error(err);
    return;
  }

  const assets = data.assets;
  const colorOf = a => css(MATERIAL_TOKEN[a.material]);
  const colors = Object.fromEntries(assets.map(a => [a.id, colorOf(a)]));
  const tickers = Object.fromEntries(assets.map(a => [a.id, a.ticker]));

  if (window.Hero) window.Hero.init(data.vol_history, colors, tickers);
  if (window.gsap && window.ScrollTrigger) gsap.registerPlugin(ScrollTrigger);


  // ---- Material cards ---------------------------------------------------------

  const rail = document.querySelector(".rail");
  rail.innerHTML = assets.map(a => `
    <button class="card" type="button" data-asset="${a.id}" aria-pressed="false"
            style="--card-color: var(${MATERIAL_TOKEN[a.material]})">
      <span class="card-top">
        <span class="swatch swatch--${a.material}" aria-hidden="true"></span>
        <span class="card-ticker">${a.ticker}</span>
      </span>
      <span class="card-name">${a.name}</span>
      <dl class="card-stats">
        <div><dt>Last close</dt><dd>${price(a.last_price)}</dd></div>
        <div><dt>1-year return</dt><dd>${signed(a.return_1y)}</dd></div>
        <div><dt>Volatility now</dt><dd>${pct(a.vol_now)}</dd></div>
      </dl>
      <span class="pctile">
        <span class="pctile-bar"><span style="width:${(a.vol_pctile * 100).toFixed(0)}%"></span></span>
        <span>Above ${(a.vol_pctile * 100).toFixed(0)}% of days since ${a.first_date.slice(0, 4)}</span>
      </span>
    </button>`).join("");

  rail.addEventListener("click", e => {
    const card = e.target.closest(".card");
    if (card) select(card.dataset.asset);
  });


  // ---- Volatility chart (D3) ------------------------------------------------------

  const chartBox = document.querySelector(".chart");
  const tooltip = document.querySelector(".tooltip");
  const EVENTS = [
    { date: "2020-03-16", label: "Covid crash" },
    { date: "2022-02-24", label: "Invasion of Ukraine" }
  ];
  let current = null;

  function drawChart(asset, animate) {
    const s = data.vol_history[asset.id];
    const points = s.date.map((d, i) => ({ date: new Date(`${d}T00:00:00Z`), vol: s.vol[i] }));
    const width = Math.max(320, chartBox.clientWidth);
    const height = Math.round(Math.min(440, Math.max(260, width * 0.42)));
    const m = { top: 28, right: 92, bottom: 28, left: 44 };

    const x = d3.scaleUtc().domain(d3.extent(points, p => p.date)).range([m.left, width - m.right]);
    const ext = d3.extent(points, p => p.vol);
    const y = d3.scaleLog().domain([ext[0] * 0.9, ext[1] * 1.1]).range([height - m.bottom, m.top]);
    const ticks = [0.05, 0.1, 0.2, 0.3, 0.5, 1, 1.5].filter(t => t >= y.domain()[0] && t <= y.domain()[1]);

    const svg = d3.select(chartBox).selectAll("svg").data([null]).join("svg")
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .attr("aria-label", `${asset.name}: 22-day realised volatility from ${s.date[0]} to ${s.date[s.date.length - 1]}, ` +
            `median ${pct(asset.vol_median)}, latest ${pct(asset.vol_now)}.`);
    svg.selectAll("*").remove();

    const color = colorOf(asset);
    const grad = svg.append("defs").append("linearGradient")
      .attr("id", "vol-fill").attr("x1", 0).attr("x2", 0).attr("y1", 0).attr("y2", 1);
    grad.append("stop").attr("offset", "0%").attr("stop-color", color).attr("stop-opacity", 0.28);
    grad.append("stop").attr("offset", "100%").attr("stop-color", color).attr("stop-opacity", 0);

    svg.append("g").attr("class", "grid")
      .selectAll("line").data(ticks).join("line")
      .attr("x1", m.left).attr("x2", width - m.right)
      .attr("y1", d => y(d)).attr("y2", d => y(d));

    svg.append("g").attr("class", "axis").attr("transform", `translate(${m.left - 8},0)`)
      .call(d3.axisLeft(y).tickValues(ticks).tickFormat(d => pct(d, 0)).tickSize(0));
    svg.append("g").attr("class", "axis").attr("transform", `translate(0,${height - m.bottom + 6})`)
      .call(d3.axisBottom(x).ticks(width < 600 ? d3.utcYear.every(3) : d3.utcYear.every(2)).tickSize(0));

    // Events
    const ev = svg.append("g").selectAll("g").data(EVENTS).join("g").attr("class", "event")
      .attr("transform", d => `translate(${x(new Date(`${d.date}T00:00:00Z`))},0)`);
    ev.append("line").attr("y1", m.top - 10).attr("y2", height - m.bottom);
    ev.append("text").attr("x", 6).attr("y", m.top - 14).text(d => d.label);

    // Median
    const median = asset.vol_median;
    svg.append("line").attr("class", "median")
      .attr("x1", m.left).attr("x2", width - m.right).attr("y1", y(median)).attr("y2", y(median));
    svg.append("text").attr("class", "label").attr("x", width - m.right + 8).attr("y", y(median) + 4)
      .text(`median ${pct(median)}`);

    // Series
    const area = d3.area().x(p => x(p.date)).y0(height - m.bottom).y1(p => y(p.vol)).curve(d3.curveMonotoneX);
    const line = d3.line().x(p => x(p.date)).y(p => y(p.vol)).curve(d3.curveMonotoneX);
    svg.append("path").attr("class", "series-area").attr("d", area(points));
    const path = svg.append("path").attr("class", "series-line").attr("d", line(points)).attr("stroke", color);

    if (animate && !reduceMotion) {
      const len = path.node().getTotalLength();
      path.attr("stroke-dasharray", `${len} ${len}`).attr("stroke-dashoffset", len)
        .transition().duration(1400).ease(d3.easeCubicOut).attr("stroke-dashoffset", 0)
        .on("end", () => path.attr("stroke-dasharray", null));
    }

    // Endpoint
    const last = points[points.length - 1];
    svg.append("circle").attr("class", "end-dot").attr("r", 4.5).attr("cx", x(last.date)).attr("cy", y(last.vol));
    svg.append("text").attr("class", "label-strong").attr("x", x(last.date) + 10).attr("y", y(last.vol) - 4)
      .text(pct(last.vol));
    svg.append("text").attr("class", "label").attr("x", x(last.date) + 10).attr("y", y(last.vol) + 12)
      .text(longDate(s.date[s.date.length - 1]).replace(/ \d{4}$/, ""));

    // Hover: nearest week
    const hover = svg.append("line").attr("class", "hover-line").attr("y1", m.top).attr("y2", height - m.bottom).attr("opacity", 0);
    const bisect = d3.bisector(p => p.date).center;
    svg.on("pointermove", e => {
      const [mx] = d3.pointer(e);
      const p = points[bisect(points, x.invert(mx))];
      if (!p) return;
      const px = x(p.date);
      hover.attr("x1", px).attr("x2", px).attr("opacity", 1);
      tooltip.hidden = false;
      tooltip.style.left = `${(px / width) * 100}%`;
      tooltip.textContent = `${longDate(p.date.toISOString().slice(0, 10))}  ${pct(p.vol)}`;
    }).on("pointerleave", () => { hover.attr("opacity", 0); tooltip.hidden = true; });
  }

  function select(id) {
    const asset = assets.find(a => a.id === id);
    if (!asset || current === id) return;
    current = id;
    document.querySelectorAll(".card").forEach(c => c.setAttribute("aria-pressed", String(c.dataset.asset === id)));
    document.documentElement.style.setProperty("--material", `var(${MATERIAL_TOKEN[asset.material]})`);
    if (window.Hero) window.Hero.setTint(colorOf(asset));

    document.querySelector(".vol-head h3").textContent = `${asset.name} volatility`;
    document.querySelector(".vol-head p").textContent =
      `${asset.ticker}, ${asset.first_date.slice(0, 4)}–${asset.last_date.slice(0, 4)}. ` +
      `Now ${pct(asset.vol_now)}, median ${pct(asset.vol_median)}.`;
    drawChart(asset, true);
  }

  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => current && drawChart(assets.find(a => a.id === current), false), 150);
  });

  document.querySelector(".data-date").textContent = longDate(data.meta.sample_end);
  select("gold");
  if (window.Story) window.Story.init(data, { pct, colors });
})();
