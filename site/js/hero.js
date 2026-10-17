/* hero.js — the two layers behind the headline.
 *
 *  1. Traces: the real 22-day realised volatility of the five ETFs since
 *     2011, drawn on a log scale across the whole hero (2D canvas).
 *  2. Metal: a liquid-metal object rendered by a small WebGL fragment shader
 *     (ray marching of three blended spheres, reflecting a warm "studio").
 *     One sphere follows the cursor within a small range. Its tint follows
 *     the selected commodity.
 *
 * Exposes window.Hero = { init(volHistory, colors), setTint(hex) }.
 */
(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
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

  const VERT = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";

  const FRAG = `
    precision highp float;
    uniform vec2 u_res;
    uniform float u_time;
    uniform vec2 u_mouse;
    uniform vec3 u_tint;

    float smin(float a, float b, float k) {
      float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
      return mix(b, a, h) - k * h * (1.0 - h);
    }

    float map(vec3 p) {
      float t = u_time * 0.32;
      vec3 c1 = vec3(sin(t) * 0.28, cos(t * 1.3) * 0.22, 0.0);
      vec3 c2 = vec3(u_mouse * 0.55, 0.25);
      vec3 c3 = vec3(-cos(t * 0.8) * 0.42, sin(t * 0.9) * 0.34, -0.1);
      float d = length(p - c1) - 0.62;
      d = smin(d, length(p - c2) - 0.30, 0.45);
      d = smin(d, length(p - c3) - 0.40, 0.50);
      d += 0.025 * sin(p.x * 6.0 + t * 2.0) * sin(p.y * 5.0 - t * 1.7) * sin(p.z * 4.0 + t);
      return d;
    }

    vec3 normalAt(vec3 p) {
      vec2 e = vec2(0.0015, 0.0);
      return normalize(vec3(map(p + e.xyy) - map(p - e.xyy),
                            map(p + e.yxy) - map(p - e.yxy),
                            map(p + e.yyx) - map(p - e.yyx)));
    }

    // A warm photo studio reflected by the metal: dark room, soft boxes.
    vec3 studio(vec3 r) {
      float up = r.y * 0.5 + 0.5;
      vec3 col = mix(vec3(0.006, 0.005, 0.004), vec3(0.07, 0.05, 0.035), smoothstep(0.1, 1.0, up));
      col += vec3(1.0, 0.95, 0.84) * smoothstep(0.90, 0.96, r.y) * 2.2;                 // overhead soft box
      col += vec3(1.0, 0.88, 0.66) * pow(max(dot(r, normalize(vec3(0.85, 0.35, 0.45))), 0.0), 90.0) * 4.0;  // key light
      col += vec3(1.0, 0.90, 0.75) * smoothstep(0.985, 0.995, dot(r, normalize(vec3(-0.35, 0.55, 0.75)))) * 2.5; // window strip
      col += vec3(0.75, 0.52, 0.30) * pow(max(dot(r, normalize(vec3(-0.9, 0.05, 0.35))), 0.0), 12.0) * 0.9; // warm rim
      col += vec3(0.22, 0.14, 0.07) * smoothstep(0.2, -0.8, r.y) * 0.6;                   // floor bounce
      return col;
    }

    void main() {
      vec2 uv = (gl_FragCoord.xy - 0.5 * u_res) / u_res.y;
      vec3 ro = vec3(0.0, 0.0, 3.0);
      vec3 rd = normalize(vec3(uv, -1.7));

      float t = 0.0, d = 1.0, dmin = 1e3, tmin = 0.0;
      for (int i = 0; i < 80; i++) {
        d = map(ro + rd * t);
        if (d < dmin) { dmin = d; tmin = t; }
        if (d < 0.001 || t > 6.0) break;
        t += d * 0.9;
      }

      // Soft edge: shade the closest point, fade it out over a few pixels.
      float alpha = d < 0.001 ? 1.0 : smoothstep(0.012, 0.0, dmin);
      if (alpha <= 0.0) { gl_FragColor = vec4(0.0); return; }
      vec3 p = ro + rd * (d < 0.001 ? t : tmin);
      vec3 n = normalAt(p);
      vec3 r = reflect(rd, n);
      float fres = pow(1.0 - max(dot(-rd, n), 0.0), 3.0);
      vec3 c = studio(r) * u_tint * 1.9 + fres * vec3(1.0, 0.95, 0.85) * 0.25 * u_tint;
      c = c / (1.0 + c);
      c = pow(c, vec3(0.92));
      gl_FragColor = vec4(c * alpha, alpha);
    }`;

  const metal = { gl: null, canvas: null, uniforms: {}, tint: [0.89, 0.74, 0.41],
                  target: [0.89, 0.74, 0.41], mouse: [0.35, 0.1], goal: [0.35, 0.1],
                  visible: true, start: performance.now() };

  function compile(gl, type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }

  function initMetal(canvas) {
    const gl = canvas.getContext("webgl", { premultipliedAlpha: true, antialias: false });
    if (!gl) { document.documentElement.classList.add("no-webgl"); return false; }
    try {
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(prog);
      gl.useProgram(prog);
      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(prog, "p");
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
      ["u_res", "u_time", "u_mouse", "u_tint"].forEach(u => { metal.uniforms[u] = gl.getUniformLocation(prog, u); });
    } catch (err) {
      document.documentElement.classList.add("no-webgl");
      return false;
    }
    metal.gl = gl;
    metal.canvas = canvas;

    // Cursor: restrained range, eased.
    window.addEventListener("pointermove", e => {
      const r = canvas.getBoundingClientRect();
      metal.goal = [
        Math.max(-1, Math.min(1, ((e.clientX - r.left) / r.width) * 2 - 1)),
        Math.max(-1, Math.min(1, -(((e.clientY - r.top) / r.height) * 2 - 1)))
      ];
    }, { passive: true });

    // Only render while the hero is on screen.
    new IntersectionObserver(entries => { metal.visible = entries[0].isIntersecting; }).observe(canvas);
    requestAnimationFrame(frame);
    return true;
  }

  function frame(now) {
    const { gl, canvas, uniforms } = metal;
    const scale = window.innerWidth < 760 ? 0.8 * dpr : dpr;   // lighter on phones
    const w = Math.round(canvas.clientWidth * scale), h = Math.round(canvas.clientHeight * scale);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }

    if (metal.visible || reduceMotion) {
      for (let i = 0; i < 2; i++) metal.mouse[i] += (metal.goal[i] - metal.mouse[i]) * 0.05;
      for (let i = 0; i < 3; i++) metal.tint[i] += (metal.target[i] - metal.tint[i]) * 0.06;
      gl.viewport(0, 0, w, h);
      gl.uniform2f(uniforms.u_res, w, h);
      gl.uniform1f(uniforms.u_time, reduceMotion ? 4.0 : (now - metal.start) / 1000);
      gl.uniform2f(uniforms.u_mouse, metal.mouse[0], metal.mouse[1]);
      gl.uniform3f(uniforms.u_tint, metal.tint[0], metal.tint[1], metal.tint[2]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    if (!reduceMotion) requestAnimationFrame(frame);
    else setTimeout(() => requestAnimationFrame(frame), 250);   // still follow tint changes
  }

  function hexToRgb(hex) {
    const v = parseInt(hex.replace("#", ""), 16);
    return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
  }


  // ---- Entry sequence (one orchestrated moment) -------------------------------

  function playIntro() {
    if (reduceMotion || !window.gsap) { traces.progress = 1; drawTraces(); return; }
    const tl = gsap.timeline({ defaults: { ease: "expo.out" } });
    tl.from(".hero-title .line > span", { yPercent: 105, duration: 1.4, stagger: 0.12 })
      .from(".hero-metal", { opacity: 0, scale: 0.92, duration: 1.8 }, 0.1)
      .to(traces, { progress: 1, duration: 2.8, ease: "power2.inOut", onUpdate: drawTraces }, 0.2)
      .from([".hero-lede", ".hero-answer", ".hero .cta"], { y: 24, opacity: 0, duration: 1, stagger: 0.1 }, 0.6)
      .to(".hero-title .line > span", { backgroundPosition: "0% 0", duration: 1.6, ease: "power2.inOut", stagger: 0.15 }, 1.1);
  }


  window.Hero = {
    init(volHistory, colors, tickers) {
      initTraces(document.querySelector(".hero-traces"), volHistory, colors, tickers);
      initMetal(document.querySelector(".hero-metal"));
      playIntro();
    },
    setTint(hex) { metal.target = hexToRgb(hex); }
  };
})();
