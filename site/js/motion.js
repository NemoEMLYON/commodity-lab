/* motion.js — scroll choreography (GSAP ScrollTrigger + SplitText).
 *
 *  - Hero exit: the headline lifts and the metal object sinks and shrinks
 *    as the page scrolls, so the hero has depth instead of sliding away flat.
 *  - Headings: each line rises from behind a mask when its section arrives.
 *  - Panels and cards: rise and fade in, staggered, once.
 *  - A thin progress line under the navigation.
 *
 * Everything is skipped under prefers-reduced-motion or if GSAP is missing:
 * content is never hidden by default in CSS, so the page reads without JS.
 */
(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function heroExit() {
    const tl = gsap.timeline({
      scrollTrigger: { trigger: ".hero", start: "top top", end: "bottom top", scrub: 0.6 }
    });
    tl.to(".hero-inner", { yPercent: -18, opacity: 0.15, ease: "none" }, 0)
      .to(".hero-metal", { yPercent: 22, scale: 0.82, opacity: 0.35, ease: "none" }, 0)
      .to(".hero-traces", { opacity: 0.2, ease: "none" }, 0);
  }

  function headings() {
    const selector = ".section-head h2, .chapter-text h2, .method-intro h2";
    document.querySelectorAll(selector).forEach(h => {
      const split = SplitText.create(h, { type: "lines", mask: "lines" });
      gsap.from(split.lines, {
        yPercent: 110, duration: 1.1, ease: "expo.out", stagger: 0.08,
        scrollTrigger: { trigger: h, start: "top 88%", once: true }
      });
    });
  }

  function blocks() {
    const groups = [".readouts", ".rail", ".today-grid", ".lab-grid", ".kpis", ".method-items"];
    groups.forEach(sel => {
      document.querySelectorAll(sel).forEach(g => {
        gsap.from(g.children, {
          y: 36, opacity: 0, duration: 0.9, ease: "power3.out", stagger: 0.07,
          scrollTrigger: { trigger: g, start: "top 85%", once: true }
        });
      });
    });
    document.querySelectorAll(".panel").forEach(p => {
      if (p.closest(".today-grid, .lab-grid")) return;   // already animated with their group
      gsap.from(p, {
        y: 40, opacity: 0, duration: 1, ease: "power3.out",
        scrollTrigger: { trigger: p, start: "top 88%", once: true }
      });
    });
  }

  function progressLine() {
    const bar = document.createElement("div");
    bar.className = "scroll-progress";
    document.querySelector(".site-nav .wrap").appendChild(bar);
    gsap.to(bar, { scaleX: 1, ease: "none",
                   scrollTrigger: { trigger: document.body, start: "top top", end: "bottom bottom", scrub: 0.3 } });
  }

  window.Motion = {
    init() {
      if (reduceMotion || !window.gsap || !window.ScrollTrigger || !window.SplitText) return;
      gsap.registerPlugin(ScrollTrigger, SplitText);
      heroExit();
      progressLine();
      blocks();
      // Split headings only once the display font is in, so lines break right.
      (document.fonts ? document.fonts.ready : Promise.resolve()).then(() => {
        headings();
        ScrollTrigger.refresh();
      });
    }
  };
})();
