/* weathermap.js — chapter 05 "The weather test": a 3D model of the region.
 *
 *  - The states are extruded into a dark slab (three.js), lit like a studio.
 *  - Each city is a pillar as tall as its heating demand that week (7-day
 *    mean of heating degree days); a ring marks the usual level for the date.
 *    Blue: colder than usual, amber: milder.
 *  - A timeline replays the weeks; the side panel shows the gas market the
 *    same week, and two sparklines over the whole period (click to jump).
 *  - Drag to turn the camera (no wheel zoom: the page keeps scrolling).
 *
 * three.js is loaded only when the chapter comes near (about 160 KB gzipped).
 * Without WebGL, a flat SVG map with the same controls is drawn instead.
 * Data: data/weather_map.json (R, export_site.R) and data/map_geometry.json
 * (tools/build_map_geometry.js).
 * Exposes window.WeatherMap = { init(data, helpers) }.
 */
(function () {
  "use strict";

  const THREE_URL = "https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.min.js";
  const S = 0.01;              // map units -> scene units (the map is 10 units wide)
  const SLAB = 0.1;            // thickness of the states
  const K = 0.034;             // scene units per heating degree day (55 HDD ~ 1.9 units)
  const COLD = [0.22, 0.48, 1.0], WARM = [1.0, 0.52, 0.10], NEUTRAL = [0.55, 0.52, 0.48];
  // Notable cold weeks, checked against the data (10-city anomaly vs usual):
  // Jan 2014 +14.5, Feb 2015 +19.4 (coldest week of the sample),
  // Jan 2018 +17.4, Dec 2022 +8.2 (Minneapolis +21.9).
  const PRESETS = [
    ["2014-01-10", "Jan 2014 · polar vortex"],
    ["2015-02-20", "Feb 2015 · coldest week"],
    ["2018-01-05", "Jan 2018 · bomb cyclone"],
    ["2022-12-23", "Dec 2022 · storm Elliott"],
    [null, "Latest"]
  ];
  const OPEN_ON = "2014-01-10";   // first view: a winter everyone remembers

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = sel => document.querySelector(`#weathermap ${sel}`);
  let wm, geo, h, week = 0, view = null, playing = null;

  // ---- Helpers ------------------------------------------------------------------

  const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
  function colorFor(anomaly) {
    const t = Math.min(Math.abs(anomaly) / 4, 1);      // full colour from 4 HDD off usual
    return mix(NEUTRAL, anomaly >= 0 ? COLD : WARM, t);
  }
  const rgb = c => `rgb(${c.map(v => Math.round(v * 255)).join(",")})`;
  const fmtSigned = (v, unit) => v === null || v === undefined ? "–"
    : `${v >= 0 ? "+" : "−"}${Math.abs(v).toFixed(1)}${unit}`;
  const weekLabel = s => "Week to " + new Date(`${s}T00:00:00Z`).toLocaleDateString("en-GB",
    { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
  const cityValue = (c, i) => {
    const n = c.normal[i], a = c.anomaly[i];
    return { normal: n, anomaly: a, hdd: n === null || a === null ? null : n + a };
  };

  function hasWebGL() {
    try {
      const c = document.createElement("canvas");
      return !!(c.getContext("webgl2") || c.getContext("webgl"));
    } catch (e) { return false; }
  }

  // ---- Side panel, sparklines, controls (shared by 3D and 2D) ----------------------

  function sparklines() {
    const box = $(".wm-spark");
    const n = wm.weeks.length;
    const width = Math.max(220, box.clientWidth), height = 116, m = { l: 2, r: 2, t: 14, b: 4 };
    const x = d3.scaleLinear().domain([0, n - 1]).range([m.l, width - m.r]);
    const half = (height - m.t - m.b) / 2;
    const yA = d3.scaleLinear().domain(d3.extent(wm.agg_anomaly.filter(v => v !== null))).nice()
      .range([m.t + half - 6, m.t]);
    const yV = d3.scaleLinear().domain(d3.extent(wm.ung_vol.filter(v => v !== null))).nice()
      .range([height - m.b, m.t + half + 8]);
    const svg = d3.select(box).selectAll("svg").data([null]).join("svg")
      .attr("viewBox", `0 0 ${width} ${height}`);
    svg.selectAll("*").remove();
    const line = (y, arr) => d3.line().defined(i => arr[i] !== null).x(i => x(i)).y(i => y(arr[i]))(d3.range(n));
    svg.append("text").attr("class", "wm-spark-label").attr("x", m.l).attr("y", 10).text("Heating demand vs usual");
    svg.append("line").attr("x1", m.l).attr("x2", width - m.r).attr("y1", yA(0)).attr("y2", yA(0)).attr("class", "wm-zero");
    svg.append("path").attr("d", line(yA, wm.agg_anomaly)).attr("class", "wm-line-agg");
    svg.append("text").attr("class", "wm-spark-label").attr("x", m.l).attr("y", m.t + half + 4).text("Natural gas volatility");
    svg.append("path").attr("d", line(yV, wm.ung_vol)).attr("class", "wm-line-vol");
    svg.append("line").attr("class", "wm-marker").attr("y1", m.t - 2).attr("y2", height);
    svg.append("rect").attr("width", width).attr("height", height).attr("fill", "transparent")
      .style("cursor", "pointer")
      .on("click", e => { stop(); setWeek(Math.round(x.invert(d3.pointer(e)[0]))); });
    box._x = x;
  }

  function panel(i) {
    $(".wm-week").textContent = weekLabel(wm.weeks[i]);
    $(".wm-badge-week").textContent = new Date(`${wm.weeks[i]}T00:00:00Z`).toLocaleDateString("en-GB",
      { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
    $(".wm-badge-agg").textContent = wm.agg_anomaly[i] === null ? "" :
      `${fmtSigned(wm.agg_anomaly[i], "")} HDD ${wm.agg_anomaly[i] >= 0 ? "colder" : "milder"}`;
    const agg = wm.agg_anomaly[i], gas = wm.gas_dev[i], vol = wm.ung_vol[i];
    $('[data-k="agg"]').textContent = agg === null ? "–" : `${fmtSigned(agg, "")} HDD ${agg >= 0 ? "colder" : "milder"}`;
    $('[data-k="gas"]').textContent = gas === null ? "–" : fmtSigned(gas * 100, "%");
    $('[data-k="vol"]').textContent = vol === null ? "–" : h.pct(vol);
    const box = $(".wm-spark");
    if (box._x) d3.select(box).select(".wm-marker").attr("x1", box._x(i)).attr("x2", box._x(i));
  }

  function setWeek(i) {
    week = Math.max(0, Math.min(wm.weeks.length - 1, i));
    $(".wm-range").value = week;
    panel(week);
    if (view) view.update(week);
  }

  function stop() {
    if (playing) { clearInterval(playing); playing = null; $(".wm-play").textContent = "Play"; }
  }

  function controls() {
    const range = $(".wm-range");
    range.max = wm.weeks.length - 1;
    range.addEventListener("input", () => { stop(); setWeek(Number(range.value)); });
    $(".wm-play").addEventListener("click", () => {
      if (playing) return stop();
      if (week >= wm.weeks.length - 1) setWeek(0);
      $(".wm-play").textContent = "Pause";
      playing = setInterval(() => {
        if (week >= wm.weeks.length - 1) return stop();
        setWeek(week + 1);
      }, 110);
    });
    const presets = $(".wm-presets");
    presets.innerHTML = PRESETS.map(([d, label]) => {
      const i = d ? wm.weeks.indexOf(d) : wm.weeks.length - 1;
      return i < 0 ? "" : `<button type="button" class="chip" data-i="${i}">${label}</button>`;
    }).join("");
    presets.addEventListener("click", e => {
      const b = e.target.closest("[data-i]");
      if (b) { stop(); setWeek(Number(b.dataset.i)); }
    });
  }

  // ---- 3D view ---------------------------------------------------------------------

  function build3D(THREE) {
    const stage = $(".wm-stage");
    const canvas = $(".wm-canvas");
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.05;

    const scene = new THREE.Scene();
    scene.fog = new THREE.Fog(0x130f0c, 11, 26);
    const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 100);

    // Light: warm key from the north-west (casts the pillars' shadows), cool rim.
    scene.add(new THREE.HemisphereLight(0xffe9c8, 0x140e0a, 0.75));
    const key = new THREE.DirectionalLight(0xffd9a8, 2.4);
    key.position.set(-5, 8, 4);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    Object.assign(key.shadow.camera, { left: -7, right: 7, top: 7, bottom: -7, near: 1, far: 25 });
    key.shadow.bias = -0.0008;
    scene.add(key);
    const rim = new THREE.DirectionalLight(0x86a6c8, 0.7);
    rim.position.set(4, 3, -7);
    scene.add(rim);

    // Table and grid: the "board" the region sits on.
    const table = new THREE.Mesh(new THREE.PlaneGeometry(40, 30),
      new THREE.MeshStandardMaterial({ color: 0x15100c, roughness: 1 }));
    table.rotation.x = -Math.PI / 2;
    table.receiveShadow = true;
    scene.add(table);
    const grid = new THREE.GridHelper(24, 48, 0x4a3a2b, 0x2a2018);
    grid.position.y = 0.002;
    grid.material.transparent = true;
    grid.material.opacity = 0.45;
    scene.add(grid);

    // States, extruded. Shapes are drawn in the map plane (x east, y north)
    // and turned so that north points away from the camera.
    const withCity = new Set(["New York", "Massachusetts", "Pennsylvania", "District of Columbia",
                              "Ohio", "Michigan", "Illinois", "Minnesota", "Georgia"]);
    const matHome = new THREE.MeshStandardMaterial({ color: 0x3a2e23, roughness: 0.75, metalness: 0.15 });
    const matOther = new THREE.MeshStandardMaterial({ color: 0x251d16, roughness: 0.85, metalness: 0.1 });
    const edgeMat = new THREE.LineBasicMaterial({ color: 0xd9bf8a, transparent: true, opacity: 0.3 });
    geo.states.forEach(st => {
      const shapes = st.rings.map(r => new THREE.Shape(r.map(([x, y]) => new THREE.Vector2(x * S, y * S))));
      const g = new THREE.ExtrudeGeometry(shapes, { depth: SLAB, bevelEnabled: true, bevelThickness: 0.012,
                                                    bevelSize: 0.01, bevelSegments: 1, curveSegments: 1 });
      g.rotateX(-Math.PI / 2);
      const mesh = new THREE.Mesh(g, withCity.has(st.name) ? matHome : matOther);
      mesh.receiveShadow = true;
      scene.add(mesh);
      scene.add(new THREE.LineSegments(new THREE.EdgesGeometry(g, 30), edgeMat));
    });

    // Cities: pillar (scaled in height), ring at the usual level, glow on the ground.
    const pillarGeo = new THREE.CylinderGeometry(0.07, 0.07, 1, 28);
    pillarGeo.translate(0, 0.5, 0);
    const ringGeo = new THREE.TorusGeometry(0.13, 0.012, 8, 40);
    ringGeo.rotateX(Math.PI / 2);
    const glowGeo = new THREE.CircleGeometry(0.32, 40);
    glowGeo.rotateX(-Math.PI / 2);
    const labels = $(".wm-labels");
    const pos = Object.fromEntries(geo.cities.map(c => [c.id, c]));
    const cities = wm.cities.map(c => {
      const p = pos[c.id];
      const x = p.x * S, z = -p.y * S, top = SLAB + 0.012;
      const mat = new THREE.MeshStandardMaterial({ color: 0xffffff, emissive: 0x000000, roughness: 0.45, metalness: 0.15 });
      mat.toneMapped = false;            // exact blue / amber, not washed out by the film curve
      const pillar = new THREE.Mesh(pillarGeo, mat);
      pillar.position.set(x, top, z);
      pillar.castShadow = true;
      pillar.userData.city = c.id;
      const ring = new THREE.Mesh(ringGeo, new THREE.MeshBasicMaterial({ color: 0xefe7da, transparent: true, opacity: 0.85 }));
      ring.position.set(x, top, z);
      const glow = new THREE.Mesh(glowGeo, new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true,
        opacity: 0.22, blending: THREE.AdditiveBlending, depthWrite: false }));
      glow.position.set(x, top + 0.003, z);
      scene.add(pillar, ring, glow);
      const label = document.createElement("div");
      label.className = "wm-label";
      label.innerHTML = `<b>${c.name}</b><span class="num"></span>`;
      labels.appendChild(label);
      return { data: c, pillar, ring, glow, label, height: 0.02, target: 0.02, ringY: 0, color: NEUTRAL.slice(), goal: NEUTRAL };
    });

    // Camera on a sphere around the map: drag turns it, it sways gently when idle.
    const target = new THREE.Vector3(0, 0.3, 0.2);
    const cam = { theta: 0, phi: 0.98, radius: 13.5, vTheta: 0, vPhi: 0, intro: reduceMotion ? 1 : 0 };
    let dragging = false, lastX = 0, lastY = 0, hovered = null, visible = false, started = false;

    canvas.addEventListener("pointerdown", e => {
      dragging = true; lastX = e.clientX; lastY = e.clientY;
      canvas.setPointerCapture(e.pointerId);
    });
    canvas.addEventListener("pointerup", () => { dragging = false; });
    canvas.addEventListener("pointercancel", () => { dragging = false; });
    canvas.addEventListener("pointermove", e => {
      if (dragging) {
        cam.vTheta = -(e.clientX - lastX) * 0.006;
        cam.vPhi = -(e.clientY - lastY) * 0.004;
        lastX = e.clientX; lastY = e.clientY;
        return;
      }
      pick(e);
    });
    canvas.addEventListener("pointerleave", () => { hovered = null; $(".wm-tip").hidden = true; });

    const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
    function pick(e) {
      const r = canvas.getBoundingClientRect();
      ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
      ray.setFromCamera(ndc, camera);
      const hit = ray.intersectObjects(cities.map(c => c.pillar))[0];
      hovered = hit ? cities.find(c => c.pillar === hit.object) : null;
      const tip = $(".wm-tip");
      if (!hovered) { tip.hidden = true; return; }
      const v = cityValue(hovered.data, week);
      tip.hidden = false;
      tip.style.left = `${e.clientX - r.left}px`;
      tip.style.top = `${e.clientY - r.top - 12}px`;
      tip.innerHTML = `${hovered.data.name}<br>Heating demand ${v.hdd === null ? "–" : v.hdd.toFixed(1)} HDD` +
        `<br>Usual ${v.normal === null ? "–" : v.normal.toFixed(1)} · ${fmtSigned(v.anomaly, "")} ` +
        `${v.anomaly >= 0 ? "colder" : "milder"}`;
    }

    function resize() {
      const w = stage.clientWidth, hh = stage.clientHeight;
      renderer.setSize(w, hh, false);
      camera.aspect = w / hh;
      // Keep the whole region in frame on narrow screens.
      cam.radius = w / hh < 1.1 ? 15.5 : 13.5;
      camera.updateProjectionMatrix();
    }
    new ResizeObserver(resize).observe(stage);
    resize();

    new IntersectionObserver(entries => {
      visible = entries[0].isIntersecting;
      if (visible && !started) { started = true; last = performance.now(); requestAnimationFrame(loop); }
    }, { threshold: 0.15 }).observe(stage);

    const v3 = new THREE.Vector3();
    let last = performance.now();
    function loop(now) {
      if (!visible) { started = false; return; }     // resumes when visible again
      const dt = Math.min((now - last) / 1000, 1 / 20);
      last = now;

      // Intro: from straight above to the working angle, once.
      if (cam.intro < 1) cam.intro = Math.min(1, cam.intro + dt / 2.4);
      const ease = 1 - Math.pow(1 - cam.intro, 3);
      cam.theta += cam.vTheta; cam.phi += cam.vPhi;
      cam.vTheta *= Math.exp(-dt * 6); cam.vPhi *= Math.exp(-dt * 6);
      cam.theta = Math.max(-0.9, Math.min(0.9, cam.theta));
      cam.phi = Math.max(0.45, Math.min(1.2, cam.phi));
      const sway = reduceMotion || dragging ? 0 : 0.06 * Math.sin(now / 1000 * 0.18);
      const phi = 0.06 + (cam.phi - 0.06) * ease;
      const radius = cam.radius + (1 - ease) * 6;
      const theta = cam.theta + sway;
      camera.position.set(target.x + radius * Math.sin(phi) * Math.sin(theta),
                          target.y + radius * Math.cos(phi),
                          target.z + radius * Math.sin(phi) * Math.cos(theta));
      camera.lookAt(target);

      // Pillars ease towards the week's values (time-based).
      const k = 1 - Math.exp(-dt * 7);
      cities.forEach(c => {
        c.height += (c.target - c.height) * k;
        c.color = mix(c.color, c.goal, k);
        c.pillar.scale.y = Math.max(c.height, 0.02);
        c.ring.position.y = SLAB + 0.012 + c.ringY;
        c.pillar.material.color.setRGB(...c.color);
        c.pillar.material.emissive.setRGB(...c.color.map(v => v * (c === hovered ? 0.8 : 0.45)));
        c.glow.material.color.setRGB(...c.color);

        // Label above the pillar, in screen space.
        v3.set(c.pillar.position.x, SLAB + c.height + 0.25, c.pillar.position.z).project(camera);
        c.label.style.transform = `translate(-50%, -100%) translate(${(v3.x * 0.5 + 0.5) * stage.clientWidth}px,` +
                                  `${(-v3.y * 0.5 + 0.5) * stage.clientHeight}px)`;
      });
      renderer.render(scene, camera);
      requestAnimationFrame(loop);
    }

    stage.classList.add("is-ready");
    return {
      update(i) {
        cities.forEach(c => {
          const v = cityValue(c.data, i);
          c.target = v.hdd === null ? 0.02 : Math.max(v.hdd, 0) * K;
          c.ringY = v.normal === null ? 0 : v.normal * K;
          c.ring.visible = v.normal !== null;
          c.goal = v.anomaly === null ? NEUTRAL : colorFor(v.anomaly);
          c.label.querySelector("span").textContent = v.anomaly === null ? "" : fmtSigned(v.anomaly, "");
          c.label.style.setProperty("--c", rgb(c.goal));
        });
        if (reduceMotion) cities.forEach(c => { c.height = c.target; c.color = c.goal; });
      }
    };
  }

  // ---- Flat fallback (no WebGL) ---------------------------------------------------------

  function build2D() {
    const stage = $(".wm-stage");
    $(".wm-canvas").remove();
    $(".wm-hint").textContent = "Flat map: this browser has no WebGL";
    const w = geo.width, hh = geo.height;
    const svg = d3.select(stage).insert("svg", ":first-child").attr("class", "wm-flat")
      .attr("viewBox", `${-w / 2} ${-hh / 2} ${w} ${hh}`);
    svg.selectAll("path").data(geo.states).join("path").attr("class", "wm-state")
      .attr("d", s => s.rings.map(r => "M" + r.map(([x, y]) => `${x},${-y}`).join("L") + "Z").join(""));
    const pos = Object.fromEntries(geo.cities.map(c => [c.id, c]));
    const dots = svg.selectAll("circle").data(wm.cities).join("circle")
      .attr("cx", c => pos[c.id].x).attr("cy", c => -pos[c.id].y);
    stage.classList.add("is-ready");
    return {
      update(i) {
        dots.attr("r", c => 4 + Math.sqrt(Math.max(cityValue(c, i).hdd || 0, 0)) * 3)
          .attr("fill", c => rgb(colorFor(cityValue(c, i).anomaly || 0)));
      }
    };
  }

  // ---- Loading ----------------------------------------------------------------------------

  async function start(data) {
    const get = async name => data[name] ||
      fetch(`data/${name}.json`).then(r => { if (!r.ok) throw new Error(name); return r.json(); });
    try {
      [wm, geo] = await Promise.all([get("weather_map"), get("map_geometry")]);
    } catch (err) {
      $(".wm-loading").textContent = "The weather map data could not be loaded.";
      return;
    }
    controls();
    sparklines();
    if (hasWebGL()) {
      try {
        const THREE = await import(THREE_URL);
        view = build3D(THREE);
      } catch (err) {
        console.error(err);
        view = build2D();
      }
    } else {
      view = build2D();
    }
    const first = wm.weeks.indexOf(OPEN_ON);
    setWeek(first >= 0 ? first : wm.weeks.length - 1);
    let t;
    window.addEventListener("resize", () => { clearTimeout(t); t = setTimeout(() => { sparklines(); panel(week); }, 150); });
  }

  window.WeatherMap = {
    init(data, helpers) {
      h = helpers;
      const section = document.getElementById("weathermap");
      if (!section) return;
      const obs = new IntersectionObserver(entries => {
        if (!entries[0].isIntersecting) return;
        obs.disconnect();
        start(data);
      }, { rootMargin: "600px 0px" });
      obs.observe(section);
    }
  };
})();
