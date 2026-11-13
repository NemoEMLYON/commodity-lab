/* live.js — the "Today" section: tonight's forecasts from the frozen models.
 * Reads data/live.json, written every weekday evening by live.R on GitHub
 * Actions. Exposes window.Live = { init(live, assets, helpers) }.
 */
(function () {
  "use strict";

  const MODEL_LABELS = { naive: "Naive", ewma: "EWMA", har: "HAR",
                         lasso_b2_iv: "Lasso + implied vol", rf_b2_iv: "Forest + implied vol" };
  const MODEL_ORDER = ["har", "lasso_b2_iv", "rf_b2_iv", "ewma", "naive"];
  const STALE_AFTER = 3;          // weekdays without an update before we warn
  const HORIZON = 21;

  let live, assets, h, asset = "gold";
  const $ = sel => document.querySelector(sel);
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const asDate = s => new Date(`${s}T00:00:00Z`);
  const shortDate = s => asDate(s).toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });

  // Weekdays strictly between two dates (holidays ignored: a warning, not a calendar).
  function weekdaysBetween(from, to) {
    let n = 0;
    const d = new Date(from);
    d.setUTCDate(d.getUTCDate() + 1);
    while (d < to) {
      const w = d.getUTCDay();
      if (w !== 0 && w !== 6) n++;
      d.setUTCDate(d.getUTCDate() + 1);
    }
    return n;
  }

  // Date `n` weekdays after `s` (approximate end of the forecast window).
  function addWeekdays(s, n) {
    const d = asDate(s);
    while (n > 0) {
      d.setUTCDate(d.getUTCDate() + 1);
      if (d.getUTCDay() !== 0 && d.getUTCDay() !== 6) n--;
    }
    return d;
  }

  // ---- Status: live, offline, stale -----------------------------------------------

  function status() {
    const run = live.run;
    const today = new Date();
    const todayUTC = new Date(Date.UTC(today.getFullYear(), today.getMonth(), today.getDate()));
    const behind = weekdaysBetween(asDate(run.last_close), todayUTC);
    const stale = behind >= STALE_AFTER;
    const isLive = run.mode === "live" && !stale;

    const badge = $("#live-badge");
    badge.classList.toggle("is-offline", !isLive);
    badge.lastElementChild.textContent = run.mode === "live"
      ? `Live · last close ${h.longDate(run.last_close)}`
      : `Offline snapshot · as of ${h.longDate(run.last_close)}`;

    const ran = new Date(run.run_at);
    const ranText = ran.toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit",
                                                  minute: "2-digit", timeZone: "UTC" }) + " UTC";
    let text = `Updated every weekday after the US close · last run ${ranText}.`;
    if (run.mode !== "live") text += ` Tonight's download failed, so these are the forecasts of the last successful run (${run.source}).`;
    if (stale) text += ` No update for ${behind} weekdays: the daily job may have stopped.`;
    $("#live-run").textContent = text;
    $("#live-run").classList.toggle("is-warning", stale || run.mode !== "live");
  }

  // ---- Readout cards (one per commodity) ------------------------------------------

  // Position of v on a log scale between lo and hi, in %.
  const logPos = (v, lo, hi) => Math.max(0, Math.min(100, 100 * Math.log(v / lo) / Math.log(hi / lo)));

  function readouts() {
    const box = $("#live-readouts");
    box.innerHTML = live.today.map(t => {
      const a = assets.find(x => x.id === t.id);
      const lo = Math.min(t.lo80, t.last_month_vol) * 0.8;
      const hi = Math.max(t.hi80, t.last_month_vol) * 1.2;
      const change = t.week_ago_vol ? t.forecast_vol - t.week_ago_vol : null;
      const arrow = change === null ? "" : change > 0.0005 ? "▲" : change < -0.0005 ? "▼" : "▶";
      const changeText = change === null ? "–" :
        `${arrow} ${change >= 0 ? "+" : "−"}${Math.abs(change * 100).toFixed(1)} pts`;
      const above = Math.round(t.percentile * 100);
      return `
      <button class="readout" type="button" data-asset="${t.id}" aria-pressed="false"
              style="--card-color: ${h.colors[t.id]}">
        <span class="ro-top">
          <span class="card-ticker">${a.ticker}</span>
          <span class="ro-model">${MODEL_LABELS[t.headline_model]}</span>
        </span>
        <span class="ro-name">${a.name}</span>
        <span class="ro-value num" data-value="${t.forecast_vol}">${h.pct(t.forecast_vol)}</span>
        <span class="ro-caption">expected volatility, next 21 trading days</span>
        <span class="ro-gauge" aria-label="80% range ${h.pct(t.lo80)} to ${h.pct(t.hi80)}; last 22 days ${h.pct(t.last_month_vol)}">
          <span class="ro-band" style="left:${logPos(t.lo80, lo, hi)}%;width:${logPos(t.hi80, lo, hi) - logPos(t.lo80, lo, hi)}%"></span>
          <span class="ro-now" style="left:${logPos(t.last_month_vol, lo, hi)}%" title="Last 22 days"></span>
          <span class="ro-point" style="left:${logPos(t.forecast_vol, lo, hi)}%"></span>
        </span>
        <span class="ro-range num">80% range ${h.pct(t.lo80, 0)}–${h.pct(t.hi80, 0)}</span>
        <dl class="card-stats">
          <div><dt>Last 22 days</dt><dd>${h.pct(t.last_month_vol)}</dd></div>
          <div><dt>Since last week</dt><dd>${changeText}</dd></div>
          <div><dt>Higher than</dt><dd>${above}% of months</dd></div>
          <div><dt>Hold at 10% risk</dt><dd>${t.weight_10.toFixed(2)}×</dd></div>
        </dl>
      </button>`;
    }).join("");

    box.addEventListener("click", e => {
      const card = e.target.closest(".readout");
      if (card && window.selectMaterial) window.selectMaterial(card.dataset.asset);
    });
  }

  // Count the big numbers up once, when the section first comes into view.
  function countUp() {
    if (reduceMotion || !("IntersectionObserver" in window)) return;
    const values = [...document.querySelectorAll(".ro-value")];
    values.forEach(el => { el.textContent = h.pct(0); });
    const obs = new IntersectionObserver(entries => {
      if (!entries[0].isIntersecting) return;
      obs.disconnect();
      const start = performance.now();
      const step = now => {
        const k = Math.min(1, (now - start) / 1100);
        const ease = 1 - Math.pow(1 - k, 3);
        values.forEach(el => { el.textContent = h.pct(Number(el.dataset.value) * ease); });
        if (k < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    }, { threshold: 0.1 });
    obs.observe($("#live-readouts"));
  }

  // Hero strip: the five forecasts in one line, linking to this section.
  function heroStrip() {
    const strip = document.querySelector(".live-strip");
    if (!strip) return;
    const items = strip.querySelector(".live-strip-items");
    items.innerHTML = live.today.map(t => {
      const a = assets.find(x => x.id === t.id);
      return `<button type="button" class="ls-item" data-asset="${t.id}" aria-pressed="false" ` +
             `style="--c:${h.colors[t.id]}"><i style="background:${h.colors[t.id]}"></i>${a.ticker} ` +
             `<b class="num">${h.pct(t.forecast_vol, 0)}</b><span class="ls-bar" aria-hidden="true"></span></button>`;
    }).join("");
    items.addEventListener("click", e => {
      const b = e.target.closest(".ls-item");
      if (b && window.selectMaterial) window.selectMaterial(b.dataset.asset);
    });
    strip.hidden = false;
  }

  // ---- Chart: forecast vs outcome since the models were frozen ---------------------

  function chart() {
    const s = live.history[asset];
    const a = assets.find(x => x.id === asset);
    const t = live.today.find(x => x.id === asset);
    const headline = live.run.headline[asset];
    const color = h.colors[asset];
    const rows = s.date.map((d, i) => ({ date: asDate(d), d, f: s.forecast[i], har: s.har[i], r: s.realised[i] }));
    const scored = rows.filter(r => r.r !== null);
    const pending = rows.filter(r => r.r === null);
    const end = addWeekdays(s.date[s.date.length - 1], HORIZON);

    const box = $("#live-chart");
    const width = Math.max(300, box.clientWidth);
    const height = Math.round(Math.min(380, Math.max(240, width * 0.4)));
    const m = { top: 30, right: 70, bottom: 26, left: 44 };
    const x = d3.scaleUtc().domain([rows[0].date, end]).range([m.left, width - m.right]);
    const vals = rows.flatMap(r => [r.f * s.lo_mult, r.f * s.hi_mult, r.r, r.har]).filter(v => v > 0);
    const y = d3.scaleLog().domain([d3.min(vals) * 0.92, d3.max(vals) * 1.08]).range([height - m.bottom, m.top]);
    const ticks = [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.7, 1, 1.5].filter(v => v >= y.domain()[0] && v <= y.domain()[1]);

    const svg = d3.select(box).selectAll("svg").data([null]).join("svg")
      .attr("viewBox", `0 0 ${width} ${height}`).attr("role", "img")
      .attr("aria-label", `${a.name}: daily forecasts of next month's volatility since ${shortDate(s.date[0])}, ` +
            `with their 80% range and the volatility that followed. Today: ${h.pct(t.forecast_vol)}.`);
    svg.selectAll("*").remove();

    const defs = svg.append("defs");
    const hatch = defs.append("pattern").attr("id", "pending-hatch").attr("width", 6).attr("height", 6)
      .attr("patternUnits", "userSpaceOnUse").attr("patternTransform", "rotate(45)");
    hatch.append("line").attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 6)
      .attr("stroke", "var(--bone)").attr("stroke-opacity", 0.08).attr("stroke-width", 2);

    svg.append("g").attr("class", "grid").selectAll("line").data(ticks).join("line")
      .attr("x1", m.left).attr("x2", width - m.right).attr("y1", d => y(d)).attr("y2", d => y(d));
    svg.append("g").attr("class", "axis").attr("transform", `translate(${m.left - 8},0)`)
      .call(d3.axisLeft(y).tickValues(ticks).tickFormat(d => h.pct(d, 0)).tickSize(0));
    svg.append("g").attr("class", "axis").attr("transform", `translate(0,${height - m.bottom + 6})`)
      .call(d3.axisBottom(x).ticks(width < 600 ? 4 : 8).tickFormat(d3.utcFormat("%b")).tickSize(0));

    // Pending zone: forecasts whose 21-day outcome is still unknown, and the window ahead.
    if (pending.length) {
      const x0 = x(pending[0].date);
      svg.append("rect").attr("x", x0).attr("y", m.top).attr("width", width - m.right - x0)
        .attr("height", height - m.bottom - m.top).attr("fill", "url(#pending-hatch)");
      svg.append("text").attr("class", "label").attr("x", x0 + 6).attr("y", m.top - 10)
        .text("outcome pending");
    }

    // Outcome (shaded step area + edge), forecast band, HAR, forecast line.
    svg.append("path").attr("fill", color).attr("fill-opacity", 0.12)
      .attr("d", d3.area().x(r => x(r.date)).y0(height - m.bottom).y1(r => y(r.r)).curve(d3.curveStepAfter)(scored));
    svg.append("path").attr("fill", "none").attr("stroke", color).attr("stroke-opacity", 0.45).attr("stroke-width", 1)
      .attr("d", d3.line().x(r => x(r.date)).y(r => y(r.r)).curve(d3.curveStepAfter)(scored));
    svg.append("path").attr("fill", "var(--bone)").attr("fill-opacity", 0.07)
      .attr("d", d3.area().x(r => x(r.date)).y0(r => y(r.f * s.lo_mult)).y1(r => y(r.f * s.hi_mult))(rows));
    if (headline !== "har") {
      svg.append("path").attr("fill", "none").attr("stroke", "var(--ash)").attr("stroke-width", 1.1)
        .attr("stroke-dasharray", "4 3").attr("d", d3.line().x(r => x(r.date)).y(r => y(r.har))(rows));
    }
    const line = svg.append("path").attr("fill", "none").attr("stroke", "var(--bone)").attr("stroke-width", 1.7)
      .attr("d", d3.line().x(r => x(r.date)).y(r => y(r.f))(rows));
    if (!reduceMotion) {
      const len = line.node().getTotalLength();
      line.attr("stroke-dasharray", `${len} ${len}`).attr("stroke-dashoffset", len)
        .transition().duration(1200).ease(d3.easeCubicOut).attr("stroke-dashoffset", 0)
        .on("end", () => line.attr("stroke-dasharray", null));
    }

    // Today: point, 80% whisker, and the window it covers.
    const last = rows[rows.length - 1];
    const xl = x(last.date), xe = x(end);
    svg.append("line").attr("x1", xl).attr("x2", xe).attr("y1", y(t.forecast_vol)).attr("y2", y(t.forecast_vol))
      .attr("stroke", color).attr("stroke-width", 2).attr("stroke-dasharray", "2 3");
    svg.append("rect").attr("x", xl).attr("width", xe - xl).attr("y", y(t.hi80)).attr("height", y(t.lo80) - y(t.hi80))
      .attr("fill", color).attr("fill-opacity", 0.14).attr("rx", 3);
    svg.append("circle").attr("cx", xl).attr("cy", y(t.forecast_vol)).attr("r", 5)
      .attr("fill", color).attr("stroke", "var(--char)").attr("stroke-width", 2);
    svg.append("text").attr("class", "label-strong").attr("x", xe + 6).attr("y", y(t.forecast_vol) + 4)
      .text(h.pct(t.forecast_vol));
    svg.append("text").attr("class", "label").attr("x", xe + 6).attr("y", y(t.forecast_vol) + 18)
      .text(`to ${shortDate(end.toISOString().slice(0, 10))}`);

    // Hover: the forecast made that day and what followed.
    const tip = box.querySelector(".tooltip");
    const hover = svg.append("line").attr("class", "hover-line").attr("y1", m.top).attr("y2", height - m.bottom).attr("opacity", 0);
    const bisect = d3.bisector(r => r.date).center;
    svg.on("pointermove", e => {
      const [mx] = d3.pointer(e);
      const r = rows[bisect(rows, x.invert(mx))];
      if (!r) return;
      const px = x(r.date);
      hover.attr("x1", px).attr("x2", px).attr("opacity", 1);
      tip.hidden = false;
      tip.style.left = `${Math.min(Math.max((px / width) * 100, 12), 88)}%`;
      tip.innerHTML = `${h.longDate(r.d)}<br>Forecast ${h.pct(r.f)} (${h.pct(r.f * s.lo_mult, 0)}–${h.pct(r.f * s.hi_mult, 0)})` +
        (headline !== "har" ? `<br>HAR ${h.pct(r.har)}` : "") +
        `<br>Outcome ${r.r === null ? "pending" : h.pct(r.r)}`;
    }).on("pointerleave", () => { hover.attr("opacity", 0); tip.hidden = true; });

    $("#live-chart-title").textContent = `${a.name} since ${shortDate(s.date[0])}`;
    $("#live-chart-sub").textContent = `${MODEL_LABELS[headline]}${headline !== "har" ? ", HAR dashed" : ""}. ` +
      `${scored.length} forecasts scored, ${pending.length} pending.`;
  }

  // ---- Live record table -------------------------------------------------------------

  function track() {
    const rows = MODEL_ORDER.map(id => live.track.find(r => r.asset === asset && r.model === id)).filter(Boolean);
    const lo = 0.6, hi = 1.4;
    const pos = v => 100 * (Math.min(Math.max(v, lo), hi) - lo) / (hi - lo);
    const headline = live.run.headline[asset];

    $("#live-track").innerHTML =
      `<div class="sc-row lt-row sc-head" role="row"><span role="columnheader">Model</span>` +
      `<span role="columnheader">Loss vs HAR</span><span role="columnheader">In range</span>` +
      `<span role="columnheader">Days</span></div>` +
      rows.map(r => {
        const v = r.qlike_vs_har;
        const left = Math.min(pos(v), pos(1)), w = Math.abs(pos(v) - pos(1));
        const cov = r.coverage80 === null ? "–" : `${Math.round(r.coverage80 * 100)}%`;
        return `<div class="sc-row lt-row ${r.model === headline ? "is-headline" : ""}" role="row">
          <span class="sc-name" role="cell">${MODEL_LABELS[r.model]}</span>
          <span class="sc-bar" role="cell" aria-label="${v.toFixed(2)} times HAR's loss">
            <span class="sc-track"><span class="sc-one" style="left:${pos(1)}%"></span>
            <span class="sc-fill ${v < 1 ? "is-better" : ""}" style="left:${left}%;width:${w}%"></span></span>
            <span class="num">${r.model === "har" ? "1.00" : v.toFixed(2)}</span></span>
          <span class="num" role="cell">${cov}</span>
          <span class="num" role="cell">${r.n_scored}</span>
        </div>`;
      }).join("");

    const a = assets.find(x => x.id === asset);
    const pooled = id => live.track.find(r => r.asset === "all" && r.model === id);
    const ml = ["lasso_b2_iv", "rf_b2_iv"].map(pooled).filter(Boolean);
    const best = rows.reduce((p, q) => (q.qlike_vs_har < p.qlike_vs_har ? q : p));
    $("#live-track-sub").textContent = `${a.name}, outcomes known since ${shortDate(live.run.live_from)}. ` +
      `Lowest loss so far: ${MODEL_LABELS[best.model]}` +
      (best.model === "har" ? ". " : ` (${best.qlike_vs_har.toFixed(2)}× HAR's). `) +
      `All five commodities: ` + ml.map(r => `${MODEL_LABELS[r.model]} ${r.qlike_vs_har.toFixed(2)}×`).join(", ") +
      ` HAR's loss.`;
  }

  // ---- Freshness ------------------------------------------------------------------------

  function freshness() {
    $("#live-fresh").innerHTML = live.freshness.map(f => `
      <div class="fr-row" role="row">
        <span class="fr-status fr-${f.status}" role="cell"><i aria-hidden="true"></i>${f.status}</span>
        <span class="fr-input" role="cell">${f.input}<small>${f.source} · ${f.series}</small></span>
        <span class="num" role="cell">${shortDate(f.last_obs)}</span>
        <span class="fr-rule" role="cell">${f.rule}</span>
      </div>`).join("");
  }

  // ---- Wiring --------------------------------------------------------------------------

  function update() {
    document.querySelectorAll(".readout").forEach(c =>
      c.setAttribute("aria-pressed", String(c.dataset.asset === asset)));
    chart();
    track();
  }

  window.Live = {
    init(data, assetList, helpers) {
      if (!data || !data.today) {
        $("#live-badge").lastElementChild.textContent = "Live forecast unavailable";
        $("#live-run").textContent = "data/live.json could not be loaded. Run live.R (see README).";
        return;
      }
      live = data; assets = assetList; h = helpers;
      status();
      readouts();
      countUp();
      heroStrip();
      freshness();
      update();
      document.addEventListener("material:change", e => { asset = e.detail; update(); });
      let timer;
      window.addEventListener("resize", () => { clearTimeout(timer); timer = setTimeout(chart, 150); });
    }
  };
})();
