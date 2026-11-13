/* hero.js — the two layers behind the headline.
 *
 *  1. Traces: the real 22-day realised volatility of the five ETFs since
 *     2011, drawn on a log scale across the whole hero (2D canvas).
 *  2. Metal: a liquid-metal object rendered by a small WebGL fragment shader
 *     (ray marching of three blended spheres, reflecting a warm "studio").
 *     The object takes the look of the selected commodity and ripples with
 *     its volatility forecast; one sphere is pulled by the cursor.
 *
 * Exposes window.Hero = { init(volHistory, colors, tickers), setMaterial(id, vol) }.
 */
(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  // With "reduce motion" on (Windows: Accessibility > Visual effects >
  // Animation effects off), the metal still moves, slowly and gently: time
  // runs at a third of its speed and the wandering is smaller. The intro and
  // the scroll effects stay off.
  const CALM = reduceMotion ? 0.35 : 1;
  const dpr = Math.min(window.devicePixelRatio || 1, 1.5);

  // ---- 1. Volatility traces ------------------------------------------------

  const traces = { canvas: null, ctx: null, series: [], progress: reduceMotion ? 1 : 0, shift: 0 };

  function drawTraces() {
    const { canvas, ctx, series } = traces;
    if (!ctx) return;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    // One log scale for all five series: 5% at the bottom band, 180% at the top.
    const lo = Math.log(0.05), hi = Math.log(1.8);
    const top = h * 0.12, bottom = h * 0.96;
    const y = v => bottom - (Math.log(Math.max(v, 0.05)) - lo) / (hi - lo) * (bottom - top);

    series.forEach((s, k) => {
      const n = s.vol.length;
      const last = Math.max(1, Math.floor(n * traces.progress));
      const x = i => (s.offset + i) / (s.total - 1) * w + traces.shift * (k + 1) * 0.6;
      ctx.beginPath();
      for (let i = 0; i < last; i++) {
        const px = x(i), py = y(s.vol[i]);
        i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
      }
      ctx.strokeStyle = s.color;
      ctx.globalAlpha = window.innerWidth < 760 ? 0.28 : 0.36;
      ctx.lineWidth = 1.1;
      ctx.stroke();

      // Ticker at the end of each line, so colour is never the only key.
      if (traces.progress > 0.98) {
        ctx.globalAlpha = 0.8;
        ctx.fillStyle = s.color;
        ctx.font = "11px 'IBM Plex Mono', monospace";
        ctx.textAlign = "right";
        ctx.fillText(s.ticker, w - 8, y(s.vol[n - 1]) - 6);
      }
    });
    ctx.globalAlpha = 1;
  }

  function initTraces(canvas, volHistory, colors, tickers) {
    traces.canvas = canvas;
    traces.ctx = canvas.getContext("2d");
    // Common time axis: the longest series sets the width; CPER starts later.
    const total = Math.max(...Object.values(volHistory).map(s => s.vol.length));
    traces.series = Object.keys(volHistory).map(id => ({
      vol: volHistory[id].vol,
      color: colors[id],
      ticker: tickers[id],
      total: total,
      offset: total - volHistory[id].vol.length
    }));
    drawTraces();
    window.addEventListener("resize", drawTraces);
  }


  // ---- 2. Liquid metal (WebGL) ------------------------------------------------
  //
  // The object becomes the selected material: each commodity has its own
  // surface (mirror gold, black oil with an iridescent film, brushed copper,
  // cold steel for gas, satin corn), and the surface ripples as much as that
  // commodity's volatility forecast for tonight.
  // One sphere is pulled by the cursor with a spring, so it lags, overshoots
  // and stretches like a liquid.
  //
  // Speed: rays that miss a bounding sphere are skipped (most of the canvas
  // is empty), normals use 4 samples instead of 6, and the resolution adapts
  // to the measured frame time.

  const VERT = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";

  const FRAG = `
    precision highp float;
    uniform vec2 u_res;
    uniform float u_time;
    uniform vec3 u_pull;      // world position of the cursor sphere
    uniform vec2 u_vel;       // its velocity (stretch)
    uniform vec3 u_tint;
    uniform float u_agit;     // 0 calm .. 1 turbulent (volatility)
    uniform float u_rough;    // 0 mirror .. 1 satin
    uniform float u_dark;     // 0 metal .. 1 black liquid (oil)
    uniform float u_irid;     // thin-film iridescence
    uniform float u_shape;    // 0 liquid only, 1 ingot, 2 barrel, 3 coil, 4 gas bottle, 5 corn cob
    uniform float u_morph;    // 0 liquid .. 1 shape
    uniform mat3 u_rot;       // orientation of the shape (turns towards the cursor)
    uniform float u_bob;      // gentle floating

    const float BOUND = 1.5;  // radius of a sphere containing the whole object

    float smin(float a, float b, float k) {
      float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
      return mix(b, a, h) - k * h * (1.0 - h);
    }

#if SHAPES
    // ---- Shapes ("the material takes the form of the commodity") ----
    // Each shape is a signed distance function: distance to its surface,
    // negative inside. Blending two of them gives a melting transition.

    float sdEllipsoid(vec3 p, vec3 r) {          // approximate, good enough here
      float k0 = length(p / r), k1 = length(p / (r * r));
      return k0 * (k0 - 1.0) / k1;
    }
    vec3 rotY(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z); }
    vec3 rotZ(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z); }

    // Corn: a cob covered with kernels in staggered rows, and three husk leaves.
    // One husk leaf: a thin curved sheet that hugs the cob at the base and
    // peels away towards its pointed tip, with fine longitudinal veins.
    //   center: angle around the cob, yTip: height of the tip,
    //   peel: how far it opens, width: half-width at the base (radians)
    float husk(vec3 p, float center, float yTip, float peel, float width) {
      float yBase = -0.82;
      float u = clamp((p.y - yBase) / (yTip - yBase), 0.0, 1.0);   // 0 base .. 1 tip
      float cobR = 0.25 * sqrt(max(1.0 - (p.y / 0.74) * (p.y / 0.74), 0.0));
      float ang = atan(p.z, p.x);
      float da = mod(ang - center + 3.14159, 6.28318) - 3.14159;
      float R = max(cobR, 0.10) + 0.018 + peel * u * u;            // hugs, then opens
      R += 0.005 * sin(da * 48.0);                                  // veins
      float shell = abs(length(p.xz) - R) - 0.013;
      float halfW = width * pow(1.0 - u, 0.8);                      // tapers to a point
      float side = (abs(da) - halfW) * R;
      float ends = max(yBase - p.y, p.y - yTip);
      return max(shell, max(side, ends));
    }
    float cornLeaves(vec3 p) {
      float d = husk(p, 0.4, 0.30, 0.55, 0.95);
      d = min(d, husk(p, 2.1, 0.52, 0.35, 0.85));
      d = min(d, husk(p, 3.6, 0.10, 0.70, 0.90));
      d = min(d, husk(p, 5.1, 0.42, 0.45, 0.80));
      // Short stalk under the cob
      float stalk = max(length(p.xz) - 0.075, abs(p.y + 0.90) - 0.12);
      return min(d, stalk);
    }
    float corn(vec3 p) {
      float body = sdEllipsoid(p, vec3(0.25, 0.74, 0.25));
      float rowH = 0.058, sector = 6.2832 / 18.0;            // 18 straight rows around
      float ang = atan(p.z, p.x);
      float k = floor(ang / sector + 0.5);
      float row = floor(p.y / rowH + 0.5);
      // Position inside the kernel's cell, from -1 to 1 on each side
      vec2 cell = vec2((ang - k * sector) / (0.5 * sector), (p.y - row * rowH) / (0.5 * rowH));
      // Rounded-square kernel: flat top, narrow grooves between kernels
      float edge = max(abs(cell.x), abs(cell.y));
      float kernel = smoothstep(1.0, 0.62, edge);
      float kernels = body - 0.030 * kernel * smoothstep(0.72, 0.45, abs(p.y));
      return min(kernels, cornLeaves(p));
    }
    float sdBox(vec3 p, vec3 b) {
      vec3 q = abs(p) - b;
      return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
    }
    float sdCapsule(vec3 p, vec3 a, vec3 b, float r) {
      vec3 pa = p - a, ba = b - a;
      float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
      return length(pa - ba * h) - r;
    }

    // Gold: a trapezoidal ingot (narrower on top), soft edges, a stamp on top.
    float ingot(vec3 p) {
      float h = 0.17;
      float t = clamp((p.y + h) / (2.0 * h), 0.0, 1.0);         // 0 bottom .. 1 top
      vec2 halfSize = mix(vec2(0.66, 0.31), vec2(0.54, 0.21), t);
      vec3 q = vec3(abs(p.x) - halfSize.x, abs(p.y) - h, abs(p.z) - halfSize.y);
      float d = (length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0)) * 0.94 - 0.025;
      float stamp = sdBox(p - vec3(0.0, h + 0.005, 0.0), vec3(0.30, 0.018, 0.10));
      return max(d, -stamp);
    }

    // Oil: a steel drum, slightly bulging, two rolling hoops, a rimmed lid
    // and a bung.
    float barrel(vec3 p) {
      float h = 0.62;
      float R = 0.40 + 0.035 * (1.0 - (p.y / h) * (p.y / h));
      float r = length(p.xz);
      float d = max(r - R, abs(p.y) - h) + 0.0;
      d = smin(d, length(vec2(r - 0.43, p.y - 0.22)) - 0.028, 0.02);   // hoops
      d = smin(d, length(vec2(r - 0.43, p.y + 0.22)) - 0.028, 0.02);
      d = smin(d, length(vec2(r - 0.40, abs(p.y) - h)) - 0.03, 0.02); // rims
      d = max(d, -max(r - 0.35, abs(p.y - h) - 0.03));                // lid recess
      float bung = max(length(p.xz - vec2(0.2, 0.08)) - 0.05, abs(p.y - h + 0.01) - 0.035);
      return min(d, bung);
    }

    // Copper: wire wound in a helix on a spool between two flanges, and a
    // loose end of wire.
    float coil(vec3 p) {
      float r = length(p.xz);
      float ang = atan(p.z, p.x);
      float pitch = 0.055;
      float phase = (p.y - ang / 6.2832 * pitch) / pitch * 6.2832;   // helical turns
      float wire = max(r - 0.43 - 0.016 * cos(phase), abs(p.y) - 0.42);
      float flanges = max(r - 0.55, abs(abs(p.y) - 0.46) - 0.035);
      float core = max(r - 0.16, abs(p.y) - 0.5);
      float d = min(min(wire, flanges), core);
      d = min(d, sdCapsule(p, vec3(0.43, 0.30, 0.04), vec3(0.62, 0.55, 0.30), 0.02));   // loose end
      return d - 0.004;
    }

    // Natural gas: a cylinder with rounded shoulders, a foot ring, a neck,
    // a valve and its protective collar.
    float bottle(vec3 p) {
      float body = sdCapsule(p, vec3(0.0, -0.36, 0.0), vec3(0.0, 0.36, 0.0), 0.35);
      float r = length(p.xz);
      float foot = max(abs(r - 0.30) - 0.03, abs(p.y + 0.72) - 0.07);
      float neck = max(r - 0.08, abs(p.y - 0.78) - 0.08);
      float valve = max(r - 0.11, abs(p.y - 0.88) - 0.04);
      float collar = max(abs(r - 0.20) - 0.018, abs(p.y - 0.86) - 0.12);
      collar = max(collar, -(abs(p.x) - 0.07));                       // two openings
      float d = min(body, foot);
      d = smin(d, neck, 0.05);
      return min(d, min(valve, collar));
    }

    float shapeSDF(vec3 p) {
      if (u_shape > 4.5) return corn(p);
      if (u_shape > 3.5) return bottle((p + vec3(0.0, 0.14, 0.0)) / 0.9) * 0.9;   // smaller, lower: keeps the valve in frame
      if (u_shape > 2.5) return coil(p);
      if (u_shape > 1.5) return barrel(p);
      if (u_shape > 0.5) return ingot(p);
      return 1e3;
    }
#endif

    float map(vec3 p) {
      float t = u_time * (0.28 + 0.35 * u_agit);
      vec3 c1 = vec3(sin(t) * 0.32, cos(t * 1.3) * 0.26, sin(t * 0.7) * 0.12);
      vec3 c3 = vec3(-cos(t * 0.8) * 0.46, sin(t * 0.9) * 0.38, -0.1 + cos(t * 0.6) * 0.12);

      // Cursor sphere, squashed along its motion: it stretches when moved fast.
      vec3 q = p - u_pull;
      float speed = length(u_vel);
      if (speed > 1e-3) {
        vec3 dir = vec3(u_vel / speed, 0.0);
        float s = min(speed * 0.18, 0.55);
        q -= dir * dot(q, dir) * s;
      }
      float d = length(p - c1) - 0.62;
      d = smin(d, length(q) - 0.30, 0.45);
      d = smin(d, length(p - c3) - 0.40, 0.50);

      // Liquid -> shape: interpolate the two distance functions.
#if SHAPES
      if (u_morph > 0.001) d = mix(d, shapeSDF(u_rot * (p - vec3(0.0, u_bob, 0.0))), u_morph);
#endif

      // Surface ripples: amplitude and frequency grow with volatility
      // (softer on a shape, so it stays readable).
      float a = (0.012 + 0.055 * u_agit) * (1.0 - 0.75 * u_morph);
      float f = 1.0 + 0.8 * u_agit;
      d += a * sin(p.x * 6.0 * f + t * 2.0) * sin(p.y * 5.0 * f - t * 1.7) * sin(p.z * 4.0 * f + t);
      return d;
    }

    // Tetrahedral normal: 4 evaluations of map() instead of 6.
    vec3 normalAt(vec3 p) {
      const vec2 k = vec2(1.0, -1.0);
      const float h = 0.0015;
      return normalize(k.xyy * map(p + k.xyy * h) + k.yyx * map(p + k.yyx * h) +
                       k.yxy * map(p + k.yxy * h) + k.xxx * map(p + k.xxx * h));
    }

    // A warm photo studio reflected by the metal. Rough materials see the
    // same lights, only wider and dimmer (a cheap blurred reflection).
    vec3 studio(vec3 r, float rough) {
      float up = r.y * 0.5 + 0.5;
      float sharp = mix(1.0, 0.18, rough);
      vec3 col = mix(vec3(0.006, 0.005, 0.004), vec3(0.07, 0.05, 0.035), smoothstep(0.1, 1.0, up));
      col += vec3(1.0, 0.95, 0.84) * smoothstep(0.90 - 0.25 * rough, 0.96, r.y) * mix(2.2, 0.9, rough);
      col += vec3(1.0, 0.88, 0.66) * pow(max(dot(r, normalize(vec3(0.85, 0.35, 0.45))), 0.0), 90.0 * sharp) * mix(4.0, 1.2, rough);
      col += vec3(1.0, 0.90, 0.75) * smoothstep(0.985 - 0.12 * rough, 0.995, dot(r, normalize(vec3(-0.35, 0.55, 0.75)))) * mix(2.5, 0.8, rough);
      col += vec3(0.75, 0.52, 0.30) * pow(max(dot(r, normalize(vec3(-0.9, 0.05, 0.35))), 0.0), 12.0) * 0.9;
      col += vec3(0.22, 0.14, 0.07) * smoothstep(0.2, -0.8, r.y) * 0.6;
      return col;
    }

    void main() {
      vec2 uv = (gl_FragCoord.xy - 0.5 * u_res) / u_res.y;
      vec3 ro = vec3(0.0, 0.0, 3.0);
      vec3 rd = normalize(vec3(uv, -1.7));

      // Skip rays that cannot reach the object.
      float b = dot(ro, rd);
      float disc = b * b - dot(ro, ro) + BOUND * BOUND;
      if (disc < 0.0) { gl_FragColor = vec4(0.0); return; }
      float t = max(-b - sqrt(disc), 0.0);
      float tFar = -b + sqrt(disc);

      // March until the surface (tolerance grows with distance) or out of
      // the bounding sphere. Detailed shapes need more, smaller steps.
      float d = 1.0, dmin = 1e3, tmin = t;
      bool hit = false;
      for (int i = 0; i < 120; i++) {
        d = map(ro + rd * t);
        if (d < dmin) { dmin = d; tmin = t; }
        if (d < 0.001 * (1.0 + t)) { hit = true; break; }
        if (t > tFar) break;
        if (i >= 64 && u_morph < 0.01) break;     // the liquid drop needs no more
        t += d * (0.9 - 0.3 * u_morph);
      }

      // Alpha: 1 on the surface. A ray that left the bounding sphere is a
      // miss: shade its closest point and fade it over a few pixels (soft
      // silhouette). A ray that ran out of steps INSIDE the sphere is creeping
      // along the surface: count it as a hit. (Before, those rays were faded
      // too, and the detailed shapes looked semi-transparent.)
      bool escaped = !hit && t > tFar;
      float alpha = escaped ? smoothstep(0.012, 0.0, dmin) : (hit ? 1.0 : smoothstep(0.05, 0.0, dmin));
      if (alpha <= 0.0) { gl_FragColor = vec4(0.0); return; }
      vec3 p = ro + rd * (hit ? t : tmin);
      vec3 n = normalAt(p);
      vec3 r = reflect(rd, n);
      float cosv = max(dot(-rd, n), 0.0);
      float fres = pow(1.0 - cosv, 3.0);

      // Corn husk leaves: greener than the kernels.
      vec3 tint = u_tint;
#if SHAPES
      if (u_shape > 4.5 && cornLeaves(u_rot * (p - vec3(0.0, u_bob, 0.0))) < 0.02)
        tint = mix(tint, vec3(0.74, 0.86, 0.44), u_morph);   // a lighter green-gold: the inside faces the dark studio
#endif
      vec3 c = studio(r, u_rough) * tint * 1.9 + fres * vec3(1.0, 0.95, 0.85) * 0.25 * tint;
      c *= mix(1.0, 0.28, u_dark);                                   // oil: black, glossy
      vec3 film = 0.5 + 0.5 * cos(6.2832 * (cosv * 1.6 + vec3(0.0, 0.33, 0.67)));
      c += film * u_irid * (0.10 + 0.55 * fres) * (0.4 + studio(r, 0.6));  // thin film
      c = c / (1.0 + c);
      c = pow(c, vec3(0.92));
      gl_FragColor = vec4(c * alpha, alpha);
    }`;

  // Look of each material (tint: RGB 0..1). Agitation comes from the data.
  const MATERIALS = {
    gold:   { tint: [0.92, 0.76, 0.42], rough: 0.04, dark: 0.0,  irid: 0.0 },
    oil:    { tint: [0.80, 0.86, 0.86], rough: 0.0,  dark: 0.78, irid: 0.85 },
    copper: { tint: [1.05, 0.58, 0.34], rough: 0.28, dark: 0.0,  irid: 0.08 },
    natgas: { tint: [1.05, 1.18, 1.38], rough: 0.06, dark: 0.0,  irid: 0.0 },   // cold steel: the warm studio needs a strong blue tint
    corn:   { tint: [0.80, 0.80, 0.48], rough: 0.58, dark: 0.0,  irid: 0.0 }
  };
  const PARAMS = ["tint0", "tint1", "tint2", "rough", "dark", "irid", "agit"];

  // Volatility -> agitation: 12% or less is calm, 60% or more is turbulent.
  const agitation = vol => Math.max(0, Math.min(1, (vol - 0.12) / (0.60 - 0.12)));

  function materialParams(id, vol) {
    const m = MATERIALS[id] || MATERIALS.gold;
    return { tint0: m.tint[0], tint1: m.tint[1], tint2: m.tint[2], rough: m.rough,
             dark: m.dark, irid: m.irid, agit: agitation(vol || 0.2) };
  }

  // Shape ids in the shader, and the tilt of each shape (radians) so it
  // sits at an interesting angle: ingot, barrel, coil, gas bottle, corn cob.
  const SHAPES = { gold: 1, oil: 2, copper: 3, natgas: 4, corn: 5 };
  const TILT = { 1: 0.18, 2: 0.30, 3: 0.40, 4: 0.28, 5: 0.42 };

  const REST = [0.19, 0.06, 0.25];      // cursor sphere at rest (world units)
  const REACH = 0.85;                   // how far it can be pulled from the centre

  const metal = {
    gl: null, canvas: null, uniforms: {},
    now: materialParams("gold", 0.2), goal: materialParams("gold", 0.2),
    pos: REST.slice(), vel: [0, 0], target: REST.slice(), lastPointer: -1e9,
    shape: 0, shapeGoal: 0, morph: 0, spin: 0, yaw: 0, pitch: 0,
    visible: true, start: performance.now(), last: performance.now(),
    scale: 0.75, slow: 0, fast: 0
  };

  function compile(gl, type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }

  // Screen position -> point on the plane z = 0.25 under the cursor, using
  // the same camera as the shader (eye at z = 3, focal length 1.7).
  function cursorToWorld(clientX, clientY) {
    const r = metal.canvas.getBoundingClientRect();
    const u = (clientX - r.left - 0.5 * r.width) / r.height;
    const v = -(clientY - r.top - 0.5 * r.height) / r.height;
    const depth = (3.0 - 0.25) / 1.7;
    let x = u * depth, y = v * depth;
    const len = Math.hypot(x, y);
    if (len > REACH) { x *= REACH / len; y *= REACH / len; }   // stays attached
    return [x, y, 0.25];
  }

  // Two versions of the same shader: without the shapes (the liquid drop,
  // most of the time) and with them. Some GPUs and ANGLE (Chrome on
  // Windows) do not skip unused code behind a uniform test, so carrying the
  // shapes all the time halved the frame rate even for the drop.
  const UNIFORMS = ["u_res", "u_time", "u_pull", "u_vel", "u_tint", "u_agit", "u_rough", "u_dark",
                    "u_irid", "u_shape", "u_morph", "u_rot", "u_bob"];

  function makeProgram(gl, withShapes) {
    const prog = gl.createProgram();
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, `#define SHAPES ${withShapes ? 1 : 0}\n` + FRAG));
    gl.bindAttribLocation(prog, 0, "p");             // same attribute slot in both programs
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    const uniforms = {};
    UNIFORMS.forEach(u => { uniforms[u] = gl.getUniformLocation(prog, u); });   // null if unused: harmless
    return { prog, uniforms };
  }

  // The shape program is compiled when first needed (or shortly after load).
  function shapesProgram() {
    if (!metal.progShapes) {
      try { metal.progShapes = makeProgram(metal.gl, true); }
      catch (err) { console.error(err); metal.progShapes = metal.progLiquid; }   // shapes off, drop still works
    }
    return metal.progShapes;
  }

  function initMetal(canvas) {
    const gl = canvas.getContext("webgl", { premultipliedAlpha: true, antialias: false });
    if (!gl) { document.documentElement.classList.add("no-webgl"); return false; }
    try {
      metal.progLiquid = makeProgram(gl, false);
      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    } catch (err) {
      document.documentElement.classList.add("no-webgl");
      return false;
    }
    setTimeout(() => { if (metal.gl) shapesProgram(); }, 3000);   // compile ahead, off the first paint
    metal.gl = gl;
    metal.canvas = canvas;

    const hero = canvas.closest(".hero") || document.body;
    hero.addEventListener("pointermove", e => {
      if (e.pointerType !== "mouse") return;          // touch: the material keeps wandering
      metal.target = cursorToWorld(e.clientX, e.clientY);
      metal.lastPointer = performance.now();
    }, { passive: true });
    hero.addEventListener("pointerleave", () => { metal.lastPointer = -1e9; });

    new IntersectionObserver(entries => { metal.visible = entries[0].isIntersecting; }).observe(canvas);
    requestAnimationFrame(frame);
    return true;
  }

  // Spring towards the cursor: stiffness K, damping C (slightly under-damped,
  // so the liquid overshoots a little). Time-based: same feel at 30 or 120 fps.
  const K = 70, C = 11;

  // Without a mouse on the hero, the cursor sphere wanders on its own: two
  // sine waves per axis with unrelated periods, so the path never repeats.
  const IDLE_AFTER = 1500;   // ms without mouse movement
  function wander(sec) {
    const a = reduceMotion ? 0.6 : 1;
    return [a * (0.42 * Math.sin(sec * 0.37) + 0.22 * Math.sin(sec * 0.93 + 1.7)),
            a * (0.30 * Math.cos(sec * 0.29) + 0.16 * Math.sin(sec * 1.17 + 0.4)),
            REST[2]];
  }

  function step(dt) {
    const now = performance.now();
    if (now - metal.lastPointer > IDLE_AFTER) metal.target = wander(CALM * (now - metal.start) / 1000);
    for (let i = 0; i < 2; i++) {
      const force = K * (metal.target[i] - metal.pos[i]) - C * metal.vel[i];
      metal.vel[i] += force * dt;
      metal.pos[i] += metal.vel[i] * dt;
    }
    const ease = 1 - Math.exp(-dt * 2.2);          // material morph, ~0.5 s
    PARAMS.forEach(k => { metal.now[k] += (metal.goal[k] - metal.now[k]) * ease; });

    // Shape: melt back to liquid, switch shape, then form the new one.
    let morphGoal;
    if (metal.shape !== metal.shapeGoal) {
      morphGoal = 0;
      if (metal.morph < 0.02) metal.shape = metal.shapeGoal;
    } else {
      morphGoal = metal.shape ? 1 : 0;
    }
    metal.morph += (morphGoal - metal.morph) * (1 - Math.exp(-dt * 4.5));   // melt + form in ~1.5 s

    // Orientation: a slow spin, plus a turn towards the cursor when it moves.
    metal.spin += dt * 0.35 * CALM;
    const active = now - metal.lastPointer < IDLE_AFTER;
    const lookYaw = active ? metal.target[0] * 0.7 : 0;
    const lookPitch = active ? -metal.target[1] * 0.45 : 0;
    const k = 1 - Math.exp(-dt * 3);
    metal.yaw += (lookYaw - metal.yaw) * k;
    metal.pitch += (lookPitch - metal.pitch) * k;
  }

  // Resolution follows the frame time. It starts at 75% of the screen's
  // pixels (the object has soft edges, the difference is hard to see), drops
  // quickly below ~40 fps and climbs back slowly above ~55 fps.
  function adapt(frameMs) {
    if (frameMs > 25) { metal.slow++; metal.fast = 0; } else if (frameMs < 18) { metal.fast++; metal.slow = 0; }
    if (metal.slow > 8 && metal.scale > 0.4) { metal.scale = Math.max(0.4, metal.scale * 0.8); metal.slow = 0; }
    if (metal.fast > 90 && metal.scale < 1) { metal.scale = Math.min(1, metal.scale + 0.1); metal.fast = 0; }
  }

  // World -> shape rotation (column-major 3x3 for WebGL): yaw around y,
  // pitch around x, and a fixed tilt so long shapes sit diagonally.
  function rotation(yaw, pitch, tilt) {
    const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
    const ct = Math.cos(tilt), st = Math.sin(tilt);
    const Ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]];
    const Rx = [[1, 0, 0], [0, cp, -sp], [0, sp, cp]];
    const Rz = [[ct, -st, 0], [st, ct, 0], [0, 0, 1]];
    const mul = (A, B) => A.map((row, i) => B[0].map((_, j) => row.reduce((s, v, n) => s + v * B[n][j], 0)));
    const M = mul(Ry, mul(Rx, Rz));
    return new Float32Array([M[0][0], M[1][0], M[2][0], M[0][1], M[1][1], M[2][1], M[0][2], M[1][2], M[2][2]]);
  }

  function frame(now) {
    const dt = Math.min((now - metal.last) / 1000, 1 / 20);
    adapt(now - metal.last);
    metal.last = now;
    const { gl, canvas } = metal;

    if (metal.visible) {
      step(dt);
      const needShapes = metal.shape !== 0 || metal.shapeGoal !== 0 || metal.morph > 0.001;
      const program = needShapes ? shapesProgram() : metal.progLiquid;
      gl.useProgram(program.prog);
      const uniforms = program.uniforms;
      const base = window.innerWidth < 760 ? 0.75 : 1;   // lighter on phones
      const scale = dpr * base * metal.scale;
      const w = Math.round(canvas.clientWidth * scale), h = Math.round(canvas.clientHeight * scale);
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      const m = metal.now;
      gl.viewport(0, 0, w, h);
      gl.uniform2f(uniforms.u_res, w, h);
      gl.uniform1f(uniforms.u_time, CALM * (now - metal.start) / 1000);
      gl.uniform3f(uniforms.u_pull, metal.pos[0], metal.pos[1], REST[2]);
      gl.uniform2f(uniforms.u_vel, metal.vel[0], metal.vel[1]);
      gl.uniform3f(uniforms.u_tint, m.tint0, m.tint1, m.tint2);
      gl.uniform1f(uniforms.u_agit, m.agit);
      gl.uniform1f(uniforms.u_rough, m.rough);
      gl.uniform1f(uniforms.u_dark, m.dark);
      gl.uniform1f(uniforms.u_irid, m.irid);
      gl.uniform1f(uniforms.u_shape, metal.shape);
      gl.uniform1f(uniforms.u_morph, metal.morph);
      gl.uniformMatrix3fv(uniforms.u_rot, false,
        rotation(metal.spin + metal.yaw, metal.pitch + (metal.shape === 1 ? 0.35 : 0), TILT[metal.shape] || 0));
      gl.uniform1f(uniforms.u_bob, 0.05 * Math.sin(CALM * (now - metal.start) / 1000 * 0.9));
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    requestAnimationFrame(frame);
  }


  // ---- Entry sequence (one orchestrated moment) -------------------------------

  function playIntro() {
    if (reduceMotion || !window.gsap) { traces.progress = 1; drawTraces(); return; }
    const tl = gsap.timeline({ defaults: { ease: "expo.out" } });
    tl.from(".hero-title .line > span", { yPercent: 105, duration: 1.4, stagger: 0.12 })
      .from(".hero-metal", { opacity: 0, scale: 0.92, duration: 1.8 }, 0.1)
      .to(traces, { progress: 1, duration: 2.8, ease: "power2.inOut", onUpdate: drawTraces }, 0.2)
      .from([".hero-lede", ".hero-answer", ".hero-actions"], { y: 24, opacity: 0, duration: 1, stagger: 0.1 }, 0.6)
      .to(".hero-title .line > span", { backgroundPosition: "0% 0", duration: 1.6, ease: "power2.inOut", stagger: 0.15 }, 1.1);
  }


  window.Hero = {
    init(volHistory, colors, tickers) {
      initTraces(document.querySelector(".hero-traces"), volHistory, colors, tickers);
      initMetal(document.querySelector(".hero-metal"));
      playIntro();
    },
    // The object takes the look of `id` and ripples as much as `vol`;
    // with `withShape`, it also takes the commodity's shape.
    setMaterial(id, vol, withShape) {
      metal.goal = materialParams(id, vol);
      metal.shapeGoal = withShape ? (SHAPES[id] || 0) : 0;
    },
    agitation
  };
})();
