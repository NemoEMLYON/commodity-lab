/* glass.js — "liquid glass" for the floating controls (not for content).
 *
 * Real glass does not only blur what is behind it: it bends it, mostly near
 * its edges, like a lens. For each element marked data-glass this script
 * draws a displacement map of the element's exact shape (rounded corners
 * included) and an SVG filter that uses it on the backdrop:
 *   - the backdrop is shifted along the edge normal, strongly at the rim and
 *     not at all in the middle (a bevelled lens);
 *   - red, green and blue are shifted by slightly different amounts
 *     (a touch of chromatic dispersion);
 *   - colours are slightly saturated, as through a real pane.
 * A specular highlight follows the pointer (CSS variables --gx, --gy).
 *
 * SVG filters in backdrop-filter work in Chromium browsers (Chrome, Edge).
 * Elsewhere the CSS fallback in main.css applies (frosted blur), unchanged.
 * Also handles the floating navigation (class is-floating after the hero).
 * Exposes window.Glass = { init(), refresh(el) }.
 */
(function () {
  "use strict";

  const SVG_NS = "http://www.w3.org/2000/svg";
  const ua = navigator.userAgent;
  const refract = /Chrome\/\d+/.test(ua) && !/Firefox/.test(ua) &&
                  window.CSS && CSS.supports("backdrop-filter", "url(#x)");
  const BEZEL = 16;          // px: width of the bending rim
  const STRENGTH = 26;       // px: how far the rim bends the backdrop
  const MAP_SCALE = 0.5;     // the map is computed at half resolution

  let defs, count = 0;

  // Displacement map of a rounded rectangle (w x h, radius r), as a PNG URL.
  // Red = horizontal shift, green = vertical, 128 = no shift.
  function displacementMap(w, h, r) {
    const W = Math.max(2, Math.round(w * MAP_SCALE)), H = Math.max(2, Math.round(h * MAP_SCALE));
    const canvas = document.createElement("canvas");
    canvas.width = W; canvas.height = H;
    const ctx = canvas.getContext("2d");
    const img = ctx.createImageData(W, H);
    const hx = w / 2, hy = h / 2, rr = Math.min(r, hx, hy);
    const bezel = Math.min(BEZEL, hx, hy);
    for (let j = 0; j < H; j++) {
      for (let i = 0; i < W; i++) {
        // Point relative to the centre, in CSS pixels
        const px = (i + 0.5) / MAP_SCALE - hx, py = (j + 0.5) / MAP_SCALE - hy;
        const qx = Math.abs(px) - (hx - rr), qy = Math.abs(py) - (hy - rr);
        // Signed distance to the rounded rectangle (negative inside)
        const ox = Math.max(qx, 0), oy = Math.max(qy, 0);
        const sd = Math.hypot(ox, oy) + Math.min(Math.max(qx, qy), 0) - rr;
        const inside = -sd;
        let dx = 0, dy = 0;
        if (inside < bezel && inside >= 0) {
          const t = 1 - inside / bezel;            // 0 inside the flat part, 1 at the rim
          const mag = t * t * (3 - 2 * t);         // smooth bevel
          let nx, ny;                              // outward normal
          if (qx > 0 && qy > 0) { const l = Math.hypot(qx, qy) || 1; nx = qx / l; ny = qy / l; }
          else if (qx > qy) { nx = 1; ny = 0; } else { nx = 0; ny = 1; }
          dx = Math.sign(px) * nx * mag;
          dy = Math.sign(py) * ny * mag;
        }
        const k = (j * W + i) * 4;
        img.data[k] = 128 + dx * 127;
        img.data[k + 1] = 128 + dy * 127;
        img.data[k + 2] = 128;
        img.data[k + 3] = 255;
      }
    }
    ctx.putImageData(img, 0, 0);
    return canvas.toDataURL();
  }

  function el(name, attrs, parent) {
    const node = document.createElementNS(SVG_NS, name);
    Object.entries(attrs).forEach(([k, v]) => node.setAttribute(k, v));
    if (parent) parent.appendChild(node);
    return node;
  }

  // One filter per element: three displaced copies (one per colour channel,
  // slightly different strengths) added back together, then saturated.
  function buildFilter(node) {
    const r = node.getBoundingClientRect();
    const w = Math.round(r.width), h = Math.round(r.height);
    if (w < 4 || h < 4) return;
    const radius = parseFloat(getComputedStyle(node).borderTopLeftRadius) || 0;
    const id = node.dataset.glassId || `glass-${++count}`;
    node.dataset.glassId = id;
    const old = defs.querySelector(`#${id}`);
    if (old) old.remove();

    const f = el("filter", { id, x: 0, y: 0, width: w, height: h, filterUnits: "userSpaceOnUse",
                             primitiveUnits: "userSpaceOnUse", "color-interpolation-filters": "sRGB" }, defs);
    el("feImage", { href: displacementMap(w, h, radius), x: 0, y: 0, width: w, height: h,
                    preserveAspectRatio: "none", result: "map" }, f);
    el("feGaussianBlur", { in: "SourceGraphic", stdDeviation: 0.8, result: "soft" }, f);
    const channels = [["R", 1.0, "1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0"],
                      ["G", 1.06, "0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0"],
                      ["B", 1.12, "0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0"]];
    channels.forEach(([c, k, matrix]) => {
      // Positive scale: rim pixels sample towards the centre (checked on a
      // striped test page; a negative scale samples outside the pane, where
      // the backdrop is empty, and leaves dark bands).
      el("feDisplacementMap", { in: "soft", in2: "map", scale: STRENGTH * k,
                                xChannelSelector: "R", yChannelSelector: "G", result: `d${c}` }, f);
      el("feColorMatrix", { in: `d${c}`, type: "matrix", values: matrix, result: `c${c}` }, f);
    });
    el("feComposite", { in: "cR", in2: "cG", operator: "arithmetic", k2: 1, k3: 1, result: "rg" }, f);
    el("feComposite", { in: "rg", in2: "cB", operator: "arithmetic", k2: 1, k3: 1, result: "rgb" }, f);
    el("feColorMatrix", { in: "rgb", type: "saturate", values: 1.45 }, f);

    node.style.backdropFilter = `url(#${id})`;
    node.style.webkitBackdropFilter = `url(#${id})`;
    node.classList.add("is-refracting");
  }

  function track(node) {
    node.addEventListener("pointermove", e => {
      const r = node.getBoundingClientRect();
      node.style.setProperty("--gx", `${e.clientX - r.left}px`);
      node.style.setProperty("--gy", `${e.clientY - r.top}px`);
    });
    if (!refract) return;
    let t;
    new ResizeObserver(() => { clearTimeout(t); t = setTimeout(() => buildFilter(node), 60); }).observe(node);
  }

  // Navigation: full width over the hero, a floating glass pill afterwards.
  function floatingNav() {
    const nav = document.querySelector(".site-nav");
    if (!nav) return;
    const wrap = nav.querySelector(".wrap");
    // Three states: at the top (full width), hidden while the hero scrolls
    // away (so links never sit on top of the headline), floating afterwards.
    const update = () => {
      const y = window.scrollY, floating = y > window.innerHeight * 0.55;
      nav.classList.toggle("is-floating", floating);
      nav.classList.toggle("is-hidden", !floating && y > 12);
      wrap.classList.toggle("glass", floating);
    };
    window.addEventListener("scroll", update, { passive: true });
    update();
  }

  window.Glass = {
    init() {
      const svg = el("svg", { width: 0, height: 0, "aria-hidden": "true", class: "glass-defs" });
      svg.style.position = "absolute";
      document.body.appendChild(svg);
      defs = el("defs", {}, svg);
      document.querySelectorAll("[data-glass]").forEach(track);
      floatingNav();
    },
    refresh(node) { if (refract && node) buildFilter(node); }
  };
})();
