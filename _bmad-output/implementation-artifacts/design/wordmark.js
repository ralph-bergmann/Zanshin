/* Monoline-Wortmarke im Stil des SKEBULA-Logos: ultradünne geometrische Sans,
   konstante Strichstärke, weite Sperrung, spitzes A ohne Querbalken.
   Glyphen sind Strichpfade in einer 100-Einheiten-Versalhöhe. */
window.ZanshinWordmark = (function () {
  const G = {
    Z: { w: 62, d: "M 0 0 L 62 0 L 0 100 L 62 100" },
    A: { w: 64, d: "M 0 100 L 32 0 L 64 100" },
    N: { w: 62, d: "M 0 100 L 0 0 L 62 100 L 62 0" },
    S: { w: 58, d: "M 55 19 A 27 22 0 1 0 29 50 A 27 22 0 1 1 3 81" },
    H: { w: 62, d: "M 0 0 L 0 100 M 62 0 L 62 100 M 0 50 L 62 50" },
    I: { w: 0, d: "M 0 0 L 0 100" },
    E: { w: 54, d: "M 0 0 L 54 0 M 0 50 L 54 50 M 0 100 L 54 100" },
    U: { w: 62, d: "M 0 0 L 0 66 A 31 34 0 0 0 62 66 L 62 0" },
    B: { w: 58, d: "M 0 0 L 30 0 A 25 25 0 0 1 30 50 L 0 50 M 0 50 L 32 50 A 25 25 0 0 1 32 100 L 0 100 M 0 0 L 0 100" },
    K: { w: 60, d: "M 0 0 L 0 100 M 58 0 L 4 54 M 20 40 L 60 100" },
    L: { w: 52, d: "M 0 0 L 0 100 L 52 100" }
  };
  /* Arc-Parameter dürfen nicht verschoben werden -> eigener, sicherer Shift */
  function shift(d, dx) {
    let i = 0; const toks = d.match(/[A-Za-z]|-?\d*\.?\d+/g) || []; let cmd = "", out = [], n = 0;
    for (const t of toks) {
      if (/[A-Za-z]/.test(t)) { cmd = t; n = 0; out.push(t); continue; }
      const v = parseFloat(t);
      if (cmd === "A") { out.push(n % 7 === 5 ? (v + dx).toFixed(2) : t); }
      else { out.push(n % 2 === 0 ? (v + dx).toFixed(2) : t); }
      n++; i++;
    }
    return out.join(" ");
  }
  function build(text, track) {
    let x = 0; const out = [];
    for (const ch of text.toUpperCase()) {
      if (ch === " ") { x += track * 2.4; continue; }
      const g = G[ch]; if (!g) continue;
      out.push(shift(g.d, x));
      x += g.w + track;
    }
    return { d: out.join(" "), width: Math.max(0, x - track) };
  }
  /* Erzeugt ein fertiges <svg>. swPx = gewuenschte Strichstaerke in px (schlaegt sw). */
  function svg(text, opt) {
    const o = Object.assign({ cap: 40, track: 30, sw: 4, swPx: null, stroke: "#f4cf80", gradient: null }, opt || {});
    if (o.swPx) o.sw = o.swPx / (o.cap / 100);
    const b = build(text, o.track);
    const pad = o.sw / 2 + 1;
    const vbW = b.width + pad * 2, vbH = 100 + pad * 2;
    const k = o.cap / 100;
    const id = "wm" + Math.random().toString(36).slice(2, 7);
    const st = o.gradient ? 'url(#' + id + ')' : o.stroke;
    const def = o.gradient
      ? '<defs><linearGradient id="' + id + '" x1="0" y1="0" x2="0.4" y2="1">' +
        o.gradient.map(function (s, i, a) { return '<stop offset="' + (i / (a.length - 1)) + '" stop-color="' + s + '"/>'; }).join("") +
        '</linearGradient></defs>'
      : "";
    return '<svg viewBox="' + (-pad) + ' ' + (-pad) + ' ' + vbW + ' ' + vbH + '" width="' + (vbW * k).toFixed(1) +
      '" height="' + (vbH * k).toFixed(1) + '" role="img" aria-label="' + text + '">' + def +
      '<path d="' + b.d + '" fill="none" stroke="' + st + '" stroke-width="' + o.sw +
      '" stroke-linecap="butt" stroke-linejoin="miter"/></svg>';
  }
  return { svg: svg, build: build, glyphs: G };
})();
